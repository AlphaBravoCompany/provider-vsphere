/*
Copyright 2022 Upbound Inc.
*/

package clients

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/crossplane/crossplane-runtime/v2/pkg/resource"
	"github.com/crossplane/crossplane-runtime/v2/pkg/resource/fake"
	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"
	"github.com/google/go-cmp/cmp"
	"github.com/pkg/errors"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	clientfake "sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	clusterv1beta1 "github.com/AlphaBravoCompany/provider-vsphere/apis/cluster/v1beta1"
	namespacedv1beta1 "github.com/AlphaBravoCompany/provider-vsphere/apis/namespaced/v1beta1"
)

// Test fixtures use obviously fake values. No test contacts a vCenter or a
// Kubernetes API server: the Kubernetes client is controller-runtime's fake
// client and the vSphere login is a recorded fake ConfigureFunc.
const (
	fakeUser     = "fake-user"
	fakePassword = "fake-password"
	fakeServer   = "vcenter.invalid"

	testSecretNS   = "crossplane-system"
	testSecretName = "vsphere-creds"
	testSecretKey  = "credentials"

	// pioneerPayload is what Pioneer writes today
	// (pioneer internal/operator/infra/credentials.go:302-315): every value
	// is a JSON string, including allow_unverified_ssl.
	pioneerPayload = `{"vsphere_server":"vcenter.invalid","user":"fake-user","password":"fake-password","allow_unverified_ssl":"true"}`
)

// fakeMeta stands in for the *vsphere.Client a real login returns. ID is the
// number of the configure call that produced it.
type fakeMeta struct{ ID int }

// configureRecorder is a fake ConfigureFunc that records every call. The
// first failFirst calls return err.
type configureRecorder struct {
	mu        sync.Mutex
	calls     []map[string]any
	failFirst int
	err       error
}

func (r *configureRecorder) configure(_ context.Context, cfg map[string]any) (any, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, cfg)
	if len(r.calls) <= r.failFirst {
		return nil, r.err
	}
	return &fakeMeta{ID: len(r.calls)}, nil
}

func (r *configureRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func payload(t *testing.T, kv map[string]any) string {
	t.Helper()
	b, err := json.Marshal(kv)
	if err != nil {
		t.Fatalf("cannot marshal payload: %v", err)
	}
	return string(b)
}

func newFakeClient(t *testing.T, objs ...client.Object) client.Client {
	t.Helper()
	s := runtime.NewScheme()
	for _, add := range []func(*runtime.Scheme) error{
		corev1.AddToScheme,
		clusterv1beta1.SchemeBuilder.AddToScheme,
		namespacedv1beta1.SchemeBuilder.AddToScheme,
	} {
		if err := add(s); err != nil {
			t.Fatalf("cannot build scheme: %v", err)
		}
	}
	return clientfake.NewClientBuilder().WithScheme(s).WithObjects(objs...).WithInterceptorFuncs(interceptor.Funcs{
		// The API server and the manager's cache ignore the namespace of a
		// Get for a cluster-scoped kind (resolveModern relies on that), but
		// the fake client alone does not.
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			switch obj.(type) {
			case *namespacedv1beta1.ClusterProviderConfig, *clusterv1beta1.ProviderConfig:
				key.Namespace = ""
			}
			return c.Get(ctx, key, obj, opts...)
		},
	}).Build()
}

func credentialsSecret(ns, name, data string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Data:       map[string][]byte{testSecretKey: []byte(data)},
	}
}

func secretSelectors(ns, name string) xpv2.CommonCredentialSelectors {
	return xpv2.CommonCredentialSelectors{
		SecretRef: &xpv2.SecretKeySelector{
			SecretReference: xpv2.SecretReference{Namespace: ns, Name: name},
			Key:             testSecretKey,
		},
	}
}

