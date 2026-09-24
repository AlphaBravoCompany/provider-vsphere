/*
Copyright 2022 Upbound Inc.
*/

package clients

import (
	"context"
	"crypto/tls"
	"net/url"
	"reflect"
	"testing"
	"time"

	"github.com/vmware/govmomi"
	_ "github.com/vmware/govmomi/pbm/simulator" // vsphere's Configure opens a PBM client.
	"github.com/vmware/govmomi/property"
	"github.com/vmware/govmomi/simulator"
	"github.com/vmware/govmomi/vapi/rest"
	_ "github.com/vmware/govmomi/vapi/simulator" // vsphere's Configure logs in to the CIS REST API.
	"github.com/vmware/govmomi/vim25/mo"
	"github.com/vmware/terraform-provider-vsphere/vsphere"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	namespacedv1beta1 "github.com/AlphaBravoCompany/provider-vsphere/apis/namespaced/v1beta1"
)

// The tests in this file log real vsphere.Provider() clients in to vcsim,
// govmomi's in-process vCenter simulator listening on 127.0.0.1, and count the
// sessions vcsim holds. They never contact a real vCenter or Kubernetes.

// waitTimeout bounds every wait for a background logout.
const waitTimeout = 30 * time.Second

// vcsim is a running vCenter simulator plus an observer client, logged in as
// another user, that reads vcsim's session list.
type vcsim struct {
	server   *simulator.Server
	observer *govmomi.Client
}

// startVCSim starts a vCenter simulator with the CIS REST and PBM endpoints
// that vsphere's Configure uses. It accepts any non-empty user name and
// password.
func startVCSim(t *testing.T) *vcsim {
	t.Helper()
	// Keep environment defaults of the vSphere provider from changing its
	// session handling (for example persisting sessions to disk).
	for _, env := range []string{"VSPHERE_PERSIST_SESSION", "VSPHERE_VIM_SESSION_PATH", "VSPHERE_REST_SESSION_PATH", "VSPHERE_CLIENT_DEBUG", "VSPHERE_VIM_KEEP_ALIVE"} {
		t.Setenv(env, "")
	}
	model := simulator.VPX()
	if err := model.Create(); err != nil {
		t.Fatalf("cannot create the vcsim model: %v", err)
	}
	t.Cleanup(model.Remove)
	model.Service.TLS = new(tls.Config)
	model.Service.RegisterEndpoints = true
	server := model.Service.NewServer()
	t.Cleanup(server.Close)

	u := *server.URL
	u.User = url.UserPassword("vcsim-observer", "vcsim-observer-password")
	observer, err := govmomi.NewClient(t.Context(), &u, true)
	if err != nil {
		t.Fatalf("cannot log the observer in to vcsim: %v", err)
	}
	t.Cleanup(func() { _ = observer.Logout(context.Background()) })
	return &vcsim{server: server, observer: observer}
}

// config is the vSphere provider configuration for user on this simulator.
func (v *vcsim) config(user, password string) map[string]any {
	return map[string]any{keyVSphereServer: v.server.URL.Host, keyUser: user, keyPassword: password, keyAllowUnverifiedSSL: true}
}

// payload is a credentials Secret payload for user on this simulator, in the
// Pioneer format.
func (v *vcsim) payload(t *testing.T, user, password string) string {
	t.Helper()
	return payload(t, map[string]any{keyVSphereServer: v.server.URL.Host, keyUser: user, keyPassword: password, keyAllowUnverifiedSSL: "true"})
}

// soapSessions returns the number of SOAP sessions vcsim holds for user.
func (v *vcsim) soapSessions(t *testing.T, user string) int {
	t.Helper()
	var sm mo.SessionManager
	pc := property.DefaultCollector(v.observer.Client)
	if err := pc.RetrieveOne(t.Context(), *v.observer.ServiceContent.SessionManager, []string{"sessionList"}, &sm); err != nil {
		t.Fatalf("cannot list the vcsim sessions: %v", err)
	}
	n := 0
	for _, s := range sm.SessionList {
		if s.UserName == user {
			n++
		}
	}
	return n
}

// restSessionLive reports whether vcsim still accepts the CIS REST session id.
func (v *vcsim) restSessionLive(t *testing.T, id string) bool {
	t.Helper()
	probe := rest.NewClient(v.observer.Client)
	probe.SessionID(id)
	s, err := probe.Session(t.Context())
	if err != nil {
		t.Fatalf("cannot check the REST session: %v", err)
	}
	return s != nil
}

