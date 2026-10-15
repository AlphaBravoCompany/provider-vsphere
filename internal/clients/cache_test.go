/*
Copyright 2022 Upbound Inc.
*/

package clients

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/logging"
	"github.com/crossplane/crossplane-runtime/v2/pkg/resource"
	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"github.com/pkg/errors"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	ujresource "github.com/crossplane/upjet/v2/pkg/resource"
)

var (
	errBoom = errors.New("boom")

	testID  = ProviderConfigIdentity{Group: "vsphere.m.alphabravo.io", Kind: "ClusterProviderConfig", Name: "default"}
	otherID = ProviderConfigIdentity{Group: "vsphere.m.alphabravo.io", Kind: "ProviderConfig", Namespace: "team-a", Name: "default"}
)

type entryView struct {
	CredsHash string
	Meta      any
}

// view is the cache content without creation times.
func view(c *SessionCache) map[string]entryView {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := map[string]entryView{}
	for k, e := range c.entries {
		out[k] = entryView{CredsHash: e.credsHash, Meta: e.meta}
	}
	return out
}

func createdAt(t *testing.T, c *SessionCache, id ProviderConfigIdentity) time.Time {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[id.String()]
	if !ok {
		t.Fatalf("no cache entry for %s", id)
	}
	return e.createdAt
}

func mustNotCreate(t *testing.T) CreateFunc {
	return func(context.Context) (any, error) {
		t.Error("create must not be called")
		return nil, errBoom
	}
}

// logoutRecorder is a fake SessionCache logout that records every client it
// is asked to log out.
type logoutRecorder struct {
	mu    sync.Mutex
	metas []any
}

func (r *logoutRecorder) logout(_ context.Context, meta any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.metas = append(r.metas, meta)
	return nil
}

func (r *logoutRecorder) loggedOut() []any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]any{}, r.metas...)
}

// recordingLogger is a logging.Logger that records messages.
type recordingLogger struct {
	mu     sync.Mutex
	info   []string
	debug  []string
	infoKV [][]any
}

func (l *recordingLogger) Info(msg string, keysAndValues ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.info = append(l.info, msg)
	l.infoKV = append(l.infoKV, keysAndValues)
}

func (l *recordingLogger) Debug(msg string, _ ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.debug = append(l.debug, msg)
}

func (l *recordingLogger) WithValues(...any) logging.Logger { return l }

func (l *recordingLogger) messages() (info, debug []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string{}, l.info...), append([]string{}, l.debug...)
}

func (l *recordingLogger) infoKeysAndValues() [][]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([][]any{}, l.infoKV...)
}

func TestIsAuthOrSessionError(t *testing.T) {
	cases := map[string]struct {
		msg  string
		want bool
	}{
		"SessionNotAuthenticated": {msg: "observe failed: ServerFaultCode: The session is not authenticated.", want: true},
		"NotAuthenticatedFault":   {msg: "NotAuthenticated", want: true},
		"IncorrectPassword":       {msg: "ServerFaultCode: Cannot complete login due to an incorrect user name or password.", want: true},
		"InvalidLogin":            {msg: "vim.fault.InvalidLogin", want: true},
		"REST401":                 {msg: "POST https://vcenter.invalid/rest/com/vmware/cis/session: 401 Unauthorized", want: true},
		"VAPIUnauthenticated":     {msg: "com.vmware.vapi.std.errors.unauthenticated", want: true},
		"UpperCase":               {msg: "UNAUTHENTICATED", want: true},
		"NotFound":                {msg: "ServerFaultCode: The object 'vim.VirtualMachine:vm-42' has already been deleted or has not been completely created", want: false},
		"Timeout":                 {msg: "context deadline exceeded", want: false},
		"Empty":                   {msg: "", want: false},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := IsAuthOrSessionError(tc.msg); got != tc.want {
				t.Errorf("IsAuthOrSessionError(%q): want %t, got %t", tc.msg, tc.want, got)
			}
		})
	}
}

func TestSessionCacheGetOrCreate(t *testing.T) {
	cached := &fakeMeta{ID: 100}
	created := &fakeMeta{ID: 1}
	type args struct {
		entries   map[string]*sessionEntry
		id        ProviderConfigIdentity
		credsHash string
		createErr error
	}
	type want struct {
		meta    any
		err     error
		creates int
		entries map[string]entryView
	}
	cases := map[string]struct {
		reason string
		args   args
		want   want
	}{
		"ColdMissCreates": {
			reason: "The first request for an identity must create and cache a client (ST-001).",
			args:   args{id: testID, credsHash: "h1"},
			want: want{
				meta: created, creates: 1,
				entries: map[string]entryView{testID.String(): {CredsHash: "h1", Meta: created}},
			},
		},
		"SameIdentityAndHashReuses": {
			reason: "A request with the cached identity and credentials hash must reuse the client without a login.",
			args: args{
				entries: map[string]*sessionEntry{testID.String(): {credsHash: "h1", meta: cached, createdAt: time.Now()}},
				id:      testID, credsHash: "h1",
			},
			want: want{
				meta: cached, creates: 0,
				entries: map[string]entryView{testID.String(): {CredsHash: "h1", Meta: cached}},
			},
		},
		"ChangedHashRebuilds": {
			reason: "Changed credentials must build a new client and drop the old one (ST-002, AC-022).",
			args: args{
				entries: map[string]*sessionEntry{testID.String(): {credsHash: "h1", meta: cached, createdAt: time.Now()}},
				id:      testID, credsHash: "h2",
			},
			want: want{
				meta: created, creates: 1,
				entries: map[string]entryView{testID.String(): {CredsHash: "h2", Meta: created}},
			},
		},
		"IdentitiesAreSeparate": {
			reason: "A client cached for one ProviderConfig must not be used for another.",
			args: args{
				entries: map[string]*sessionEntry{otherID.String(): {credsHash: "h1", meta: cached, createdAt: time.Now()}},
				id:      testID, credsHash: "h1",
			},
			want: want{
				meta: created, creates: 1,
				entries: map[string]entryView{
					otherID.String(): {CredsHash: "h1", Meta: cached},
					testID.String():  {CredsHash: "h1", Meta: created},
				},
			},
		},
		"CreateErrorNotCached": {
			reason: "A failed login must not be cached.",
			args:   args{id: testID, credsHash: "h1", createErr: errBoom},
			want:   want{err: errBoom, creates: 1, entries: map[string]entryView{}},
		},
		"CreateErrorEvictsPreviousEntry": {
			reason: "A failed login with new credentials must also drop the client built from the old ones.",
			args: args{
				entries:   map[string]*sessionEntry{testID.String(): {credsHash: "h1", meta: cached, createdAt: time.Now()}},
				id:        testID,
				credsHash: "h2",
				createErr: errBoom,
			},
			want: want{err: errBoom, creates: 1, entries: map[string]entryView{}},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			c := NewSessionCache()
			for k, e := range tc.args.entries {
				c.entries[k] = e
			}
			creates := 0
			meta, err := c.GetOrCreate(context.Background(), tc.args.id, tc.args.credsHash, func(context.Context) (any, error) {
				creates++
				if tc.args.createErr != nil {
					return nil, tc.args.createErr
				}
				return created, nil
			})
			if diff := cmp.Diff(tc.want.err, err, cmpopts.EquateErrors()); diff != "" {
				t.Errorf("\n%s\nGetOrCreate(...) error: -want, +got:\n%s", tc.reason, diff)
			}
			if meta != tc.want.meta {
				t.Errorf("\n%s\nGetOrCreate(...) meta: want %v, got %v", tc.reason, tc.want.meta, meta)
			}
			if creates != tc.want.creates {
				t.Errorf("\n%s\ncreate calls: want %d, got %d", tc.reason, tc.want.creates, creates)
			}
			if diff := cmp.Diff(tc.want.entries, view(c)); diff != "" {
				t.Errorf("\n%s\ncache entries: -want, +got:\n%s", tc.reason, diff)
			}
			if len(c.inflight) != 0 {
				t.Errorf("\n%s\nin-flight logins left behind: %d", tc.reason, len(c.inflight))
			}
		})
	}
}