// sharedSpec is the namespaced (shared) ProviderConfigSpec reading the
// credentials Secret ns/name.
func sharedSpec(ns, name string) *namespacedv1beta1.ProviderConfigSpec {
	return &namespacedv1beta1.ProviderConfigSpec{
		Credentials: namespacedv1beta1.ProviderCredentials{
			Source:                    xpv2.CredentialsSourceSecret,
			CommonCredentialSelectors: secretSelectors(ns, name),
		},
	}
}

// legacyProviderConfig is a cluster-scoped ProviderConfig in
// vsphere.alphabravo.io, used by cluster-scoped (legacy) MRs.
func legacyProviderConfig(name string) *clusterv1beta1.ProviderConfig {
	return &clusterv1beta1.ProviderConfig{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: clusterv1beta1.ProviderConfigSpec{
			Credentials: clusterv1beta1.ProviderCredentials{
				Source:                    xpv2.CredentialsSourceSecret,
				CommonCredentialSelectors: secretSelectors(testSecretNS, testSecretName),
			},
		},
	}
}

// namespacedProviderConfig is a namespaced ProviderConfig whose secretRef
// names secretNS; resolveModern must replace that with the MR namespace.
func namespacedProviderConfig(ns, name, secretNS string) *namespacedv1beta1.ProviderConfig {
	return &namespacedv1beta1.ProviderConfig{
		ObjectMeta: metav1.ObjectMeta{Namespace: ns, Name: name},
		Spec:       *sharedSpec(secretNS, testSecretName),
	}
}

func clusterProviderConfig(name string) *namespacedv1beta1.ClusterProviderConfig {
	return &namespacedv1beta1.ClusterProviderConfig{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec:       *sharedSpec(testSecretNS, testSecretName),
	}
}

func legacyMR(name, pcName string) *fake.LegacyManaged {
	return &fake.LegacyManaged{
		ObjectMeta:                     metav1.ObjectMeta{Name: name, UID: types.UID(name + "-uid")},
		LegacyProviderConfigReferencer: fake.LegacyProviderConfigReferencer{Ref: &xpv2.Reference{Name: pcName}},
	}
}

func modernMR(ns, name, kind, pcName string) *fake.ModernManaged {
	return &fake.ModernManaged{
		ObjectMeta:                    metav1.ObjectMeta{Namespace: ns, Name: name, UID: types.UID(ns + "-" + name + "-uid")},
		TypedProviderConfigReferencer: fake.TypedProviderConfigReferencer{Ref: &xpv2.ProviderConfigReference{Kind: kind, Name: pcName}},
	}
}

func assertNoSecrets(t *testing.T, err error, secrets ...string) {
	t.Helper()
	if err == nil {
		return
	}
	for _, s := range secrets {
		if strings.Contains(err.Error(), s) {
			t.Errorf("error %q contains the credential value %q", err.Error(), s)
		}
	}
}