// restSessionID returns the CIS REST session id of a configured client.
func restSessionID(t *testing.T, meta any) string {
	t.Helper()
	c, ok := meta.(*vsphere.Client)
	if !ok {
		t.Fatalf("meta is a %T, not a *vsphere.Client", meta)
	}
	tm, err := c.TagsManager()
	if err != nil {
		t.Fatalf("the client has no REST session: %v", err)
	}
	id := tm.SessionID()
	if id == "" {
		t.Fatal("the client has an empty REST session id")
	}
	return id
}

// logoutAtEnd logs a client out when the test ends, so its keep-alive
// goroutines do not outlive the test.
func logoutAtEnd(t *testing.T, meta any) {
	t.Helper()
	t.Cleanup(func() { _ = logoutClient(context.Background(), meta) })
}

// signalingLogout wraps logoutClient for c: each logout waits until release is
// closed (a nil release does not wait) and then reports the client on the
// returned channel.
func signalingLogout(c *SessionCache, release <-chan struct{}) <-chan any {
	done := make(chan any, 8)
	c.logout = func(ctx context.Context, meta any) error {
		if release != nil {
			<-release
		}
		err := logoutClient(ctx, meta)
		done <- meta
		return err
	}
	return done
}

func awaitLogout(t *testing.T, done <-chan any, want any) {
	t.Helper()
	select {
	case got := <-done:
		if got != want {
			t.Fatalf("logged out client %p, want %p", got, want)
		}
	case <-time.After(waitTimeout):
		t.Fatalf("no logout within %s", waitTimeout)
	}
}

func TestVSphereClientKeepsVIMClientField(t *testing.T) {
	// logoutClient reads this unexported field to log out the SOAP session,
	// because vsphere.Client has no accessor for it. If this fails after a
	// dependency bump, update vimClientOf (or use the new provider's own
	// logout method, if it has one): until then, the SOAP session of every
	// client that leaves the session cache is kept alive until the provider
	// restarts.
	f, ok := reflect.TypeFor[vsphere.Client]().FieldByName("vimClient")
	if !ok {
		t.Fatal("vsphere.Client has no field vimClient")
	}
	if want := reflect.TypeFor[*govmomi.Client](); f.Type != want {
		t.Fatalf("vsphere.Client field vimClient has type %v, want %v", f.Type, want)
	}
}

func TestVIMClientOf(t *testing.T) {
	gc := &govmomi.Client{}
	cases := map[string]struct {
		reason string
		p      any
		want   *govmomi.Client
		wantOK bool
	}{
		"UnexportedField": {
			reason: "The unexported vimClient field must be read.",
			p:      &struct{ vimClient *govmomi.Client }{vimClient: gc},
			want:   gc, wantOK: true,
		},
		"UnconfiguredVSphereClient": {
			reason: "A vsphere.Client that was never configured has the field, with no client in it.",
			p:      &vsphere.Client{},
			want:   nil, wantOK: true,
		},
		"FieldMissing": {
			reason: "A struct without the field must be reported, not panic.",
			p:      &struct{ restClient *rest.Client }{},
			want:   nil, wantOK: false,
		},
		"FieldRetyped": {
			reason: "A vimClient field of another type must be reported, not panic.",
			p:      &struct{ vimClient string }{vimClient: "not a client"},
			want:   nil, wantOK: false,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			got, ok := vimClientOf(reflect.ValueOf(tc.p))
			if got != tc.want || ok != tc.wantOK {
				t.Errorf("\n%s\nvimClientOf(...): want (%p, %t), got (%p, %t)", tc.reason, tc.want, tc.wantOK, got, ok)
			}
		})
	}
}

func TestLogoutClientIgnoresOtherMeta(t *testing.T) {
	for name, meta := range map[string]any{
		"Nil":                       nil,
		"NotAVSphereClient":         &fakeMeta{ID: 1},
		"NilVSphereClient":          (*vsphere.Client)(nil),
		"UnconfiguredVSphereClient": &vsphere.Client{},
	} {
		t.Run(name, func(t *testing.T) {
			if err := logoutClient(t.Context(), meta); err != nil {
				t.Errorf("logoutClient(%T): want no error, got %v", meta, err)
			}
		})
	}
}