func TestSessionCacheEvictIfOlderThan(t *testing.T) {
	created := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	cases := map[string]struct {
		reason      string
		id          ProviderConfigIdentity
		t           time.Time
		wantEvicted bool
	}{
		"FailureAfterCreation": {
			reason: "A client created before the failure must be evicted (ST-003).",
			id:     testID, t: created.Add(time.Second), wantEvicted: true,
		},
		"FailureAtCreation": {
			reason: "A client created at the failure instant is not older and must be kept.",
			id:     testID, t: created, wantEvicted: false,
		},
		"FailureBeforeCreation": {
			reason: "A client rebuilt after the failure must not be evicted by that same failure.",
			id:     testID, t: created.Add(-time.Minute), wantEvicted: false,
		},
		"UnknownIdentity": {
			reason: "Evicting an identity with no entry is a no-op.",
			id:     otherID, t: created.Add(time.Hour), wantEvicted: false,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			c := NewSessionCache()
			c.entries[testID.String()] = &sessionEntry{credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: created}
			if got := c.EvictIfOlderThan(tc.id, tc.t); got != tc.wantEvicted {
				t.Errorf("\n%s\nEvictIfOlderThan(...): want %t, got %t", tc.reason, tc.wantEvicted, got)
			}
			if _, cached := c.entries[testID.String()]; cached == tc.wantEvicted {
				t.Errorf("\n%s\nentry cached after the call: want %t, got %t", tc.reason, !tc.wantEvicted, cached)
			}
		})
	}
}

func TestSessionCacheEvict(t *testing.T) {
	c := NewSessionCache()
	c.entries[testID.String()] = &sessionEntry{credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: time.Now()}
	c.entries[otherID.String()] = &sessionEntry{credsHash: "h1", meta: &fakeMeta{ID: 2}, createdAt: time.Now()}
	c.EvictIfOlderThan(testID, time.Now().Add(time.Second)) // both entries are older than this cutoff
	want := map[string]entryView{otherID.String(): {CredsHash: "h1", Meta: &fakeMeta{ID: 2}}}
	if diff := cmp.Diff(want, view(c)); diff != "" {
		t.Errorf("EvictIfOlderThan(...) must remove only that identity, even when other entries are older too: -want, +got:\n%s", diff)
	}
}

func TestSessionCacheConcurrentColdMiss(t *testing.T) {
	const goroutines = 50
	cases := map[string]struct {
		reason    string
		createErr error
	}{
		"Success": {
			reason: "Concurrent requests on one cold identity must cause exactly one login and share its client.",
		},
		"Failure": {
			reason:    "Concurrent requests waiting on a failed login must share its error instead of each logging in again.",
			createErr: errBoom,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c := NewSessionCache()
				release := make(chan struct{})
				var creates atomic.Int32
				create := func(context.Context) (any, error) {
					creates.Add(1)
					<-release
					if tc.createErr != nil {
						return nil, tc.createErr
					}
					return &fakeMeta{ID: 1}, nil
				}
				metas := make([]any, goroutines)
				errs := make([]error, goroutines)
				var wg sync.WaitGroup
				for i := range goroutines {
					wg.Go(func() {
						metas[i], errs[i] = c.GetOrCreate(t.Context(), testID, "h1", create)
					})
				}
				// Every goroutine is now blocked: one inside create, the
				// others waiting for it.
				synctest.Wait()
				close(release)
				wg.Wait()

				if got := creates.Load(); got != 1 {
					t.Errorf("\n%s\ncreate calls: want 1, got %d", tc.reason, got)
				}
				for i := range goroutines {
					if !errors.Is(errs[i], tc.createErr) {
						t.Errorf("\n%s\ngoroutine %d error: want %v, got %v", tc.reason, i, tc.createErr, errs[i])
					}
					if metas[i] != metas[0] {
						t.Errorf("\n%s\ngoroutine %d got a different client: %v vs %v", tc.reason, i, metas[i], metas[0])
					}
				}
			})
		})
	}
}

func TestSessionCacheWaiterContextCanceled(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache()
		release := make(chan struct{})
		go func() {
			_, _ = c.GetOrCreate(t.Context(), testID, "h1", func(context.Context) (any, error) {
				<-release
				return &fakeMeta{ID: 1}, nil
			})
		}()
		synctest.Wait()

		ctx, cancel := context.WithCancel(t.Context())
		var waitErr error
		done := make(chan struct{})
		go func() {
			_, waitErr = c.GetOrCreate(ctx, testID, "h1", mustNotCreate(t))
			close(done)
		}()
		synctest.Wait()
		cancel()
		<-done
		if !errors.Is(waitErr, context.Canceled) || !strings.Contains(waitErr.Error(), errWaitForSession) {
			t.Errorf("a waiter whose reconcile is canceled must return: want %q wrapping context.Canceled, got %v", errWaitForSession, waitErr)
		}

		close(release)
		synctest.Wait()
		meta, err := c.GetOrCreate(t.Context(), testID, "h1", mustNotCreate(t))
		if err != nil || meta == nil {
			t.Errorf("the login must still be cached after a waiter gave up: meta %v, err %v", meta, err)
		}
	})
}

