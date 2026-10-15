/*
Copyright 2022 Upbound Inc.
*/

package clients

import (
	"cmp"
	"context"
	"strings"
	"sync"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/logging"
	"github.com/pkg/errors"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

const (
	errWaitForSession = "cannot wait for the in-flight vSphere login of this ProviderConfig"
	errCreatePanicked = "vSphere login panicked"
	errCacheClosed    = "the vSphere session cache is closed because the provider is stopping"
	errCloseLogout    = "cannot log out %d of the %d vSphere clients of the session cache"
	errCloseCanceled  = "cannot finish logging out the vSphere clients of the session cache"

	msgLogoutIncomplete = "Cannot log out every vCenter session of vSphere clients that leave the session cache; the sessions left are kept alive until the provider restarts"
	msgLogoutPanicked   = "Recovered from a panic while logging out a vSphere client"
)

const (
	// DefaultLogoutDelay is how long, by default, a client that was replaced
	// because its credentials changed, or evicted after a session failure,
	// stays usable before it is logged out. Such a client can still be in
	// use: upjet runs a managed resource's async Create, Update and Delete for
	// up to an hour (defaultAsyncTimeout in upjet
	// pkg/controller/external_async_tfpluginsdk.go) with the Meta the SetupFn
	// returned when the operation started, and logging it out earlier would
	// fail such an operation half-way, for example a VM clone. The delay is
	// that deadline plus a grace period, as provider-upjet-gcp's
	// configureNoForkGCPClient waits before it cancels the context of a
	// configured provider.
	DefaultLogoutDelay = terraformPluginSDKAsyncTimeout + gracePeriod

	terraformPluginSDKAsyncTimeout = time.Hour
	gracePeriod                    = 10 * time.Minute

	// logoutTimeout bounds the logout of one client.
	logoutTimeout = 30 * time.Second

	// defaultSweepInterval is the minimum time between two EvictDeleted
	// sweeps.
	defaultSweepInterval = time.Minute
)

// defaultLogger writes like the provider's own logger does without --debug:
// JSON lines on stderr, at info level.
var defaultLogger = logging.NewLogrLogger(zap.New().WithName("provider-vsphere"))

// authOrSessionErrorMarkers are lower-case fragments of vCenter SOAP and REST
// error messages that mean the session or the login is no longer valid.
var authOrSessionErrorMarkers = []string{
	"notauthenticated",
	"not authenticated",
	"session is not authenticated",
	"incorrect user name or password",
	"invalidlogin",
	"401 unauthorized",
	"unauthenticated",
}

// IsAuthOrSessionError reports whether msg describes a vCenter authentication
// or session failure (case-insensitive).
func IsAuthOrSessionError(msg string) bool {
	m := strings.ToLower(msg)
	for _, marker := range authOrSessionErrorMarkers {
		if strings.Contains(m, marker) {
			return true
		}
	}
	return false
}

// ProviderConfigIdentity identifies the ProviderConfig or ClusterProviderConfig
// that a cached vSphere client was configured from. Namespace is empty for
// cluster-scoped kinds.
type ProviderConfigIdentity struct {
	Group     string
	Kind      string
	Namespace string
	Name      string
}

// String returns the cache key group/kind/namespace/name. Kubernetes API
// groups, kinds, namespaces and names cannot contain "/", so the key is
// unambiguous.
func (i ProviderConfigIdentity) String() string {
	return i.Group + "/" + i.Kind + "/" + i.Namespace + "/" + i.Name
}

// CreateFunc configures a new vSphere client (a vCenter login) and returns the
// provider Meta.
type CreateFunc func(ctx context.Context) (any, error)

// DeletedFunc reports whether the ProviderConfig or ClusterProviderConfig that
// id names is known to have been deleted. It returns false when that cannot be
// determined.
type DeletedFunc func(ctx context.Context, id ProviderConfigIdentity) bool

type sessionEntry struct {
	id        ProviderConfigIdentity
	credsHash string
	meta      any
	createdAt time.Time
}

// inflightCreate is a login in progress for one identity. meta and err are
// written once by the creating goroutine before done is closed.
type inflightCreate struct {
	done      chan struct{}
	credsHash string
	meta      any
	err       error
}

// SessionCache holds one configured vSphere client per ProviderConfig
// identity, so that reconciles reuse a vCenter session instead of logging in
// every time. An entry is reused only while the SHA-256 of the credentials it
// was built from matches. Every client that leaves the cache is logged out in
// the background, so its vCenter sessions and keep-alive goroutines do not
// outlive it. The cache is safe for concurrent use.
type SessionCache struct {
	mu        sync.Mutex
	entries   map[string]*sessionEntry
	inflight  map[string]*inflightCreate
	lastSweep time.Time
	warnOnce  sync.Once
	// retiring holds the clients that left the cache and wait for their
	// delayed logout. Whoever removes a client from it, its timer or Close,
	// logs it out, so no client is logged out twice.
	retiring map[*sessionEntry]*time.Timer
	// closed is set by Close. A closed cache caches no client.
	closed bool

	// The fields below are set by NewSessionCache. Tests may replace them
	// before the cache is used.

	// logoutDelay is how long a replaced or evicted client stays usable
	// before it is logged out.
	logoutDelay time.Duration
	// sweepInterval is the minimum time between two EvictDeleted sweeps.
	sweepInterval time.Duration
	// logout ends the vCenter sessions of a client that left the cache. A
	// failed vCenter call is not an error, because the session may already
	// have ended. It returns an error only when it cannot even try to end
	// one of the sessions. It must never log credentials.
	logout func(ctx context.Context, meta any) error
	log    logging.Logger
}

// SessionCacheOption customizes a SessionCache.
type SessionCacheOption func(*SessionCache)

// WithLogoutDelay sets how long a client that left the cache stays usable
// before it is logged out: one replaced because its credentials changed, one
// dropped because the login with new credentials failed, and one evicted. The
// default is DefaultLogoutDelay. Clients of deleted ProviderConfigs are logged
// out at once regardless.
func WithLogoutDelay(d time.Duration) SessionCacheOption {
	return func(c *SessionCache) {
		c.logoutDelay = d
	}
}

// NewSessionCache returns an empty SessionCache.
func NewSessionCache(opts ...SessionCacheOption) *SessionCache {
	c := &SessionCache{
		entries:       map[string]*sessionEntry{},
		inflight:      map[string]*inflightCreate{},
		retiring:      map[*sessionEntry]*time.Timer{},
		logoutDelay:   DefaultLogoutDelay,
		sweepInterval: defaultSweepInterval,
		logout:        logoutClient,
		log:           defaultLogger,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// GetOrCreate returns the Meta cached for id when it was built from
// credentials with credsHash. Otherwise it calls create and caches the
// result, replacing any entry built from other credentials. Concurrent callers
// that miss on the same identity and hash share a single create call and its
// result. A failed create caches nothing and removes the identity's previous
// entry. The replaced or removed client is logged out after the logout delay.
// After Close it fails without calling create.
func (c *SessionCache) GetOrCreate(ctx context.Context, id ProviderConfigIdentity, credsHash string, create CreateFunc) (any, error) {
	key := id.String()
	for {
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return nil, errors.New(errCacheClosed)
		}
		if e, ok := c.entries[key]; ok && e.credsHash == credsHash {
			c.mu.Unlock()
			return e.meta, nil
		}
		call, busy := c.inflight[key]
		if !busy {
			call = &inflightCreate{done: make(chan struct{}), credsHash: credsHash}
			c.inflight[key] = call
			c.mu.Unlock()
			c.runCreate(ctx, id, call, create)
			return call.meta, call.err
		}
		c.mu.Unlock()

		select {
		case <-call.done:
		case <-ctx.Done():
			return nil, errors.Wrap(ctx.Err(), errWaitForSession)
		}
		if call.credsHash == credsHash {
			return call.meta, call.err
		}
		// The finished login was for other credentials: look again.
	}
}

// runCreate runs create for id and publishes the outcome to the cache and to
// every caller waiting on call. The deferred publish also runs if create
// panics, so waiters are released and the identity is not left blocked. A
// client created after Close is logged out at once and not returned.
func (c *SessionCache) runCreate(ctx context.Context, id ProviderConfigIdentity, call *inflightCreate, create CreateFunc) {
	key := id.String()
	call.err = errors.New(errCreatePanicked)
	defer func() {
		c.mu.Lock()
		delete(c.inflight, key)
		if c.closed {
			c.mu.Unlock()
			if call.err == nil {
				lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), logoutTimeout)
				_ = c.logoutRecovered(lctx, call.meta)
				cancel()
			}
			call.meta, call.err = nil, errors.New(errCacheClosed)
			close(call.done)
			return
		}
		old := c.entries[key]
		if call.err != nil {
			delete(c.entries, key)
		} else {
			c.entries[key] = &sessionEntry{id: id, credsHash: call.credsHash, meta: call.meta, createdAt: time.Now()}
		}
		if old != nil {
			// Whether or not the new login worked, async operations that
			// started with the old client may still be running, so it gets
			// the full logout delay: an earlier logout could fail a VM clone
			// half-way and orphan the VM.
			c.retire(old, c.logoutDelay)
		}
		c.mu.Unlock()
		close(call.done)
	}()
	call.meta, call.err = create(ctx)
}

