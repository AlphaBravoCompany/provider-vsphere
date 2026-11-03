/*
Copyright 2021 Upbound Inc.
*/

package clients

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/crossplane/crossplane-runtime/v2/pkg/resource"
	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"
	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	tfsdk "github.com/hashicorp/terraform-plugin-sdk/v2/terraform"
	"github.com/pkg/errors"
	"github.com/vmware/govmomi"
	"github.com/vmware/terraform-provider-vsphere/vsphere"
	corev1 "k8s.io/api/core/v1"
	kerrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	ujresource "github.com/crossplane/upjet/v2/pkg/resource"
	"github.com/crossplane/upjet/v2/pkg/terraform"

	clusterv1beta1 "github.com/AlphaBravoCompany/provider-vsphere/apis/cluster/v1beta1"
	namespacedv1beta1 "github.com/AlphaBravoCompany/provider-vsphere/apis/namespaced/v1beta1"
)

const (
	// error messages
	errNoProviderConfig      = "no providerConfigRef provided"
	errGetProviderConfig     = "cannot get referenced ProviderConfig"
	errTrackUsage            = "cannot track ProviderConfig usage"
	errExtractCredentials    = "cannot extract credentials"
	errUnmarshalCredentials  = "cannot unmarshal vsphere credentials as JSON"
	errResolveProviderConfig = "cannot resolve provider config"
	errNotManaged            = "resource is not a managed resource"
	errUnknownPCGVK          = "unknown GVK for ProviderConfig"
	errPCNotObject           = "resolved ProviderConfig is not a client.Object"
	errUnknownPCType         = "unknown provider config type"
	errGetSession            = "cannot get a configured vSphere client"
	errConfigureProvider     = "cannot configure the vSphere provider"
	errNoVIMClientField      = "cannot log out the vCenter SOAP session: vsphere.Client has no field vimClient of type *govmomi.Client"

	// Credential parse errors name the key and never include a value.
	errFmtCredentialsSyntax = errUnmarshalCredentials + ": syntax error at byte offset %d"
	errFmtMissingKey        = "credentials key %q is missing or empty"
	errFmtNotString         = "credentials key %q must be a string"
	errFmtNotBool           = "credentials key %q must be a boolean (true or false, as a JSON boolean or a string)"
	errFmtNotMinutes        = "credentials key %q must be a positive integer (minutes), as a JSON number or a numeric string"

	// Keys of the JSON object stored in the credentials Secret. They are also
	// the vSphere provider's configuration argument names.
	keyVSphereServer      = "vsphere_server"
	keyUser               = "user"
	keyPassword           = "password"
	keyAllowUnverifiedSSL = "allow_unverified_ssl"
	keyAPITimeout         = "api_timeout"

	redacted = "[redacted]"
)

// ConfigureFunc configures a vSphere provider with cfg (a vCenter login) and
// returns its Meta.
type ConfigureFunc func(ctx context.Context, cfg map[string]any) (any, error)

// SetupOption customizes the SetupFn built by TerraformSetupBuilder.
type SetupOption func(*setupOptions)

type setupOptions struct {
	cache     *SessionCache
	configure ConfigureFunc
}

// WithSessionCache makes the SetupFn use c instead of the process-wide cache.
func WithSessionCache(c *SessionCache) SetupOption {
	return func(o *setupOptions) {
		o.cache = c
	}
}

// WithConfigureFunc makes the SetupFn configure clients with fn instead of the
// in-process vSphere provider.
func WithConfigureFunc(fn ConfigureFunc) SetupOption {
	return func(o *setupOptions) {
		o.configure = fn
	}
}

// defaultSessionCache is shared by every SetupFn in the process, so all
// controllers reuse one cached client per ProviderConfig identity.
var defaultSessionCache = NewSessionCache()