func TestSessionCacheCreatePanicReleasesIdentity(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache()
		release := make(chan struct{})
		go func() {
			defer func() { _ = recover() }()
			_, _ = c.GetOrCreate(t.Context(), testID, "h1", func(context.Context) (any, error) {
				<-release
				panic("provider bug")
			})
		}()
		synctest.Wait()

		var waitErr error
		done := make(chan struct{})
		go func() {
			_, waitErr = c.GetOrCreate(t.Context(), testID, "h1", mustNotCreate(t))
			close(done)
		}()
		synctest.Wait()
		close(release)
		<-done
		if waitErr == nil || !strings.Contains(waitErr.Error(), errCreatePanicked) {
			t.Errorf("a waiter on a panicked login: want error %q, got %v", errCreatePanicked, waitErr)
		}
		if len(c.inflight) != 0 || len(c.entries) != 0 {
			t.Fatalf("a panicked login must leave nothing behind: inflight %d, entries %d", len(c.inflight), len(c.entries))
		}

		creates := 0
		if _, err := c.GetOrCreate(t.Context(), testID, "h1", func(context.Context) (any, error) {
			creates++
			return &fakeMeta{ID: 2}, nil
		}); err != nil || creates != 1 {
			t.Errorf("the identity must not stay blocked after a panic: creates %d, err %v", creates, err)
		}
	})
}

func TestNewSessionCacheLogoutDelay(t *testing.T) {
	if got := NewSessionCache().logoutDelay; got != DefaultLogoutDelay {
		t.Errorf("default logout delay: want %s, got %s", DefaultLogoutDelay, got)
	}
	if DefaultLogoutDelay <= time.Hour {
		t.Errorf("the default logout delay %s must outlast upjet's one-hour async operation timeout", DefaultLogoutDelay)
	}
	if got := NewSessionCache(WithLogoutDelay(time.Second)).logoutDelay; got != time.Second {
		t.Errorf("WithLogoutDelay(1s): want 1s, got %s", got)
	}
}

func TestSessionCacheLogoutTiming(t *testing.T) {
	const delay = 5 * time.Minute
	createNew := func(context.Context) (any, error) { return &fakeMeta{ID: 2}, nil }
	cases := map[string]struct {
		reason string
		opts   []SessionCacheOption
		act    func(ctx context.Context, c *SessionCache)
		// wantAfter is how long after act the cached client must be logged
		// out. A negative value means never.
		wantAfter time.Duration
	}{
		"ReplacedAfterDelay": {
			reason: "A client replaced after a credentials change must stay usable for the logout delay, then be logged out (ST-002).",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(ctx context.Context, c *SessionCache) {
				_, _ = c.GetOrCreate(ctx, testID, "h2", createNew)
			},
			wantAfter: delay,
		},
		"ReplacedAfterDefaultDelay": {
			reason: "Without WithLogoutDelay a replaced client must be logged out after DefaultLogoutDelay.",
			act: func(ctx context.Context, c *SessionCache) {
				_, _ = c.GetOrCreate(ctx, testID, "h2", createNew)
			},
			wantAfter: DefaultLogoutDelay,
		},
		"AuthEvictedAfterDelay": {
			reason: "A client evicted after a session failure must be logged out after the logout delay (ST-003).",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(_ context.Context, c *SessionCache) {
				c.EvictIfOlderThan(testID, time.Now())
			},
			wantAfter: delay,
		},
		"EvictedAfterDelay": {
			reason: "A client evicted by the SetupFn's auth-condition check (evictOnAuthFailure) must be logged out after the logout delay (ST-003).",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(_ context.Context, c *SessionCache) {
				mg := modernMR("team-a", "vm", "ClusterProviderConfig", "default")
				mg.SetConditions(xpv2.ReconcileError(errors.New("ServerFaultCode: The session is not authenticated.")))
				evictOnAuthFailure(c, testID, mg)
			},
			wantAfter: delay,
		},
		"FailedCreateAfterDelay": {
			reason: "A client dropped because the login with new credentials failed must stay usable for the logout delay, as async operations may still use it, then be logged out.",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(ctx context.Context, c *SessionCache) {
				_, _ = c.GetOrCreate(ctx, testID, "h2", func(context.Context) (any, error) { return nil, errBoom })
			},
			wantAfter: delay,
		},
		"DeletedProviderConfigAtOnce": {
			reason: "The client of a deleted ProviderConfig must be logged out at once.",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(ctx context.Context, c *SessionCache) {
				c.EvictDeleted(ctx, func(context.Context, ProviderConfigIdentity) bool { return true })
			},
			wantAfter: 0,
		},
		"ReusedNeverLoggedOut": {
			reason: "A client that is reused must never be logged out.",
			opts:   []SessionCacheOption{WithLogoutDelay(delay)},
			act: func(ctx context.Context, c *SessionCache) {
				_, _ = c.GetOrCreate(ctx, testID, "h1", createNew)
				c.EvictDeleted(ctx, func(context.Context, ProviderConfigIdentity) bool { return false })
			},
			wantAfter: -1,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c := NewSessionCache(tc.opts...)
				c.sweepInterval = 0
				rec := &logoutRecorder{}
				c.logout = rec.logout
				old := &fakeMeta{ID: 1}
				c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: old, createdAt: time.Now().Add(-time.Minute)}

				tc.act(t.Context(), c)
				synctest.Wait()
				if tc.wantAfter > 0 {
					time.Sleep(tc.wantAfter - time.Nanosecond)
					synctest.Wait()
					if got := rec.loggedOut(); len(got) != 0 {
						t.Fatalf("\n%s\nlogged out %v before the logout delay ended", tc.reason, got)
					}
					time.Sleep(time.Nanosecond)
					synctest.Wait()
				}
				var want []any
				if tc.wantAfter >= 0 {
					want = []any{old}
				}
				if diff := cmp.Diff(want, rec.loggedOut(), cmpopts.EquateEmpty()); diff != "" {
					t.Errorf("\n%s\nlogged out clients: -want, +got:\n%s", tc.reason, diff)
				}
				// No client is ever logged out twice.
				time.Sleep(2 * DefaultLogoutDelay)
				synctest.Wait()
				if diff := cmp.Diff(want, rec.loggedOut(), cmpopts.EquateEmpty()); diff != "" {
					t.Errorf("\n%s\nlogged out clients much later: -want, +got:\n%s", tc.reason, diff)
				}
			})
		})
	}
}

