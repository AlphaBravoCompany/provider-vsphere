/*
Copyright 2021 Upbound Inc.
*/

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/alecthomas/kingpin/v2"
	changelogsv1alpha1 "github.com/crossplane/crossplane-runtime/v2/apis/changelogs/proto/v1alpha1"
	xpcontroller "github.com/crossplane/crossplane-runtime/v2/pkg/controller"
	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/crossplane-runtime/v2/pkg/feature"
	"github.com/crossplane/crossplane-runtime/v2/pkg/gate"
	"github.com/crossplane/crossplane-runtime/v2/pkg/logging"
	"github.com/crossplane/crossplane-runtime/v2/pkg/ratelimiter"
	"github.com/crossplane/crossplane-runtime/v2/pkg/reconciler/customresourcesgate"
	"github.com/crossplane/crossplane-runtime/v2/pkg/reconciler/managed"
	"github.com/crossplane/crossplane-runtime/v2/pkg/statemetrics"
	tjcontroller "github.com/crossplane/upjet/v2/pkg/controller"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	authv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	clientgoscheme "k8s.io/client-go/kubernetes/scheme"

	apisCluster "github.com/AlphaBravoCompany/provider-vsphere/apis/cluster"
	apisNamespaced "github.com/AlphaBravoCompany/provider-vsphere/apis/namespaced"
	"github.com/AlphaBravoCompany/provider-vsphere/config"
	"github.com/AlphaBravoCompany/provider-vsphere/internal/clients"
	controllerCluster "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster"
	controllerNamespaced "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/namespaced"
	"github.com/AlphaBravoCompany/provider-vsphere/internal/features"
	"github.com/AlphaBravoCompany/provider-vsphere/internal/version"
)

const (
	webhookTLSCertDirEnvVar = "WEBHOOK_TLS_CERT_DIR"
	tlsServerCertDirEnvVar  = "TLS_SERVER_CERTS_DIR"
	certsDirEnvVar          = "CERTS_DIR"
	tlsServerCertDir        = "/tls/server"
)

const (
	// crdWatchCheckTimeout bounds how long the provider waits at startup for
	// the RBAC permissions it needs for SafeStart. Crossplane's RBAC manager
	// binds the provider's ClusterRole a few seconds after the provider pod
	// can start, so a single check right away often finds the permissions
	// missing and falls back to eager controller setup, which then crash-loops
	// until Crossplane has created every CRD.
	crdWatchCheckTimeout = 2 * time.Minute
	// crdWatchCheckInterval is the time between two RBAC checks.
	crdWatchCheckInterval = 5 * time.Second

	// sessionLogoutTimeout bounds the logout of the cached vCenter sessions
	// when the controller manager stops. It is well inside the default 30s
	// termination grace period of the provider pod.
	sessionLogoutTimeout = 10 * time.Second
)

// crdWatchVerbs are the verbs on CustomResourceDefinitions that SafeStart
// needs.
var crdWatchVerbs = []string{"get", "list", "watch"}

func deprecationAction(flagName string) kingpin.Action {
	return func(c *kingpin.ParseContext) error {
		_, err := fmt.Fprintf(os.Stderr, "warning: Command-line flag %q is deprecated and no longer used. It will be removed in a future release. Please remove it from all of your configurations (DeploymentRuntimeConfigs, etc.).\n", flagName)
		kingpin.FatalIfError(err, "Failed to print the deprecation notice.")
		return nil
	}
}