// TerraformSetupBuilder returns the terraform.SetupFn used by the no-fork
// controllers. For each reconcile it resolves the ProviderConfig or
// ClusterProviderConfig, reads and types the credentials, and returns a
// vSphere client configured in-process. The client comes from the session
// cache when one was already built for the same ProviderConfig and
// credentials, so a vCenter login happens only on a cache miss. No Terraform
// CLI and no workspace are used.
func TerraformSetupBuilder(opts ...SetupOption) terraform.SetupFn {
	o := setupOptions{cache: defaultSessionCache, configure: defaultConfigure}
	for _, opt := range opts {
		opt(&o)
	}

	return func(ctx context.Context, crClient client.Client, mg resource.Managed) (terraform.Setup, error) {
		// Log out the clients of deleted ProviderConfigs first, so this also
		// happens when this reconcile fails.
		o.cache.EvictDeleted(ctx, providerConfigDeleted(crClient))

		pcSpec, id, err := resolveProviderConfig(ctx, crClient, mg)
		if err != nil {
			return terraform.Setup{}, errors.Wrap(err, errResolveProviderConfig)
		}

		data, err := resource.CommonCredentialExtractor(ctx, pcSpec.Credentials.Source, crClient, pcSpec.Credentials.CommonCredentialSelectors)
		if err != nil {
			return terraform.Setup{}, errors.Wrap(err, errExtractCredentials)
		}
		cfg, err := parseCredentials(data)
		if err != nil {
			return terraform.Setup{}, err
		}

		evictOnAuthFailure(o.cache, id, mg)
		meta, err := o.cache.GetOrCreate(ctx, id, credentialsHash(data), func(ctx context.Context) (any, error) {
			// The client outlives this reconcile, so do not let the
			// reconcile's cancellation reach the configure call.
			return o.configure(context.WithoutCancel(ctx), cfg)
		})
		if err != nil {
			user, _ := cfg[keyUser].(string)
			password, _ := cfg[keyPassword].(string)
			return terraform.Setup{}, errors.Wrap(redact(err, user, password), errGetSession)
		}

		return terraform.Setup{Configuration: cfg, Meta: meta}, nil
	}
}

// defaultConfigure configures a new instance of the vSphere Terraform provider
// in-process and returns its Meta (a *vsphere.Client). Each cache miss gets a
// fresh provider and client, so no two cache entries share a provider instance
// or a client. They do share the process-wide state of the pinned
// vmware/vsphere (v2.15.1):
//
//   - api_timeout: besides the client's own copy, which only the
//     VirtualMachine resource reads, every Configure writes it to the
//     package-level defaultAPITimeout (vsphere/provider.go), which the login
//     and many vSphere calls of every client read. An omitted api_timeout
//     writes the default (VSPHERE_API_TIMEOUT, else 5 minutes). The most
//     recent login of any ProviderConfig therefore sets it for the whole pod;
//     see the api_timeout note in the Credentials section of README.md.
//   - govmomi debug logging: when client_debug is true, Configure installs a
//     process-wide govmomi debug provider that is never removed.
//     parseCredentials does not forward client_debug, so only the
//     VSPHERE_CLIENT_DEBUG environment variable of the pod enables it.
//   - persisted sessions: parseCredentials does not forward persist_session
//     either. If VSPHERE_PERSIST_SESSION enables it, clients with the same
//     vsphere_server, user and allow_unverified_ssl load one vCenter session
//     saved on disk.
func defaultConfigure(ctx context.Context, cfg map[string]any) (any, error) {
	p := vsphere.Provider()
	if diags := p.Configure(ctx, &tfsdk.ResourceConfig{Config: cfg}); diags.HasError() {
		return nil, errors.Wrap(diagnosticsError(diags), errConfigureProvider)
	}
	return p.Meta(), nil
}

// logoutClient ends both vCenter sessions of a *vsphere.Client that left the
// session cache: the CIS REST session (tags, content library) and the VIM SOAP
// session (also used by its PBM and vSAN clients). Each logout also stops the
// govmomi keep-alive goroutine of that session, which otherwise keeps the
// session open on vCenter until the pod stops. A failed vCenter call is
// ignored, because the session may already have ended, and nothing is logged,
// so no credential can leak. It returns an error, after the REST logout, only
// when the SOAP session cannot be reached (see vimClientOf). Any other meta is
// ignored.
func logoutClient(ctx context.Context, meta any) error {
	c, ok := meta.(*vsphere.Client)
	if !ok || c == nil {
		return nil
	}
	vim, ok := vimClientOf(reflect.ValueOf(c))
	if ok && vim == nil {
		// Not a configured client, so it holds no session.
		return nil
	}
	// TagsManager fails when the client has no REST session.
	if tm, err := c.TagsManager(); err == nil {
		_ = tm.Logout(ctx)
		tm.CloseIdleConnections()
	}
	if !ok {
		return errors.New(errNoVIMClientField)
	}
	_ = vim.Logout(ctx)
	return nil
}