func TestSessionCacheLogoutNeverBlocksReconcile(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache(WithLogoutDelay(0))
		c.sweepInterval = 0
		var mu sync.Mutex
		var started int
		var ended []error
		// Every logout hangs like a vCenter that never answers.
		c.logout = func(ctx context.Context, _ any) error {
			mu.Lock()
			started++
			mu.Unlock()
			<-ctx.Done()
			mu.Lock()
			ended = append(ended, ctx.Err())
			mu.Unlock()
			return nil
		}
		n := 0
		create := func(context.Context) (any, error) {
			n++
			return &fakeMeta{ID: n}, nil
		}
		fail := func(context.Context) (any, error) { return nil, errBoom }
		ctx := t.Context()

		// Fake time moves only while every goroutine of the test is blocked,
		// so it stays put unless one of these calls waits for a logout.
		start := time.Now()
		_, _ = c.GetOrCreate(ctx, testID, "h1", create)
		_, _ = c.GetOrCreate(ctx, testID, "h2", create) // replaces client 1
		_, _ = c.GetOrCreate(ctx, testID, "h3", fail)   // drops client 2
		_, _ = c.GetOrCreate(ctx, testID, "h1", create)
		c.EvictIfOlderThan(testID, time.Now().Add(time.Nanosecond)) // drops client 3
		_, _ = c.GetOrCreate(ctx, otherID, "h1", create)
		c.EvictIfOlderThan(otherID, time.Now().Add(time.Nanosecond)) // drops client 4
		_, _ = c.GetOrCreate(ctx, testID, "h1", create)
		c.EvictDeleted(ctx, func(context.Context, ProviderConfigIdentity) bool { return true }) // drops client 5
		meta, err := c.GetOrCreate(ctx, testID, "h1", create)
		if elapsed := time.Since(start); elapsed != 0 {
			t.Errorf("cache calls waited %s for hanging logouts; they must never block a reconcile", elapsed)
		}
		if err != nil || meta.(*fakeMeta).ID != 6 {
			t.Errorf("a reconcile while logouts hang must still get a new client: meta %v, err %v", meta, err)
		}

		synctest.Wait()
		mu.Lock()
		gotStarted, gotEnded := started, len(ended)
		mu.Unlock()
		if gotStarted != 5 || gotEnded != 0 {
			t.Fatalf("logouts in progress: want 5 started and 0 ended, got %d and %d", gotStarted, gotEnded)
		}

		time.Sleep(logoutTimeout)
		synctest.Wait()
		mu.Lock()
		defer mu.Unlock()
		if len(ended) != 5 {
			t.Fatalf("every hanging logout must end at the logout timeout: want 5 ended, got %d", len(ended))
		}
		for _, err := range ended {
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Errorf("a hanging logout must be canceled by its %s timeout, got %v", logoutTimeout, err)
			}
		}
	})
}

func TestSessionCacheIncompleteLogoutReportedOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		log := &recordingLogger{}
		c := NewSessionCache(WithLogoutDelay(0))
		c.log = log
		var calls atomic.Int32
		c.logout = func(context.Context, any) error {
			calls.Add(1)
			return errors.New(errNoVIMClientField)
		}
		for i := range 3 {
			id := testID
			id.Name = string(rune('a' + i))
			c.entries[id.String()] = &sessionEntry{id: id, credsHash: "h1", meta: &fakeMeta{ID: i}, createdAt: time.Now()}
			c.EvictIfOlderThan(id, time.Now().Add(time.Nanosecond))
		}
		synctest.Wait()

		if got := calls.Load(); got != 3 {
			t.Errorf("every client that left the cache must still be logged out as far as possible: want 3 logouts, got %d", got)
		}
		info, _ := log.messages()
		if diff := cmp.Diff([]string{msgLogoutIncomplete}, info); diff != "" {
			t.Errorf("an incomplete logout must be reported exactly once: -want, +got:\n%s", diff)
		}
		if kv := log.infoKeysAndValues(); len(kv) != 1 || len(kv[0]) != 2 || kv[0][1] != errNoVIMClientField {
			t.Errorf("the report must give the reason %q, got %v", errNoVIMClientField, kv)
		}
	})
}

func TestSessionCacheLogoutPanicRecovered(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		log := &recordingLogger{}
		c := NewSessionCache(WithLogoutDelay(0))
		c.log = log
		c.logout = func(context.Context, any) error { panic("provider bug") }
		c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: time.Now()}
		c.EvictIfOlderThan(testID, time.Now().Add(time.Nanosecond))
		synctest.Wait()

		info, debug := log.messages()
		if diff := cmp.Diff([]string{msgLogoutPanicked}, debug); diff != "" {
			t.Errorf("a panicking logout must be recovered and logged at debug level: -want, +got:\n%s", diff)
		}
		if len(info) != 0 {
			t.Errorf("a panicking logout must not be reported as incomplete: %v", info)
		}

		rec := &logoutRecorder{}
		c.logout = rec.logout
		c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: &fakeMeta{ID: 2}, createdAt: time.Now()}
		c.EvictIfOlderThan(testID, time.Now().Add(time.Nanosecond))
		synctest.Wait()
		if diff := cmp.Diff([]any{&fakeMeta{ID: 2}}, rec.loggedOut()); diff != "" {
			t.Errorf("logouts must keep working after a panic: -want, +got:\n%s", diff)
		}
	})
}