func TestLogoutClientEndsBothSessions(t *testing.T) {
	v := startVCSim(t)
	meta, err := defaultConfigure(t.Context(), v.config(fakeUser, fakePassword))
	if err != nil {
		t.Fatalf("defaultConfigure(...) on vcsim: %v", err)
	}
	logoutAtEnd(t, meta)
	restID := restSessionID(t, meta)
	if n := v.soapSessions(t, fakeUser); n != 1 {
		t.Fatalf("SOAP sessions after one login: want 1, got %d", n)
	}
	if !v.restSessionLive(t, restID) {
		t.Fatal("the REST session must be live after the login")
	}

	if err := logoutClient(t.Context(), meta); err != nil {
		t.Fatalf("logoutClient(...): %v", err)
	}
	if n := v.soapSessions(t, fakeUser); n != 0 {
		t.Errorf("SOAP sessions after logoutClient: want 0, got %d", n)
	}
	if v.restSessionLive(t, restID) {
		t.Error("the REST session must be ended by logoutClient")
	}
}

func TestSessionCacheEvictLogsOutBothSessions(t *testing.T) {
	v := startVCSim(t)
	c := NewSessionCache(WithLogoutDelay(10 * time.Millisecond))
	done := signalingLogout(c, nil)
	meta, err := c.GetOrCreate(t.Context(), testID, "h1", func(ctx context.Context) (any, error) {
		return defaultConfigure(ctx, v.config(fakeUser, fakePassword))
	})
	if err != nil {
		t.Fatalf("GetOrCreate(...) on vcsim: %v", err)
	}
	logoutAtEnd(t, meta)
	restID := restSessionID(t, meta)

	c.EvictIfOlderThan(testID, time.Now().Add(time.Nanosecond))
	awaitLogout(t, done, meta)
	if n := v.soapSessions(t, fakeUser); n != 0 {
		t.Errorf("SOAP sessions after the eviction: want 0, got %d", n)
	}
	if v.restSessionLive(t, restID) {
		t.Error("the REST session must be ended after the eviction")
	}
}

func TestSetupFnRotationLeavesOneVCenterSession(t *testing.T) {
	const rotated = "fake-password-rotated"
	v := startVCSim(t)
	c := NewSessionCache(WithLogoutDelay(10 * time.Millisecond))
	release := make(chan struct{})
	done := signalingLogout(c, release)
	setupFn := TerraformSetupBuilder(WithSessionCache(c)) // the real in-process vSphere provider
	kube := newFakeClient(t, clusterProviderConfig("default"), credentialsSecret(testSecretNS, testSecretName, v.payload(t, fakeUser, fakePassword)))
	vm1 := modernMR("team-a", "vm-1", "ClusterProviderConfig", "default")
	vm2 := modernMR("team-b", "vm-2", "ClusterProviderConfig", "default")
	ctx := t.Context()

	before, err := setupFn(ctx, kube, vm1)
	if err != nil {
		t.Fatalf("setupFn(...) on vcsim: %v", err)
	}
	logoutAtEnd(t, before.Meta)
	if _, err := setupFn(ctx, kube, vm2); err != nil {
		t.Fatalf("setupFn(...) for a second MR on vcsim: %v", err)
	}
	if n := v.soapSessions(t, fakeUser); n != 1 {
		t.Fatalf("SOAP sessions with two MRs on one ProviderConfig: want 1, got %d (NFR-101)", n)
	}
	oldREST := restSessionID(t, before.Meta)

	s := &corev1.Secret{}
	if err := kube.Get(ctx, client.ObjectKey{Namespace: testSecretNS, Name: testSecretName}, s); err != nil {
		t.Fatalf("cannot get Secret: %v", err)
	}
	s.Data[testSecretKey] = []byte(v.payload(t, fakeUser, rotated))
	if err := kube.Update(ctx, s); err != nil {
		t.Fatalf("cannot update Secret: %v", err)
	}
	after, err := setupFn(ctx, kube, vm1)
	if err != nil {
		t.Fatalf("setupFn(...) after rotation on vcsim: %v", err)
	}
	logoutAtEnd(t, after.Meta)
	if after.Meta == before.Meta {
		t.Fatal("the client built from the old password must not be reused after rotation (AC-022)")
	}
	// Until the logout delay ends, the old client stays usable for async
	// operations that started with it.
	if n := v.soapSessions(t, fakeUser); n != 2 {
		t.Errorf("SOAP sessions during the logout delay: want 2, got %d", n)
	}

	close(release)
	awaitLogout(t, done, before.Meta)
	if n := v.soapSessions(t, fakeUser); n != 1 {
		t.Errorf("SOAP sessions after the logout delay: want exactly 1, got %d (NFR-101, ST-002)", n)
	}
	if v.restSessionLive(t, oldREST) {
		t.Error("the old client's REST session must be ended after the logout delay")
	}
	if !v.restSessionLive(t, restSessionID(t, after.Meta)) {
		t.Error("the new client's REST session must stay live")
	}
}