func TestParseCredentials(t *testing.T) {
	baseCfg := map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer}
	withCfg := func(kv map[string]any) map[string]any {
		out := map[string]any{}
		for k, v := range baseCfg {
			out[k] = v
		}
		for k, v := range kv {
			out[k] = v
		}
		return out
	}
	withRaw := func(kv map[string]any) string {
		m := map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer}
		for k, v := range kv {
			if v == nil {
				delete(m, k)
				continue
			}
			m[k] = v
		}
		return payload(t, m)
	}
	type want struct {
		cfg         map[string]any
		errContains string
	}
	cases := map[string]struct {
		reason string
		raw    string
		want   want
	}{
		"PioneerPayload": {
			reason: "The Pioneer payload (all strings, allow_unverified_ssl \"true\") must parse, with allow_unverified_ssl as a boolean.",
			raw:    pioneerPayload,
			want:   want{cfg: withCfg(map[string]any{keyAllowUnverifiedSSL: true})},
		},
		"NativeBoolean": {
			reason: "A native JSON boolean allow_unverified_ssl must give the same result as the string form.",
			raw:    withRaw(map[string]any{keyAllowUnverifiedSSL: true}),
			want:   want{cfg: withCfg(map[string]any{keyAllowUnverifiedSSL: true})},
		},
		"StringFalse": {
			reason: "The string \"false\" must parse to false.",
			raw:    withRaw(map[string]any{keyAllowUnverifiedSSL: "false"}),
			want:   want{cfg: withCfg(map[string]any{keyAllowUnverifiedSSL: false})},
		},
		"StringFormOfBoolean": {
			reason: "Every string form accepted by strconv.ParseBool must parse.",
			raw:    withRaw(map[string]any{keyAllowUnverifiedSSL: "1"}),
			want:   want{cfg: withCfg(map[string]any{keyAllowUnverifiedSSL: true})},
		},
		"APITimeoutNumber": {
			reason: "A whole JSON number api_timeout must become an int (minutes).",
			raw:    withRaw(map[string]any{keyAPITimeout: 10}),
			want:   want{cfg: withCfg(map[string]any{keyAPITimeout: 10})},
		},
		"APITimeoutString": {
			reason: "A numeric string api_timeout must become the same int as the number form.",
			raw:    withRaw(map[string]any{keyAPITimeout: "10"}),
			want:   want{cfg: withCfg(map[string]any{keyAPITimeout: 10})},
		},
		"APITimeoutPaddedString": {
			reason: "Surrounding spaces in a numeric string api_timeout must be ignored.",
			raw:    withRaw(map[string]any{keyAPITimeout: " 10 "}),
			want:   want{cfg: withCfg(map[string]any{keyAPITimeout: 10})},
		},
		"NullOptionalKeysOmitted": {
			reason: "JSON null optional keys must be treated as absent.",
			raw:    `{"vsphere_server":"vcenter.invalid","user":"fake-user","password":"fake-password","allow_unverified_ssl":null,"api_timeout":null}`,
			want:   want{cfg: withCfg(nil)},
		},
		"UnknownKeysNotForwarded": {
			reason: "Keys outside the credentials contract must not reach the provider configuration.",
			raw:    withRaw(map[string]any{"username": "other-user", "vim_keep_alive": 1}),
			want:   want{cfg: withCfg(nil)},
		},
		"AllowUnverifiedSSLNotBoolean": {
			reason: "An unparsable allow_unverified_ssl string must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyAllowUnverifiedSSL: "abc"}),
			want:   want{errContains: keyAllowUnverifiedSSL},
		},
		"AllowUnverifiedSSLWrongType": {
			reason: "A JSON number allow_unverified_ssl must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyAllowUnverifiedSSL: 1}),
			want:   want{errContains: keyAllowUnverifiedSSL},
		},
		"APITimeoutNotNumeric": {
			reason: "An unparsable api_timeout string must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyAPITimeout: "abc"}),
			want:   want{errContains: keyAPITimeout},
		},
		"APITimeoutFractional": {
			reason: "A fractional api_timeout must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyAPITimeout: 1.5}),
			want:   want{errContains: keyAPITimeout},
		},
		"APITimeoutZero": {
			reason: "A zero api_timeout would time out every vSphere call and must be rejected.",
			raw:    withRaw(map[string]any{keyAPITimeout: 0}),
			want:   want{errContains: keyAPITimeout},
		},
		"APITimeoutWrongType": {
			reason: "A JSON boolean api_timeout must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyAPITimeout: true}),
			want:   want{errContains: keyAPITimeout},
		},
		"MissingUser": {
			reason: "A missing user must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyUser: nil}),
			want:   want{errContains: `"user"`},
		},
		"MissingPassword": {
			reason: "A missing password must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyPassword: nil}),
			want:   want{errContains: `"password"`},
		},
		"MissingVSphereServer": {
			reason: "A missing vsphere_server must yield an error naming the key (OT-013).",
			raw:    withRaw(map[string]any{keyVSphereServer: nil}),
			want:   want{errContains: keyVSphereServer},
		},
		"EmptyVSphereServer": {
			reason: "An empty vsphere_server must be treated as missing.",
			raw:    withRaw(map[string]any{keyVSphereServer: ""}),
			want:   want{errContains: keyVSphereServer},
		},
		"UserNotString": {
			reason: "A non-string user must yield an error naming the key.",
			raw:    withRaw(map[string]any{keyUser: 42}),
			want:   want{errContains: `"user"`},
		},
		"LegacyUsernameKeyNotAccepted": {
			reason: "The key is user; username from the old example is not an alias.",
			raw:    `{"vsphere_server":"vcenter.invalid","username":"fake-user","password":"fake-password"}`,
			want:   want{errContains: `"user"`},
		},
		"UnquotedPasswordSyntaxError": {
			reason: "A JSON syntax error must report only the position, never the offending characters.",
			raw:    `{"vsphere_server":"vcenter.invalid","user":"fake-user","password":fake-password}`,
			want:   want{errContains: "syntax error at byte offset"},
		},
		"NotAnObject": {
			reason: "A payload that is not a JSON object must yield an unmarshal error.",
			raw:    `"fake-password"`,
			want:   want{errContains: errUnmarshalCredentials},
		},
		"Empty": {
			reason: "An empty payload (for example credentials source None) must yield an unmarshal error.",
			raw:    ``,
			want:   want{errContains: errUnmarshalCredentials},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := parseCredentials([]byte(tc.raw))
			assertNoSecrets(t, err, fakePassword, fakeUser, fakeServer, "invalid character")
			if tc.want.errContains != "" {
				if err == nil || !strings.Contains(err.Error(), tc.want.errContains) {
					t.Fatalf("\n%s\nparseCredentials(...): want error containing %q, got %v", tc.reason, tc.want.errContains, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("\n%s\nparseCredentials(...): unexpected error: %v", tc.reason, err)
			}
			if diff := cmp.Diff(tc.want.cfg, got); diff != "" {
				t.Errorf("\n%s\nparseCredentials(...): -want, +got:\n%s", tc.reason, diff)
			}
		})
	}
}