func TestSessionCacheEvictDeleted(t *testing.T) {
	t.Run("DeletedDroppedOthersKept", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			c := NewSessionCache()
			rec := &logoutRecorder{}
			c.logout = rec.logout
			c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: time.Now()}
			c.entries[otherID.String()] = &sessionEntry{id: otherID, credsHash: "h1", meta: &fakeMeta{ID: 2}, createdAt: time.Now()}
			var checked []ProviderConfigIdentity
			c.EvictDeleted(t.Context(), func(_ context.Context, id ProviderConfigIdentity) bool {
				checked = append(checked, id)
				return id == testID
			})
			synctest.Wait()

			if diff := cmp.Diff([]ProviderConfigIdentity{otherID, testID}, checked, cmpopts.SortSlices(func(a, b ProviderConfigIdentity) bool { return a.String() < b.String() })); diff != "" {
				t.Errorf("every cached identity must be checked: -want, +got:\n%s", diff)
			}
			if diff := cmp.Diff(map[string]entryView{otherID.String(): {CredsHash: "h1", Meta: &fakeMeta{ID: 2}}}, view(c)); diff != "" {
				t.Errorf("only the deleted ProviderConfig's entry must be dropped: -want, +got:\n%s", diff)
			}
			if diff := cmp.Diff([]any{&fakeMeta{ID: 1}}, rec.loggedOut()); diff != "" {
				t.Errorf("the deleted ProviderConfig's client must be logged out at once: -want, +got:\n%s", diff)
			}
		})
	})
	t.Run("AtMostOncePerInterval", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			c := NewSessionCache()
			c.logout = (&logoutRecorder{}).logout
			c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: time.Now()}
			checks := 0
			notDeleted := func(context.Context, ProviderConfigIdentity) bool {
				checks++
				return false
			}
			c.EvictDeleted(t.Context(), notDeleted)
			time.Sleep(defaultSweepInterval - time.Nanosecond)
			c.EvictDeleted(t.Context(), notDeleted)
			if checks != 1 {
				t.Errorf("a sweep within %s of the last one must not look anything up: lookups want 1, got %d", defaultSweepInterval, checks)
			}
			time.Sleep(time.Nanosecond)
			c.EvictDeleted(t.Context(), notDeleted)
			if checks != 2 {
				t.Errorf("a sweep %s after the last one must look up again: lookups want 2, got %d", defaultSweepInterval, checks)
			}
		})
	})
	t.Run("EntryReplacedDuringLookupKept", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			const delay = 5 * time.Minute
			c := NewSessionCache(WithLogoutDelay(delay))
			rec := &logoutRecorder{}
			c.logout = rec.logout
			old, recreated := &fakeMeta{ID: 1}, &fakeMeta{ID: 2}
			c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: old, createdAt: time.Now()}
			// While the sweep looks the ProviderConfig up, it is recreated
			// with other credentials and a reconcile caches a client for it.
			c.EvictDeleted(t.Context(), func(ctx context.Context, _ ProviderConfigIdentity) bool {
				_, _ = c.GetOrCreate(ctx, testID, "h2", func(context.Context) (any, error) { return recreated, nil })
				return true
			})
			synctest.Wait()
			if diff := cmp.Diff(map[string]entryView{testID.String(): {CredsHash: "h2", Meta: recreated}}, view(c)); diff != "" {
				t.Errorf("the sweep must keep an entry created after its lookup: -want, +got:\n%s", diff)
			}
			if got := rec.loggedOut(); len(got) != 0 {
				t.Errorf("the replaced client must be logged out by the replacement, after the delay, not at once by the sweep: %v", got)
			}
			time.Sleep(delay)
			synctest.Wait()
			if diff := cmp.Diff([]any{old}, rec.loggedOut()); diff != "" {
				t.Errorf("the replaced client must be logged out exactly once: -want, +got:\n%s", diff)
			}
		})
	})
}

func TestSessionCacheConcurrentChurn(t *testing.T) {
	// Run with -race: GetOrCreate with rotating credentials, failing logins,
	// sweeps and evictions run concurrently on two identities. Afterwards
	// every client that was ever created must have been logged out exactly
	// once: none leaked, none logged out twice.
	synctest.Test(t, func(t *testing.T) {
		const goroutines, rounds = 16, 200
		const delay = time.Minute
		c := NewSessionCache(WithLogoutDelay(delay))
		c.sweepInterval = 0
		var mu sync.Mutex
		created := map[*fakeMeta]bool{}
		loggedOut := map[*fakeMeta]int{}
		c.logout = func(_ context.Context, meta any) error {
			mu.Lock()
			defer mu.Unlock()
			loggedOut[meta.(*fakeMeta)]++
			return nil
		}
		var next atomic.Int32
		create := func(context.Context) (any, error) {
			n := int(next.Add(1))
			if n%7 == 0 {
				return nil, errBoom
			}
			m := &fakeMeta{ID: n}
			mu.Lock()
			created[m] = true
			mu.Unlock()
			return m, nil
		}
		ids := []ProviderConfigIdentity{testID, otherID}
		hashes := []string{"h1", "h2", "h3"}
		otherDeleted := func(_ context.Context, id ProviderConfigIdentity) bool { return id == otherID }

		var wg sync.WaitGroup
		for g := range goroutines {
			wg.Go(func() {
				for i := range rounds {
					id := ids[(g+i)%len(ids)]
					switch (g*7 + i) % 6 {
					case 0, 1, 2:
						_, _ = c.GetOrCreate(t.Context(), id, hashes[(g*3+i)%len(hashes)], create)
					case 3:
						c.EvictDeleted(t.Context(), otherDeleted)
					case 4, 5:
						c.EvictIfOlderThan(id, time.Now().Add(time.Nanosecond))
					}
				}
			})
		}
		wg.Wait()
		for _, id := range ids {
			c.EvictIfOlderThan(id, time.Now().Add(time.Nanosecond))
		}
		time.Sleep(delay)
		synctest.Wait()

		mu.Lock()
		defer mu.Unlock()
		if len(created) == 0 {
			t.Fatal("no client was created")
		}
		for m := range created {
			if n := loggedOut[m]; n != 1 {
				t.Errorf("client %d was logged out %d times, want exactly once", m.ID, n)
			}
		}
		for m := range loggedOut {
			if !created[m] {
				t.Errorf("client %d was logged out but never created", m.ID)
			}
		}
		entries := len(view(c))
		c.mu.Lock()
		inflight := len(c.inflight)
		c.mu.Unlock()
		if entries != 0 || inflight != 0 {
			t.Errorf("the cache must be empty after evicting every identity: entries %d, in-flight %d", entries, inflight)
		}
	})
}

// cpcObjects is a ClusterProviderConfig "default" plus its credentials Secret.
func cpcObjects(data string) []client.Object {
	return []client.Object{clusterProviderConfig("default"), credentialsSecret(testSecretNS, testSecretName, data)}
}