func TestSetupFnLogsOutDeletedProviderConfig(t *testing.T) {
	const userA, userB = "fake-user-a", "fake-user-b"
	v := startVCSim(t)
	// The default logout delay does not apply to deleted ProviderConfigs:
	// their client must be logged out without waiting for it.
	c := NewSessionCache()
	c.sweepInterval = 0
	done := signalingLogout(c, nil)
	setupFn := TerraformSetupBuilder(WithSessionCache(c))
	cpc := func(name, secret string) *namespacedv1beta1.ClusterProviderConfig {
		return &namespacedv1beta1.ClusterProviderConfig{ObjectMeta: metav1.ObjectMeta{Name: name}, Spec: *sharedSpec(testSecretNS, secret)}
	}
	cpcA := cpc("a", "creds-a")
	kube := newFakeClient(t,
		cpcA, credentialsSecret(testSecretNS, "creds-a", v.payload(t, userA, fakePassword)),
		cpc("b", "creds-b"), credentialsSecret(testSecretNS, "creds-b", v.payload(t, userB, fakePassword)),
	)
	idA := ProviderConfigIdentity{Group: namespacedv1beta1.Group, Kind: namespacedv1beta1.ClusterProviderConfigKind, Name: "a"}
	idB := ProviderConfigIdentity{Group: namespacedv1beta1.Group, Kind: namespacedv1beta1.ClusterProviderConfigKind, Name: "b"}
	vmA := modernMR("team-a", "vm-a", "ClusterProviderConfig", "a")
	vmB := modernMR("team-a", "vm-b", "ClusterProviderConfig", "b")
	ctx := t.Context()

	psA, err := setupFn(ctx, kube, vmA)
	if err != nil {
		t.Fatalf("setupFn(...) for ClusterProviderConfig a: %v", err)
	}
	logoutAtEnd(t, psA.Meta)
	restA := restSessionID(t, psA.Meta)
	psB, err := setupFn(ctx, kube, vmB)
	if err != nil {
		t.Fatalf("setupFn(...) for ClusterProviderConfig b: %v", err)
	}
	logoutAtEnd(t, psB.Meta)

	// Crossplane deletes a ProviderConfig only after its last MR is gone.
	if err := kube.Delete(ctx, cpcA); err != nil {
		t.Fatalf("cannot delete ClusterProviderConfig a: %v", err)
	}
	if _, err := setupFn(ctx, kube, vmB); err != nil {
		t.Fatalf("setupFn(...) for ClusterProviderConfig b after a was deleted: %v", err)
	}
	awaitLogout(t, done, psA.Meta)

	entries := view(c)
	if _, ok := entries[idA.String()]; ok {
		t.Error("the entry of the deleted ClusterProviderConfig must be dropped")
	}
	if e, ok := entries[idB.String()]; !ok || e.Meta != psB.Meta {
		t.Error("the entry of the remaining ClusterProviderConfig must stay")
	}
	if n := v.soapSessions(t, userA); n != 0 {
		t.Errorf("SOAP sessions of the deleted ClusterProviderConfig: want 0, got %d", n)
	}
	if v.restSessionLive(t, restA) {
		t.Error("the REST session of the deleted ClusterProviderConfig must be ended")
	}
	if n := v.soapSessions(t, userB); n != 1 {
		t.Errorf("SOAP sessions of the remaining ClusterProviderConfig: want 1, got %d", n)
	}
	select {
	case m := <-done:
		t.Errorf("only the deleted ClusterProviderConfig's client must be logged out, also got %p", m)
	default:
	}
}