func TestDefaultConfigureInProcess(t *testing.T) {
	// Clear the provider's environment fallbacks so no server is configured.
	// The real vsphere.Provider() then accepts the typed values in its schema
	// diff and in providerConfigure (which asserts api_timeout is an int), and
	// fails in NewConfig before any network call.
	for _, env := range []string{"VSPHERE_SERVER", "VSPHERE_VCENTER"} {
		t.Setenv(env, "")
	}
	cfg := map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyAllowUnverifiedSSL: true, keyAPITimeout: 10}
	meta, err := defaultConfigure(context.Background(), cfg)
	if err == nil || !strings.Contains(err.Error(), errConfigureProvider) || !strings.Contains(err.Error(), keyVSphereServer) {
		t.Fatalf("defaultConfigure(...) without a server: want an error containing %q and %q, got %v", errConfigureProvider, keyVSphereServer, err)
	}
	if meta != nil {
		t.Errorf("defaultConfigure(...) must not return a client when configure fails, got %v", meta)
	}
	assertNoSecrets(t, err, fakePassword)
}

func TestResolveProviderConfig(t *testing.T) {
	type args struct {
		objs []client.Object
		mg   resource.Managed
	}
	type want struct {
		spec        *namespacedv1beta1.ProviderConfigSpec
		id          ProviderConfigIdentity
		errContains string
		// usage checks the ProviderConfigUsage recorded for the MR.
		usage func(t *testing.T, c client.Client)
	}
	cases := map[string]struct {
		reason string
		args   args
		want   want
	}{
		"LegacyClusterProviderConfig": {
			reason: "A cluster-scoped MR must resolve the cluster ProviderConfig and track its usage with a cluster ProviderConfigUsage.",
			args:   args{objs: []client.Object{legacyProviderConfig("pc")}, mg: legacyMR("vm", "pc")},
			want: want{
				spec: sharedSpec(testSecretNS, testSecretName),
				id:   ProviderConfigIdentity{Group: "vsphere.alphabravo.io", Kind: "ProviderConfig", Name: "pc"},
				usage: func(t *testing.T, c client.Client) {
					t.Helper()
					pcu := &clusterv1beta1.ProviderConfigUsage{}
					if err := c.Get(context.Background(), types.NamespacedName{Name: "vm-uid"}, pcu); err != nil {
						t.Fatalf("cannot get ProviderConfigUsage: %v", err)
					}
					if diff := cmp.Diff(xpv2.Reference{Name: "pc"}, pcu.GetProviderConfigReference()); diff != "" {
						t.Errorf("ProviderConfigUsage providerConfigRef: -want, +got:\n%s", diff)
					}
				},
			},
		},
		"LegacyNoProviderConfigRef": {
			reason: "A cluster-scoped MR without providerConfigRef must be rejected.",
			args:   args{mg: &fake.LegacyManaged{ObjectMeta: metav1.ObjectMeta{Name: "vm", UID: "vm-uid"}}},
			want:   want{errContains: errNoProviderConfig},
		},
		"LegacyMissingProviderConfig": {
			reason: "A missing cluster ProviderConfig must yield an error naming it.",
			args:   args{mg: legacyMR("vm", "missing-pc")},
			want:   want{errContains: "missing-pc"},
		},
		"ModernNamespacedProviderConfig": {
			reason: "A namespaced ProviderConfig must resolve with its secretRef namespace forced to the MR namespace.",
			args: args{
				objs: []client.Object{namespacedProviderConfig("team-a", "pc", "somewhere-else")},
				mg:   modernMR("team-a", "vm", "ProviderConfig", "pc"),
			},
			want: want{
				spec: sharedSpec("team-a", testSecretName),
				id:   ProviderConfigIdentity{Group: "vsphere.m.alphabravo.io", Kind: "ProviderConfig", Namespace: "team-a", Name: "pc"},
				usage: func(t *testing.T, c client.Client) {
					t.Helper()
					pcu := &namespacedv1beta1.ProviderConfigUsage{}
					if err := c.Get(context.Background(), types.NamespacedName{Namespace: "team-a", Name: "team-a-vm-uid"}, pcu); err != nil {
						t.Fatalf("cannot get ProviderConfigUsage: %v", err)
					}
					if diff := cmp.Diff(xpv2.ProviderConfigReference{Kind: "ProviderConfig", Name: "pc"}, pcu.GetProviderConfigReference()); diff != "" {
						t.Errorf("ProviderConfigUsage providerConfigRef: -want, +got:\n%s", diff)
					}
				},
			},
		},
		"ModernClusterProviderConfig": {
			reason: "A ClusterProviderConfig must be used as-is and keyed without a namespace.",
			args: args{
				objs: []client.Object{clusterProviderConfig("default")},
				mg:   modernMR("team-b", "vm", "ClusterProviderConfig", "default"),
			},
			want: want{
				spec: sharedSpec(testSecretNS, testSecretName),
				id:   ProviderConfigIdentity{Group: "vsphere.m.alphabravo.io", Kind: "ClusterProviderConfig", Name: "default"},
				usage: func(t *testing.T, c client.Client) {
					t.Helper()
					pcu := &namespacedv1beta1.ProviderConfigUsage{}
					if err := c.Get(context.Background(), types.NamespacedName{Namespace: "team-b", Name: "team-b-vm-uid"}, pcu); err != nil {
						t.Fatalf("cannot get ProviderConfigUsage: %v", err)
					}
					if diff := cmp.Diff(xpv2.ProviderConfigReference{Kind: "ClusterProviderConfig", Name: "default"}, pcu.GetProviderConfigReference()); diff != "" {
						t.Errorf("ProviderConfigUsage providerConfigRef: -want, +got:\n%s", diff)
					}
				},
			},
		},
		"ModernMissingProviderConfig": {
			reason: "A namespaced MR referencing a missing ProviderConfig must yield an error naming it (AC-007).",
			args:   args{mg: modernMR("team-a", "vm", "ProviderConfig", "missing-pc")},
			want:   want{errContains: "missing-pc"},
		},
		"ModernMissingClusterProviderConfig": {
			reason: "A namespaced MR referencing a missing ClusterProviderConfig must yield an error naming it.",
			args:   args{mg: modernMR("team-a", "vm", "ClusterProviderConfig", "missing-cpc")},
			want:   want{errContains: "missing-cpc"},
		},
		"ModernUnknownKind": {
			reason: "A providerConfigRef kind that is not registered must be rejected.",
			args:   args{mg: modernMR("team-a", "vm", "Bogus", "pc")},
			want:   want{errContains: errUnknownPCGVK},
		},
		"ModernNoProviderConfigRef": {
			reason: "A namespaced MR without providerConfigRef must be rejected.",
			args:   args{mg: &fake.ModernManaged{ObjectMeta: metav1.ObjectMeta{Namespace: "team-a", Name: "vm", UID: "vm-uid"}}},
			want:   want{errContains: errNoProviderConfig},
		},
		"NotAManagedResource": {
			reason: "An object that is neither a legacy nor a modern managed resource must be rejected.",
			args:   args{mg: &fake.Managed{}},
			want:   want{errContains: errNotManaged},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			c := newFakeClient(t, tc.args.objs...)
			spec, id, err := resolveProviderConfig(context.Background(), c, tc.args.mg)
			if tc.want.errContains != "" {
				if err == nil || !strings.Contains(err.Error(), tc.want.errContains) {
					t.Fatalf("\n%s\nresolveProviderConfig(...): want error containing %q, got %v", tc.reason, tc.want.errContains, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("\n%s\nresolveProviderConfig(...): unexpected error: %v", tc.reason, err)
			}
			if diff := cmp.Diff(tc.want.spec, spec); diff != "" {
				t.Errorf("\n%s\nresolveProviderConfig(...) spec: -want, +got:\n%s", tc.reason, diff)
			}
			if diff := cmp.Diff(tc.want.id, id); diff != "" {
				t.Errorf("\n%s\nresolveProviderConfig(...) identity: -want, +got:\n%s", tc.reason, diff)
			}
			tc.want.usage(t, c)
		})
	}
}

// failingGetClient is a Kubernetes client whose Get always fails with errBoom.
type failingGetClient struct{ client.Client }

func (failingGetClient) Get(context.Context, client.ObjectKey, client.Object, ...client.GetOption) error {
	return errBoom
}

func TestProviderConfigDeleted(t *testing.T) {
	legacyID := ProviderConfigIdentity{Group: clusterv1beta1.Group, Kind: clusterv1beta1.ProviderConfigKind, Name: "pc"}
	cpcID := testID // ClusterProviderConfig "default"
	pcID := otherID // ProviderConfig "default" in namespace team-a
	cases := map[string]struct {
		reason  string
		objs    []client.Object
		failGet bool
		id      ProviderConfigIdentity
		want    bool
	}{
		"LegacyProviderConfigExists": {
			reason: "An existing cluster ProviderConfig is not deleted.",
			objs:   []client.Object{legacyProviderConfig("pc")},
			id:     legacyID,
			want:   false,
		},
		"LegacyProviderConfigDeleted": {
			reason: "A cluster ProviderConfig that is not found is deleted.",
			id:     legacyID,
			want:   true,
		},
		"ClusterProviderConfigExists": {
			reason: "An existing ClusterProviderConfig is not deleted.",
			objs:   []client.Object{clusterProviderConfig("default")},
			id:     cpcID,
			want:   false,
		},
		"ClusterProviderConfigDeleted": {
			reason: "A ClusterProviderConfig that is not found is deleted.",
			objs:   []client.Object{legacyProviderConfig("default")},
			id:     cpcID,
			want:   true,
		},
		"NamespacedProviderConfigExists": {
			reason: "An existing namespaced ProviderConfig is not deleted.",
			objs:   []client.Object{namespacedProviderConfig("team-a", "default", "team-a")},
			id:     pcID,
			want:   false,
		},
		"NamespacedProviderConfigDeleted": {
			reason: "A namespaced ProviderConfig is deleted when it is gone from its namespace, even if another namespace has one with that name.",
			objs:   []client.Object{namespacedProviderConfig("team-b", "default", "team-b")},
			id:     pcID,
			want:   true,
		},
		"LookupFails": {
			reason:  "A lookup error other than NotFound must not count as deleted.",
			failGet: true,
			id:      cpcID,
			want:    false,
		},
		"UnknownKind": {
			reason: "An identity whose kind is not registered must not count as deleted.",
			id:     ProviderConfigIdentity{Group: namespacedv1beta1.Group, Kind: "Bogus", Name: "pc"},
			want:   false,
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			kube := newFakeClient(t, tc.objs...)
			if tc.failGet {
				kube = failingGetClient{Client: kube}
			}
			if got := providerConfigDeleted(kube)(context.Background(), tc.id); got != tc.want {
				t.Errorf("\n%s\nproviderConfigDeleted(...)(%s): want %t, got %t", tc.reason, tc.id, tc.want, got)
			}
		})
	}
}