func TestSetupFnReusesClientPerProviderConfig(t *testing.T) {
	cases := map[string]struct {
		reason      string
		objs        []client.Object
		mgs         []resource.Managed
		wantMetaIDs []int
	}{
		"NamespacedMRsShareClusterProviderConfig": {
			reason: "MRs in different namespaces on one ClusterProviderConfig must share one login (OT-014, NFR-101).",
			objs:   cpcObjects(pioneerPayload),
			mgs: []resource.Managed{
				modernMR("team-a", "vm-1", "ClusterProviderConfig", "default"),
				modernMR("team-b", "vm-2", "ClusterProviderConfig", "default"),
				modernMR("team-a", "vm-1", "ClusterProviderConfig", "default"),
			},
			wantMetaIDs: []int{1, 1, 1},
		},
		"LegacyMRsShareProviderConfig": {
			reason:      "Cluster-scoped MRs on one ProviderConfig must share one login (OT-014).",
			objs:        []client.Object{legacyProviderConfig("default"), credentialsSecret(testSecretNS, testSecretName, pioneerPayload)},
			mgs:         []resource.Managed{legacyMR("vm-1", "default"), legacyMR("vm-2", "default")},
			wantMetaIDs: []int{1, 1},
		},
		"NamespacedProviderConfigsAreSeparate": {
			reason: "Same-named ProviderConfigs in two namespaces are different configs and get separate clients.",
			objs: []client.Object{
				namespacedProviderConfig("team-a", "pc", "team-a"), credentialsSecret("team-a", testSecretName, pioneerPayload),
				namespacedProviderConfig("team-b", "pc", "team-b"), credentialsSecret("team-b", testSecretName, pioneerPayload),
			},
			mgs: []resource.Managed{
				modernMR("team-a", "vm", "ProviderConfig", "pc"),
				modernMR("team-b", "vm", "ProviderConfig", "pc"),
				modernMR("team-a", "vm", "ProviderConfig", "pc"),
			},
			wantMetaIDs: []int{1, 2, 1},
		},
		"SameNameDifferentKindsAreSeparate": {
			reason: "A cluster ProviderConfig and a ClusterProviderConfig with the same name are different configs.",
			objs: []client.Object{
				legacyProviderConfig("default"), clusterProviderConfig("default"),
				credentialsSecret(testSecretNS, testSecretName, pioneerPayload),
			},
			mgs:         []resource.Managed{legacyMR("vm", "default"), modernMR("team-a", "vm", "ClusterProviderConfig", "default")},
			wantMetaIDs: []int{1, 2},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			rec := &configureRecorder{}
			setupFn := TerraformSetupBuilder(WithSessionCache(NewSessionCache()), WithConfigureFunc(rec.configure))
			kube := newFakeClient(t, tc.objs...)
			got := make([]int, 0, len(tc.mgs))
			for _, mg := range tc.mgs {
				ps, err := setupFn(context.Background(), kube, mg)
				if err != nil {
					t.Fatalf("\n%s\nsetupFn(...): unexpected error: %v", tc.reason, err)
				}
				got = append(got, ps.Meta.(*fakeMeta).ID)
			}
			if diff := cmp.Diff(tc.wantMetaIDs, got); diff != "" {
				t.Errorf("\n%s\nclient per reconcile (configure call number): -want, +got:\n%s", tc.reason, diff)
			}
		})
	}
}

func TestSetupFnRebuildsOnCredentialChange(t *testing.T) {
	const rotated = "fake-password-rotated"
	rec := &configureRecorder{}
	setupFn := TerraformSetupBuilder(WithSessionCache(NewSessionCache()), WithConfigureFunc(rec.configure))
	kube := newFakeClient(t, cpcObjects(pioneerPayload)...)
	vm1 := modernMR("team-a", "vm-1", "ClusterProviderConfig", "default")
	vm2 := modernMR("team-b", "vm-2", "ClusterProviderConfig", "default")
	ctx := context.Background()

	before, err := setupFn(ctx, kube, vm1)
	if err != nil {
		t.Fatalf("setupFn(...) before rotation: %v", err)
	}

	s := &corev1.Secret{}
	if err := kube.Get(ctx, client.ObjectKey{Namespace: testSecretNS, Name: testSecretName}, s); err != nil {
		t.Fatalf("cannot get Secret: %v", err)
	}
	s.Data[testSecretKey] = []byte(strings.Replace(pioneerPayload, fakePassword, rotated, 1))
	if err := kube.Update(ctx, s); err != nil {
		t.Fatalf("cannot update Secret: %v", err)
	}

	after1, err := setupFn(ctx, kube, vm1)
	if err != nil {
		t.Fatalf("setupFn(...) after rotation: %v", err)
	}
	after2, err := setupFn(ctx, kube, vm2)
	if err != nil {
		t.Fatalf("setupFn(...) after rotation, second MR: %v", err)
	}

	if rec.count() != 2 {
		t.Errorf("rotating the password must cause exactly one new login (ST-002): configure calls want 2, got %d", rec.count())
	}
	if after1.Meta == before.Meta || after2.Meta == before.Meta {
		t.Errorf("the client built from the old password must not be reused after rotation (AC-022)")
	}
	if after1.Meta != after2.Meta {
		t.Errorf("MRs on the rotated ProviderConfig must share the new client")
	}
	if got := rec.calls[1][keyPassword]; got != rotated {
		t.Errorf("the new client must be configured with the rotated password")
	}
}

func TestSetupFnEvictsOnAuthFailure(t *testing.T) {
	cases := map[string]struct {
		reason string
		// cond builds the condition the failed reconcile left on the MR,
		// given the creation time of the cached client.
		cond           func(created time.Time) xpv2.Condition
		wantConfigures int
	}{
		"SyncedAuthFailureAfterCreation": {
			reason: "Synced=False with a session error observed after the client was built must evict it before the retry (OT-015, ST-003).",
			cond: func(time.Time) xpv2.Condition {
				return xpv2.ReconcileError(errors.New("observe failed: cannot run refresh: ServerFaultCode: The session is not authenticated."))
			},
			wantConfigures: 2,
		},
		"AsyncAuthFailureAfterCreation": {
			reason: "LastAsyncOperation=False with an authentication error must evict the client (ST-003).",
			cond: func(time.Time) xpv2.Condition {
				return xpv2.Condition{
					Type:               ujresource.TypeLastAsyncOperation,
					Status:             corev1.ConditionFalse,
					Reason:             ujresource.ReasonApplyFailure,
					LastTransitionTime: metav1.Now(),
					Message:            "apply failed: POST https://vcenter.invalid/rest/com/vmware/cis/tagging/tag: 401 Unauthorized",
				}
			},
			wantConfigures: 2,
		},
		"AuthFailureInSameSecondAsCreation": {
			reason: "Condition times have second precision, so a failure stamped in the client's creation second must still evict it.",
			cond: func(created time.Time) xpv2.Condition {
				c := xpv2.ReconcileError(errors.New("NotAuthenticated"))
				c.LastTransitionTime = metav1.NewTime(created.Truncate(time.Second))
				return c
			},
			wantConfigures: 2,
		},
		"AuthFailureBeforeCreation": {
			reason: "A stale failure from before the client was built must not evict it, so a rebuilt client is not evicted again.",
			cond: func(created time.Time) xpv2.Condition {
				c := xpv2.ReconcileError(errors.New("NotAuthenticated"))
				c.LastTransitionTime = metav1.NewTime(created.Add(-time.Hour))
				return c
			},
			wantConfigures: 1,
		},
		"NonAuthFailure": {
			reason: "A failure that is not an authentication or session error must keep the client.",
			cond: func(time.Time) xpv2.Condition {
				return xpv2.ReconcileError(errors.New("ServerFaultCode: The object 'vim.VirtualMachine:vm-42' has already been deleted"))
			},
			wantConfigures: 1,
		},
		"SyncedTrue": {
			reason: "A healthy resource must keep the client.",
			cond: func(time.Time) xpv2.Condition {
				return xpv2.ReconcileSuccess()
			},
			wantConfigures: 1,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			rec := &configureRecorder{}
			cache := NewSessionCache()
			setupFn := TerraformSetupBuilder(WithSessionCache(cache), WithConfigureFunc(rec.configure))
			kube := newFakeClient(t, cpcObjects(pioneerPayload)...)
			vm := modernMR("team-a", "vm", "ClusterProviderConfig", "default")

			first, err := setupFn(context.Background(), kube, vm)
			if err != nil {
				t.Fatalf("\n%s\nfirst setupFn(...): %v", tc.reason, err)
			}
			vm.SetConditions(tc.cond(createdAt(t, cache, testID)))
			second, err := setupFn(context.Background(), kube, vm)
			if err != nil {
				t.Fatalf("\n%s\nsecond setupFn(...): %v", tc.reason, err)
			}

			if got := rec.count(); got != tc.wantConfigures {
				t.Errorf("\n%s\nconfigure calls: want %d, got %d", tc.reason, tc.wantConfigures, got)
			}
			if rebuilt := first.Meta != second.Meta; rebuilt != (tc.wantConfigures == 2) {
				t.Errorf("\n%s\nclient rebuilt: want %t, got %t", tc.reason, tc.wantConfigures == 2, rebuilt)
			}
		})
	}
}