func main() {
	var (
		app                     = kingpin.New(filepath.Base(os.Args[0]), "Terraform based Crossplane provider for vSphere").DefaultEnvars()
		debug                   = app.Flag("debug", "Run with debug logging.").Short('d').Bool()
		syncPeriod              = app.Flag("sync", "Controller manager sync period such as 300ms, 1.5h, or 2h45m").Short('s').Default("1h").Duration()
		pollInterval            = app.Flag("poll", "Poll interval controls how often an individual resource should be checked for drift.").Default("10m").Duration()
		pollStateMetricInterval = app.Flag("poll-state-metric", "State metric recording interval").Default("5s").Duration()
		leaderElection          = app.Flag("leader-election", "Use leader election for the controller manager.").Short('l').Default("false").OverrideDefaultFromEnvar("LEADER_ELECTION").Bool()
		maxReconcileRate        = app.Flag("max-reconcile-rate", "The global maximum rate per second at which resources may be checked for drift from the desired state.").Default("10").Int()

		webhookPort          = app.Flag("webhook-port", "The port the webhook listens on").Default("9443").Envar("WEBHOOK_PORT").Int()
		metricsBindAddress   = app.Flag("metrics-bind-address", "The address the metrics server listens on").Default(":8080").Envar("METRICS_BIND_ADDRESS").String()
		changelogsSocketPath = app.Flag("changelogs-socket-path", "Path for changelogs socket (if enabled)").Default("/var/run/changelogs/changelogs.sock").Envar("CHANGELOGS_SOCKET_PATH").String()

		enableManagementPolicies = app.Flag("enable-management-policies", "Enable support for Management Policies.").Default("true").Envar("ENABLE_MANAGEMENT_POLICIES").Bool()
		enableChangeLogs         = app.Flag("enable-changelogs", "Enable support for capturing change logs during reconciliation.").Default("false").Envar("ENABLE_CHANGE_LOGS").Bool()
		enableSecretCache        = app.Flag("enable-secret-cache", "Enable caching of Secret objects. When true, Secrets are served from the informer cache instead of direct API calls. This reduces API server load but increases memory usage.").Default("true").Envar("ENABLE_SECRET_CACHE").Bool()

		certsDirSet = false
		// we record whether the command-line option "--certs-dir" was supplied
		// in the registered PreAction for the flag.
		certsDir = app.Flag("certs-dir", "The directory that contains the server key and certificate.").Default(tlsServerCertDir).Envar(certsDirEnvVar).PreAction(func(_ *kingpin.ParseContext) error {
			certsDirSet = true
			return nil
		}).String()

		// now deprecated command-line arguments with the Terraform SDK-based upjet architecture
		_ = app.Flag("terraform-version", "[DEPRECATED: This option is no longer used and it will be removed in a future release.] Terraform version.").Envar("TERRAFORM_VERSION").Hidden().Action(deprecationAction("terraform-version")).String()
		_ = app.Flag("terraform-provider-version", "[DEPRECATED: This option is no longer used and it will be removed in a future release.] Terraform provider version.").Envar("TERRAFORM_PROVIDER_VERSION").Hidden().Action(deprecationAction("terraform-provider-version")).String()
		_ = app.Flag("terraform-provider-source", "[DEPRECATED: This option is no longer used and it will be removed in a future release.] Terraform provider source.").Envar("TERRAFORM_PROVIDER_SOURCE").Hidden().Action(deprecationAction("terraform-provider-source")).String()
	)

	kingpin.MustParse(app.Parse(os.Args[1:]))

	zl := zap.New(zap.UseDevMode(*debug))
	log := logging.NewLogrLogger(zl.WithName("provider-vsphere"))
	if *debug {
		// The controller-runtime runs with a no-op logger by default. It is
		// *very* verbose even at info level, so we only provide it a real
		// logger when we're running in debug mode.
		ctrl.SetLogger(zl)
	}

	log.Debug("Starting", "sync-period", syncPeriod.String(), "poll-interval", pollInterval.String(), "max-reconcile-rate", *maxReconcileRate)

	cfg, err := ctrl.GetConfig()
	kingpin.FatalIfError(err, "Cannot get API server rest config")

	// Get the TLS certs directory from the environment variables set by
	// Crossplane if they're available.
	// In older XP versions we used WEBHOOK_TLS_CERT_DIR, in newer versions
	// we use TLS_SERVER_CERTS_DIR. If an explicit certs dir is not supplied
	// via the command-line options, then these environment variables are used
	// instead.
	if !certsDirSet {
		// backwards-compatibility concerns
		xpCertsDir := os.Getenv(certsDirEnvVar)
		if xpCertsDir == "" {
			xpCertsDir = os.Getenv(tlsServerCertDirEnvVar)
		}
		if xpCertsDir == "" {
			xpCertsDir = os.Getenv(webhookTLSCertDirEnvVar)
		}
		// we probably don't need this condition but just to be on the
		// safe side, if we are missing any kingpin machinery details...
		if xpCertsDir != "" {
			*certsDir = xpCertsDir
		}
	}

	var clientOpts client.Options
	if !*enableSecretCache {
		// When secret caching is disabled, configure the client to bypass
		// the cache for Secret objects. This means Get/List calls for
		// Secrets will go directly to the API server.
		clientOpts = client.Options{
			Cache: &client.CacheOptions{
				DisableFor: []client.Object{&corev1.Secret{}},
			},
		}
	}

	scheme := runtime.NewScheme()
	kingpin.FatalIfError(clientgoscheme.AddToScheme(scheme), "Cannot add clientgo scheme")
	kingpin.FatalIfError(apisCluster.AddToScheme(scheme), "Cannot add cluster-scoped vSphere APIs to scheme")
	kingpin.FatalIfError(apisNamespaced.AddToScheme(scheme), "Cannot add namespace-scoped vSphere APIs to scheme")
	kingpin.FatalIfError(apiextensionsv1.AddToScheme(scheme), "Cannot add CustomResourceDefinition to scheme")

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:           scheme,
		LeaderElection:   *leaderElection,
		LeaderElectionID: "crossplane-leader-election-provider-vsphere",
		Cache: cache.Options{
			SyncPeriod: syncPeriod,
			ByObject: map[client.Object]cache.ByObject{
				&apiextensionsv1.CustomResourceDefinition{}: {
					Transform: customresourcesgate.TransformStripCRDSchema,
				},
			},
		},
		Client: clientOpts,
		Metrics: metricsserver.Options{
			BindAddress: *metricsBindAddress,
		},
		WebhookServer: webhook.NewServer(
			webhook.Options{
				CertDir: *certsDir,
				Port:    *webhookPort,
			}),
		LeaderElectionResourceLock: resourcelock.LeasesResourceLock,
		LeaseDuration:              func() *time.Duration { d := 60 * time.Second; return &d }(),
		RenewDeadline:              func() *time.Duration { d := 50 * time.Second; return &d }(),
	})
	kingpin.FatalIfError(err, "Cannot create controller manager")
	kingpin.FatalIfError(apisCluster.AddToScheme(mgr.GetScheme()), "Cannot add cluster-scoped vSphere APIs to scheme")
	kingpin.FatalIfError(apisNamespaced.AddToScheme(mgr.GetScheme()), "Cannot add namespaced vSphere APIs to scheme")
	kingpin.FatalIfError(apiextensionsv1.AddToScheme(mgr.GetScheme()), "Cannot add api-extensions APIs to scheme")
	kingpin.FatalIfError(authv1.AddToScheme(mgr.GetScheme()), "Cannot add k8s authorization APIs to scheme")

	metricRecorder := managed.NewMRMetricRecorder()
	stateMetrics := statemetrics.NewMRStateMetrics()

	metrics.Registry.MustRegister(metricRecorder)
	metrics.Registry.MustRegister(stateMetrics)

	// One SetupFn (and therefore one vCenter session cache) is shared by the
	// cluster-scoped and the namespaced controllers. The vSphere Terraform
	// provider runs in-process (no-fork), so no Terraform CLI or provider
	// plugin binary is used at runtime.
	sessionCache := clients.NewSessionCache()
	setupFn := clients.TerraformSetupBuilder(clients.WithSessionCache(sessionCache))
	// Log out every cached vCenter session when the controller manager stops,
	// instead of leaving them open until vCenter's idle timeout.
	kingpin.FatalIfError(mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		<-ctx.Done()
		logoutSessions(ctx, sessionCache, log)
		return nil
	})), "Cannot add the vCenter session logout to the controller manager")

	clusterOpts := tjcontroller.Options{
		Options: xpcontroller.Options{
			Logger:                  log,
			GlobalRateLimiter:       ratelimiter.NewGlobal(*maxReconcileRate),
			PollInterval:            *pollInterval,
			MaxConcurrentReconciles: *maxReconcileRate,
			Features:                &feature.Flags{},
			MetricOptions: &xpcontroller.MetricOptions{
				PollStateMetricInterval: *pollStateMetricInterval,
				MRMetrics:               metricRecorder,
				MRStateMetrics:          stateMetrics,
			},
		},
		Provider:              config.GetProvider(),
		SetupFn:               setupFn,
		OperationTrackerStore: tjcontroller.NewOperationStore(log),
		StartWebhooks:         *certsDir != "",
	}

	namespacedOpts := tjcontroller.Options{
		Options: xpcontroller.Options{
			Logger:                  log,
			GlobalRateLimiter:       ratelimiter.NewGlobal(*maxReconcileRate),
			PollInterval:            *pollInterval,
			MaxConcurrentReconciles: *maxReconcileRate,
			Features:                &feature.Flags{},
			MetricOptions: &xpcontroller.MetricOptions{
				PollStateMetricInterval: *pollStateMetricInterval,
				MRMetrics:               metricRecorder,
				MRStateMetrics:          stateMetrics,
			},
		},
		Provider:              config.GetProviderNamespaced(),
		SetupFn:               setupFn,
		OperationTrackerStore: tjcontroller.NewOperationStore(log),
		StartWebhooks:         *certsDir != "",
	}

	if *enableManagementPolicies {
		clusterOpts.Features.Enable(features.EnableBetaManagementPolicies)
		namespacedOpts.Features.Enable(features.EnableBetaManagementPolicies)
		log.Info("Beta feature enabled", "flag", features.EnableBetaManagementPolicies)
	}

	if *enableChangeLogs {
		clusterOpts.Features.Enable(feature.EnableAlphaChangeLogs)
		namespacedOpts.Features.Enable(feature.EnableAlphaChangeLogs)
		log.Info("Alpha feature enabled", "flag", feature.EnableAlphaChangeLogs)

		conn, err := grpc.NewClient("unix://"+*changelogsSocketPath, grpc.WithTransportCredentials(insecure.NewCredentials()))
		kingpin.FatalIfError(err, "failed to create change logs client connection at %s", *changelogsSocketPath)

		clo := xpcontroller.ChangeLogOptions{
			ChangeLogger: managed.NewGRPCChangeLogger(
				changelogsv1alpha1.NewChangeLogServiceClient(conn),
				managed.WithProviderVersion(fmt.Sprintf("provider-vsphere:%s", version.Version))),
		}
		clusterOpts.ChangeLogOptions = &clo
		namespacedOpts.ChangeLogOptions = &clo
	}

	canSafeStart, err := canWatchCRD(context.TODO(), mgr, log)
	kingpin.FatalIfError(err, "SafeStart precheck failed")
	if canSafeStart {
		crdGate := new(gate.Gate[schema.GroupVersionKind])
		clusterOpts.Gate = crdGate
		namespacedOpts.Gate = crdGate
		kingpin.FatalIfError(customresourcesgate.Setup(mgr, xpcontroller.Options{
			Logger:                  log,
			Gate:                    crdGate,
			MaxConcurrentReconciles: 1,
		}), "Cannot setup CRD gate")
		log.Info("SafeStart capability enabled, controllers are gated on CRD availability")
		kingpin.FatalIfError(controllerCluster.SetupGated(mgr, clusterOpts), "Cannot setup cluster-scoped vSphere controllers")
		kingpin.FatalIfError(controllerNamespaced.SetupGated(mgr, namespacedOpts), "Cannot setup namespaced vSphere controllers")
	} else {
		log.Info("Provider has missing RBAC permissions for watching CRDs, controller SafeStart capability will be disabled")
		kingpin.FatalIfError(controllerCluster.Setup(mgr, clusterOpts), "Cannot setup cluster-scoped vSphere controllers")
		kingpin.FatalIfError(controllerNamespaced.Setup(mgr, namespacedOpts), "Cannot setup namespaced vSphere controllers")
	}

	kingpin.FatalIfError(mgr.Start(ctrl.SetupSignalHandler()), "Cannot start controller manager")
}