func TestTerraformSetupBuilder(t *testing.T) {
	const escapedPassword = "p@ss:w/rd?"
	type args struct {
		objs         []client.Object
		mg           resource.Managed
		configureErr error
	}
	type want struct {
		cfg         map[string]any
		configures  int
		errContains []string
		errExcludes []string
	}
	cpcWith := func(data string) []client.Object {
		return []client.Object{clusterProviderConfig("default"), credentialsSecret(testSecretNS, testSecretName, data)}
	}
	vm := modernMR("team-a", "vm", "ClusterProviderConfig", "default")
	pioneerCfg := map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer, keyAllowUnverifiedSSL: true}
	cases := map[string]struct {
		reason string
		args   args
		want   want
	}{
		"PioneerStringBoolean": {
			reason: "A Secret with allow_unverified_ssl as the string true must configure the provider with a boolean (OT-012).",
			args:   args{objs: cpcWith(pioneerPayload), mg: vm},
			want:   want{cfg: pioneerCfg, configures: 1},
		},
		"NativeBoolean": {
			reason: "A Secret with allow_unverified_ssl as the boolean true must configure the provider the same way (OT-012).",
			args: args{
				objs: cpcWith(payload(t, map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer, keyAllowUnverifiedSSL: true})),
				mg:   vm,
			},
			want: want{cfg: pioneerCfg, configures: 1},
		},
		"APITimeoutString": {
			reason: "A numeric string api_timeout must reach the provider configuration as an int.",
			args: args{
				objs: cpcWith(payload(t, map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer, keyAPITimeout: "10"})),
				mg:   vm,
			},
			want: want{cfg: map[string]any{keyUser: fakeUser, keyPassword: fakePassword, keyVSphereServer: fakeServer, keyAPITimeout: 10}, configures: 1},
		},
		"LegacyMR": {
			reason: "A cluster-scoped MR must be configured from the cluster ProviderConfig's Secret.",
			args: args{
				objs: []client.Object{legacyProviderConfig("default"), credentialsSecret(testSecretNS, testSecretName, pioneerPayload)},
				mg:   legacyMR("vm", "default"),
			},
			want: want{cfg: pioneerCfg, configures: 1},
		},
		"MissingVSphereServer": {
			reason: "A Secret missing vsphere_server must fail naming the key, without a login (OT-013).",
			args:   args{objs: cpcWith(`{"user":"fake-user","password":"fake-password"}`), mg: vm},
			want:   want{errContains: []string{keyVSphereServer}, errExcludes: []string{fakePassword}},
		},
		"MissingProviderConfig": {
			reason: "A namespaced MR naming a missing ProviderConfig must fail with a message naming it, without a login (AC-007).",
			args:   args{mg: modernMR("team-a", "vm", "ProviderConfig", "missing-pc")},
			want:   want{errContains: []string{"missing-pc", errGetProviderConfig}},
		},
		"MissingSecret": {
			reason: "A ProviderConfig whose Secret does not exist must fail with the extract error.",
			args:   args{objs: []client.Object{clusterProviderConfig("default")}, mg: vm},
			want:   want{errContains: []string{errExtractCredentials}},
		},
		"ConfigureErrorIsRedacted": {
			reason: "A login error echoing the user or password must reach the MR with both redacted.",
			args: args{
				objs:         cpcWith(pioneerPayload),
				mg:           vm,
				configureErr: errors.New("cannot login as fake-user with fake-password: ServerFaultCode: Cannot complete login due to an incorrect user name or password."),
			},
			want: want{
				configures:  1,
				errContains: []string{errGetSession, redacted, "incorrect user name or password"},
				errExcludes: []string{fakePassword, fakeUser},
			},
		},
		"ConfigureErrorEscapedPasswordIsRedacted": {
			reason: "A login error echoing the password in URL userinfo encoding must also be redacted.",
			args: args{
				objs:         cpcWith(payload(t, map[string]any{keyUser: fakeUser, keyPassword: escapedPassword, keyVSphereServer: fakeServer})),
				mg:           vm,
				configureErr: errors.New("Post \"https://fake-user:" + url.User(escapedPassword).String() + "@vcenter.invalid/sdk\": password " + escapedPassword),
			},
			want: want{
				configures:  1,
				errContains: []string{redacted},
				errExcludes: []string{escapedPassword, url.User(escapedPassword).String(), fakeUser},
			},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			rec := &configureRecorder{}
			if tc.args.configureErr != nil {
				rec.failFirst, rec.err = 1, tc.args.configureErr
			}
			setupFn := TerraformSetupBuilder(WithSessionCache(NewSessionCache()), WithConfigureFunc(rec.configure))
			ps, err := setupFn(context.Background(), newFakeClient(t, tc.args.objs...), tc.args.mg)

			assertNoSecrets(t, err, tc.want.errExcludes...)
			if got := rec.count(); got != tc.want.configures {
				t.Errorf("\n%s\nconfigure calls: want %d, got %d", tc.reason, tc.want.configures, got)
			}
			if len(tc.want.errContains) > 0 {
				if err == nil {
					t.Fatalf("\n%s\nsetupFn(...): want an error, got nil", tc.reason)
				}
				for _, s := range tc.want.errContains {
					if !strings.Contains(err.Error(), s) {
						t.Errorf("\n%s\nsetupFn(...): want error containing %q, got %q", tc.reason, s, err.Error())
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("\n%s\nsetupFn(...): unexpected error: %v", tc.reason, err)
			}
			if diff := cmp.Diff(tc.want.cfg, map[string]any(ps.Configuration)); diff != "" {
				t.Errorf("\n%s\nSetup.Configuration: -want, +got:\n%s", tc.reason, diff)
			}
			if diff := cmp.Diff(tc.want.cfg, rec.calls[0]); diff != "" {
				t.Errorf("\n%s\nconfiguration passed to configure: -want, +got:\n%s", tc.reason, diff)
			}
			if diff := cmp.Diff(&fakeMeta{ID: 1}, ps.Meta); diff != "" {
				t.Errorf("\n%s\nSetup.Meta: -want, +got:\n%s", tc.reason, diff)
			}
		})
	}
}