func TestSetupFnDoesNotCacheConfigureFailure(t *testing.T) {
	rec := &configureRecorder{
		failFirst: 1,
		err:       errors.New("ServerFaultCode: Cannot complete login due to an incorrect user name or password."),
	}
	cache := NewSessionCache()
	setupFn := TerraformSetupBuilder(WithSessionCache(cache), WithConfigureFunc(rec.configure))
	kube := newFakeClient(t, cpcObjects(pioneerPayload)...)
	vm := modernMR("team-a", "vm", "ClusterProviderConfig", "default")

	if _, err := setupFn(context.Background(), kube, vm); err == nil {
		t.Fatal("a failed login must fail the SetupFn")
	}
	if len(view(cache)) != 0 {
		t.Errorf("a failed login must not be cached")
	}
	for range 2 {
		if _, err := setupFn(context.Background(), kube, vm); err != nil {
			t.Fatalf("setupFn(...) after the login recovered: %v", err)
		}
	}
	if got := rec.count(); got != 2 {
		t.Errorf("the reconcile after a failed login must log in again, then reuse the client: configure calls want 2, got %d", got)
	}
}

// byID orders fakeMeta clients by ID.
var byID = cmpopts.SortSlices(func(a, b any) bool { return a.(*fakeMeta).ID < b.(*fakeMeta).ID })

func TestSessionCacheClose(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache(WithLogoutDelay(5 * time.Minute))
		rec := &logoutRecorder{}
		c.logout = rec.logout
		n := 0
		create := func(context.Context) (any, error) {
			n++
			return &fakeMeta{ID: n}, nil
		}
		ctx := t.Context()
		_, _ = c.GetOrCreate(ctx, testID, "h1", create)
		_, _ = c.GetOrCreate(ctx, testID, "h2", create) // client 1 waits for its delayed logout
		_, _ = c.GetOrCreate(ctx, otherID, "h1", create)
		c.EvictIfOlderThan(otherID, time.Now().Add(time.Nanosecond)) // client 3 waits for its delayed logout
		_, _ = c.GetOrCreate(ctx, otherID, "h1", create)
		synctest.Wait()
		if got := rec.loggedOut(); len(got) != 0 {
			t.Fatalf("no client may be logged out before its delay: %v", got)
		}

		start := time.Now()
		if err := c.Close(ctx); err != nil {
			t.Errorf("Close(...): %v", err)
		}
		if elapsed := time.Since(start); elapsed != 0 {
			t.Errorf("Close must log out at once, not after the logout delay: took %s", elapsed)
		}
		want := []any{&fakeMeta{ID: 1}, &fakeMeta{ID: 2}, &fakeMeta{ID: 3}, &fakeMeta{ID: 4}}
		if diff := cmp.Diff(want, rec.loggedOut(), byID); diff != "" {
			t.Errorf("Close must log out every cached client and every client waiting for its delayed logout: -want, +got:\n%s", diff)
		}
		if got := view(c); len(got) != 0 {
			t.Errorf("Close must empty the cache, got %v", got)
		}

		// The delayed logouts that Close preempted must not log out again,
		// and closing again must do nothing.
		time.Sleep(2 * DefaultLogoutDelay)
		synctest.Wait()
		if err := c.Close(ctx); err != nil {
			t.Errorf("a second Close(...): %v", err)
		}
		if diff := cmp.Diff(want, rec.loggedOut(), byID); diff != "" {
			t.Errorf("every client must be logged out exactly once: -want, +got:\n%s", diff)
		}
	})
}

func TestSessionCacheCloseRacesDelayedLogout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache(WithLogoutDelay(0))
		var mu sync.Mutex
		count := map[any]int{}
		c.logout = func(_ context.Context, meta any) error {
			mu.Lock()
			defer mu.Unlock()
			count[meta]++
			return nil
		}
		// Each client's delayed logout is due at once, so its timer races
		// Close for it.
		for i := range 100 {
			id := testID
			id.Name = fmt.Sprintf("pc-%d", i)
			c.entries[id.String()] = &sessionEntry{id: id, credsHash: "h1", meta: &fakeMeta{ID: i}, createdAt: time.Now()}
			c.EvictIfOlderThan(id, time.Now().Add(time.Nanosecond))
		}
		if err := c.Close(t.Context()); err != nil {
			t.Errorf("Close(...): %v", err)
		}
		synctest.Wait()

		mu.Lock()
		defer mu.Unlock()
		if len(count) != 100 {
			t.Errorf("every client must be logged out: want 100, got %d", len(count))
		}
		for meta, n := range count {
			if n != 1 {
				t.Errorf("client %v was logged out %d times, want exactly once", meta, n)
			}
		}
	})
}