// vimClientOf returns the value of the unexported field vimClient of the
// struct that p, a non-nil struct pointer, points to, and whether that field
// exists with type *govmomi.Client. vsphere.Client of the pinned
// vmware/terraform-provider-vsphere (v2.15.1) keeps its SOAP client in that
// field and has no accessor, Close or Logout method for it, so reading the
// field is the only way to end that session. reflect finds the field, and
// reflect.NewAt makes a readable value of it at its address. If a later
// vSphere provider renames or retypes the field, vimClientOf reports false
// instead of panicking, logoutClient skips the SOAP logout, and
// TestVSphereClientKeepsVIMClientField fails.
func vimClientOf(p reflect.Value) (*govmomi.Client, bool) {
	f := p.Elem().FieldByName("vimClient")
	if !f.IsValid() || f.Type() != reflect.TypeFor[*govmomi.Client]() {
		return nil, false
	}
	// f is addressable because p is a pointer, and its type is checked above.
	vim := reflect.NewAt(f.Type(), unsafe.Pointer(f.UnsafeAddr())).Elem() //nolint:gosec // G103: reads one unexported field whose name and type are checked above.
	return vim.Interface().(*govmomi.Client), true
}

// providerConfigDeleted returns a DeletedFunc that looks the ProviderConfig or
// ClusterProviderConfig up with crClient and reports it deleted only when the
// lookup returns NotFound.
func providerConfigDeleted(crClient client.Client) DeletedFunc {
	return func(ctx context.Context, id ProviderConfigIdentity) bool {
		gv := namespacedv1beta1.SchemeGroupVersion
		if id.Group == clusterv1beta1.Group {
			gv = clusterv1beta1.SchemeGroupVersion
		}
		obj, err := crClient.Scheme().New(gv.WithKind(id.Kind))
		if err != nil {
			return false
		}
		pc, ok := obj.(client.Object)
		if !ok {
			return false
		}
		return kerrors.IsNotFound(crClient.Get(ctx, types.NamespacedName{Namespace: id.Namespace, Name: id.Name}, pc))
	}
}

// diagnosticsError joins the error diagnostics into one error.
func diagnosticsError(diags diag.Diagnostics) error {
	msgs := make([]string, 0, len(diags))
	for _, d := range diags {
		if d.Severity != diag.Error {
			continue
		}
		m := d.Summary
		if d.Detail != "" {
			m += ": " + d.Detail
		}
		msgs = append(msgs, m)
	}
	return errors.New(strings.Join(msgs, "; "))
}

// evictOnAuthFailure evicts the cached client for id when mg reports, in its
// Synced or LastAsyncOperation condition, an authentication or session failure
// observed after that client was created. The SetupFn cannot see the error of
// the external client's vSphere call, but the managed reconciler and upjet's
// async callbacks record it on these conditions before the next reconcile, so
// the dead session is dropped before the retry uses it.
func evictOnAuthFailure(cache *SessionCache, id ProviderConfigIdentity, mg resource.Managed) {
	for _, ct := range []xpv2.ConditionType{xpv2.TypeSynced, ujresource.TypeLastAsyncOperation} {
		cond := mg.GetCondition(ct)
		if cond.Status != corev1.ConditionFalse || !IsAuthOrSessionError(cond.Message) {
			continue
		}
		// Conditions read from the API server have second precision, so a
		// client created within the same second as the failure counts as
		// older. That costs at most one extra login. Keeping it instead could
		// reuse a dead session indefinitely: a repeated identical failure does
		// not move LastTransitionTime.
		cutoff := cond.LastTransitionTime.Truncate(time.Second).Add(time.Second)
		cache.EvictIfOlderThan(id, cutoff)
	}
}

