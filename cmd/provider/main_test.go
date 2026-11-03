/*
Copyright 2021 Upbound Inc.
*/

package main

import (
	"context"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/logging"
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"github.com/pkg/errors"
	authv1 "k8s.io/api/authorization/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	clientfake "sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// No test in this file contacts a Kubernetes API server: the RBAC checks are
// fakes and the Kubernetes client is controller-runtime's fake client.

var errBoom = errors.New("boom")

// debugRecorder is a logging.Logger that records debug messages.
type debugRecorder struct {
	mu    sync.Mutex
	debug []string
}

func (l *debugRecorder) Info(string, ...any) {}

func (l *debugRecorder) Debug(msg string, _ ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.debug = append(l.debug, msg)
}

func (l *debugRecorder) WithValues(...any) logging.Logger { return l }

func (l *debugRecorder) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.debug)
}

// checkResult is the outcome of one fake RBAC check. A check with block set
// waits for the end of the window and fails with the context error, like a
// SelfSubjectAccessReview create cut short.
type checkResult struct {
	allowed bool
	err     error
	block   bool
}

func TestWaitUntilAllowed(t *testing.T) {
	const (
		timeout  = time.Minute
		interval = 7 * time.Second
	)
	denied := checkResult{}
	allowed := checkResult{allowed: true}
	failed := checkResult{err: errBoom}
	type want struct {
		allowed bool
		err     error
		checks  int
		elapsed time.Duration
		debugs  int
	}
	cases := map[string]struct {
		reason string
		// results are the outcomes of the checks in order. The last one
		// repeats.
		results []checkResult
		want    want
	}{
		"AllowedFirstTry": {
			reason:  "Permissions that are already granted must enable SafeStart at once.",
			results: []checkResult{allowed},
			want:    want{allowed: true, checks: 1},
		},
		"AllowedAfterDenials": {
			reason:  "Permissions granted a few seconds after startup, once Crossplane's RBAC manager has bound the ClusterRole, must still enable SafeStart.",
			results: []checkResult{denied, denied, denied, allowed},
			want:    want{allowed: true, checks: 4, elapsed: 3 * interval, debugs: 3},
		},
		"NeverAllowed": {
			reason:  "Permissions that are never granted must disable SafeStart after the window, without an error.",
			results: []checkResult{denied},
			want:    want{allowed: false, checks: 9, elapsed: timeout, debugs: 9},
		},
		"TransientErrorRetried": {
			reason:  "An API error followed by granted permissions must enable SafeStart.",
			results: []checkResult{failed, failed, allowed},
			want:    want{allowed: true, checks: 3, elapsed: 2 * interval, debugs: 2},
		},
		"PersistentErrorReturned": {
			reason:  "An API error on every check must be returned after the window, so startup still fails.",
			results: []checkResult{failed},
			want:    want{allowed: false, err: errBoom, checks: 9, elapsed: timeout, debugs: 9},
		},
		"ErrorThenDenied": {
			reason:  "When the last check was denied, an earlier API error must not be returned.",
			results: []checkResult{failed, denied},
			want:    want{allowed: false, checks: 9, elapsed: timeout, debugs: 9},
		},
		"DeniedThenError": {
			reason:  "When the last check failed, its API error must be returned.",
			results: []checkResult{denied, failed},
			want:    want{allowed: false, err: errBoom, checks: 9, elapsed: timeout, debugs: 9},
		},
		"CheckCutShortByWindow": {
			reason:  "A check cut short by the end of the window must not turn an earlier denial into an error.",
			results: []checkResult{denied, {block: true}},
			want:    want{allowed: false, checks: 2, elapsed: timeout, debugs: 1},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				log := &debugRecorder{}
				checks := 0
				check := func(ctx context.Context) (bool, error) {
					r := tc.results[min(checks, len(tc.results)-1)]
					checks++
					if r.block {
						<-ctx.Done()
						return false, ctx.Err()
					}
					return r.allowed, r.err
				}
				start := time.Now()
				got, err := waitUntilAllowed(t.Context(), log, timeout, interval, check)
				elapsed := time.Since(start)

				if got != tc.want.allowed {
					t.Errorf("\n%s\nwaitUntilAllowed(...): want %t, got %t", tc.reason, tc.want.allowed, got)
				}
				if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
					t.Errorf("\n%s\nwaitUntilAllowed(...) error: -want, +got:\n%s", tc.reason, diff)
				}
				if checks != tc.want.checks {
					t.Errorf("\n%s\nchecks: want %d, got %d", tc.reason, tc.want.checks, checks)
				}
				if elapsed != tc.want.elapsed {
					t.Errorf("\n%s\nelapsed: want %s, got %s", tc.reason, tc.want.elapsed, elapsed)
				}
				if got := log.count(); got != tc.want.debugs {
					t.Errorf("\n%s\ndebug log lines: want %d, got %d", tc.reason, tc.want.debugs, got)
				}
			})
		})
	}
}