func TestSessionCacheCloseContext(t *testing.T) {
	cases := map[string]struct {
		reason  string
		ctx     func(ctx context.Context) (context.Context, context.CancelFunc)
		want    error
		elapsed time.Duration
	}{
		"Deadline": {
			reason: "Close must return at its context deadline even when a logout hangs, so shutdown never hangs.",
			ctx: func(ctx context.Context) (context.Context, context.CancelFunc) {
				return context.WithTimeout(ctx, 10*time.Second)
			},
			want:    context.DeadlineExceeded,
			elapsed: 10 * time.Second,
		},
		"Canceled": {
			reason: "Close must return at once with a canceled context.",
			ctx: func(ctx context.Context) (context.Context, context.CancelFunc) {
				ctx, cancel := context.WithCancel(ctx)
				cancel()
				return ctx, cancel
			},
			want: context.Canceled,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c := NewSessionCache()
				release := make(chan struct{})
				var started atomic.Int32
				// Every logout hangs and ignores its context, like a vCenter
				// call stuck in a broken connection.
				c.logout = func(context.Context, any) error {
					started.Add(1)
					<-release
					return nil
				}
				c.entries[testID.String()] = &sessionEntry{id: testID, credsHash: "h1", meta: &fakeMeta{ID: 1}, createdAt: time.Now()}
				c.entries[otherID.String()] = &sessionEntry{id: otherID, credsHash: "h1", meta: &fakeMeta{ID: 2}, createdAt: time.Now()}

				ctx, cancel := tc.ctx(t.Context())
				defer cancel()
				start := time.Now()
				err := c.Close(ctx)
				if elapsed := time.Since(start); elapsed != tc.elapsed {
					t.Errorf("\n%s\nClose(...) took %s, want %s", tc.reason, elapsed, tc.elapsed)
				}
				if !errors.Is(err, tc.want) || !strings.Contains(err.Error(), errCloseCanceled) {
					t.Errorf("\n%s\nClose(...): want %q wrapping %v, got %v", tc.reason, errCloseCanceled, tc.want, err)
				}
				close(release)
				synctest.Wait()
				if got := started.Load(); got != 2 {
					t.Errorf("\n%s\nClose must start the logout of every client: want 2, got %d", tc.reason, got)
				}
			})
		})
	}
}

func TestSessionCacheCloseLogoutFailure(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		log := &recordingLogger{}
		c := NewSessionCache()
		c.log = log
		rec := &logoutRecorder{}
		c.logout = func(ctx context.Context, meta any) error {
			switch meta.(*fakeMeta).ID {
			case 1:
				return errors.New(errNoVIMClientField)
			case 2:
				panic("provider bug")
			default:
				return rec.logout(ctx, meta)
			}
		}
		for i := 1; i <= 3; i++ {
			id := testID
			id.Name = fmt.Sprintf("pc-%d", i)
			c.entries[id.String()] = &sessionEntry{id: id, credsHash: "h1", meta: &fakeMeta{ID: i}, createdAt: time.Now()}
		}

		err := c.Close(t.Context())
		if err == nil || !strings.Contains(err.Error(), fmt.Sprintf(errCloseLogout, 1, 3)) || !strings.Contains(err.Error(), errNoVIMClientField) {
			t.Errorf("Close must report the failed logout: want %q and %q, got %v", fmt.Sprintf(errCloseLogout, 1, 3), errNoVIMClientField, err)
		}
		if diff := cmp.Diff([]any{&fakeMeta{ID: 3}}, rec.loggedOut()); diff != "" {
			t.Errorf("one failed logout must not stop the others: -want, +got:\n%s", diff)
		}
		if _, debug := log.messages(); !cmp.Equal([]string{msgLogoutPanicked}, debug) {
			t.Errorf("a panicking logout must be recovered and logged at debug level, got %v", debug)
		}
	})
}

func TestSessionCacheAfterClose(t *testing.T) {
	c := NewSessionCache(WithLogoutDelay(0))
	c.sweepInterval = 0
	rec := &logoutRecorder{}
	c.logout = rec.logout
	if err := c.Close(t.Context()); err != nil {
		t.Fatalf("Close(...): %v", err)
	}

	meta, err := c.GetOrCreate(t.Context(), testID, "h1", mustNotCreate(t))
	if meta != nil || err == nil || !strings.Contains(err.Error(), errCacheClosed) {
		t.Errorf("GetOrCreate after Close must fail without a login: want error %q, got meta %v, err %v", errCacheClosed, meta, err)
	}
	if c.EvictIfOlderThan(testID, time.Now().Add(time.Hour)) {
		t.Error("EvictIfOlderThan after Close must find nothing to evict")
	}
	c.EvictDeleted(t.Context(), func(context.Context, ProviderConfigIdentity) bool { return true })
	if got := view(c); len(got) != 0 {
		t.Errorf("a closed cache must cache nothing, got %v", got)
	}
	if got := rec.loggedOut(); len(got) != 0 {
		t.Errorf("nothing must be logged out after Close, got %v", got)
	}
}

func TestSessionCacheCloseWaitsForInflightLogin(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := NewSessionCache()
		rec := &logoutRecorder{}
		c.logout = rec.logout
		release := make(chan struct{})
		created := &fakeMeta{ID: 1}
		type result struct {
			meta any
			err  error
		}
		results := make(chan result, 2)
		get := func(create CreateFunc) {
			meta, err := c.GetOrCreate(t.Context(), testID, "h1", create)
			results <- result{meta: meta, err: err}
		}
		go get(func(context.Context) (any, error) {
			<-release
			return created, nil
		})
		synctest.Wait()
		go get(mustNotCreate(t)) // waits for the login in flight
		synctest.Wait()

		closed := make(chan error, 1)
		go func() { closed <- c.Close(t.Context()) }()
		synctest.Wait()
		select {
		case err := <-closed:
			t.Fatalf("Close must wait for the login in flight, returned %v", err)
		default:
		}

		close(release)
		if err := <-closed; err != nil {
			t.Errorf("Close(...): %v", err)
		}
		for range 2 {
			r := <-results
			if r.meta != nil || r.err == nil || !strings.Contains(r.err.Error(), errCacheClosed) {
				t.Errorf("a login that finishes after Close must not be returned: want error %q, got meta %v, err %v", errCacheClosed, r.meta, r.err)
			}
		}
		synctest.Wait()
		if diff := cmp.Diff([]any{created}, rec.loggedOut()); diff != "" {
			t.Errorf("a client whose login finishes after Close must be logged out exactly once: -want, +got:\n%s", diff)
		}
		if got := view(c); len(got) != 0 {
			t.Errorf("a closed cache must cache nothing, got %v", got)
		}
	})
}