// EvictIfOlderThan removes the entry cached for id if it was created before t,
// and reports whether it did. An entry created at or after t is kept, so a
// client rebuilt after a failure is not evicted again by that same failure. The
// removed client is logged out after the logout delay.
func (c *SessionCache) EvictIfOlderThan(id ProviderConfigIdentity, t time.Time) bool {
	key := id.String()
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok || !e.createdAt.Before(t) {
		return false
	}
	delete(c.entries, key)
	c.retire(e, c.logoutDelay)
	return true
}

// EvictDeleted removes the entries whose ProviderConfig or
// ClusterProviderConfig deleted reports as deleted, and logs their clients out
// at once: Crossplane does not delete a ProviderConfig while a managed
// resource still uses it, so no operation holds those clients any more. It
// runs at most once per sweep interval and never holds the cache lock while
// deleted runs.
func (c *SessionCache) EvictDeleted(ctx context.Context, deleted DeletedFunc) {
	c.mu.Lock()
	if now := time.Now(); now.Sub(c.lastSweep) >= c.sweepInterval {
		c.lastSweep = now
	} else {
		c.mu.Unlock()
		return
	}
	candidates := make([]*sessionEntry, 0, len(c.entries))
	for _, e := range c.entries {
		candidates = append(candidates, e)
	}
	c.mu.Unlock()

	for _, e := range candidates {
		if !deleted(ctx, e.id) {
			continue
		}
		key := e.id.String()
		c.mu.Lock()
		// Remove only the entry that was checked. One that replaced it
		// meanwhile, for example for a ProviderConfig recreated with the same
		// name, stays; the replaced one is already being logged out.
		if c.entries[key] == e {
			delete(c.entries, key)
			c.retire(e, 0)
		}
		c.mu.Unlock()
	}
}