func TestCRDWatchCheckWindow(t *testing.T) {
	if crdWatchCheckTimeout < time.Minute || crdWatchCheckTimeout > 5*time.Minute {
		t.Errorf("the SafeStart RBAC check window %s must outlast Crossplane's RBAC manager but not stall startup", crdWatchCheckTimeout)
	}
	if crdWatchCheckInterval <= 0 || crdWatchCheckInterval >= crdWatchCheckTimeout {
		t.Errorf("the SafeStart RBAC check interval %s must be positive and shorter than the window %s", crdWatchCheckInterval, crdWatchCheckTimeout)
	}
	if diff := cmp.Diff([]string{"get", "list", "watch"}, crdWatchVerbs); diff != "" {
		t.Errorf("SafeStart watches CRDs, so it needs get, list and watch on them: -want, +got:\n%s", diff)
	}
	if sessionLogoutTimeout <= 0 || sessionLogoutTimeout >= 30*time.Second {
		t.Errorf("the session logout timeout %s must be positive and well inside the default 30s termination grace period", sessionLogoutTimeout)
	}
}

func TestCRDWatchAllowed(t *testing.T) {
	type want struct {
		allowed bool
		err     bool
		verbs   []string
	}
	cases := map[string]struct {
		reason string
		denied string
		err    error
		want   want
	}{
		"AllVerbsAllowed": {
			reason: "get, list and watch on CustomResourceDefinitions must all be checked and allowed.",
			want:   want{allowed: true, verbs: crdWatchVerbs},
		},
		"WatchDenied": {
			reason: "A denied verb must report the permissions missing.",
			denied: crdWatchVerbs[2],
			want:   want{allowed: false, verbs: crdWatchVerbs},
		},
		"GetDenied": {
			reason: "The checks must stop at the first denied verb.",
			denied: crdWatchVerbs[0],
			want:   want{allowed: false, verbs: crdWatchVerbs[:1]},
		},
		"APIError": {
			reason: "A failed SelfSubjectAccessReview create must be returned as an error.",
			err:    errBoom,
			want:   want{allowed: false, err: true, verbs: crdWatchVerbs[:1]},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			s := runtime.NewScheme()
			if err := authv1.AddToScheme(s); err != nil {
				t.Fatalf("cannot build the scheme: %v", err)
			}
			var verbs []string
			c := clientfake.NewClientBuilder().WithScheme(s).WithInterceptorFuncs(interceptor.Funcs{
				Create: func(_ context.Context, _ client.WithWatch, obj client.Object, _ ...client.CreateOption) error {
					sar := obj.(*authv1.SelfSubjectAccessReview)
					attr := sar.Spec.ResourceAttributes
					if attr.Group != "apiextensions.k8s.io" || attr.Resource != "customresourcedefinitions" {
						t.Errorf("unexpected access review for %s/%s", attr.Group, attr.Resource)
					}
					verbs = append(verbs, attr.Verb)
					if tc.err != nil {
						return tc.err
					}
					sar.Status.Allowed = attr.Verb != tc.denied
					return nil
				},
			}).Build()

			got, err := crdWatchAllowed(t.Context(), c)
			if got != tc.want.allowed {
				t.Errorf("\n%s\ncrdWatchAllowed(...): want %t, got %t", tc.reason, tc.want.allowed, got)
			}
			if (err != nil) != tc.want.err || (tc.err != nil && !errors.Is(err, tc.err)) {
				t.Errorf("\n%s\ncrdWatchAllowed(...) error: want error %t wrapping %v, got %v", tc.reason, tc.want.err, tc.err, err)
			}
			if diff := cmp.Diff(tc.want.verbs, verbs); diff != "" {
				t.Errorf("\n%s\nchecked verbs: -want, +got:\n%s", tc.reason, diff)
			}
		})
	}
}