// credentialsHash returns the hex SHA-256 of the raw credentials.
func credentialsHash(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// parseCredentials parses the credentials Secret payload into the vSphere
// provider configuration. user, password and vsphere_server are required
// non-empty strings. allow_unverified_ssl is optional and may be a JSON boolean
// or a string accepted by strconv.ParseBool. api_timeout is optional and may be
// a whole JSON number or a numeric string, in minutes. Unknown keys are not
// forwarded. Errors name the offending key and never include a value.
func parseCredentials(raw []byte) (map[string]any, error) {
	creds := map[string]any{}
	if err := json.Unmarshal(raw, &creds); err != nil {
		// A syntax error quotes the offending character of the payload, so
		// report only its position.
		var se *json.SyntaxError
		if errors.As(err, &se) {
			return nil, errors.Errorf(errFmtCredentialsSyntax, se.Offset)
		}
		return nil, errors.Wrap(err, errUnmarshalCredentials)
	}

	cfg := make(map[string]any, 5)
	for _, k := range []string{keyUser, keyPassword, keyVSphereServer} {
		v, err := requiredString(creds, k)
		if err != nil {
			return nil, err
		}
		cfg[k] = v
	}
	if err := setOptional(cfg, creds, keyAllowUnverifiedSSL, errFmtNotBool, parseBool); err != nil {
		return nil, err
	}
	if err := setOptional(cfg, creds, keyAPITimeout, errFmtNotMinutes, parseMinutes); err != nil {
		return nil, err
	}
	return cfg, nil
}

// setOptional parses creds[key] with parse and stores the result in cfg[key].
// An absent or JSON null key is left unset.
func setOptional[T any](cfg, creds map[string]any, key, errFmt string, parse func(any) (T, bool)) error {
	v, ok := creds[key]
	if !ok || v == nil {
		return nil
	}
	parsed, ok := parse(v)
	if !ok {
		return errors.Errorf(errFmt, key)
	}
	cfg[key] = parsed
	return nil
}

func requiredString(creds map[string]any, key string) (string, error) {
	v, ok := creds[key]
	if !ok || v == nil {
		return "", errors.Errorf(errFmtMissingKey, key)
	}
	s, ok := v.(string)
	if !ok {
		return "", errors.Errorf(errFmtNotString, key)
	}
	if s == "" {
		return "", errors.Errorf(errFmtMissingKey, key)
	}
	return s, nil
}

func parseBool(v any) (bool, bool) {
	switch t := v.(type) {
	case bool:
		return t, true
	case string:
		b, err := strconv.ParseBool(strings.TrimSpace(t))
		return b, err == nil
	default:
		return false, false
	}
}

func parseMinutes(v any) (int, bool) {
	var n float64
	switch t := v.(type) {
	case float64:
		n = t
	case string:
		i, err := strconv.Atoi(strings.TrimSpace(t))
		if err != nil {
			return 0, false
		}
		n = float64(i)
	default:
		return 0, false
	}
	// The upper bound keeps the conversion to int well defined.
	if n != math.Trunc(n) || n < 1 || n > math.MaxInt32 {
		return 0, false
	}
	return int(n), true
}

// redact returns err with every occurrence of the given secrets, raw and in
// URL userinfo encoding, replaced, so that an error text echoing the vCenter
// user or password is never surfaced in a condition or a log.
func redact(err error, secrets ...string) error {
	msg := err.Error()
	for _, s := range secrets {
		if s == "" {
			continue
		}
		msg = strings.ReplaceAll(msg, s, redacted)
		if escaped := url.User(s).String(); escaped != s {
			msg = strings.ReplaceAll(msg, escaped, redacted)
		}
	}
	return errors.New(msg)
}

func toSharedPCSpec(pc *clusterv1beta1.ProviderConfig) (*namespacedv1beta1.ProviderConfigSpec, error) {
	if pc == nil {
		return nil, nil
	}
	data, err := json.Marshal(pc.Spec)
	if err != nil {
		return nil, err
	}

	var mSpec namespacedv1beta1.ProviderConfigSpec
	err = json.Unmarshal(data, &mSpec)
	return &mSpec, err
}

// resolveProviderConfig returns the credentials spec of the ProviderConfig or
// ClusterProviderConfig that mg references, plus the identity the session
// cache keys that config by.
func resolveProviderConfig(ctx context.Context, crClient client.Client, mg resource.Managed) (*namespacedv1beta1.ProviderConfigSpec, ProviderConfigIdentity, error) {
	switch managed := mg.(type) {
	case resource.LegacyManaged: //nolint:staticcheck // still handling cluster-scoped behavior
		return resolveLegacy(ctx, crClient, managed)
	case resource.ModernManaged:
		return resolveModern(ctx, crClient, managed)
	default:
		return nil, ProviderConfigIdentity{}, errors.New(errNotManaged)
	}
}

func resolveLegacy(ctx context.Context, client client.Client, mg resource.LegacyManaged) (*namespacedv1beta1.ProviderConfigSpec, ProviderConfigIdentity, error) { //nolint:staticcheck // still handling cluster-scoped behavior
	configRef := mg.GetProviderConfigReference()
	if configRef == nil {
		return nil, ProviderConfigIdentity{}, errors.New(errNoProviderConfig)
	}
	pc := &clusterv1beta1.ProviderConfig{}
	if err := client.Get(ctx, types.NamespacedName{Name: configRef.Name}, pc); err != nil {
		return nil, ProviderConfigIdentity{}, errors.Wrap(err, errGetProviderConfig)
	}

	t := resource.NewLegacyProviderConfigUsageTracker(client, &clusterv1beta1.ProviderConfigUsage{})
	if err := t.Track(ctx, mg); err != nil {
		return nil, ProviderConfigIdentity{}, errors.Wrap(err, errTrackUsage)
	}

	pcSpec, err := toSharedPCSpec(pc)
	id := ProviderConfigIdentity{Group: clusterv1beta1.Group, Kind: clusterv1beta1.ProviderConfigKind, Name: configRef.Name}
	return pcSpec, id, err
}

func resolveModern(ctx context.Context, crClient client.Client, mg resource.ModernManaged) (*namespacedv1beta1.ProviderConfigSpec, ProviderConfigIdentity, error) {
	configRef := mg.GetProviderConfigReference()
	if configRef == nil {
		return nil, ProviderConfigIdentity{}, errors.New(errNoProviderConfig)
	}

	pcRuntimeObj, err := crClient.Scheme().New(namespacedv1beta1.SchemeGroupVersion.WithKind(configRef.Kind))
	if err != nil {
		return nil, ProviderConfigIdentity{}, errors.Wrap(err, errUnknownPCGVK)
	}
	pcObj, ok := pcRuntimeObj.(client.Object)
	if !ok {
		// This indicates a programming error, types are not properly generated
		return nil, ProviderConfigIdentity{}, errors.New(errPCNotObject)
	}

	// Namespace will be ignored if the PC is a cluster-scoped type
	if err := crClient.Get(ctx, types.NamespacedName{Name: configRef.Name, Namespace: mg.GetNamespace()}, pcObj); err != nil {
		return nil, ProviderConfigIdentity{}, errors.Wrap(err, errGetProviderConfig)
	}

	var pcSpec namespacedv1beta1.ProviderConfigSpec
	id := ProviderConfigIdentity{Group: namespacedv1beta1.Group, Name: configRef.Name}
	pcu := &namespacedv1beta1.ProviderConfigUsage{}
	switch pc := pcObj.(type) {
	case *namespacedv1beta1.ProviderConfig:
		pcSpec = pc.Spec
		if pcSpec.Credentials.SecretRef != nil {
			pcSpec.Credentials.SecretRef.Namespace = mg.GetNamespace()
		}
		id.Kind = namespacedv1beta1.ProviderConfigKind
		id.Namespace = mg.GetNamespace()
	case *namespacedv1beta1.ClusterProviderConfig:
		pcSpec = pc.Spec
		// Cluster-scoped: MRs in every namespace share one cache entry.
		id.Kind = namespacedv1beta1.ClusterProviderConfigKind
	default:
		return nil, ProviderConfigIdentity{}, errors.New(errUnknownPCType)
	}
	t := resource.NewProviderConfigUsageTracker(crClient, pcu)
	if err := t.Track(ctx, mg); err != nil {
		return nil, ProviderConfigIdentity{}, errors.Wrap(err, errTrackUsage)
	}
	return &pcSpec, id, nil
}