// logoutSessions closes the session cache, logging out its vCenter sessions
// within sessionLogoutTimeout. ctx is already done when the manager stops, so
// only its values are kept. A failure is logged, not returned, so it never
// fails the shutdown.
func logoutSessions(ctx context.Context, c *clients.SessionCache, log logging.Logger) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sessionLogoutTimeout)
	defer cancel()
	if err := c.Close(ctx); err != nil {
		log.Info("Cannot log out every cached vCenter session on shutdown", "error", err)
	}
}

// canWatchCRD reports whether the provider may get, list and watch
// CustomResourceDefinitions. It retries for up to crdWatchCheckTimeout until
// all three verbs are allowed, so it does not race Crossplane's RBAC manager.
func canWatchCRD(ctx context.Context, mgr manager.Manager, log logging.Logger) (bool, error) {
	if err := authv1.AddToScheme(mgr.GetScheme()); err != nil {
		return false, err
	}
	return waitUntilAllowed(ctx, log, crdWatchCheckTimeout, crdWatchCheckInterval, func(ctx context.Context) (bool, error) {
		return crdWatchAllowed(ctx, mgr.GetClient())
	})
}

// waitUntilAllowed calls check every interval until it reports true or timeout
// has elapsed. It returns false when the last completed check was denied. An
// API error is retried too, as the API server may be briefly unavailable while
// the provider starts; it is returned only when the last completed check
// failed with it, so a persistent error is still fatal, just later. A check
// cut short by the end of the window does not count.
func waitUntilAllowed(ctx context.Context, log logging.Logger, timeout, interval time.Duration, check func(context.Context) (bool, error)) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var lastErr error
	for {
		allowed, err := check(ctx)
		switch {
		case err == nil && allowed:
			return true, nil
		case err == nil:
			lastErr = nil
			log.Debug("Provider does not have RBAC permissions for watching CRDs yet, retrying", "interval", interval)
		case ctx.Err() == nil:
			lastErr = err
			log.Debug("RBAC check for watching CRDs failed, retrying", "interval", interval, "error", err)
		}
		t := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			t.Stop()
			return false, lastErr
		case <-t.C:
		}
	}
}

// crdWatchAllowed reports whether a SelfSubjectAccessReview allows each of
// the get, list and watch verbs on CustomResourceDefinitions.
func crdWatchAllowed(ctx context.Context, c client.Client) (bool, error) {
	for _, verb := range crdWatchVerbs {
		sar := &authv1.SelfSubjectAccessReview{
			Spec: authv1.SelfSubjectAccessReviewSpec{
				ResourceAttributes: &authv1.ResourceAttributes{
					Group:    "apiextensions.k8s.io",
					Resource: "customresourcedefinitions",
					Verb:     verb,
				},
			},
		}
		if err := c.Create(ctx, sar); err != nil {
			return false, errors.Wrapf(err, "unable to perform RBAC check for verb %s on CustomResourceDefinitions", verb)
		}
		if !sar.Status.Allowed {
			return false, nil
		}
	}
	return true, nil
}