// retire logs out the client of e, which has just left the cache, after delay.
// The caller must hold c.mu. The logout runs in its own goroutine, bounded by
// logoutTimeout, so no reconcile waits for it, unless Close has logged the
// client out already. The first logout that cannot reach every session is
// reported once.
//
//nolint:contextcheck // The logout runs after its caller has returned, up to the logout delay later, so it must not inherit the caller's context.
func (c *SessionCache) retire(e *sessionEntry, delay time.Duration) {
	c.retiring[e] = time.AfterFunc(delay, func() {
		c.mu.Lock()
		_, ok := c.retiring[e]
		delete(c.retiring, e)
		c.mu.Unlock()
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), logoutTimeout)
		defer cancel()
		if err := c.logoutRecovered(ctx, e.meta); err != nil {
			c.warnOnce.Do(func() {
				c.log.Info(msgLogoutIncomplete, "reason", err.Error())
			})
		}
	})
}

// logoutRecovered logs meta out. A panic in the logout is recovered and
// logged at debug level, as it must never stop the provider.
func (c *SessionCache) logoutRecovered(ctx context.Context, meta any) (err error) {
	defer func() {
		if r := recover(); r != nil {
			c.log.Debug(msgLogoutPanicked, "panic", r)
		}
	}()
	return c.logout(ctx, meta)
}

// Close logs out at once, concurrently, every cached client and every client
// still waiting for its delayed logout, so that no vCenter session outlives
// the provider. It then waits for the logins in flight, whose clients are
// logged out as they finish. It returns when all of that is done or ctx is
// done, whichever comes first, and returns an error if a logout could not
// reach every session or ctx ended first. After Close the cache caches
// nothing: GetOrCreate fails, so a reconcile racing the shutdown cannot open
// a new session. Calling Close again does nothing.
func (c *SessionCache) Close(ctx context.Context) error {
	metas, inflight := c.closeAndTake()
	err := c.logoutAll(ctx, metas)
	for _, call := range inflight {
		select {
		case <-call.done:
		case <-ctx.Done():
			return errors.Wrap(ctx.Err(), errCloseCanceled)
		}
	}
	return err
}

// closeAndTake closes the cache and empties it. It returns the clients to log
// out and the logins in flight, or nothing if the cache was already closed.
func (c *SessionCache) closeAndTake() ([]any, []*inflightCreate) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, nil
	}
	c.closed = true
	metas := make([]any, 0, len(c.entries)+len(c.retiring))
	for _, e := range c.entries {
		metas = append(metas, e.meta)
	}
	for e, t := range c.retiring {
		// A timer that has already fired finds its client gone and does
		// nothing.
		t.Stop()
		metas = append(metas, e.meta)
	}
	inflight := make([]*inflightCreate, 0, len(c.inflight))
	for _, call := range c.inflight {
		inflight = append(inflight, call)
	}
	c.entries = map[string]*sessionEntry{}
	c.retiring = map[*sessionEntry]*time.Timer{}
	return metas, inflight
}

// logoutAll logs every client in metas out concurrently, bounded by ctx.
func (c *SessionCache) logoutAll(ctx context.Context, metas []any) error {
	results := make(chan error, len(metas))
	for _, meta := range metas {
		go func() { results <- c.logoutRecovered(ctx, meta) }()
	}
	var firstErr error
	failed := 0
	for range metas {
		select {
		case err := <-results:
			if err != nil {
				failed++
				firstErr = cmp.Or(firstErr, err)
			}
		case <-ctx.Done():
			return errors.Wrap(ctx.Err(), errCloseCanceled)
		}
	}
	if firstErr != nil {
		return errors.Wrapf(firstErr, errCloseLogout, failed, len(metas))
	}
	return nil
}
