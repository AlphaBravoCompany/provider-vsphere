#!/usr/bin/env bash
#
# Lab end-to-end test for provider-vsphere (FR-111, CT-005, NFR-001, NFR-002).
#
# A HUMAN runs this by hand against a dedicated lab k3s cluster and a lab vCenter. It must never
# run from CI or from an automated agent. The usual entry point is the Makefile:
#
#   make e2e-lab E2E_CROSSPLANE_VERSION=2.2.0 \
#     E2E_PROVIDER_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
#
# What it does, in order (run it with --dry-run first to see every command):
#   1. read-only preflight on the pinned kube context and the lab vCenter;
#   2. version gate (AC-008): Crossplane 1.20.x must reject the package (managed mode only);
#   3. install Crossplane v2 (managed mode) or use the existing one (--existing-crossplane);
#   4. install the provider package and record whether SafeStart engaged (FR-110, info only);
#   5. create a cluster-scoped and a namespaced VirtualMachine from examples/ and assert AC-005,
#      AC-006, AC-007, AC-016, AC-018, AC-019 and AC-021. A third, namespaced VM checks three
#      known upjet/vSphere-provider behaviors of this provider lineage: INITPROVIDER (ankasoft
#      #5), LATEINIT-DISABLED (ankasoft #7: an out-of-band change to a field Crossplane does not
#      manage, one that is optional, provider-computed, late-init-ignored and not set in
#      forProvider, such as annotation, is not reverted), and DEFAULTED-DRIFT-CORRECTED
#      (A-036/OT-019: an out-of-band change to an unset field that the provider enforces as its
#      schema default or zero value, such as cpu_reservation, is corrected, which may power a
#      powered-off VM back on with vSphere provider 2.15.1);
#   6. AC-022 password rotation, when E2E_VSPHERE_ROTATED_PASSWORD is set: the run records the
#      provider-user session keys, pauses on /dev/tty for you to change the vCenter password,
#      then logs govc in with the rotated password only (vCenter rejects the original from then
#      on), re-samples the keys before it rotates the credentials Secrets, touches each VM and
#      requires both Synced=True and, per rotated ProviderConfig, a NEW vCenter session: one
#      whose session key was not listed before the rotation -- vCenter keeps the old session
#      alive across a password change, so Synced=True alone cannot tell a rebuilt client from a
#      reused one.
#      Keys, not vCenter's loginTime, identify it, so the check does not depend on the vCenter
#      and workstation clocks agreeing. Then, after E2E_LOGOUT_DELAY (default 70m, matching the
#      provider's delayed client logout) plus E2E_LOGOUT_SLACK (default 10m) measured on this
#      workstation's clock from when the new session was first seen (not from the rotation
#      itself, which can precede it by up to one poll interval), confirms every pre-rotation
#      session key is gone;
#   7. delete every object this run labelled (unless --skip-cleanup), then print a PASS/FAIL
#      table.
#
# AC-022 is a US-006 criterion, so it is part of the release gate (FR-111): at least one release
# run sets E2E_REQUIRE_AC022=true. Then a missing E2E_VSPHERE_ROTATED_PASSWORD is rejected before
# anything is touched, and an AC-022 that ends SKIPPED for any reason fails the run. With the
# default E2E_REQUIRE_AC022=false a run may skip AC-022, and a passing run then says on its
# Result line that AC-022 was not asserted, so it cannot pass for a full gate run.
#
# Credentials come only from the environment (NFR-103). The passwords (VSPHERE_PASSWORD and
# E2E_VSPHERE_ROTATED_PASSWORD) are never printed and never put on a command line: the Secret
# JSON is piped through stdin, and govc receives them as environment variables of its own
# process only. VSPHERE_USER and VSPHERE_SERVER are printed in the plan.
#
# The jq programs below are single-quoted on purpose: their $names are jq variables.
# shellcheck disable=SC2016
set -Eeuo pipefail

# Minimum tool versions, defined only here: the bash check below, check_tools and the usage
# "Tools:" line read them, and RELEASING.md section 2 gives the same values.
#   MIN_BASH  associative arrays and ${var,,}.
#   MIN_JQ    --rawfile, which create_secret uses to read the password from stdin (jq 1.5 has
#             no --rawfile).
#   MIN_GOVC  the camelCase -json field names the jq programs read (.sessionList,
#             .virtualMachines[0].runtime.powerState, ...). govc 0.30.7 and older print
#             PascalCase everywhere, and 0.31.0 still prints VirtualMachines for vm.info.
# GOVC_LAST_GO_INSTALL is the newest govc release that `go install
# github.com/vmware/govmomi/govc@vX.Y.Z` can build; check_tools explains why. Its messages and
# the usage "Tools:" text name it, and RELEASING.md section 2 gives the same value.
readonly MIN_BASH=4 MIN_JQ=1.6 MIN_GOVC=0.32.0 GOVC_LAST_GO_INSTALL=0.46.3

if ((BASH_VERSINFO[0] < MIN_BASH)); then
  echo "e2e-lab: bash ${MIN_BASH} or newer is required (found ${BASH_VERSION})" >&2
  exit 2
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT

readonly CP_NS=crossplane-system
readonly CP_RELEASE=crossplane
readonly CP_CHART_REPO=https://charts.crossplane.io/stable
readonly PROVIDER_NAME=provider-vsphere
readonly RUNTIME_CONFIG_NAME=e2e-lab-runtime
readonly RUN_LABEL_KEY=e2e-lab.alphabravo.io/run
readonly DEFAULT_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
# Newest 1.20.x chart listed in https://charts.crossplane.io/stable/index.yaml when written.
readonly DEFAULT_LEGACY_CROSSPLANE_VERSION=1.20.13
readonly PACKAGE_REGEX='^[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9_][A-Za-z0-9._-]*$'
readonly PROVIDER_RES=providers.pkg.crossplane.io
readonly CRD_RES=customresourcedefinitions.apiextensions.k8s.io
readonly REVISION_RES=providerrevisions.pkg.crossplane.io
readonly DRC_RES=deploymentruntimeconfigs.pkg.crossplane.io
# The cluster-scoped Lock Crossplane keeps of every installed package, named "lock". It carries
# its own finalizer, lock.pkg.crossplane.io, until no package remains (see remove_provider).
readonly LOCK_RES=locks.pkg.crossplane.io
readonly LOCK_NAME=lock
readonly VM_RES_CLUSTER=virtualmachines.virtualmachine.vsphere.alphabravo.io
readonly VM_RES_NS=virtualmachines.virtualmachine.vsphere.m.alphabravo.io
readonly VMFS_RES_CLUSTER=vmfsdatastores.storage.vsphere.alphabravo.io
readonly PC_RES_CLUSTER=providerconfigs.vsphere.alphabravo.io
readonly PC_RES_NS=providerconfigs.vsphere.m.alphabravo.io
readonly CPC_RES=clusterproviderconfigs.vsphere.m.alphabravo.io
# The two test VMs use two distinct ProviderConfigs: the cluster one and the namespaced one.
readonly PROVIDER_CONFIGS_IN_USE=2
readonly STEADY_MIN_INTERVALS=3
readonly STEADY_MAX_INTERVALS=5
readonly POLL_SLACK_SECONDS=15
# Log lines of cmd/provider/main.go. Match the fallback first: both lines mention SafeStart.
readonly SAFESTART_FALLBACK_LOG="missing RBAC permissions for watching CRDs"
readonly SAFESTART_GATED_LOG="SafeStart capability enabled"
# How long the provider keeps a client that a Secret rotation replaced before it logs the client
# out: DefaultLogoutDelay in internal/clients/cache.go (upjet's 1h async operation timeout plus a
# 10m grace period). E2E_LOGOUT_DELAY overrides it. This equals the provider's own delay with
# zero slack, so run_ac022_rotation_finish measures it from when the post-rotation login was
# first seen (NEW_LOGIN_EPOCH), not from the moment the Secret was rotated -- those two instants
# can differ by up to one poll interval, and racing the provider's own timer would fail a
# correct build.
readonly DEFAULT_LOGOUT_DELAY=70m
# Extra margin added to E2E_LOGOUT_DELAY before the finish check, to absorb any remaining skew
# and the scheduling jitter of the provider's delayed-logout timer. E2E_LOGOUT_SLACK overrides it.
readonly DEFAULT_LOGOUT_SLACK=10m
# How long remove_provider waits, after it deletes the Provider and DeploymentRuntimeConfig, for
# Crossplane to actually finish removing them: its ProviderRevision gone (Crossplane drops
# that revision's own finalizer, revision.pkg.crossplane.io, before it disappears -- internal
# /controller/pkg/revision/reconciler.go:396-427, confirmed against Crossplane v2.2.0, v2.4.2 and
# v1.20.13 source), the Deployment that revision owns gone from crossplane-system, and, in managed
# mode only, the cluster-scoped Lock's own finalizer (lock.pkg.crossplane.io) cleared, which
# Crossplane does only once no package remains (internal/controller/pkg/resolver
# /reconciler.go:217-233). uninstall_crossplane only runs `helm uninstall` once this wait
# succeeds: doing it earlier removes the only controller left that can clear those finalizers,
# which is how a stuck finalizer gets created while the report still says cleanup completed.
# E2E_PROVIDER_REMOVAL_TIMEOUT overrides it.
readonly DEFAULT_PROVIDER_REMOVAL_TIMEOUT=10m
# AC-022 waits this long (seconds) for you to confirm the vCenter password change.
readonly ROTATION_CONFIRM_TIMEOUT=1800
# The terminal rotate_confirm reads that confirmation from; validate checks this same path is
# usable. Not an environment setting: cluster/test/e2e-lab-selftest.sh points it at a file.
CONFIRM_TTY=/dev/tty
readonly TOUCH_ANNOTATION=e2e-lab.alphabravo.io/touched
# INITPROVIDER / LATEINIT-DISABLED / DEFAULTED-DRIFT-CORRECTED VM: every management action
# except LateInitialize.
readonly LATEINIT_POLICIES='["Observe", "Create", "Update", "Delete"]'
# DEFAULTED-DRIFT-CORRECTED (A-036/OT-019): out-of-band MHz value for cpu_reservation. Unlike
# annotation (Optional and Computed), cpu_reservation is Optional only, with no schema default,
# so while it is absent from forProvider the provider enforces its zero value, 0. Must be
# non-zero so the correction back to 0 is observable.
readonly INITLATE_CPU_RESERVATION_OOB=500
readonly ROWS=(AC-005 AC-006-update AC-006-delete/OT-021 AC-007 AC-008 AC-016 AC-018 AC-019 AC-021
  AC-022 INITPROVIDER LATEINIT-DISABLED DEFAULTED-DRIFT-CORRECTED "SafeStart(info)")
readonly COLS=(cluster namespaced package)
readonly REQUIRED_VM_ENV=(VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER E2E_RESOURCE_POOL_ID
  E2E_DATASTORE_ID E2E_NETWORK_ID E2E_TEMPLATE_UUID E2E_GUEST_ID E2E_FOLDER)
readonly ID_ENV=(VSPHERE_USER VSPHERE_SERVER E2E_RESOURCE_POOL_ID E2E_DATASTORE_ID E2E_NETWORK_ID
  E2E_TEMPLATE_UUID E2E_GUEST_ID E2E_FOLDER E2E_FIRMWARE E2E_HOST_SYSTEM_ID E2E_DATACENTER
  E2E_VMFS_DATASTORE_ID E2E_NAMESPACE E2E_DISK_GB)

# Which vCenter sessions are the provider's. vCenter reports a session's user as DOMAIN\account,
# with DOMAIN as its identity source names it (LAB\svc-pioneer, LAB.LOCAL\svc-pioneer,
# VSPHERE.LOCAL\Administrator); VSPHERE_USER is usually account@domain, the form the provider logs
# in with. Both are split into (account, domain) and lower-cased (vCenter and AD user names are
# case-insensitive). With E2E_SESSION_USER_MATCH=account (the default) a session matches when
# the accounts are equal and the domains agree: equal, or one side gives no domain, or one side
# is a single label (a short/NetBIOS name such as LAB) equal to the first label of the other
# (lab.local). So svc-pioneer@lab.local matches LAB\svc-pioneer, LAB.LOCAL\SVC-PIONEER and
# svc-pioneer@lab.local, but not LAB\svc-other, CORP\svc-pioneer or svc-pioneer@corp.example.com.
# With E2E_SESSION_USER_MATCH=exact, account and domain must both be equal (still
# case-insensitive: svc-pioneer@lab.local matches LAB.LOCAL\svc-pioneer, not LAB\svc-pioneer).
# provider_sessions($u; $mode; $base): the sessions of user $u that are not govc's (its current
# session and any govc/ user agent) and not in the pre-install baseline key list $base.
readonly JQ_SESSION_DEFS='
  def acct_dom: ascii_downcase
    | if contains("\\") then (split("\\") | {d: .[0], a: (.[1:] | join("\\"))})
      elif contains("@") then (split("@") | {a: (.[:-1] | join("@")), d: .[-1]})
      else {a: ., d: ""} end;
  def dom_ok($x; $y): $x == "" or $y == "" or $x == $y
    or (($x | contains(".") | not) and ($y | split(".") | .[0]) == $x)
    or (($y | contains(".") | not) and ($x | split(".") | .[0]) == $y);
  def isuser($u; $mode): acct_dom as $n | ($u | acct_dom) as $m
    | if $mode == "exact" then $n == $m else $n.a == $m.a and dom_ok($n.d; $m.d) end;
  def provider_sessions($u; $mode; $base):
    (.currentSession.key // "") as $cur
    | [.sessionList[]?
       | select(.key != $cur)
       | select((.userAgent // "") | startswith("govc/") | not)
       | select(.key as $k | $base | any(.[]; . == $k) | not)
       | select((.userName // "") | isuser($u; $mode))];'
# The count of the provider-user sessions, then one line per session. The userName shows which
# form matched; loginTime is vCenter's clock and informational only. Keys are never printed.
readonly JQ_PROVIDER_SESSIONS=$JQ_SESSION_DEFS'
  provider_sessions($u; $mode; $base[0])
  | (length | tostring),
    (.[] | "      \(.userName) via \(.userAgent // "?") from \(.ipAddress // "?") since \(.loginTime // "?")")'
# Same sessions as JQ_PROVIDER_SESSIONS, as {key, userName, loginTime, userAgent} records. AC-022
# needs the exact keys: to recognize a session that did not exist before the rotation (a rebuilt
# client), and to prove each specific pre-rotation session is gone. vCenter keeps a session alive
# across a password change, so a shrinking count alone cannot show a client was rebuilt.
readonly JQ_PROVIDER_SESSION_RECORDS=$JQ_SESSION_DEFS'
  provider_sessions($u; $mode; $base[0])
  | map({key, userName: (.userName // ""), loginTime: (.loginTime // ""), userAgent: (.userAgent // "?")})'

OPT_CROSSPLANE_VERSION="" OPT_PACKAGE="" OPT_KUBE_CONTEXT="" OPT_EXISTING="" OPT_PHASE=""
OPT_LEGACY="" OPT_POLL="" OPT_SKIP_CLEANUP="" OPT_DRY_RUN=""
DRY_RUN=false STARTED=false CLUSTER_TOUCHED=false CP_INSTALLED_BY_RUN=false PROVIDER_APPLIED=false
NS_CREATED=false CLEANUP_STARTED=false CLEANUP_OK=true ABORT_REASON="" WORKDIR="" RUN_ID=""
DS_TYPE="" VMFS_DS_ID="" POLL_SECONDS=60 GOVC_INSECURE_VALUE=1
# What this run created and may not have removed. collect_left, print_removal_steps and
# print_manual_cleanup read only these flags, never the phase: each is set by the step that
# creates the object, just before it does, and cleared only once that object is confirmed gone.
#   CP_INSTALLED_BY_RUN  the Crossplane Helm release: helm_install_crossplane, uninstall_crossplane.
#                        CP_INSTALLED_NAME names it for the end-of-run lists ("Crossplane 1.20.13",
#                        "Crossplane v2.4.2"). It is never cleared, so it also says this run
#                        installed a Crossplane, whose uninstall leaves what crossplane_remainder
#                        names.
#   PROVIDER_APPLIED     the Provider and DeploymentRuntimeConfig: apply_provider, remove_provider.
#                        PROVIDER_REMOVAL_OK (below) is false while Crossplane may still be removing
#                        one this run deleted.
#   NS_CREATED           the namespace, credentials Secrets and ProviderConfigs: setup_configs,
#                        cleanup.
#   VMFS_APPLIED         the Observe-only VmfsDatastore: setup_vmfs_ref, cleanup.
#   VMS_APPLIED          the VirtualMachine MRs: run_vm_setup_checks, cleanup. AC-006 and AC-007
#                        delete some of them, but no vm-phase step deletes the INITPROVIDER/LATEINIT
#                        VM, so only cleanup clears it.
# GATE_TEARDOWN: the version gate's removal of its own Provider and Crossplane, which runs even
# with --skip-cleanup: "" (not reached), started, or finished.
# LEGACY_WEBHOOK_LEFT: uninstalling this run's Crossplane also leaves the webhook configuration
# crossplane, which only a Crossplane 1.x creates (helm_install_crossplane, crossplane_remainder).
VMFS_APPLIED=false VMS_APPLIED=false CP_INSTALLED_NAME="" GATE_TEARDOWN="" LEGACY_WEBHOOK_LEFT=false
# AC-022 (US-006, password rotation). ROTATED_PASSWORD comes from E2E_VSPHERE_ROTATED_PASSWORD
# (resolve_settings); it is empty, and AC-022 is SKIPPED, unless that is set (a dry run then
# only plans AC-022).
ROTATED_PASSWORD="" LOGOUT_DELAY_RAW="" LOGOUT_DELAY_SECONDS=4200
LOGOUT_SLACK_RAW="" LOGOUT_SLACK_SECONDS=600
# E2E_PROVIDER_REMOVAL_TIMEOUT (resolve_settings, validate): how long remove_provider's wait may
# run before it gives up. PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS is the poll spacing, not an
# environment setting; cluster/test/e2e-lab-selftest.sh shortens it so its cases finish in
# seconds. PROVIDER_REMOVAL_OK says whether Crossplane finished removing the Provider this run
# applied: remove_provider sets it false before its deletes and true only when its wait
# succeeds, so a failed delete or a wait that ran out leaves it false, and uninstall_crossplane
# then skips the helm uninstall. It starts true for a run that never applies a Provider.
PROVIDER_REMOVAL_TIMEOUT_RAW="" PROVIDER_REMOVAL_TIMEOUT_SECONDS=600
PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=10
PROVIDER_REMOVAL_OK=true
# E2E_REQUIRE_AC022 (resolve_settings, validate): true makes AC-022 part of this run's gate
# (any_fail); false lets a run pass without it, and result_line then says it was not asserted.
REQUIRE_AC022=false
ROTATE_STARTED=false
# NEW_LOGIN_EPOCH: this workstation's clock (date -u +%s) at the moment a post-rotation
# provider-user session -- one whose key is not in PRE_ROTATION_SESSION_KEYS -- was first seen
# (0 until one is seen). It anchors the delayed-logout wait in run_ac022_rotation_finish. It is
# never compared with vCenter's loginTime, so vCenter/workstation clock skew cannot affect it.
# NEW_LOGIN_COUNT: how many such sessions the latest observe_new_logins call saw.
NEW_LOGIN_EPOCH=0 NEW_LOGIN_COUNT=0
# E2E_SESSION_USER_MATCH (resolve_settings, validate): account (default) or exact; see
# JQ_SESSION_DEFS for exactly which vCenter userNames each mode counts as the provider's.
SESSION_USER_MATCH=account
# JSON array of the provider-user session keys seen before the credentials Secret was rotated:
# before the password-change pause, plus right after it (run_ac022_rotation_start explains why
# both). run_ac022_rotation_finish requires all of these to be gone, which is how this script
# confirms the rotated-out client actually logged out (vCenter keeps a session alive across a
# password change, so a session count within bound does not by itself prove these specific
# sessions ended).
PRE_ROTATION_SESSION_KEYS='[]'
# INITPROVIDER/LATEINIT-DISABLED VM (ankasoft #5, #7): annotation values, set from RUN_ID in main().
INITLATE_NAME="" INITLATE_ANNOTATION="" INITLATE_OOB=""
declare -A RESULT=()
ALIVE=()
LEFT_IN_PLACE=()
REF=()
VM_NAME=""

usage() {
  cat <<EOF
Usage: cluster/test/e2e-lab.sh [options]

Lab end-to-end test for provider-vsphere. A human runs it by hand against a dedicated lab k3s
cluster and a lab vCenter; never run it from CI or an automated agent. Every option except -h
has an environment equivalent, and a flag wins over its environment variable.

Options:
  --crossplane-version vX.Y.Z   Crossplane v2 chart for the vm phase (required; v2.2.0 and v2.4.2
                                are the release gates). Env: E2E_CROSSPLANE_VERSION, alias
                                CROSSPLANE_VERSION.
  --package REF                 Fully qualified provider package (registry.host/repo:tag).
                                Env: E2E_PROVIDER_PACKAGE, alias PROVIDER_PACKAGE.
                                Default: ${DEFAULT_PACKAGE}
  --kube-context NAME           Context pinned on every kubectl and helm call. Env: KUBE_CONTEXT.
                                Default: the current context, resolved once at start.
  --existing-crossplane         Use the Crossplane already running in ${CP_NS}: never install,
                                upgrade or uninstall it; the version gate is skipped.
                                Without it (managed mode) the script installs Crossplane itself
                                and refuses to start (exit 2) if it finds a Deployment with a
                                crossplane/crossplane image, a ${CP_RELEASE} Helm release in
                                ${CP_NS} or the ${PROVIDER_RES} CRD, which helm
                                uninstall leaves behind. Env: E2E_EXISTING_CROSSPLANE=true
  --phase all|version-gate|vm   Env: E2E_PHASE (default all: version gate, then the vm phase).
  --legacy-crossplane-version X.Y.Z
                                Crossplane 1.x used by the version gate (AC-008).
                                Env: LEGACY_CROSSPLANE_VERSION (default ${DEFAULT_LEGACY_CROSSPLANE_VERSION}).
  --poll-interval DURATION      Provider --poll value, e.g. 1m. Env: E2E_POLL_INTERVAL (default 1m).
  --skip-cleanup                Skip only the end-of-run cleanup: leave in place what this run
                                created and has not removed, and list it with the commands to
                                remove it. The run's own steps still delete what they test (the
                                AC-006 and AC-007 VMs), and in managed mode the version gate still
                                removes its own Provider and DeploymentRuntimeConfig and
                                uninstalls its Crossplane 1.x. Env: E2E_SKIP_CLEANUP=true
  --dry-run                     Print the plan and every command of the run, and execute none
                                of them (the local tool checks still run).
                                Env: E2E_DRY_RUN=true
  -h, --help                    Show this help.

Required environment for the vm phase:
  VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER
  E2E_RESOURCE_POOL_ID E2E_DATASTORE_ID E2E_NETWORK_ID E2E_TEMPLATE_UUID E2E_GUEST_ID E2E_FOLDER
Optional environment:
  VSPHERE_ALLOW_UNVERIFIED_SSL (default true)   E2E_FIRMWARE (bios|efi, default bios)
  E2E_HOST_SYSTEM_ID (pins the host)            E2E_DISK_GB (default 40)
  E2E_NAMESPACE (default vsphere-e2e)           E2E_DATACENTER (GOVC_DATACENTER for govc)
  E2E_VMFS_DATASTORE_ID (VMFS datastore for the AC-016 datastoreIdRef check; defaults to
                        E2E_DATASTORE_ID when govc reports that datastore as VMFS)
  E2E_VSPHERE_ROTATED_PASSWORD (AC-022: the vCenter password you will change to by hand; unset
                        by default, which SKIPs AC-022 -- not allowed with E2E_REQUIRE_AC022=true.
                        Needs an interactive /dev/tty to confirm.)
  E2E_REQUIRE_AC022 (true|false, default false. true makes AC-022 part of this run's gate:
                        E2E_VSPHERE_ROTATED_PASSWORD and the vm phase become required, and an
                        AC-022 that ends SKIPPED for any reason fails the run. With false a run
                        may skip AC-022, and a passing run's Result line then says
                        "AC-022 not asserted: E2E_REQUIRE_AC022=false". A release gate needs at
                        least one run with true that ends in a plain "Result: PASS".)
  E2E_LOGOUT_DELAY (AC-022: how long the provider keeps a rotated-out client before logging it
                        out; default 70m, matching internal/clients/cache.go DefaultLogoutDelay)
  E2E_LOGOUT_SLACK (AC-022: extra margin added to E2E_LOGOUT_DELAY before the finish check;
                        default 10m. Both are measured on this workstation's clock from when the
                        first post-rotation session (a session key absent before the rotation)
                        was seen, not from the moment the Secret was rotated.)
  E2E_SESSION_USER_MATCH (account|exact, default account: which vCenter session userNames count
                        as VSPHERE_USER's for AC-021 and AC-022. account: the same account name,
                        any case, with the domain optional and a short name such as LAB matching
                        lab.local, so svc-pioneer@lab.local matches LAB\svc-pioneer but not
                        LAB\svc-other or CORP\svc-pioneer. exact: account and domain both equal,
                        any case. Needs the Sessions.TerminateSession privilege to list the
                        provider's sessions; see RELEASING.md section 2.)
  E2E_PROVIDER_REMOVAL_TIMEOUT (how long the run waits, after deleting its Provider and
                        DeploymentRuntimeConfig, for Crossplane to finish removing the
                        ProviderRevision and its Deployment (and, in managed mode, drop the
                        Lock's own finalizer); default 10m. If that wait runs out, or the delete
                        fails, the run marks cleanup incomplete, names exactly what is left and
                        prints the recovery, in either mode; in managed mode it also skips the
                        helm uninstall and leaves Crossplane installed, and in the version gate
                        it stops the run there.)

Tools: bash ${MIN_BASH}+, jq ${MIN_JQ}+ and kubectl (every phase), helm (managed mode), govc ${MIN_GOVC}+
  (vm phase); kubectl and helm in any version supported by your cluster. They are checked before
  any cluster call: a missing tool stops a real run (a dry run only warns), and a tool older than
  its minimum, or a govc whose version cannot be determined, stops a real run and a dry run with
  exit 2. Use a govc release binary, or 'go install github.com/vmware/govmomi/govc@vX.Y.Z' with
  X.Y.Z from ${MIN_GOVC} to ${GOVC_LAST_GO_INSTALL} (later releases cannot be installed that way). Such a
  build prints 0.0.0, so go must be on PATH: its version is read with 'go version -m'. A govc
  built from a govmomi clone at 0.47.0 or later (cd govc && go install .) is accepted too, with
  go on PATH.
Exit codes: 0 no criterion failed, and cleanup completed or --skip-cleanup skipped it (the version
gate's own teardown, which runs either way, must complete; after a skipped cleanup that left
anything in place the Result line says "cleanup skipped", and it says when AC-022 was not
asserted); a dry run that prints its whole plan exits 0; 1 a criterion failed, a required AC-022
did not pass, cleanup or the version gate's own teardown was incomplete, or the run aborted; 2
usage or environment error, or managed mode found Crossplane already present (nothing was
changed); 130 interrupted.
EOF
}

say() { printf '%s\n' "$*" >&3; }
warn() { printf 'e2e-lab: WARNING: %s\n' "$*" >&2; }
# die: only before the cluster is touched. fatal: afterwards; the EXIT trap cleans up and reports.
die() {
  printf 'e2e-lab: ERROR: %s\n' "$*" >&2
  exit 2
}
fatal() {
  ABORT_REASON=$*
  printf 'e2e-lab: FATAL: %s\n' "$*" >&2
  exit 1
}
# refuse: preflight found Crossplane where managed mode would install its own. Nothing has been
# changed, so it exits 2 as die does, and it sets ABORT_REASON so the EXIT trap's report names it.
refuse() {
  ABORT_REASON=$*
  printf 'e2e-lab: ERROR: %s\n' "$*" >&2
  printf 'e2e-lab: nothing was changed.\n' >&2
  exit 2
}
usage_error() {
  printf 'e2e-lab: %s\n' "$*" >&2
  printf "Run 'cluster/test/e2e-lab.sh --help' for usage.\n" >&2
  exit 2
}
is_dry() { [[ $DRY_RUN == true ]]; }
is_num() { [[ $1 =~ ^[0-9]+$ ]]; }
phase_has_vm() { [[ $PHASE == all || $PHASE == vm ]]; }
phase_has_gate() { [[ $PHASE == all || $PHASE == version-gate ]]; }

# redact masks the vCenter password in a string, in plain and in shell-quoted form.
redact() {
  local s=$1 q
  if [[ -n ${VSPHERE_PASSWORD:-} ]]; then
    printf -v q '%q' "$VSPHERE_PASSWORD"
    s=${s//"$VSPHERE_PASSWORD"/'<redacted>'}
    s=${s//"$q"/'<redacted>'}
  fi
  printf '%s' "$s"
}

# run is the single wrapper for every kubectl, helm and govc command (check_tools' local probes
# excepted) and for the jq that builds the credentials JSON; jq calls that only parse output run
# directly. In dry-run it prints the command (shell-quoted, password masked) to stdout and
# executes nothing.
run() {
  if is_dry; then
    local line
    printf -v line '%q ' "$@"
    printf '+ %s\n' "$(redact "${line% }")" >&3
    return 0
  fi
  "$@"
}
k() { run kubectl --context "$KUBE_CONTEXT" "$@"; }
h() { run helm --kube-context "$KUBE_CONTEXT" "$@"; }
# g runs govc with the vCenter credentials exported only into the govc process environment.
g() {
  if is_dry; then
    local line
    printf -v line '%q ' "$@"
    printf '+ GOVC_URL=%q GOVC_USERNAME=%q GOVC_PASSWORD=<redacted> GOVC_INSECURE=%s%s govc %s\n' \
      "$VSPHERE_SERVER" "$VSPHERE_USER" "$GOVC_INSECURE_VALUE" \
      "${E2E_DATACENTER:+ GOVC_DATACENTER=$E2E_DATACENTER}" "$(redact "${line% }")" >&3
    return 0
  fi
  (
    export GOVC_URL="$VSPHERE_SERVER" GOVC_USERNAME="$VSPHERE_USER" GOVC_PASSWORD="$VSPHERE_PASSWORD"
    export GOVC_INSECURE="$GOVC_INSECURE_VALUE" GOVC_PERSIST_SESSION=false
    if [[ -n ${E2E_DATACENTER:-} ]]; then export GOVC_DATACENTER="$E2E_DATACENTER"; fi
    run govc "$@"
  )
}

parse_args() {
  local arg
  while (($#)); do
    arg=$1
    if [[ $arg == --*=* ]]; then
      shift
      set -- "${arg%%=*}" "${arg#*=}" "$@"
      arg=$1
    fi
    case $arg in
      --crossplane-version | --package | --kube-context | --phase | --legacy-crossplane-version | --poll-interval)
        (($# >= 2)) || usage_error "$arg needs a value"
        case $arg in
          --crossplane-version) OPT_CROSSPLANE_VERSION=$2 ;;
          --package) OPT_PACKAGE=$2 ;;
          --kube-context) OPT_KUBE_CONTEXT=$2 ;;
          --phase) OPT_PHASE=$2 ;;
          --legacy-crossplane-version) OPT_LEGACY=$2 ;;
          --poll-interval) OPT_POLL=$2 ;;
        esac
        shift 2
        ;;
      --existing-crossplane) OPT_EXISTING=true && shift ;;
      --skip-cleanup) OPT_SKIP_CLEANUP=true && shift ;;
      --dry-run) OPT_DRY_RUN=true && shift ;;
      -h | --help) usage && exit 0 ;;
      *) usage_error "unknown argument: $arg" ;;
    esac
  done
}

# Flags win over environment variables; E2E_* names win over their aliases.
resolve_settings() {
  XP_VERSION_RAW=${OPT_CROSSPLANE_VERSION:-${E2E_CROSSPLANE_VERSION:-${CROSSPLANE_VERSION:-}}}
  PACKAGE=${OPT_PACKAGE:-${E2E_PROVIDER_PACKAGE:-${PROVIDER_PACKAGE:-$DEFAULT_PACKAGE}}}
  KUBE_CONTEXT=${OPT_KUBE_CONTEXT:-${KUBE_CONTEXT:-}}
  EXISTING=${OPT_EXISTING:-${E2E_EXISTING_CROSSPLANE:-false}}
  PHASE=${OPT_PHASE:-${E2E_PHASE:-all}}
  LEGACY_RAW=${OPT_LEGACY:-${LEGACY_CROSSPLANE_VERSION:-$DEFAULT_LEGACY_CROSSPLANE_VERSION}}
  POLL_INTERVAL=${OPT_POLL:-${E2E_POLL_INTERVAL:-1m}}
  SKIP_CLEANUP=${OPT_SKIP_CLEANUP:-${E2E_SKIP_CLEANUP:-false}}
  DRY_RUN=${OPT_DRY_RUN:-${E2E_DRY_RUN:-false}}
  ALLOW_UNVERIFIED_SSL=${VSPHERE_ALLOW_UNVERIFIED_SSL:-true}
  NS=${E2E_NAMESPACE:-vsphere-e2e}
  FIRMWARE=${E2E_FIRMWARE:-bios}
  ROTATED_PASSWORD=${E2E_VSPHERE_ROTATED_PASSWORD:-}
  REQUIRE_AC022=${E2E_REQUIRE_AC022:-false}
  LOGOUT_DELAY_RAW=${E2E_LOGOUT_DELAY:-$DEFAULT_LOGOUT_DELAY}
  LOGOUT_SLACK_RAW=${E2E_LOGOUT_SLACK:-$DEFAULT_LOGOUT_SLACK}
  SESSION_USER_MATCH=${E2E_SESSION_USER_MATCH:-account}
  PROVIDER_REMOVAL_TIMEOUT_RAW=${E2E_PROVIDER_REMOVAL_TIMEOUT:-$DEFAULT_PROVIDER_REMOVAL_TIMEOUT}
}

bool_value() {
  case ${1,,} in
    true | 1 | yes) printf true ;;
    false | 0 | no | "") printf false ;;
    *) return 1 ;;
  esac
}

# validate checks the settings without calling any external command. It prints every missing
# or invalid setting and exits 2, so nothing on any cluster or vCenter is touched.
validate() {
  local -a missing=() errors=()
  local v b
  # The environment variable each boolean comes from (a flag always sets "true"), so an error
  # names the setting you actually set.
  local -A bool_env=([EXISTING]=E2E_EXISTING_CROSSPLANE [SKIP_CLEANUP]=E2E_SKIP_CLEANUP
    [DRY_RUN]=E2E_DRY_RUN [ALLOW_UNVERIFIED_SSL]=VSPHERE_ALLOW_UNVERIFIED_SSL)
  for v in EXISTING SKIP_CLEANUP DRY_RUN ALLOW_UNVERIFIED_SSL; do
    if b=$(bool_value "${!v}"); then
      printf -v "$v" '%s' "$b"
    else
      errors+=("${bool_env[$v]} must be true or false (got '${!v}')")
    fi
  done
  if b=$(bool_value "$REQUIRE_AC022"); then
    REQUIRE_AC022=$b
  else
    errors+=("E2E_REQUIRE_AC022 must be true or false (got '$REQUIRE_AC022')")
  fi
  case $PHASE in
    all | version-gate | vm) ;;
    *) errors+=("--phase / E2E_PHASE must be all, version-gate or vm (got '$PHASE')") ;;
  esac
  case $SESSION_USER_MATCH in
    account | exact) ;;
    *) errors+=("E2E_SESSION_USER_MATCH must be account or exact (got '$SESSION_USER_MATCH')") ;;
  esac
  if [[ -z $XP_VERSION_RAW ]]; then
    missing+=("E2E_CROSSPLANE_VERSION (or --crossplane-version, or CROSSPLANE_VERSION)")
  elif [[ ! $XP_VERSION_RAW =~ ^v?2\.[0-9]+\.[0-9]+$ ]]; then
    errors+=("Crossplane version must be v2.N.N, e.g. v2.2.0 or 2.4.2 (got '$XP_VERSION_RAW')")
  fi
  if [[ ! $PACKAGE =~ $PACKAGE_REGEX ]]; then
    errors+=("provider package must be fully qualified as registry.host/repo:tag (got '$PACKAGE')")
  fi
  if [[ ! $LEGACY_RAW =~ ^v?1\.[0-9]+\.[0-9]+$ ]]; then
    errors+=("legacy Crossplane version must be 1.N.N (got '$LEGACY_RAW')")
  fi
  if [[ $POLL_INTERVAL =~ ^([1-9][0-9]*)(s|m|h)$ ]]; then
    case ${BASH_REMATCH[2]} in
      s) POLL_SECONDS=${BASH_REMATCH[1]} ;;
      m) POLL_SECONDS=$((BASH_REMATCH[1] * 60)) ;;
      h) POLL_SECONDS=$((BASH_REMATCH[1] * 3600)) ;;
    esac
  else
    errors+=("poll interval must look like 30s, 1m or 1h (got '$POLL_INTERVAL')")
  fi
  if [[ $LOGOUT_DELAY_RAW =~ ^([1-9][0-9]*)(s|m|h)$ ]]; then
    case ${BASH_REMATCH[2]} in
      s) LOGOUT_DELAY_SECONDS=${BASH_REMATCH[1]} ;;
      m) LOGOUT_DELAY_SECONDS=$((BASH_REMATCH[1] * 60)) ;;
      h) LOGOUT_DELAY_SECONDS=$((BASH_REMATCH[1] * 3600)) ;;
    esac
  else
    errors+=("E2E_LOGOUT_DELAY must look like 30s, 1m or 1h (got '$LOGOUT_DELAY_RAW')")
  fi
  if [[ $LOGOUT_SLACK_RAW =~ ^([1-9][0-9]*)(s|m|h)$ ]]; then
    case ${BASH_REMATCH[2]} in
      s) LOGOUT_SLACK_SECONDS=${BASH_REMATCH[1]} ;;
      m) LOGOUT_SLACK_SECONDS=$((BASH_REMATCH[1] * 60)) ;;
      h) LOGOUT_SLACK_SECONDS=$((BASH_REMATCH[1] * 3600)) ;;
    esac
  else
    errors+=("E2E_LOGOUT_SLACK must look like 30s, 1m or 1h (got '$LOGOUT_SLACK_RAW')")
  fi
  if [[ $PROVIDER_REMOVAL_TIMEOUT_RAW =~ ^([1-9][0-9]*)(s|m|h)$ ]]; then
    case ${BASH_REMATCH[2]} in
      s) PROVIDER_REMOVAL_TIMEOUT_SECONDS=${BASH_REMATCH[1]} ;;
      m) PROVIDER_REMOVAL_TIMEOUT_SECONDS=$((BASH_REMATCH[1] * 60)) ;;
      h) PROVIDER_REMOVAL_TIMEOUT_SECONDS=$((BASH_REMATCH[1] * 3600)) ;;
    esac
  else
    errors+=("E2E_PROVIDER_REMOVAL_TIMEOUT must look like 30s, 1m or 1h (got '$PROVIDER_REMOVAL_TIMEOUT_RAW')")
  fi
  # AC-022 needs an interactive confirmation once the cluster is touched; check the terminal
  # rotate_confirm reads (CONFIRM_TTY, /dev/tty) now so a broken or absent terminal aborts before
  # anything is created, not 20 minutes into the run.
  if [[ -n $ROTATED_PASSWORD && $DRY_RUN != true ]] && phase_has_vm; then
    if ! (exec 0<"$CONFIRM_TTY") 2>/dev/null; then
      errors+=("E2E_VSPHERE_ROTATED_PASSWORD is set but $CONFIRM_TTY is not available for the AC-022 confirmation prompt; run this from an interactive terminal, or unset both E2E_VSPHERE_ROTATED_PASSWORD and E2E_REQUIRE_AC022 to skip AC-022 (not a full release-gate run)")
    fi
  fi
  # E2E_REQUIRE_AC022=true makes AC-022 part of this run's gate (FR-111, US-006). Reject up front
  # a run that could never assert it, rather than failing it at the end.
  if [[ $REQUIRE_AC022 == true ]]; then
    if [[ -z $ROTATED_PASSWORD ]]; then
      missing+=("E2E_VSPHERE_ROTATED_PASSWORD (required because E2E_REQUIRE_AC022=true: the new vCenter password AC-022 rotates to; set E2E_REQUIRE_AC022=false to run without asserting AC-022)")
    fi
    if [[ $PHASE == version-gate ]]; then
      errors+=("E2E_REQUIRE_AC022=true needs the vm phase, where AC-022 runs; --phase version-gate never asserts it (set E2E_REQUIRE_AC022=false for a version-gate-only run)")
    fi
  fi
  if [[ $PHASE == version-gate && $EXISTING == true ]]; then
    errors+=("--phase version-gate installs a legacy Crossplane, so it cannot run with --existing-crossplane")
  fi
  if phase_has_vm; then
    for v in "${REQUIRED_VM_ENV[@]}"; do
      [[ -n ${!v:-} ]] || missing+=("$v")
    done
    for v in "${ID_ENV[@]}"; do
      if [[ ${!v:-} == *[[:cntrl:]]* ]]; then errors+=("$v contains a control character"); fi
    done
    if [[ ! $NS =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
      errors+=("E2E_NAMESPACE must be a DNS label (got '$NS')")
    fi
    case $FIRMWARE in
      bios | efi) ;;
      *) errors+=("E2E_FIRMWARE must be bios or efi (got '$FIRMWARE')") ;;
    esac
    if [[ -n ${E2E_DISK_GB:-} && ! ${E2E_DISK_GB} =~ ^[1-9][0-9]*$ ]]; then
      errors+=("E2E_DISK_GB must be a positive integer (got '${E2E_DISK_GB}')")
    fi
  fi
  if ((${#missing[@]})); then
    printf 'e2e-lab: missing required setting(s):\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
  fi
  if ((${#errors[@]})); then
    printf 'e2e-lab: invalid setting(s):\n' >&2
    printf '  %s\n' "${errors[@]}" >&2
  fi
  if ((${#missing[@]} + ${#errors[@]})); then
    printf 'e2e-lab: nothing was changed. Fix the settings above and re-run (see --help).\n' >&2
    exit 2
  fi
  XP_VERSION=${XP_VERSION_RAW#v}
  LEGACY_VERSION=${LEGACY_RAW#v}
  if [[ $ALLOW_UNVERIFIED_SSL == true ]]; then GOVC_INSECURE_VALUE=1; else GOVC_INSECURE_VALUE=0; fi
  if phase_has_vm && [[ $XP_VERSION != 2.2.0 && $XP_VERSION != 2.4.2 ]]; then
    warn "Crossplane v$XP_VERSION is not one of the release-gate versions v2.2.0 and v2.4.2"
  fi
}

# version_ge A B: the version A (major.minor.patch, digits only) is B or newer.
version_ge() {
  local -a va vb
  local i
  IFS=. read -r -a va <<<"$1"
  IFS=. read -r -a vb <<<"$2"
  for i in 0 1 2; do
    if ((10#${va[i]:-0} != 10#${vb[i]:-0})); then
      ((10#${va[i]:-0} > 10#${vb[i]:-0})) && return 0
      return 1
    fi
  done
  return 0
}

# check_tools runs before any cluster, helm or vCenter call. A missing tool stops a real run with
# exit 2; a dry run, which runs none of them, only warns. A tool older than its minimum (MIN_JQ,
# MIN_GOVC), or a govc whose version cannot be determined, stops a real run and a dry run alike
# with exit 2, naming what was found: a dry run that passed would otherwise vouch for a real run
# that fails part-way, after it has changed the cluster. The probes are local and read-only, and
# bypass run() so that a dry run makes them too: jq on /dev/null, `govc version` (it contacts no
# vCenter) and, for a govc that reports 0.0.0, `go version -m` on the govc binary.
#
# The govc version, decided as follows. cluster/test/e2e-lab-selftest.sh (case v) replays the
# recorded output of real govc binaries for each case below, except build info that names no
# govmomi module, which none of the recorded builds has.
#   1. A govc that prints its version, as a release binary does ("govc 0.56.0"): compared with
#      MIN_GOVC.
#   2. A govc that prints "govc 0.0.0", as every go install and go build recorded in the
#      self-test does: its Go build info (`go version -m`) is read. If that gives
#      github.com/vmware/govmomi a release or pre-release version, that version is compared,
#      with semver precedence (a pre-release is older than its release, a +build suffix
#      such as +dirty is ignored). go install github.com/vmware/govmomi/govc@vX.Y.Z records it on
#      the "mod" line, as does go build in a clone at a release tag. A replace directive adds a
#      "=>" line right after the module's line, and the version on it is the one compiled in.
#   3. Otherwise, a github.com/vmware/govmomi/govc module in the build info is accepted. govmomi
#      v0.47.0 moved govc into that module (no earlier release has it), so the build is 0.47.0
#      or later. Its go.mod replaces github.com/vmware/govmomi with ../, and go install
#      ...@version refuses such a module, which is why GOVC_LAST_GO_INSTALL is the last release
#      go install can build and a later govc is built in a clone (cd govc && go install .).
#   4. Anything else leaves the version unknown and stops the run: a Go pseudo-version (a clone
#      at a commit between release tags), (devel) (built without VCS information), no govmomi
#      module in the build info, build info go cannot read (a wrapper script in front of govc),
#      or no go on PATH.
# GOTOOLCHAIN=local: never switch to, or download, the toolchain a go.mod here asks for.
check_tools() {
  local -a need=(kubectl jq) missing=() errors=()
  local t out found ver pre why info kind mpath mver last gm split
  local fix="use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from $MIN_GOVC to $GOVC_LAST_GO_INSTALL"
  # A semver module version (vX.Y.Z, an optional -pre-release, an optional +build), and a Go
  # pseudo-version (vX.0.0-yyyymmddhhmmss-hash, vX.Y.Z-pre.0.yyyymmddhhmmss-hash or
  # vX.Y.Z-0.yyyymmddhhmmss-hash), which also matches the first but names a commit, not a release.
  local semver_re='^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
  local pseudo_re='^v[0-9]+\.(0\.0-|[0-9]+\.[0-9]+-([^+]*\.)?0\.)[0-9]{14}-[0-9A-Za-z]+(\+[0-9A-Za-z.-]+)?$'
  if [[ $EXISTING != true ]]; then need+=(helm); fi
  if phase_has_vm; then need+=(govc); fi
  for t in "${need[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    if is_dry; then
      warn "missing tool(s) that a real run needs: ${missing[*]}"
    else
      errors+=("missing required tool(s): ${missing[*]}")
    fi
  fi
  if command -v jq >/dev/null 2>&1 && ! jq -n --rawfile f /dev/null '$f' >/dev/null 2>&1; then
    out=$(jq --version 2>&1) || true
    errors+=("jq $MIN_JQ or newer is required, for --rawfile (found: ${out%%$'\n'*})")
  fi
  if phase_has_vm && command -v govc >/dev/null 2>&1; then
    out=$(govc version 2>&1) || true
    found=${out%%$'\n'*} ver="" pre="" why="" split=false
    if [[ $found =~ ^govc\ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then ver=${BASH_REMATCH[1]}; fi
    if [[ $ver == 0.0.0 ]]; then
      ver=""
      if ! command -v go >/dev/null 2>&1; then
        why="no go on PATH to read its build info with 'go version -m'"
        fix="put go on PATH, or $fix"
      elif ! info=$(GOTOOLCHAIN=local go version -m "$(command -v govc)" 2>/dev/null); then
        why="'go version -m' cannot read Go build info from it (a wrapper script in front of govc has none)"
      else
        gm="" last=""
        while IFS=$'\t' read -r kind mpath mver _; do
          case $kind in
            mod | dep)
              last=$mpath
              if [[ $mpath == github.com/vmware/govmomi ]]; then gm=$mver; fi
              if [[ $mpath == github.com/vmware/govmomi/govc ]]; then split=true; fi
              ;;
            "=>")
              if [[ $last == github.com/vmware/govmomi ]]; then gm=$mver; fi
              last=""
              ;;
            *) last="" ;;
          esac
        done <<<"$info"
        if [[ ! $gm =~ $pseudo_re && $gm =~ $semver_re ]]; then
          ver=${BASH_REMATCH[1]} pre=${BASH_REMATCH[2]} split=false
          found+=", built from govmomi $gm per 'go version -m'"
        elif [[ $split == false && -n $gm ]]; then
          why="'go version -m' gives github.com/vmware/govmomi $gm, which is not a release version"
        elif [[ $split == false ]]; then
          why="'go version -m' names no github.com/vmware/govmomi module"
        fi
      fi
    fi
    if [[ -n $why ]]; then
      errors+=("govc $MIN_GOVC or newer is required, and its version cannot be determined (found: $found; $why): $fix")
    elif [[ $split == true ]]; then
      : # the github.com/vmware/govmomi/govc module: govmomi 0.47.0 or later
    elif [[ -z $ver ]]; then
      errors+=("govc $MIN_GOVC or newer is required, and its version cannot be read (found: ${found:-no output from 'govc version'})")
    elif ! version_ge "$ver" "$MIN_GOVC" || [[ -n $pre && $ver == "$MIN_GOVC" ]]; then
      errors+=("govc $MIN_GOVC or newer is required, for the camelCase -json fields this script reads (found: $found)")
    fi
  fi
  ((${#errors[@]})) || return 0
  printf 'e2e-lab: tool problem(s):\n' >&2
  printf '  %s\n' "${errors[@]}" >&2
  printf 'e2e-lab: nothing was changed. Fix the tools above and re-run (see --help for the minimum versions).\n' >&2
  exit 2
}

resolve_context() {
  if [[ -z $KUBE_CONTEXT ]]; then
    if is_dry; then
      KUBE_CONTEXT='<current-context>'
      say "Kube context not set: a real run resolves it once with 'kubectl config current-context'."
      return 0
    fi
    KUBE_CONTEXT=$(run kubectl config current-context) || die "cannot read the current kube context; pass --kube-context"
    [[ -n $KUBE_CONTEXT ]] || die "the current kube context is empty; pass --kube-context"
    say "Resolved kube context: $KUBE_CONTEXT (pinned on every kubectl and helm call of this run)"
  fi
  if ! is_dry; then
    k config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 || die "kube context '$KUBE_CONTEXT' does not exist in the kubeconfig"
  fi
}

# session_user_rule describes, for the plan, which vCenter session userNames AC-021 and AC-022
# count as VSPHERE_USER's. It mirrors acct_dom/dom_ok/isuser in JQ_SESSION_DEFS.
session_user_rule() {
  local u=${VSPHERE_USER,,} acct dom doms
  if [[ $u == *\\* ]]; then
    dom=${u%%\\*} acct=${u#*\\}
  elif [[ $u == *@* ]]; then
    acct=${u%@*} dom=${u##*@}
  else
    acct=$u dom=""
  fi
  if [[ $SESSION_USER_MATCH == exact ]]; then
    printf '%s' "account '$acct' in domain '${dom:-(none)}' exactly, any case (E2E_SESSION_USER_MATCH=exact)"
    return 0
  fi
  if [[ -z $dom ]]; then
    doms="ANY domain (VSPHERE_USER has none; add one to narrow this)"
  elif [[ $dom == *.* ]]; then
    doms="domain '$dom', its short name '${dom%%.*}' or no domain"
  else
    doms="domain '$dom', any '$dom.*' domain or no domain"
  fi
  printf '%s' "account '$acct', any case, in $doms (E2E_SESSION_USER_MATCH=account; each sample prints the userNames it counted)"
}

# crossplane_label plan|report [PHASE]: the Crossplane a run in this mode and PHASE (default: this
# run's) uses, worded for the plan's "crossplane" line (plan) or for the report's first line
# (report). Both come from this one decision, so the plan and the report always name the same
# Crossplane versions: existing mode installs none, a version-gate-only run only LEGACY_VERSION, a
# vm-only run only XP_VERSION, and --phase all LEGACY_VERSION for the gate, then XP_VERSION. The
# plan form also says what happens to the vm phase's Crossplane: uninstalled at the end, or left
# installed under --skip-cleanup. The gate uninstalls its own either way. print_report runs from
# the EXIT trap, hence the ? defaults.
crossplane_label() {
  local form=$1 phase=${2:-$PHASE} xp=${XP_VERSION:-?} legacy=${LEGACY_VERSION:-?} plan report
  local vm_end="uninstalls it at the end"
  if [[ ${SKIP_CLEANUP:-false} == true ]]; then vm_end="leaves it installed (--skip-cleanup)"; fi
  if [[ $EXISTING == true ]]; then
    plan="existing installation in $CP_NS; this script never installs, upgrades or uninstalls it"
    report="existing"
  else
    case $phase in
      version-gate)
        plan="managed: installs only Crossplane $legacy with helm, for the version gate, and uninstalls it after the gate"
        report="managed $legacy (version gate only)"
        ;;
      all)
        plan="managed: installs Crossplane $legacy with helm for the version gate and uninstalls it, then installs Crossplane v$xp and $vm_end"
        report="managed $legacy (version gate), then v$xp"
        ;;
      *)
        plan="managed: installs Crossplane v$xp with helm and $vm_end"
        report="managed v$xp"
        ;;
    esac
  fi
  if [[ $form == report ]]; then printf '%s' "$report"; else printf '%s' "$plan"; fi
}

print_plan() {
  local removal cleanup_line gate="" foreign="$PROVIDER_NAME Provider or $RUNTIME_CONFIG_NAME" n=0
  # removal: which Provider this run removes, and what follows the wait for Crossplane to finish
  # removing it. Under --skip-cleanup only the version gate removes its Provider (managed mode):
  # the vm phase's is left in place.
  if [[ $SKIP_CLEANUP == true ]]; then
    if [[ $EXISTING == true ]]; then
      removal="none: --skip-cleanup leaves this run's Provider in place, and this script never uninstalls an existing Crossplane"
    elif phase_has_gate; then
      removal="the version gate's Provider only: after deleting it, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW for Crossplane to finish removing it, and only then helm uninstall Crossplane $LEGACY_VERSION; if the wait runs out, Crossplane $LEGACY_VERSION is left installed, the report says CLEANUP INCOMPLETE and the run stops there"
      if phase_has_vm; then removal+="; --skip-cleanup leaves the vm phase's Provider and Crossplane v$XP_VERSION in place"; fi
    else
      removal="none: --skip-cleanup leaves this run's Provider and Crossplane v$XP_VERSION in place"
    fi
    cleanup_line="skipped (--skip-cleanup): the end of the run deletes nothing; it lists what this run left in place and the commands to remove it"
    if phase_has_gate && [[ $EXISTING != true ]]; then
      cleanup_line+="; the version gate still removes its own Provider and uninstalls Crossplane $LEGACY_VERSION"
    fi
  elif [[ $EXISTING == true ]]; then
    removal="after deleting the Provider this run applied, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW for the existing Crossplane to finish removing it; no helm uninstall follows (this script never uninstalls an existing Crossplane); if the wait runs out, cleanup is reported incomplete"
    cleanup_line="delete everything labelled $RUN_LABEL_KEY=$RUN_ID"
  else
    removal="after deleting each Provider this run applied, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW for Crossplane to finish removing it, and only then helm uninstall Crossplane; if the wait runs out, Crossplane is left installed and cleanup is reported incomplete"
    cleanup_line="delete everything labelled $RUN_LABEL_KEY=$RUN_ID"
  fi
  # Only the vm phase's preflight checks the namespace.
  if phase_has_vm; then foreign="$PROVIDER_NAME Provider, $RUNTIME_CONFIG_NAME or namespace $NS"; fi
  if is_dry; then gate=" [DRY RUN: no command below is executed]"; fi
  say "e2e-lab plan, run $RUN_ID$gate"
  say "  kube context     : $KUBE_CONTEXT"
  say "  crossplane       : $(crossplane_label plan)"
  say "  provider package : $PACKAGE"
  say "  phase            : $PHASE"
  if [[ $REQUIRE_AC022 == true ]]; then
    say "  require AC-022   : true (E2E_REQUIRE_AC022): AC-022 is part of this run's gate; an AC-022 that ends SKIPPED for any reason fails the run"
  else
    say "  require AC-022   : false (E2E_REQUIRE_AC022): AC-022 may be skipped; a passing run then says 'AC-022 not asserted' on its Result line and is not a full release-gate run"
  fi
  say "  poll interval    : $POLL_INTERVAL (provider --poll, via DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME)"
  say "  provider removal : $removal"
  if phase_has_vm; then
    say "  namespace        : $NS"
    say "  vCenter          : server=$VSPHERE_SERVER user=$VSPHERE_USER password=<redacted> allow_unverified_ssl=$ALLOW_UNVERIFIED_SSL${E2E_DATACENTER:+ datacenter=$E2E_DATACENTER}"
    say "  session user     : $(session_user_rule)"
    say "  placement        : resourcePoolId=$E2E_RESOURCE_POOL_ID datastoreId=$E2E_DATASTORE_ID networkId=$E2E_NETWORK_ID folder=$E2E_FOLDER"
    say "  clone            : templateUuid=$E2E_TEMPLATE_UUID guestId=$E2E_GUEST_ID firmware=$FIRMWARE hostSystemId=${E2E_HOST_SYSTEM_ID:-(vSphere places the VM)} disk=${E2E_DISK_GB:-40}GB"
    say "  VMs              : $VM_NAME_CLUSTER (cluster-scoped), $NS/$VM_NAME_NS (namespaced), $NS/$INITLATE_NAME (namespaced, INITPROVIDER/LATEINIT-DISABLED ankasoft #5 #7, DEFAULTED-DRIFT-CORRECTED A-036/OT-019)"
    if [[ -n $ROTATED_PASSWORD ]]; then
      say "  rotation (AC-022): record the provider's session keys, pause on /dev/tty (up to ${ROTATION_CONFIRM_TIMEOUT}s) for you to change the vCenter password, log govc in with the rotated password from then on, rotate the credentials Secrets, then wait out E2E_LOGOUT_DELAY=$LOGOUT_DELAY_RAW + E2E_LOGOUT_SLACK=$LOGOUT_SLACK_RAW (measured on this workstation's clock from when a post-rotation session key is first seen, not from the rotation itself) for the old client's delayed logout"
    else
      say "  rotation (AC-022): SKIPPED(E2E_VSPHERE_ROTATED_PASSWORD not set)"
    fi
  fi
  say "  cleanup          : $cleanup_line"
  say "Steps:"
  say "  $((n += 1)). preflight (read-only): no foreign $foreign; managed mode refuses (exit 2, nothing changed) if it finds a Deployment with a crossplane/crossplane image, a $CP_RELEASE Helm release in $CP_NS or the $PROVIDER_RES CRD"
  if phase_has_gate; then
    if [[ $EXISTING == true ]]; then
      say "  $((n += 1)). [AC-008] version gate: SKIPPED(existing-crossplane)"
    else
      say "  $((n += 1)). [AC-008] version gate: helm upgrade --install Crossplane $LEGACY_VERSION, apply the Provider, expect the revision to be rejected by spec.crossplane.version >=v2.0.0, then remove it, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW for Crossplane to finish, and uninstall Crossplane $LEGACY_VERSION; if that teardown does not complete, the run stops there rather than run anything else on it"
    fi
  fi
  if phase_has_vm; then
    if [[ $EXISTING == true ]]; then
      say "  $((n += 1)). Crossplane: $(crossplane_label plan vm); the run tests whatever v2 release it runs (a real run stops if it is not v2, and warns when it is not the requested v$XP_VERSION)"
    else
      say "  $((n += 1)). Crossplane v$XP_VERSION: $(crossplane_label plan vm)"
    fi
    say "  $((n += 1)). install $PACKAGE; wait Installed and Healthy; SafeStart(info): engaged or fallback, never gating"
    say "  $((n += 1)). setup: namespace, credentials Secrets (JSON piped through stdin), ProviderConfig examples; [AC-016] Observe-only VmfsDatastore when a VMFS datastore is available"
    say "  $((n += 1)). [AC-007] namespaced VM whose providerConfigRef names a missing ProviderConfig reports Synced=False naming it within 5m"
    say "  $((n += 1)). [AC-016] cluster: datastoreIdRef to the VmfsDatastore resolves; namespaced: literal datastoreId on an NFS datastore works"
    say "  $((n += 1)). [AC-005] both VMs reach Ready=True and Synced=True within 30m"
    say "  $((n += 1)). [INITPROVIDER] (ankasoft #5) $INITLATE_NAME: spec.initProvider.annotation is applied on create; [LATEINIT-DISABLED] (ankasoft #7) an out-of-band annotation change is not reverted (annotation is optional, provider-computed, late-init-ignored and not in forProvider, and managementPolicies exclude LateInitialize); [DEFAULTED-DRIFT-CORRECTED] (A-036/OT-019) an out-of-band cpu_reservation change IS corrected back to 0 (it is absent from forProvider but not provider-computed, so the provider enforces its zero value) despite LateInitialize being excluded"
    say "  $((n += 1)). [AC-018] no UpdatedExternalResource event for $STEADY_MIN_INTERVALS consecutive poll intervals; [AC-021] provider-user vCenter sessions at least $PROVIDER_CONFIGS_IN_USE (one per ProviderConfig in use; fewer means the script cannot see them: FAIL, never a pass) and at most $PROVIDER_CONFIGS_IN_USE x provider pods"
    if [[ -n $ROTATED_PASSWORD ]]; then
      say "  $((n += 1)). [AC-022] record the provider-user session keys, pause on /dev/tty for you to change the vCenter password, then log govc in with the rotated password only (vCenter rejects the original from then on) and re-sample the keys before rotating the credentials Secrets; touch each VM and within one poll interval confirm both Synced=True AND one new provider-user session per rotated ProviderConfig, identified by a session key absent before the rotation (vCenter keeps the old session alive across a password change, so Synced=True alone cannot prove the client was rebuilt; keys, not vCenter loginTime, so vCenter/workstation clock skew cannot affect it)"
    else
      say "  $((n += 1)). [AC-022] SKIPPED(E2E_VSPHERE_ROTATED_PASSWORD not set)"
    fi
    say "  $((n += 1)). [AC-019] annotation removed from the MR spec; VM powered off and annotation changed out of band with govc; still poweredOff after the next reconcile"
    say "  $((n += 1)). [AC-006] update numCpus 2->4 and memory 4096->6144 in place (same external-name and instance UUID)"
    say "  $((n += 1)). [AC-006] delete each MR / OT-021: the VM is gone from vCenter"
    if [[ -n $ROTATED_PASSWORD ]]; then
      say "  $((n += 1)). [AC-022] wait out whatever remains of E2E_LOGOUT_DELAY=$LOGOUT_DELAY_RAW + E2E_LOGOUT_SLACK=$LOGOUT_SLACK_RAW since a post-rotation session key was first seen (workstation clock), then confirm every pre-rotation session key is gone, at least one provider-user session is still visible (so the check cannot pass blind), and the count is back within the AC-021 bound"
    fi
  fi
  if [[ $SKIP_CLEANUP == true ]]; then
    say "  $((n += 1)). no cleanup (--skip-cleanup): list what this run left in place, if anything, and the commands to remove it; then the PASS/FAIL report"
  else
    say "  $((n += 1)). cleanup, then the PASS/FAIL report"
  fi
  say ""
}

init_results() {
  local r c
  for r in "${ROWS[@]}"; do
    for c in "${COLS[@]}"; do RESULT["$r|$c"]="SKIPPED(n/a)"; done
  done
  for r in AC-005 AC-006-update AC-006-delete/OT-021 AC-016 AC-018 AC-019 AC-022; do
    RESULT["$r|cluster"]="SKIPPED(not run)"
    RESULT["$r|namespaced"]="SKIPPED(not run)"
  done
  RESULT["AC-007|namespaced"]="SKIPPED(not run)"
  RESULT["AC-008|package"]="SKIPPED(not run)"
  RESULT["AC-021|package"]="SKIPPED(not run)"
  RESULT["AC-022|package"]="SKIPPED(not run)"
  RESULT["INITPROVIDER|namespaced"]="SKIPPED(not run)"
  RESULT["LATEINIT-DISABLED|namespaced"]="SKIPPED(not run)"
  RESULT["DEFAULTED-DRIFT-CORRECTED|namespaced"]="SKIPPED(not run)"
  RESULT["SafeStart(info)|package"]="SKIPPED(not run)"
}

# record stores a cell. In dry-run a PASS or FAIL outcome is only PLANNED.
record() {
  if is_dry && [[ $3 == PASS || $3 == FAIL ]]; then
    RESULT["$1|$2"]=PLANNED
  else
    RESULT["$1|$2"]=$3
  fi
}
# check runs an assertion command and records PASS or FAIL for row $1, column $2.
check() {
  if "${@:3}"; then record "$1" "$2" PASS; else record "$1" "$2" FAIL; fi
}
# ac022_passed: AC-022 PASSed in every column (each scope's post-rotation reconcile and the
# package-level delayed-logout check). Anything else -- SKIPPED for any reason, or PLANNED in a
# dry run -- means AC-022 was not asserted.
ac022_passed() {
  local c
  for c in "${COLS[@]}"; do
    [[ ${RESULT[AC-022|$c]:-} == PASS ]] || return 1
  done
  return 0
}
# any_fail: a criterion FAILed, or E2E_REQUIRE_AC022=true and AC-022 did not PASS in every column
# (with it required, an AC-022 that ended SKIPPED, for any reason, counts as a failure). Both
# callers (print_report via result_line, and on_exit) rule out a dry run first.
any_fail() {
  local key
  for key in "${!RESULT[@]}"; do
    [[ ${RESULT[$key]} != FAIL* ]] || return 0
  done
  [[ $REQUIRE_AC022 == true ]] && ! ac022_passed
}
# result_line prints the report's last line. A PASS that did not assert AC-022 -- possible only
# with E2E_REQUIRE_AC022=false, since with true any_fail makes it a FAIL -- says so, and so does a
# PASS whose skipped cleanup (--skip-cleanup) left anything this run created in place
# (collect_left), so a partial run cannot be mistaken for a full release-gate run, which deletes
# everything it labelled and uninstalls the Crossplane it installed. Neither kind of run removes
# what that uninstall leaves (crossplane_remainder), so it earns no note. Both notes share one
# pair of parentheses.
result_line() {
  local -a notes=()
  local s
  if is_dry; then
    printf 'Result: DRY RUN (no planned command was executed)'
    return 0
  fi
  if any_fail || [[ -n $ABORT_REASON || $CLEANUP_OK != true ]]; then
    printf 'Result: FAIL'
    return 0
  fi
  if ! ac022_passed; then notes+=("AC-022 not asserted: E2E_REQUIRE_AC022=false"); fi
  if [[ $SKIP_CLEANUP == true ]]; then
    collect_left
    if ((${#LEFT_IN_PLACE[@]})); then notes+=("cleanup skipped: --skip-cleanup left objects in place"); fi
  fi
  if ((${#notes[@]})); then
    printf -v s '%s; ' "${notes[@]}"
    printf 'Result: PASS (%s)' "${s%; }"
  else
    printf 'Result: PASS'
  fi
}

# poll_until TIMEOUT_S INTERVAL_S DESCRIPTION COMMAND...: retry COMMAND until it succeeds.
poll_until() {
  local timeout=$1 interval=$2 desc=$3 deadline
  shift 3
  if is_dry; then
    say "  (poll every ${interval}s, up to ${timeout}s, until: $desc)"
    "$@" || true
    return 0
  fi
  deadline=$((SECONDS + timeout))
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep "$interval"
  done
}
sleep_poll() {
  local s=$((POLL_SECONDS + POLL_SLACK_SECONDS))
  if is_dry; then
    say "+ sleep ${s}  # one provider poll interval ($POLL_INTERVAL) plus ${POLL_SLACK_SECONDS}s"
    return 0
  fi
  sleep "$s"
}

# get_names prints `kubectl get -o name` output; an absent resource type counts as no objects.
get_names() {
  local out rc=0
  out=$(k get "$@" -o name 2>"$WORKDIR/stderr") || rc=$?
  if ((rc == 0)); then
    printf '%s' "$out"
    return 0
  fi
  if grep -q "doesn't have a resource type" "$WORKDIR/stderr"; then return 0; fi
  cat "$WORKDIR/stderr" >&2
  return 1
}
# del runs `kubectl delete`; an absent resource type is not an error. Failures mark cleanup.
del() {
  local rc=0
  if is_dry; then
    k delete "$@"
    return 0
  fi
  k delete "$@" 2>"$WORKDIR/stderr" || rc=$?
  ((rc != 0)) || return 0
  if grep -q "doesn't have a resource type" "$WORKDIR/stderr"; then return 0; fi
  cat "$WORKDIR/stderr" >&2
  CLEANUP_OK=false
  return 1
}

apply_manifest() {
  if is_dry; then
    k apply -f -
    printf '%s\n' "$1" | sed 's/^/    | /' >&3
    return 0
  fi
  printf '%s\n' "$1" | k apply -f -
}
apply_file() {
  if is_dry; then
    k apply -f "$1"
    sed 's/^/    | /' "$1" >&3
    return 0
  fi
  k apply -f "$1"
}

yaml_quote() {
  local s=$1
  s=${s//"\\"/"\\\\"}
  s=${s//"\""/"\\\""}
  printf '"%s"' "$s"
}

# render_example SRC DST [FROM TO]...: copy an examples/ file, apply literal replacements, drop
# comment lines, add this run's label and refuse any REPLACE_WITH_ token left over.
render_example() {
  local src=$REPO_ROOT/$1 dst=$2 content
  shift 2
  [[ -f $src ]] || fatal "missing example file $src"
  content=$(<"$src")
  while (($# >= 2)); do
    content=${content//"$1"/"$2"}
    shift 2
  done
  printf '%s\n' "$content" | awk -v key="$RUN_LABEL_KEY" -v id="$RUN_ID" '
    /^[ \t]*#/ { next }
    !done && /^metadata:[ \t]*$/ { print; print "  labels:"; printf "    %s: \"%s\"\n", key, id; done = 1; next }
    { print }' >"$dst"
  if grep -q 'REPLACE_WITH_' "$dst"; then
    fatal "refusing to apply $dst: placeholder(s) left: $(grep -o 'REPLACE_WITH_[A-Z_]*' "$dst" | sort -u | tr '\n' ' ')"
  fi
}

# vm_pairs fills VM_PAIRS with the REPLACE_WITH_* replacements taken from the environment.
vm_pairs() {
  VM_PAIRS=()
  if [[ -n ${E2E_HOST_SYSTEM_ID:-} ]]; then
    VM_PAIRS+=("# hostSystemId: REPLACE_WITH_HOST_SYSTEM_ID" "hostSystemId: $(yaml_quote "$E2E_HOST_SYSTEM_ID")")
  fi
  if [[ -n ${E2E_DISK_GB:-} ]]; then VM_PAIRS+=("size: 40" "size: $E2E_DISK_GB"); fi
  VM_PAIRS+=(
    REPLACE_WITH_NETWORK_ID "$(yaml_quote "$E2E_NETWORK_ID")"
    REPLACE_WITH_DATASTORE_ID "$(yaml_quote "$E2E_DATASTORE_ID")"
    REPLACE_WITH_RESOURCE_POOL_ID "$(yaml_quote "$E2E_RESOURCE_POOL_ID")"
    REPLACE_WITH_FOLDER "$(yaml_quote "$E2E_FOLDER")"
    REPLACE_WITH_TEMPLATE_UUID "$(yaml_quote "$E2E_TEMPLATE_UUID")"
    REPLACE_WITH_GUEST_ID "$(yaml_quote "$E2E_GUEST_ID")"
    REPLACE_WITH_FIRMWARE "$(yaml_quote "$FIRMWARE")"
  )
}

vmref() {
  case $1 in
    cluster) REF=("$VM_RES_CLUSTER/$VM_NAME_CLUSTER") && VM_NAME=$VM_NAME_CLUSTER ;;
    namespaced) REF=(-n "$NS" "$VM_RES_NS/$VM_NAME_NS") && VM_NAME=$VM_NAME_NS ;;
  esac
}

# vm_path prints the VM's vCenter inventory path, or nothing when the VM does not exist.
vm_path() {
  local out
  out=$(g find / -type m -name "$1") || return 1
  if is_dry; then
    printf '%s' "<inventory path of $1>"
    return 0
  fi
  printf '%s' "${out%%$'\n'*}"
}
vm_info() { g vm.info -json "$1"; }
power_state() {
  local json
  json=$(vm_info "$1") || return 1
  if is_dry; then printf 'poweredOff' && return 0; fi
  jq -r '.virtualMachines[0].runtime.powerState // empty' <<<"$json"
}
instance_uuid() {
  local json
  json=$(vm_info "$1") || return 1
  if is_dry; then printf 'dry-run' && return 0; fi
  jq -r '.virtualMachines[0].config.instanceUuid // empty' <<<"$json"
}
external_name() {
  vmref "$1"
  k get "${REF[@]}" -o 'jsonpath={.metadata.annotations.crossplane\.io/external-name}'
}
count_updates() {
  local json
  json=$(k get events -A --field-selector "involvedObject.name=$1,reason=UpdatedExternalResource" -o json) || return 1
  if is_dry; then printf '0' && return 0; fi
  jq '[.items[] | (.count // 1)] | add // 0' <<<"$json"
}
provider_pod_count() {
  local json
  json=$(k -n "$CP_NS" get pods -l "pkg.crossplane.io/provider=$PROVIDER_NAME" --field-selector=status.phase=Running -o json) || return 1
  if is_dry; then printf '1' && return 0; fi
  jq '.items | length' <<<"$json"
}
# provider_sessions prints the count of provider-user sessions, then one line per session
# (userName, user agent, client IP, login time; session keys are never printed). It keeps govc's
# raw output in $WORKDIR/session-last.json for session_visibility_diag.
provider_sessions() {
  local json
  json=$(g session.ls -json) || return 1
  if is_dry; then printf '0\n' && return 0; fi
  printf '%s\n' "$json" >"$WORKDIR/session-last.json"
  jq -r --arg u "$VSPHERE_USER" --arg mode "$SESSION_USER_MATCH" \
    --slurpfile base "$WORKDIR/session-baseline.json" "$JQ_PROVIDER_SESSIONS" <<<"$json"
}
# provider_session_records prints the JSON array [{key, userName, loginTime, userAgent}, ...] of
# the same provider-user sessions as provider_sessions. AC-022 uses it to tell sessions apart by
# key, which a bare count cannot do. It also keeps govc's raw output in session-last.json.
provider_session_records() {
  local json
  json=$(g session.ls -json) || return 1
  if is_dry; then printf '[]' && return 0; fi
  printf '%s\n' "$json" >"$WORKDIR/session-last.json"
  jq -c --arg u "$VSPHERE_USER" --arg mode "$SESSION_USER_MATCH" \
    --slurpfile base "$WORKDIR/session-baseline.json" "$JQ_PROVIDER_SESSION_RECORDS" <<<"$json"
}
synced_at_generation() {
  local json
  vmref "$1"
  json=$(k get "${REF[@]}" -o json) || return 1
  if is_dry; then return 0; fi
  jq -e '.metadata.generation as $g | any(.status.conditions[]?; .type == "Synced" and .status == "True" and ((.observedGeneration // $g) == $g))' <<<"$json" >/dev/null
}
# synced_now: Synced=True at any generation. Used after an AC-022 annotation touch, which does
# not bump .metadata.generation (only spec changes do), so synced_at_generation cannot apply.
synced_now() {
  local json
  vmref "$1"
  json=$(k get "${REF[@]}" -o json) || return 1
  if is_dry; then return 0; fi
  jq -e 'any(.status.conditions[]?; .type == "Synced" and .status == "True")' <<<"$json" >/dev/null
}
# observe_new_logins lists the provider-user sessions once and sets NEW_LOGIN_COUNT to how many
# have a session key absent from PRE_ROTATION_SESSION_KEYS. Such a session is a login made after
# the last pre-rotation sample, which run_ac022_rotation_start takes once VSPHERE_USER's vCenter
# password has been changed, so it logged in with the rotated password, which only the rotated
# Secret gives the provider: a rebuilt client. vCenter keeps the pre-rotation session alive
# across a password change, so Synced=True after the touch proves nothing about which client
# served it. The first time it sees such a session it sets NEW_LOGIN_EPOCH from this
# workstation's clock, which anchors the delayed-logout wait in run_ac022_rotation_finish.
# vCenter's loginTime is deliberately not used: compared with this workstation's clock, a
# lagging vCenter clock can date a new session before the rotation, and the check would then
# fail a correct provider (self-test case (a)). Returns 1 when the sessions cannot be listed or
# none is new.
observe_new_logins() {
  local json n
  NEW_LOGIN_COUNT=0
  json=$(provider_session_records) || return 1
  n=$(jq --argjson pre "$PRE_ROTATION_SESSION_KEYS" \
    '[.[] | select(.key as $k | $pre | any(.[]; . == $k) | not)] | length' <<<"$json") || return 1
  is_num "$n" || return 1
  NEW_LOGIN_COUNT=$n
  ((n > 0)) || return 1
  if ((NEW_LOGIN_EPOCH == 0)); then NEW_LOGIN_EPOCH=$(date -u +%s); fi
  return 0
}
# min_provider_sessions prints the fewest provider-user vCenter sessions a correct provider holds
# while the VMs in ALIVE are Ready: one per distinct ProviderConfig they use (the cluster VM uses
# the cluster ProviderConfig, the namespaced VM the namespaced one), because the provider's
# session cache (internal/clients/cache.go) keeps one client, with its own vCenter login, per
# ProviderConfig identity. It drops that client only on a session or login error or a
# credentials change, rebuilding it at the next reconcile, or when the ProviderConfig is
# deleted. That is PROVIDER_CONFIGS_IN_USE when both VMs are Ready, and never less than 1. A
# lower count means this script cannot see the provider's sessions, so it is a measurement
# failure, never a pass.
min_provider_sessions() {
  local n=${#ALIVE[@]}
  ((n >= 1)) || n=1
  ((n <= PROVIDER_CONFIGS_IN_USE)) || n=$PROVIDER_CONFIGS_IN_USE
  printf '%s' "$n"
}
# session_visibility_diag LABEL SEEN MIN explains a provider-user session count below the
# minimum the provider must hold. It names the configured VSPHERE_USER, the userName vCenter
# gives govc's own login as that user, and the distinct userNames of every other session govc
# was shown. It prints user names only: never a session key and never a password.
session_visibility_diag() {
  local label=$1 seen=$2 min=$3 raw=$WORKDIR/session-last.json own others
  say "[$label] MEASUREMENT FAILURE: $seen provider-user vCenter session(s) visible, fewer than the $min the provider must hold now (one per ProviderConfig in use); this script cannot see the provider's sessions, so this sample cannot pass"
  say "[$label]   configured VSPHERE_USER: $VSPHERE_USER (E2E_SESSION_USER_MATCH=$SESSION_USER_MATCH)"
  if [[ -s $raw ]] && own=$(jq -r '.currentSession.userName // "?"' "$raw") &&
    others=$(jq -r '(.currentSession.key // "") as $cur
      | [.sessionList[]? | select(.key != $cur) | .userName // "?"]
      | "\(length) session(s) listed besides the govc session itself; their distinct userNames: \(unique | if length == 0 then "(none)" else join(", ") end)"' "$raw"); then
    say "[$label]   vCenter reports the govc session (logged in as VSPHERE_USER) as userName: $own"
    say "[$label]   $others"
  else
    say "[$label]   no usable govc session.ls output to diagnose from"
  fi
  say "[$label]   likely causes: (1) VSPHERE_USER lacks the Sessions.TerminateSession privilege ('Sessions > View and stop sessions') on the vCenter root object, so SessionManager.sessionList shows govc only its own session; (2) the userName vCenter reports for the provider's sessions does not match VSPHERE_USER under E2E_SESSION_USER_MATCH=$SESSION_USER_MATCH: compare it with the userNames above (see RELEASING.md section 2)"
}
diag_vm() {
  vmref "$1"
  if is_dry; then return 0; fi
  k get "${REF[@]}" -o 'jsonpath={range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' >&2 || true
}
diag_provider() {
  if is_dry; then return 0; fi
  k describe "$PROVIDER_RES/$PROVIDER_NAME" >&2 || true
  k get "$REVISION_RES" -l "pkg.crossplane.io/package=$PROVIDER_NAME" -o wide >&2 || true
}

# find_crossplane prints "namespace/name image" for every Deployment, in any namespace, whose
# container image is crossplane/crossplane:<tag> from any registry (the Crossplane Helm chart's
# image). A Crossplane core under another image name is not found.
find_crossplane() {
  local json
  json=$(k get deployments -A -o json) || return 1
  if is_dry; then return 0; fi
  jq -r '.items[] | . as $d | .spec.template.spec.containers[]
    | select(.image | test("(^|/)crossplane/crossplane:"))
    | "\($d.metadata.namespace)/\($d.metadata.name) \(.image)"' <<<"$json"
}

# preflight checks, read-only, that this run can proceed. Managed mode installs its own Crossplane,
# so it refuses (refuse: exit 2, nothing changed) when it finds any sign of one: a Deployment with
# a crossplane/crossplane image (find_crossplane), a crossplane Helm release in crossplane-system,
# or the providers.pkg.crossplane.io CRD. The CRD also catches a Crossplane installed under
# another image or release name, and one whose CRDs outlived it: Crossplane creates its CRDs
# itself (the chart's init container), so helm uninstall leaves them. --existing-crossplane
# instead requires a Crossplane v2 Deployment in crossplane-system.
preflight() {
  local cps img tag existing crd found_list
  local -a found=()
  say "== Preflight (read-only) on context $KUBE_CONTEXT"
  cps=$(find_crossplane) || fatal "cannot list Deployments on context $KUBE_CONTEXT"
  if [[ $EXISTING == true ]]; then
    if ! is_dry; then
      img=$(awk -v ns="$CP_NS" 'index($1, ns "/") == 1 { print $2; exit }' <<<"$cps")
      [[ -n $img ]] || fatal "--existing-crossplane: no Crossplane Deployment runs in namespace $CP_NS"
      tag=${img%%@*}
      tag=${tag##*:}
      tag=${tag#v}
      [[ $tag == 2.* ]] || fatal "the existing Crossplane runs $img; this provider needs Crossplane >= v2.0.0"
      if [[ $tag != "$XP_VERSION" ]]; then
        warn "the existing Crossplane runs v$tag, not the requested v$XP_VERSION; results are for v$tag"
      fi
      say "Existing Crossplane: $img"
    fi
  else
    if [[ -n $cps ]]; then found+=("Deployment ${cps//$'\n'/, Deployment }"); fi
    if is_dry; then
      h status "$CP_RELEASE" --namespace "$CP_NS"
    elif h status "$CP_RELEASE" --namespace "$CP_NS" >/dev/null 2>&1; then
      found+=("Helm release $CP_RELEASE in $CP_NS")
    fi
    crd=$(get_names "$CRD_RES" "$PROVIDER_RES" --ignore-not-found) || fatal "cannot check for the $PROVIDER_RES CRD"
    if [[ -n $crd ]]; then found+=("CRD $PROVIDER_RES"); fi
    if ((${#found[@]})); then
      printf -v found_list '%s; ' "${found[@]}"
      refuse "managed mode found Crossplane already present on context $KUBE_CONTEXT (${found_list%; }). Use --existing-crossplane to test against it, or a clean lab cluster. Crossplane creates its CRDs itself and helm uninstall leaves them, so a cluster where an earlier managed run ended still has them: RELEASING.md section 8 shows how to remove them."
    fi
  fi
  existing=$(get_names "$PROVIDER_RES" "$PROVIDER_NAME" --ignore-not-found) || fatal "cannot check for an existing Provider"
  [[ -z $existing ]] || fatal "Provider $PROVIDER_NAME already exists and was not created by this run; remove it or use another cluster"
  existing=$(get_names "$DRC_RES" "$RUNTIME_CONFIG_NAME" --ignore-not-found) || fatal "cannot check for an existing DeploymentRuntimeConfig"
  [[ -z $existing ]] || fatal "DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME already exists and was not created by this run"
  if phase_has_vm; then
    existing=$(get_names namespace "$NS" --ignore-not-found) || fatal "cannot check namespace $NS"
    [[ -z $existing ]] || fatal "namespace $NS already exists; set E2E_NAMESPACE to an unused name"
    g about >/dev/null || fatal "govc cannot reach vCenter $VSPHERE_SERVER as $VSPHERE_USER"
    preflight_datastores
  fi
}

# preflight_datastores decides the AC-016 inputs from the datastore types govc reports.
preflight_datastores() {
  local vmfs_type
  DS_TYPE=$(g object.collect -s "Datastore:$E2E_DATASTORE_ID" summary.type) || fatal "govc cannot read datastore $E2E_DATASTORE_ID"
  if is_dry; then
    VMFS_DS_ID=${E2E_VMFS_DATASTORE_ID:-$E2E_DATASTORE_ID}
    say "  [AC-016] a real run uses $VMFS_DS_ID for the datastoreIdRef check only when govc reports it as VMFS"
    return 0
  fi
  say "Datastore $E2E_DATASTORE_ID type: $DS_TYPE"
  if [[ -n ${E2E_VMFS_DATASTORE_ID:-} ]]; then
    vmfs_type=$(g object.collect -s "Datastore:$E2E_VMFS_DATASTORE_ID" summary.type) || fatal "govc cannot read datastore $E2E_VMFS_DATASTORE_ID"
    [[ $vmfs_type == VMFS ]] || fatal "E2E_VMFS_DATASTORE_ID=$E2E_VMFS_DATASTORE_ID is $vmfs_type, not VMFS"
    VMFS_DS_ID=$E2E_VMFS_DATASTORE_ID
  elif [[ $DS_TYPE == VMFS ]]; then
    VMFS_DS_ID=$E2E_DATASTORE_ID
  fi
}

apply_provider() {
  CLUSTER_TOUCHED=true
  PROVIDER_APPLIED=true
  apply_manifest "$(
    cat <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: $RUNTIME_CONFIG_NAME
  labels:
    $RUN_LABEL_KEY: "$RUN_ID"
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              args:
                - --debug
                - --poll=$POLL_INTERVAL
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: $PROVIDER_NAME
  labels:
    $RUN_LABEL_KEY: "$RUN_ID"
spec:
  package: $PACKAGE
  runtimeConfigRef:
    name: $RUNTIME_CONFIG_NAME
EOF
  )"
}
# revision_gone: no ProviderRevision carries this Provider's package label. Crossplane removes a
# ProviderRevision from the Lock and drops its own finalizer (revision.pkg.crossplane.io) before
# the object disappears, and before it checks spec.crossplane.version, so a revision the version
# gate rejected is cleaned up the same way it would be otherwise.
revision_gone() {
  local out
  out=$(get_names "$REVISION_RES" -l "pkg.crossplane.io/package=$PROVIDER_NAME") || return 1
  if is_dry; then return 0; fi
  [[ -z $out ]]
}
# deployment_gone: no Deployment in crossplane-system whose pod selector names $PROVIDER_NAME. The
# Deployment a ProviderRevision owns carries pkg.crossplane.io/provider=<name> only in
# .spec.selector.matchLabels and its pod template, never in its own metadata labels, so this is
# filtered with jq, never `kubectl -l`.
deployment_gone() {
  local json
  json=$(k -n "$CP_NS" get deployments -o json) || return 1
  if is_dry; then return 0; fi
  jq -e --arg p "$PROVIDER_NAME" \
    '[.items[] | select(.spec.selector.matchLabels["pkg.crossplane.io/provider"] == $p)] | length == 0' \
    <<<"$json" >/dev/null
}
# lock_finalizer_gone: the cluster-scoped Lock (name "lock") no longer carries its own
# lock.pkg.crossplane.io finalizer, which Crossplane drops only once no package remains. Only
# meaningful in managed mode: an existing installation may hold other packages, whose presence
# alone keeps this finalizer, so provider_removed never calls this under --existing-crossplane.
lock_finalizer_gone() {
  local json
  json=$(k get "$LOCK_RES" "$LOCK_NAME" -o json --ignore-not-found) || return 1
  if is_dry || [[ -z $json ]]; then return 0; fi
  jq -e '((.metadata.finalizers // []) | index("lock.pkg.crossplane.io")) == null' <<<"$json" >/dev/null
}
# provider_removed: every condition remove_provider's wait requires currently holds.
provider_removed() {
  revision_gone && deployment_gone && { [[ $EXISTING == true ]] || lock_finalizer_gone; }
}

# removal_wait_step: provider_removed as a step a human runs by hand, the wait between deleting
# this run's Provider and uninstalling Crossplane: no ProviderRevision of the provider, no
# Deployment in crossplane-system selecting it (that label is only in the Deployment's selector,
# so the SELECTOR column of -o wide shows it), and, in managed mode, the Lock's own finalizer
# cleared. An existing installation may hold other packages, which alone keep that finalizer.
removal_wait_step() {
  local kc="kubectl --context $KUBE_CONTEXT" s
  s="check the Crossplane pod logs ($kc -n $CP_NS logs deploy/$CP_RELEASE) and wait until this lists no ProviderRevision: $kc get $REVISION_RES -l pkg.crossplane.io/package=$PROVIDER_NAME; until no Deployment this lists shows pkg.crossplane.io/provider=$PROVIDER_NAME under SELECTOR: $kc -n $CP_NS get deployments -o wide"
  if [[ $EXISTING != true ]]; then
    s+="; and until this no longer prints lock.pkg.crossplane.io: $kc get $LOCK_RES $LOCK_NAME -o jsonpath='{.metadata.finalizers}'"
  fi
  printf '%s' "$s"
}

# print_removal_steps FIRST: numbered from FIRST, the steps that remove by hand what is left of
# this run's Provider and Crossplane, in the order the automated teardown follows (remove_provider,
# then uninstall_crossplane). They come from the state flags alone, so they name only what may
# still exist: delete this run's Provider and DeploymentRuntimeConfig while PROVIDER_APPLIED; wait
# (removal_wait_step) while Crossplane may still be removing a Provider this run applied
# (PROVIDER_APPLIED, or PROVIDER_REMOVAL_OK false after its deletes); then, while
# CP_INSTALLED_BY_RUN, helm uninstall the Crossplane this run installed -- only after that wait
# when there is one -- or, in existing mode with a removal to finish, leave Crossplane installed;
# and last, after a Provider removal, the finalizer patch, only on a dedicated lab cluster. In
# managed mode that comes only once this run's Crossplane is gone. In existing mode Crossplane is
# never uninstalled, and while it runs it removes these finalizers itself: on a ProviderRevision's
# deletion it removes the revision from the Lock and then drops the revision.pkg.crossplane.io
# finalizer, the revision's Deployment going by garbage collection (internal/controller/pkg
# /revision/reconciler.go:396-427, Crossplane v2.2.0 and v2.4.2). It drops the Lock's own
# lock.pkg.crossplane.io finalizer only once no package is left in the Lock (internal/controller
# /pkg/resolver/reconciler.go:217-233), so on a shared installation that finalizer is expected to
# stay. There the step is a last resort, after the Crossplane pod logs, that the installation's
# operator decides on, and never for the Lock's own finalizer. print_provider_removal_diag and
# print_manual_cleanup both print these, so the two lists cannot drift apart.
print_removal_steps() {
  local n=$(($1 - 1)) kc="kubectl --context $KUBE_CONTEXT" pending=false
  local uninstall="helm --kube-context $KUBE_CONTEXT uninstall $CP_RELEASE --namespace $CP_NS"
  local patch="$kc patch <TYPE> <NAME> -p '{\"metadata\":{\"finalizers\": []}}' --type=merge"
  if [[ $PROVIDER_APPLIED == true ]]; then
    say "  $((n += 1)). delete this run's Provider and DeploymentRuntimeConfig: $kc delete $PROVIDER_RES,$DRC_RES -l $RUN_LABEL_KEY=$RUN_ID"
    pending=true
  elif [[ $PROVIDER_REMOVAL_OK != true ]]; then
    pending=true
  fi
  if [[ $pending == true ]]; then say "  $((n += 1)). $(removal_wait_step)"; fi
  if [[ $EXISTING == true ]]; then
    if [[ $pending == true ]]; then
      say "  $((n += 1)). leave Crossplane installed: it is not this run's (--existing-crossplane), and it is the controller that finishes this removal"
    fi
  elif [[ $CP_INSTALLED_BY_RUN == true ]]; then
    if [[ $pending == true ]]; then
      say "  $((n += 1)). only then uninstall the Crossplane this run installed, which the script leaves in place: $uninstall"
    else
      say "  $((n += 1)). uninstall the Crossplane this run installed, which the script leaves in place (no Provider of this run is left for it to remove first): $uninstall"
    fi
  fi
  if [[ $pending == true && $EXISTING == true ]]; then
    say "  $((n += 1)). only as a last resort, if the ProviderRevision is still there after that wait: the running Crossplane removes it from the Lock and drops its revision.pkg.crossplane.io finalizer itself (its Deployment then goes by garbage collection), so check the Crossplane pod logs first ($kc -n $CP_NS logs deploy/$CP_RELEASE); only if they show it cannot finish, only on this dedicated lab cluster, and only if you, as the operator of this shared Crossplane, decide to, clear the leftover finalizer by hand: $patch. Never clear the Lock's own lock.pkg.crossplane.io finalizer: Crossplane keeps it while any other package is installed"
  elif [[ $pending == true ]]; then
    say "  $((n += 1)). only if an object is still stuck after Crossplane is gone, and only on this dedicated lab cluster, clear its finalizer by hand: $patch"
  fi
}

# print_provider_removal_diag WHY says why this run could not confirm that Crossplane removed its
# Provider (WHY is "delete" when a kubectl delete of its Provider or DeploymentRuntimeConfig
# failed, "timeout" when remove_provider's wait ran out), names exactly what is still there, and
# prints the recovery (print_removal_steps) as an ordered list, for this dedicated lab cluster
# only. The list follows the removal order of docs.crossplane.io guides/uninstall-crossplane:
# providers before the helm uninstall, CRDs only after it. Checking the Crossplane pod logs,
# waiting for the ProviderRevision, its Deployment and the Lock finalizer to go, and clearing a
# finalizer by hand only once Crossplane itself is gone (in existing mode, only as a last resort
# its operator decides on, and never the Lock's own finalizer) are this script's own advice, not
# that page's.
print_provider_removal_diag() {
  local why=$1 sel="$RUN_LABEL_KEY=$RUN_ID" left revs deps_json deps lock_json
  if [[ $why == delete ]]; then
    say "Removing $PROVIDER_NAME is incomplete: deleting this run's Provider or DeploymentRuntimeConfig failed (the kubectl error is above):"
  else
    say "Crossplane has not finished removing $PROVIDER_NAME within E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW:"
  fi
  if ! is_dry; then
    if left=$(get_names "$PROVIDER_RES,$DRC_RES" -l "$sel") && [[ -n $left ]]; then
      say "  still present: ${left//$'\n'/, }"
    fi
    if revs=$(get_names "$REVISION_RES" -l "pkg.crossplane.io/package=$PROVIDER_NAME") && [[ -n $revs ]]; then
      say "  ProviderRevision still present: ${revs//$'\n'/, }"
    fi
    if deps_json=$(k -n "$CP_NS" get deployments -o json 2>/dev/null); then
      deps=$(jq -r --arg p "$PROVIDER_NAME" \
        '.items[] | select(.spec.selector.matchLabels["pkg.crossplane.io/provider"] == $p) | .metadata.name' \
        <<<"$deps_json" 2>/dev/null) || deps=""
      if [[ -n $deps ]]; then say "  Deployment in $CP_NS still selecting it: ${deps//$'\n'/, }"; fi
    fi
    if [[ $EXISTING != true ]] && lock_json=$(k get "$LOCK_RES" "$LOCK_NAME" -o json --ignore-not-found 2>/dev/null) &&
      [[ -n $lock_json ]] && jq -e '((.metadata.finalizers // []) | index("lock.pkg.crossplane.io")) != null' <<<"$lock_json" >/dev/null 2>&1; then
      say "  Lock $LOCK_NAME still carries its lock.pkg.crossplane.io finalizer"
    fi
  fi
  say "Recovery, on this dedicated lab cluster only, in this order:"
  # After a failed delete PROVIDER_APPLIED is still true, so the recovery starts by deleting again;
  # after a wait that ran out it is false, so the recovery starts with the wait.
  print_removal_steps 1
  if [[ $why == timeout ]]; then
    say "Next time, a longer E2E_PROVIDER_REMOVAL_TIMEOUT (this run: $PROVIDER_REMOVAL_TIMEOUT_RAW) gives a slow Crossplane more time; it does not help this run."
  fi
}

# remove_provider deletes this run's Provider and DeploymentRuntimeConfig, then waits
# (provider_removed) for Crossplane to actually finish tearing the package down, so that a caller
# never uninstalls Crossplane while its controller is the only thing left that can clear those
# finalizers. PROVIDER_REMOVAL_OK is false from before the first delete and turns true only when
# that wait succeeds. When a delete fails or the wait runs out, in either mode, it marks cleanup
# incomplete, warns, and prints what is left and the recovery (print_provider_removal_diag);
# uninstall_crossplane then only skips the helm uninstall. It returns 1 when a delete failed
# (PROVIDER_APPLIED stays true, so cleanup deletes again) and 0 otherwise: whether the wait
# succeeded is PROVIDER_REMOVAL_OK, not the return status.
remove_provider() {
  local wait_desc
  PROVIDER_REMOVAL_OK=false
  if ! del "$PROVIDER_RES" -l "$RUN_LABEL_KEY=$RUN_ID" --ignore-not-found --timeout=5m ||
    ! del "$DRC_RES" -l "$RUN_LABEL_KEY=$RUN_ID" --ignore-not-found --timeout=2m; then
    warn "cannot delete this run's Provider or DeploymentRuntimeConfig; cleanup is incomplete"
    print_provider_removal_diag delete
    return 1
  fi
  PROVIDER_APPLIED=false
  wait_desc="Crossplane has finished removing $PROVIDER_NAME: no ProviderRevision, no Deployment in $CP_NS selecting it"
  if [[ $EXISTING != true ]]; then wait_desc+=", and the Lock finalizer cleared"; fi
  if poll_until "$PROVIDER_REMOVAL_TIMEOUT_SECONDS" "$PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS" "$wait_desc" provider_removed; then
    PROVIDER_REMOVAL_OK=true
    return 0
  fi
  CLEANUP_OK=false
  warn "Crossplane has not finished removing $PROVIDER_NAME within E2E_PROVIDER_REMOVAL_TIMEOUT=$PROVIDER_REMOVAL_TIMEOUT_RAW; cleanup is incomplete"
  print_provider_removal_diag timeout
  return 0
}
# helm_install_crossplane VERSION NAME: NAME is how the end-of-run lists call it
# (CP_INSTALLED_NAME). LEGACY_WEBHOOK_LEFT follows the one webhook configuration whose presence
# depends on the Crossplane line (crossplane_remainder): a 1.x init container creates crossplane,
# and a v2 one deletes it. A v2 install that succeeded implies its init container ran (with
# --wait, helm waits for the pod to be ready, which it is only once that container has
# finished); a failed one leaves the flag as it was.
helm_install_crossplane() {
  CLUSTER_TOUCHED=true
  CP_INSTALLED_BY_RUN=true
  CP_INSTALLED_NAME=$2
  if [[ $1 == 1.* ]]; then LEGACY_WEBHOOK_LEFT=true; fi
  h upgrade --install "$CP_RELEASE" crossplane --repo "$CP_CHART_REPO" --namespace "$CP_NS" \
    --create-namespace --version "$1" --wait --timeout 10m || return
  if [[ $1 == 2.* ]]; then LEGACY_WEBHOOK_LEFT=false; fi
}
# uninstall_crossplane is the only place that uninstalls the Helm release named $CP_RELEASE. It
# runs helm uninstall only when remove_provider's wait (PROVIDER_REMOVAL_OK) confirmed Crossplane
# finished removing the Provider: uninstalling earlier would remove the only controller left that
# can clear the ProviderRevision and Lock finalizers, which is how a stuck finalizer gets created.
# Otherwise it only skips the uninstall, leaving Crossplane installed, and returns 1:
# remove_provider has already reported what is left and the recovery. It still marks cleanup
# incomplete, and names the uninstall to run later, for a wait that an interrupt cut short,
# which remove_provider never got to report.
uninstall_crossplane() {
  if [[ $PROVIDER_REMOVAL_OK != true ]]; then
    CLEANUP_OK=false
    warn "leaving Crossplane installed and skipping helm uninstall: Crossplane has not finished removing $PROVIDER_NAME. To finish by hand, on this dedicated lab cluster only: $(removal_wait_step); only then run: helm --kube-context $KUBE_CONTEXT uninstall $CP_RELEASE --namespace $CP_NS"
    return 1
  fi
  if h uninstall "$CP_RELEASE" --namespace "$CP_NS" --wait --timeout 10m; then
    CP_INSTALLED_BY_RUN=false
    return 0
  fi
  CLEANUP_OK=false
  warn "helm uninstall of $CP_RELEASE failed (its error is above); to retry it: helm --kube-context $KUBE_CONTEXT uninstall $CP_RELEASE --namespace $CP_NS"
  return 1
}

ac008_rejected() {
  local json
  json=$(k get "$REVISION_RES" -l "pkg.crossplane.io/package=$PROVIDER_NAME" -o json) || return 1
  if is_dry; then return 0; fi
  jq -e '[.items[].status.conditions[]? | select(.type == "Healthy" and .status == "False")
    | .message // "" | select(test("incompatible Crossplane version|not compatible with Crossplane version"; "i"))]
    | length > 0' <<<"$json" >/dev/null
}

phase_version_gate() {
  say "== [AC-008] version gate: Crossplane $LEGACY_VERSION must reject $PACKAGE (spec.crossplane.version >=v2.0.0)"
  helm_install_crossplane "$LEGACY_VERSION" "Crossplane $LEGACY_VERSION" || fatal "cannot install Crossplane $LEGACY_VERSION for the version gate"
  apply_provider || fatal "cannot apply the Provider for the version gate"
  if poll_until 300 10 "the ProviderRevision is unhealthy because of the Crossplane version constraint" ac008_rejected; then
    record AC-008 package PASS
  else
    record AC-008 package FAIL
    diag_provider
  fi
  # The gate removes what it installed even under --skip-cleanup: the vm phase must not start on
  # a legacy Crossplane (see below).
  GATE_TEARDOWN=started
  remove_provider || fatal "cannot delete the version-gate Provider; see above for what is left and the recovery"
  # A legacy Crossplane the gate could not remove must not be left for the vm phase, whose helm
  # upgrade --install would take it straight to v2: Crossplane's upgrade guide
  # (docs.crossplane.io/latest/guides/upgrade-to-crossplane-v2) supports v2 only as an upgrade
  # from v1.20, one minor version at a time. So the run stops here. After a removal that did not
  # finish, the EXIT trap's cleanup skips the uninstall too (PROVIDER_REMOVAL_OK stays false) and
  # reports cleanup incomplete; after a failed helm uninstall, it tries that uninstall once more.
  uninstall_crossplane || fatal "the version gate could not uninstall Crossplane $LEGACY_VERSION, so the run stops here rather than run anything else on it; see above for what is left and the recovery"
  GATE_TEARDOWN=finished
}

safestart_seen() {
  SAFESTART_LOGS=$(k -n "$CP_NS" logs -l "pkg.crossplane.io/provider=$PROVIDER_NAME" --tail=-1 2>/dev/null) || return 1
  if is_dry; then return 0; fi
  grep -qF -e "$SAFESTART_FALLBACK_LOG" -e "$SAFESTART_GATED_LOG" <<<"$SAFESTART_LOGS"
}
safestart_info() {
  local v
  SAFESTART_LOGS=""
  say "== SafeStart (FR-110): recorded for information, never gating"
  poll_until 60 5 "the provider log shows which SafeStart path ran" safestart_seen || true
  if is_dry; then
    RESULT["SafeStart(info)|package"]=PLANNED
    return 0
  fi
  if grep -qF "$SAFESTART_FALLBACK_LOG" <<<"$SAFESTART_LOGS"; then
    v="INFO(fallback: eager setup)"
  elif grep -qF "$SAFESTART_GATED_LOG" <<<"$SAFESTART_LOGS"; then
    v="INFO(engaged: gated setup)"
  else
    v="INFO(unknown: no log line)"
  fi
  RESULT["SafeStart(info)|package"]=$v
  say "SafeStart: $v"
}

# create_secret NAMESPACE: the credentials JSON (CT-001 keys) goes from jq to kubectl through
# pipes only, so the password is never an argument of any process.
create_secret() {
  local ns=$1
  if is_dry; then
    say "+ printf %s <redacted> | jq -cn --rawfile password /dev/stdin --arg user $(printf '%q' "$VSPHERE_USER") --arg vsphere_server $(printf '%q' "$VSPHERE_SERVER") --arg allow_unverified_ssl $ALLOW_UNVERIFIED_SSL '{user, password, vsphere_server, allow_unverified_ssl}' | kubectl --context $(printf '%q' "$KUBE_CONTEXT") -n $ns create secret generic $SECRET_NAME --from-file=credentials=/dev/stdin --dry-run=client -o yaml | kubectl --context $(printf '%q' "$KUBE_CONTEXT") label --local -f - $RUN_LABEL_KEY=$RUN_ID -o yaml | kubectl --context $(printf '%q' "$KUBE_CONTEXT") apply -f -"
    return 0
  fi
  printf '%s' "$VSPHERE_PASSWORD" |
    run jq -cn --rawfile password /dev/stdin --arg user "$VSPHERE_USER" --arg vsphere_server "$VSPHERE_SERVER" \
      --arg allow_unverified_ssl "$ALLOW_UNVERIFIED_SSL" \
      '{user: $user, password: $password, vsphere_server: $vsphere_server, allow_unverified_ssl: $allow_unverified_ssl}' |
    k -n "$ns" create secret generic "$SECRET_NAME" --from-file=credentials=/dev/stdin --dry-run=client -o yaml |
    k label --local -f - "$RUN_LABEL_KEY=$RUN_ID" -o yaml |
    k apply -f -
}

setup_configs() {
  say "== Setup: namespace $NS, credentials Secrets, ProviderConfig examples"
  CLUSTER_TOUCHED=true
  NS_CREATED=true
  apply_manifest "$(printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    %s: "%s"' "$NS" "$RUN_LABEL_KEY" "$RUN_ID")" ||
    fatal "cannot create namespace $NS"
  create_secret "$CP_NS" || fatal "cannot create the credentials Secret in $CP_NS"
  create_secret "$NS" || fatal "cannot create the credentials Secret in $NS"
  render_example examples/providerconfig/providerconfig.yaml "$WORKDIR/pc-cluster.yaml" example-creds "$SECRET_NAME"
  render_example examples/providerconfig/clusterproviderconfig.yaml "$WORKDIR/cpc.yaml" example-creds "$SECRET_NAME"
  # A namespaced ProviderConfig reads its Secret from the MR namespace, so both point at $NS.
  render_example examples/providerconfig/namespaced-providerconfig.yaml "$WORKDIR/pc-namespaced.yaml" \
    example-creds "$SECRET_NAME" "namespace: default" "namespace: $NS"
  apply_file "$WORKDIR/pc-cluster.yaml" || fatal "cannot apply the cluster ProviderConfig"
  apply_file "$WORKDIR/cpc.yaml" || fatal "cannot apply the ClusterProviderConfig"
  apply_file "$WORKDIR/pc-namespaced.yaml" || fatal "cannot apply the namespaced ProviderConfig"
}

vmfs_ready() {
  k wait "$VMFS_RES_CLUSTER/$VMFS_MR_NAME" --for=condition=Ready --timeout=10s >/dev/null 2>&1
}

# setup_vmfs_ref: AC-016 cluster check. An Observe-only VmfsDatastore adopts an existing VMFS
# datastore (nothing in vCenter changes), and the cluster VM then uses datastoreIdRef to it.
setup_vmfs_ref() {
  VMFS_REF_ACTIVE=false
  if [[ -z $VMFS_DS_ID ]]; then
    record AC-016 cluster "SKIPPED(no VMFS datastore)"
    say "[AC-016][cluster] skipped: set E2E_VMFS_DATASTORE_ID to a VMFS datastore to run the datastoreIdRef check"
    return 0
  fi
  say "[AC-016][cluster] Observe-only VmfsDatastore $VMFS_MR_NAME for datastore $VMFS_DS_ID"
  VMFS_APPLIED=true
  apply_manifest "$(
    cat <<EOF
apiVersion: storage.vsphere.alphabravo.io/v1alpha1
kind: VmfsDatastore
metadata:
  name: $VMFS_MR_NAME
  labels:
    $RUN_LABEL_KEY: "$RUN_ID"
  annotations:
    crossplane.io/external-name: "$VMFS_DS_ID"
spec:
  managementPolicies: ["Observe"]
  forProvider: {}
  providerConfigRef:
    name: default
EOF
  )" || fatal "cannot apply the Observe-only VmfsDatastore"
  if poll_until 300 10 "VmfsDatastore $VMFS_MR_NAME is Ready (observed)" vmfs_ready; then
    VMFS_REF_ACTIVE=true
  else
    record AC-016 cluster FAIL
    warn "VmfsDatastore $VMFS_MR_NAME never became Ready; the cluster VM uses the literal datastoreId instead"
  fi
}

render_vms() {
  local -a ref_pair=()
  vm_pairs
  if [[ $VMFS_REF_ACTIVE == true ]]; then
    ref_pair=("datastoreId: REPLACE_WITH_DATASTORE_ID" "datastoreIdRef:"$'\n'"      name: $VMFS_MR_NAME")
  fi
  render_example examples/cluster/virtualmachine/virtualmachine.yaml "$WORKDIR/vm-cluster.yaml" \
    "${ref_pair[@]}" example-vm-cluster "$VM_NAME_CLUSTER" "${VM_PAIRS[@]}"
  render_example examples/namespaced/virtualmachine/virtualmachine.yaml "$WORKDIR/vm-namespaced.yaml" \
    example-vm-namespaced "$VM_NAME_NS" "namespace: default" "namespace: $NS" "${VM_PAIRS[@]}"
  render_example examples/namespaced/virtualmachine/virtualmachine.yaml "$WORKDIR/vm-ac007.yaml" \
    example-vm-namespaced "$AC007_NAME" "namespace: default" "namespace: $NS" \
    "kind: ProviderConfig"$'\n'"    name: default" "kind: ProviderConfig"$'\n'"    name: $MISSING_PC" "${VM_PAIRS[@]}"
  grep -q "name: $MISSING_PC" "$WORKDIR/vm-ac007.yaml" || fatal "cannot point the AC-007 copy at $MISSING_PC"
  # INITPROVIDER/LATEINIT-DISABLED (ankasoft #5, #7): remove forProvider.annotation (matched
  # before the example-vm-namespaced rename below, since that rename is a substring of this
  # line too), set it only under spec.initProvider, and exclude LateInitialize, so annotation
  # stays a field Crossplane does not manage (OT-019) and an out-of-band change to it is left
  # alone.
  render_example examples/namespaced/virtualmachine/virtualmachine.yaml "$WORKDIR/vm-initlate.yaml" \
    "    annotation: pioneer/example/example-vm-namespaced/0" "" \
    example-vm-namespaced "$INITLATE_NAME" "namespace: default" "namespace: $NS" \
    "  providerConfigRef:" "  managementPolicies: $LATEINIT_POLICIES"$'\n'"  initProvider:"$'\n'"    annotation: $INITLATE_ANNOTATION"$'\n'"  providerConfigRef:" \
    "${VM_PAIRS[@]}"
  grep -q "annotation: $INITLATE_ANNOTATION" "$WORKDIR/vm-initlate.yaml" || fatal "cannot set spec.initProvider.annotation on the INITPROVIDER/LATEINIT-DISABLED VM"
}

ac007_reported() {
  local json
  json=$(k -n "$NS" get "$VM_RES_NS/$AC007_NAME" -o json) || return 1
  if is_dry; then return 0; fi
  jq -e --arg n "$MISSING_PC" 'any(.status.conditions[]?; .type == "Synced" and .status == "False"
    and ((.message // "") | contains($n)))' <<<"$json" >/dev/null
}
delete_ac007_object() {
  k -n "$NS" delete "$VM_RES_NS" "$AC007_NAME" --ignore-not-found --wait=false || return 0
  if ! k -n "$NS" wait "$VM_RES_NS/$AC007_NAME" --for=delete --timeout=2m; then
    warn "removing the finalizers of $AC007_NAME only: it never created anything in vCenter"
    k -n "$NS" patch "$VM_RES_NS" "$AC007_NAME" --type=merge -p '{"metadata":{"finalizers":null}}' || true
  fi
}

ref_resolved() {
  local got
  got=$(k get "$VM_RES_CLUSTER/$VM_NAME_CLUSTER" -o 'jsonpath={.spec.forProvider.datastoreId}') || return 1
  if is_dry; then return 0; fi
  [[ $got == "$VMFS_DS_ID" ]]
}

run_vm_setup_checks() {
  say "== Create the VMs from examples/ and the AC-007 negative case"
  VMS_APPLIED=true
  apply_file "$WORKDIR/vm-cluster.yaml" || fatal "cannot apply the cluster VM"
  apply_file "$WORKDIR/vm-namespaced.yaml" || fatal "cannot apply the namespaced VM"
  apply_file "$WORKDIR/vm-ac007.yaml" || fatal "cannot apply the AC-007 VM"
  apply_file "$WORKDIR/vm-initlate.yaml" || fatal "cannot apply the INITPROVIDER/LATEINIT-DISABLED VM"
  say "[AC-007][namespaced] $AC007_NAME names missing ProviderConfig $MISSING_PC"
  check AC-007 namespaced poll_until 300 10 "Synced=False with a message naming $MISSING_PC" ac007_reported
  if [[ ${RESULT[AC-007|namespaced]} == FAIL ]]; then
    k -n "$NS" get "$VM_RES_NS/$AC007_NAME" -o 'jsonpath={.status.conditions}' >&2 || true
  fi
  delete_ac007_object
  if [[ $VMFS_REF_ACTIVE == true ]]; then
    say "[AC-016][cluster] datastoreIdRef -> VmfsDatastore $VMFS_MR_NAME must resolve to $VMFS_DS_ID"
    check AC-016 cluster poll_until 600 10 "spec.forProvider.datastoreId == $VMFS_DS_ID" ref_resolved
  fi
}

run_ac005() {
  local s r
  for s in cluster namespaced; do
    vmref "$s"
    say "[AC-005][$s] wait for Ready=True and Synced=True (30m): $VM_NAME"
    if k wait "${REF[@]}" --for=condition=Ready --timeout=30m && k wait "${REF[@]}" --for=condition=Synced --timeout=30m; then
      record AC-005 "$s" PASS
      ALIVE+=("$s")
    else
      record AC-005 "$s" FAIL
      diag_vm "$s"
      for r in AC-006-update AC-006-delete/OT-021 AC-018 AC-019 AC-022; do record "$r" "$s" "SKIPPED(AC-005 failed)"; done
    fi
  done
  # AC-016 namespaced: the literal datastoreId path, which is how an NFS datastore is used.
  if is_dry; then
    record AC-016 namespaced PASS
  elif [[ $DS_TYPE == NFS || $DS_TYPE == NFS41 ]]; then
    record AC-016 namespaced "${RESULT[AC-005|namespaced]}"
  else
    record AC-016 namespaced "SKIPPED(datastore ${DS_TYPE:-unknown}, not NFS)"
  fi
  ((${#ALIVE[@]})) || fatal "no VirtualMachine became Ready; the remaining VM assertions cannot run"
}

# initlate_annotation_matches PATH WANT: the vCenter VM's annotation equals WANT.
initlate_annotation_matches() {
  local path=$1 want=$2 json got
  json=$(vm_info "$path") || return 1
  if is_dry; then return 0; fi
  got=$(jq -r '.virtualMachines[0].config.annotation // ""' <<<"$json")
  [[ $got == "$want" ]]
}

# initlate_cpu_reservation_matches PATH WANT: the vCenter VM's cpuAllocation.reservation (MHz)
# equals WANT. Unlike annotation (Optional and Computed), cpu_reservation is Optional only, with
# no schema default (terraform-provider-vsphere vsphere/virtual_machine_config_structure.go
# schemaVirtualMachineResourceAllocation), so while forProvider.cpuReservation is absent the
# provider enforces its zero value, 0. Leaving LateInitialize out of managementPolicies does not
# stop that; leaving out Update, or pausing the MR, would.
initlate_cpu_reservation_matches() {
  local path=$1 want=$2 json got
  json=$(vm_info "$path") || return 1
  if is_dry; then return 0; fi
  got=$(jq -r '.virtualMachines[0].config.cpuAllocation.reservation // 0' <<<"$json")
  [[ $got == "$want" ]]
}

# run_initlate_checks: the third, namespaced-only VM (FR-105, FR-111). INITPROVIDER
# (ankasoft #5) checks that spec.initProvider.annotation -- the only place this VM sets
# annotation -- was actually applied on create. LATEINIT-DISABLED (ankasoft #7) then changes
# annotation out of band and checks it is left alone: it is a field Crossplane does not manage
# (OT-019), being optional and provider-computed (Optional and Computed in the vSphere provider
# schema), late-init-ignored (config/vsphere_virtual_machine/config.go) and not set in
# forProvider, and this VM's managementPolicies also exclude LateInitialize.
# DEFAULTED-DRIFT-CORRECTED (A-036/OT-019) then makes the same kind of change to cpu_reservation
# -- also absent from forProvider, but not provider-computed, so the provider enforces its zero
# value, 0 -- and checks the opposite: it is corrected back to 0 on the next reconcile even
# though managementPolicies excludes LateInitialize, because that policy only stops Crossplane
# from copying observed values into spec; it does not stop the provider from enforcing an unset
# field. With vSphere provider 2.15.1 this correction may power a powered-off VM back on, same as
# any other reconfigure (AC-019); this VM stays powered on throughout, so that side effect is not
# itself exercised here.
run_initlate_checks() {
  local path
  say "== [INITPROVIDER/LATEINIT-DISABLED/DEFAULTED-DRIFT-CORRECTED] namespaced VM $INITLATE_NAME (ankasoft #5, #7; A-036/OT-019)"
  if ! k -n "$NS" wait "$VM_RES_NS/$INITLATE_NAME" --for=condition=Ready --timeout=30m ||
    ! k -n "$NS" wait "$VM_RES_NS/$INITLATE_NAME" --for=condition=Synced --timeout=30m; then
    record INITPROVIDER namespaced FAIL
    record LATEINIT-DISABLED namespaced FAIL
    record DEFAULTED-DRIFT-CORRECTED namespaced FAIL
    k -n "$NS" get "$VM_RES_NS/$INITLATE_NAME" -o 'jsonpath={.status.conditions}' >&2 || true
    return 0
  fi
  path=$(vm_path "$INITLATE_NAME") || path=""
  if [[ -z $path ]]; then
    record INITPROVIDER namespaced FAIL
    record LATEINIT-DISABLED namespaced FAIL
    record DEFAULTED-DRIFT-CORRECTED namespaced FAIL
    return 0
  fi
  say "[INITPROVIDER][namespaced] spec.initProvider.annotation must be applied on create: $INITLATE_ANNOTATION"
  check INITPROVIDER namespaced initlate_annotation_matches "$path" "$INITLATE_ANNOTATION"
  say "[LATEINIT-DISABLED][namespaced] change annotation out of band with govc; it must not be reconciled/reverted"
  if ! g vm.change -vm "$path" -annotation "$INITLATE_OOB"; then
    record LATEINIT-DISABLED namespaced FAIL
  else
    sleep_poll
    check LATEINIT-DISABLED namespaced initlate_annotation_matches "$path" "$INITLATE_OOB"
  fi
  say "[DEFAULTED-DRIFT-CORRECTED][namespaced] change cpu_reservation to ${INITLATE_CPU_RESERVATION_OOB}MHz out of band with govc (absent from forProvider and not provider-computed, so the provider enforces 0); it must be corrected back to 0 on the next reconcile"
  if ! g vm.change -vm "$path" -cpu.reservation "$INITLATE_CPU_RESERVATION_OOB"; then
    record DEFAULTED-DRIFT-CORRECTED namespaced FAIL
    return 0
  fi
  sleep_poll
  check DEFAULTED-DRIFT-CORRECTED namespaced initlate_cpu_reservation_matches "$path" 0
}

# run_steady_state: AC-018 (no perpetual diff) and AC-021 (session count), sampled together.
# AC-021 needs a count between min_provider_sessions and PROVIDER_CONFIGS_IN_USE x provider pods
# in every sample: below the minimum the script is not seeing the provider's sessions (for
# example the lab user cannot list other sessions, or its userName form does not match), and a
# count of 0 must never pass as "within the limit".
run_steady_state() {
  local s i n pods limit min out sessions sessions_ok=true samples=0 all_clean diag_done=false
  local -A prev=() clean=()
  min=$(min_provider_sessions)
  say "== [AC-018] + [AC-021]: sample every $POLL_INTERVAL for at least $STEADY_MIN_INTERVALS intervals (at most $STEADY_MAX_INTERVALS)"
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    prev[$s]=$(count_updates "$VM_NAME") || prev[$s]=x
    clean[$s]=0
  done
  for ((i = 1; i <= STEADY_MAX_INTERVALS; i++)); do
    sleep_poll
    all_clean=true
    for s in "${ALIVE[@]}"; do
      vmref "$s"
      n=$(count_updates "$VM_NAME") || n=x
      if is_num "$n" && is_num "${prev[$s]}" && ((n == prev[$s])); then
        clean[$s]=$((clean[$s] + 1))
      else
        clean[$s]=0
        say "[AC-018][$s] interval $i: UpdatedExternalResource events ${prev[$s]} -> $n"
      fi
      prev[$s]=$n
      ((clean[$s] >= STEADY_MIN_INTERVALS)) || all_clean=false
    done
    pods=$(provider_pod_count) || pods=x
    out=$(provider_sessions) || out=x
    sessions=${out%%$'\n'*}
    if is_dry; then
      say "[AC-021] interval $i: a real run requires at least $min provider-user session(s) (one per ProviderConfig in use; fewer is a measurement failure: FAIL) and at most $PROVIDER_CONFIGS_IN_USE x provider pods"
    elif is_num "$pods" && is_num "$sessions"; then
      limit=$((PROVIDER_CONFIGS_IN_USE * pods))
      say "[AC-021] interval $i: $sessions provider-user session(s); allowed $min..$limit (at least 1 per ProviderConfig in use; at most $PROVIDER_CONFIGS_IN_USE ProviderConfigs x $pods provider pod(s))"
      if ((sessions < min)); then
        sessions_ok=false
        if [[ $diag_done == false ]]; then
          session_visibility_diag AC-021 "$sessions" "$min"
          diag_done=true
        fi
      elif ((pods < 1 || sessions > limit)); then
        sessions_ok=false
      fi
    else
      sessions_ok=false
      say "[AC-021] interval $i: cannot count sessions (pods=$pods sessions=$sessions)"
    fi
    if [[ $out == *$'\n'* ]]; then say "${out#*$'\n'}"; fi
    samples=$i
    if is_dry; then break; fi
    if ((samples >= STEADY_MIN_INTERVALS)) && [[ $all_clean == true ]]; then break; fi
  done
  for s in "${ALIVE[@]}"; do
    if ((clean[$s] >= STEADY_MIN_INTERVALS)); then record AC-018 "$s" PASS; else record AC-018 "$s" FAIL; fi
  done
  if [[ $sessions_ok == true ]] && ((samples >= STEADY_MIN_INTERVALS)); then
    record AC-021 package PASS
  else
    record AC-021 package FAIL
  fi
}

# rotate_confirm pauses for you to change the vCenter password by hand, reading the answer from
# /dev/tty (CONFIRM_TTY; never stdin, which may be redirected) so a non-interactive run cannot
# hang past ROTATION_CONFIRM_TIMEOUT. It returns 0 only for yes (or y). Any answer other than
# yes/y/no/n is asked again rather than read as "no": the answer decides which password every
# later govc call logs in with, so a "no" by accident after a real password change would run the
# rest of the run, and its cleanup, on a password vCenter rejects. The script never prints the
# reply, in case a password is typed there (the terminal still shows what is typed, as read
# runs without -s). validate() already checked CONFIRM_TTY is reachable before any cluster
# call; a failure to open it here (e.g. it went away mid-run) is treated the same as "no".
rotate_confirm() {
  local reply="" left deadline=$((SECONDS + ROTATION_CONFIRM_TIMEOUT))
  say "[AC-022] change the vCenter password for $VSPHERE_USER to the value in E2E_VSPHERE_ROTATED_PASSWORD now."
  while left=$((deadline - SECONDS)) && ((left > 0)); do
    read -r -t "$left" -p "e2e-lab: password changed in vCenter? [yes/no]: " reply || break
    case ${reply,,} in
      yes | y) return 0 ;;
      no | n)
        warn "[AC-022] answered no: the vCenter password is taken as unchanged, and the rest of this run keeps logging in with VSPHERE_PASSWORD"
        return 1
        ;;
      *) warn "[AC-022] please answer yes or no" ;;
    esac
  done <"$CONFIRM_TTY"
  warn "[AC-022] no yes/no answer on /dev/tty within ${ROTATION_CONFIRM_TIMEOUT}s: the vCenter password is taken as unchanged, and the rest of this run keeps logging in with VSPHERE_PASSWORD"
  return 1
}

# run_ac022_rotation_start: AC-022 (US-006). Records the provider's pre-rotation vCenter session
# keys, pauses for you to change the vCenter password, rotates the credentials Secret in every
# scope and forces a reconcile by touching an annotation on each live VM. vCenter keeps the
# pre-rotation session alive across a password change, so a reconcile that reaches Synced=True is
# NOT, by itself, evidence the provider built a new client: a reused (still-valid) old client
# would let the touch succeed too. The evidence that distinguishes them is a provider-user session
# whose key was not recorded before the rotation (observe_new_logins), and each touched VM's
# ProviderConfig has its own cached client, so every scope's PASS needs Synced=True and at least
# one new key per touched VM. Keys, not vCenter's loginTime, so the result does not depend on the
# vCenter and workstation clocks agreeing. Fewer visible provider sessions than
# min_provider_sessions before the pause is a measurement failure (FAIL, and no pause), because
# an invisible or incomplete key list would make old sessions look new.
#
# Password order. Every govc call is a fresh login (GOVC_PERSIST_SESSION=false), and vCenter
# rejects the original password as soon as you change it, so govc uses the original password up
# to your confirmation and the rotated one from then on. The keys are sampled on both sides:
#   1. Before the pause, with the original password. The provider cannot have logged in with the
#      rotated password yet (its cache keys each client by the credentials Secret, which still
#      holds the original password), and vCenter keeps these sessions alive across the change,
#      so they are the pre-rotation sessions to tell apart later. Once you change the password,
#      govc can no longer log in with the original one to take this sample.
#   2. Right after you confirm, with the rotated password, still before the Secret changes. It
#      shows vCenter accepts the rotated password, and it adds any session the provider opened
#      during the pause (a client rebuilt after an error logs in with the Secret's original
#      password, which works until you change it). From the change until the Secret rotation the
#      provider cannot log in at all, so a session first listed after this sample logged in with
#      the rotated password, which only the rotated Secret gives it.
# run_ac022_rotation_finish (called after the other checks, so its wait overlaps them) confirms
# the old client's specific pre-rotation sessions are gone, anchored on the workstation time the
# first new key was seen here rather than on the moment the Secret was rotated.
run_ac022_rotation_start() {
  local s min pre_json pre_count="" post_json post_count="" keys post_ok=false login_ok synced_ok
  local -a touched=()
  if [[ -z $ROTATED_PASSWORD ]]; then
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" "SKIPPED(E2E_VSPHERE_ROTATED_PASSWORD not set)"; done
    return 0
  fi
  if is_dry; then
    say "== [AC-022] password rotation: dry run prompts nothing and waits nothing"
    say "  (a real run first records the provider-user session keys with the original password and requires at least one visible session per ProviderConfig in use -- otherwise AC-022 FAILs as a measurement failure without pausing -- then pauses here on /dev/tty, up to ${ROTATION_CONFIRM_TIMEOUT}s, for you to change the vCenter password)"
    say "  (from your confirmation on, govc logs in with the rotated password only, since vCenter rejects the original one; it re-samples the keys before the Secret rotation to add any session opened during the pause; after the touch, each scope needs Synced=True AND one new provider-user session per rotated ProviderConfig, identified by a session key absent before the rotation, since vCenter keeps the old session alive across a password change; keys, not vCenter loginTime, so vCenter/workstation clock skew cannot affect the result, and the delayed-logout wait starts on the workstation clock when the first new key is seen)"
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" PLANNED; done
    return 0
  fi
  say "== [AC-022] password rotation (US-006)"
  min=$(min_provider_sessions)
  # Sample 1 (see above): before the pause, with the original password.
  if pre_json=$(provider_session_records) && pre_count=$(jq 'length' <<<"$pre_json") && is_num "$pre_count"; then
    say "[AC-022] provider-user sessions before the rotation pause: $pre_count (at least $min expected)"
  else
    pre_count=""
    say "[AC-022] cannot list the vCenter sessions (govc session.ls failed)"
  fi
  if [[ -z $pre_count ]] || ((pre_count < min)); then
    if [[ -n $pre_count ]]; then session_visibility_diag AC-022 "$pre_count" "$min"; fi
    say "[AC-022] not pausing for a password change: without the provider's sessions in view, a rebuilt client cannot be told from a reused one"
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" FAIL; done
    return 0
  fi
  PRE_ROTATION_SESSION_KEYS=$(jq -c '[.[].key]' <<<"$pre_json")
  if ! rotate_confirm; then
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" "SKIPPED(no confirmation)"; done
    return 0
  fi
  # vCenter now rejects the original password. Every later govc call -- this function's, the
  # other checks', run_ac022_rotation_finish's and cleanup's, on its failure and interrupt paths
  # too -- reads VSPHERE_PASSWORD when it runs, so from here on it logs in with the rotated one.
  VSPHERE_PASSWORD=$ROTATED_PASSWORD
  # Sample 2 (see above): with the rotated password, before the Secret changes.
  if post_json=$(provider_session_records) && post_count=$(jq 'length' <<<"$post_json") && is_num "$post_count" &&
    keys=$(jq -c --argjson pre "$PRE_ROTATION_SESSION_KEYS" '$pre + [.[].key] | unique' <<<"$post_json"); then
    PRE_ROTATION_SESSION_KEYS=$keys
    post_ok=true
  fi
  # You confirmed the change, so the Secrets are rotated even when sample 2 failed: the rest of
  # the run needs the provider to hold the current password.
  say "[AC-022] rotating the credentials Secret in $CP_NS and $NS"
  if ! create_secret "$CP_NS" || ! create_secret "$NS"; then
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" FAIL; done
    return 0
  fi
  if [[ $post_ok != true ]]; then
    say "[AC-022] govc cannot list the vCenter sessions with E2E_VSPHERE_ROTATED_PASSWORD right after you confirmed the password change (govc's error is above). If vCenter rejected the login, the lab user's password is not E2E_VSPHERE_ROTATED_PASSWORD: set it to exactly that value now, or the remaining vCenter checks and the cleanup's leak check fail as well"
    for s in "${ALIVE[@]}" package; do record AC-022 "$s" FAIL; done
    return 0
  fi
  ROTATE_STARTED=true
  say "[AC-022] pre-rotation provider sessions recorded: $(jq 'length' <<<"$PRE_ROTATION_SESSION_KEYS") key(s) ($pre_count before the pause, $post_count after the password change)"
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    if k annotate "${REF[@]}" "$TOUCH_ANNOTATION=$RUN_ID-$SECONDS" --overwrite; then
      touched+=("$s")
    else
      record AC-022 "$s" FAIL
    fi
  done
  ((${#touched[@]})) || return 0
  sleep_poll
  login_ok=false
  if observe_new_logins && ((NEW_LOGIN_COUNT >= ${#touched[@]})); then login_ok=true; fi
  say "[AC-022] provider-user sessions with a key absent before the rotation: $NEW_LOGIN_COUNT (need ${#touched[@]}: one per touched VM's ProviderConfig)"
  for s in "${touched[@]}"; do
    vmref "$s"
    synced_ok=false
    synced_now "$s" && synced_ok=true
    if [[ $synced_ok == true && $login_ok == true ]]; then
      record AC-022 "$s" PASS
    else
      record AC-022 "$s" FAIL
      say "[AC-022][$s] Synced=$synced_ok, enough new post-rotation logins observed=$login_ok"
      diag_vm "$s"
    fi
  done
}

# run_ac022_rotation_finish: waits out E2E_LOGOUT_DELAY (internal/clients/cache.go
# DefaultLogoutDelay) plus an E2E_LOGOUT_SLACK margin, measured on this workstation's
# clock from when run_ac022_rotation_start first saw a post-rotation session key
# (NEW_LOGIN_EPOCH) -- NOT from the moment the Secret was rotated. The provider's own retire timer
# for the old client starts when a touched MR's reconcile has logged a new client in with the
# rotated credentials (runCreate in internal/clients/cache.go), which is no later than that
# first sighting; DEFAULT_LOGOUT_DELAY equals the provider's own delay with zero slack, so
# anchoring on the Secret write instead races the provider's timer and fails a correct build.
# Both are durations on one clock each, so vCenter's clock plays no part. Then confirms every
# pre-rotation session key is gone: vCenter keeps a session alive across a password change, so a
# session count within the AC-021 bound does not, by itself, prove the specific rotated-out
# session actually ended. "Every key is gone" also holds when nothing is visible, so at least one
# provider-user session must still be seen: barring a session error, the rebuilt clients stay
# cached until cleanup deletes their ProviderConfigs, and the INITPROVIDER/LATEINIT VM still
# uses the namespaced one. Called last in phase_vm so the wait overlaps run_ac019 and the AC-006
# checks instead of blocking on its own.
run_ac022_rotation_finish() {
  local remaining pods now deadline still_json still_count="" sessions="" limit
  [[ $ROTATE_STARTED == true ]] || return 0
  say "== [AC-022] delayed logout: E2E_LOGOUT_DELAY=$LOGOUT_DELAY_RAW + E2E_LOGOUT_SLACK=$LOGOUT_SLACK_RAW since the first post-rotation session key was seen (workstation clock)"
  if ((NEW_LOGIN_EPOCH == 0)); then
    say "[AC-022] no post-rotation login was ever observed; cannot confirm the old client was replaced"
    record AC-022 package FAIL
    return 0
  fi
  deadline=$((NEW_LOGIN_EPOCH + LOGOUT_DELAY_SECONDS + LOGOUT_SLACK_SECONDS))
  now=$(date -u +%s)
  remaining=$((deadline - now))
  if ((remaining > 0)); then
    say "[AC-022] waiting ${remaining}s more for the rotated-out client's delayed logout"
    sleep "$remaining"
  fi
  pods=$(provider_pod_count) || pods=x
  if still_json=$(provider_session_records); then
    sessions=$(jq 'length' <<<"$still_json") || sessions=x
    still_count=$(jq --argjson pre "$PRE_ROTATION_SESSION_KEYS" '
      [.[].key] as $now | [$pre[] | select(. as $k | $now | any(.[]; . == $k))] | length' <<<"$still_json") ||
      still_count=x
  fi
  if is_num "$pods" && is_num "$sessions" && is_num "$still_count"; then
    limit=$((PROVIDER_CONFIGS_IN_USE * pods))
    say "[AC-022] provider-user sessions after the delayed logout: $sessions; allowed 1..$limit; pre-rotation keys still alive: $still_count"
    if ((sessions < 1)); then
      session_visibility_diag AC-022 "$sessions" 1
      record AC-022 package FAIL
    elif ((pods >= 1 && sessions <= limit && still_count == 0)); then
      record AC-022 package PASS
    else
      record AC-022 package FAIL
    fi
  else
    say "[AC-022] cannot count sessions (pods=$pods sessions=${sessions:-?} still_count=${still_count:-?})"
    record AC-022 package FAIL
  fi
  if is_num "$sessions" && ((sessions > 0)); then
    say "$(jq -r '.[] | "      \(.userName) via \(.userAgent) since \(.loginTime)"' <<<"$still_json")"
  fi
}

# run_ac019: AC-019 as reworded by A-035. An out-of-band change to an unrelated field must not
# power a VM back on. annotation is late-init-ignored but set by the example (Pioneer's profile),
# so it is first removed from the MR spec; otherwise Crossplane would, by design, revert the
# out-of-band edit, and vSphere provider 2.15.1 powers a VM on after any reconfigure.
run_ac019() {
  local s path state n
  local -A vmpath=() base=()
  say "== [AC-019] change annotation out of band on a VM powered off out of band"
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    say "[AC-019][$s] remove annotation from the MR spec (it becomes an unrelated field)"
    if ! k patch "${REF[@]}" --type=merge -p '{"spec":{"forProvider":{"annotation":null}}}' ||
      ! poll_until 300 10 "Synced=True at the new generation" synced_at_generation "$s"; then
      record AC-019 "$s" FAIL
      continue
    fi
    path=$(vm_path "$VM_NAME") || path=""
    if [[ -z $path ]]; then
      record AC-019 "$s" FAIL
      continue
    fi
    base[$s]=$(count_updates "$VM_NAME") || base[$s]=x
    say "[AC-019][$s] power off and change annotation with govc: $path"
    if g vm.power -off -force "$path" && g vm.change -vm "$path" -annotation "e2e-oob-$RUN_ID"; then
      vmpath[$s]=$path
    else
      record AC-019 "$s" FAIL
    fi
  done
  ((${#vmpath[@]})) || return 0
  sleep_poll
  for s in "${!vmpath[@]}"; do
    vmref "$s"
    state=$(power_state "${vmpath[$s]}") || state=unknown
    n=$(count_updates "$VM_NAME") || n=x
    say "[AC-019][$s] after the next reconcile: power state $state; UpdatedExternalResource events ${base[$s]} -> $n"
    if [[ $state == poweredOff ]]; then record AC-019 "$s" PASS; else record AC-019 "$s" FAIL; fi
  done
}

hw_updated() {
  local json info
  vmref "$1"
  json=$(k get "${REF[@]}" -o json) || return 1
  info=$(vm_info "$2") || return 1
  if is_dry; then return 0; fi
  jq -e 'any(.status.conditions[]?; .type == "Synced" and .status == "True")' <<<"$json" >/dev/null &&
    jq -e '.virtualMachines[0].config.hardware | .numCPU == 4 and .memoryMB == 6144' <<<"$info" >/dev/null
}

run_ac006_update() {
  local s path new_ext new_uuid
  local -A ext=() uuid=() vmpath=()
  say "== [AC-006] update numCpus 2->4 and memory 4096->6144 in place"
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    path=$(vm_path "$VM_NAME") || path=""
    ext[$s]=$(external_name "$s") || ext[$s]=""
    uuid[$s]=""
    if [[ -n $path ]]; then uuid[$s]=$(instance_uuid "$path") || uuid[$s]=""; fi
    vmref "$s"
    if [[ -n $path && -n ${uuid[$s]} ]] && k patch "${REF[@]}" --type=merge -p '{"spec":{"forProvider":{"numCpus":4,"memory":6144}}}'; then
      vmpath[$s]=$path
    else
      record AC-006-update "$s" FAIL
    fi
  done
  for s in "${!vmpath[@]}"; do
    if ! poll_until 1200 15 "govc reports 4 vCPUs / 6144 MB and the MR is Synced ($s)" hw_updated "$s" "${vmpath[$s]}"; then
      record AC-006-update "$s" FAIL
      continue
    fi
    new_ext=$(external_name "$s") || new_ext=""
    new_uuid=$(instance_uuid "${vmpath[$s]}") || new_uuid=""
    say "[AC-006][$s] external-name ${ext[$s]} -> $new_ext; instance UUID ${uuid[$s]} -> $new_uuid"
    if is_dry || [[ -n $new_ext && $new_ext == "${ext[$s]}" && $new_uuid == "${uuid[$s]}" ]]; then
      record AC-006-update "$s" PASS
    else
      record AC-006-update "$s" FAIL
    fi
  done
}

run_ac006_delete() {
  local s left
  say "== [AC-006] delete each MR / OT-021: the VM must be gone from vCenter"
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    k delete "${REF[@]}" --wait=false || true
  done
  for s in "${ALIVE[@]}"; do
    vmref "$s"
    if ! k wait "${REF[@]}" --for=delete --timeout=20m; then
      record AC-006-delete/OT-021 "$s" FAIL
      continue
    fi
    left=$(g find / -type m -name "$VM_NAME") || left="(govc failed)"
    if [[ -z $left ]]; then
      record AC-006-delete/OT-021 "$s" PASS
    else
      say "[AC-006][$s] still in vCenter: $left"
      record AC-006-delete/OT-021 "$s" FAIL
    fi
  done
}

phase_vm() {
  if [[ $EXISTING == true ]]; then
    say "== Crossplane: using the existing installation (no install, upgrade or uninstall)"
  else
    say "== Crossplane v$XP_VERSION (managed mode)"
    helm_install_crossplane "$XP_VERSION" "Crossplane v$XP_VERSION" || fatal "cannot install Crossplane v$XP_VERSION"
    k wait --for=condition=Established crd/providers.pkg.crossplane.io "crd/$DRC_RES" --timeout=2m ||
      fatal "Crossplane package CRDs are not established"
  fi
  say "[AC-021] record the provider user's existing vCenter sessions (excluded from the count)"
  if ! is_dry; then
    g session.ls -json | jq '[.sessionList[]?.key]' >"$WORKDIR/session-baseline.json" ||
      fatal "cannot record the vCenter session baseline"
  else
    g session.ls -json
  fi
  say "== Install $PACKAGE (DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME: --debug --poll=$POLL_INTERVAL)"
  apply_provider || fatal "cannot apply the Provider"
  if ! k wait "$PROVIDER_RES/$PROVIDER_NAME" --for=condition=Installed --timeout=10m ||
    ! k wait "$PROVIDER_RES/$PROVIDER_NAME" --for=condition=Healthy --timeout=10m; then
    diag_provider
    fatal "Provider $PROVIDER_NAME did not become Installed and Healthy within 10m"
  fi
  k wait --for=condition=Established "crd/$VM_RES_CLUSTER" "crd/$VM_RES_NS" "crd/$VMFS_RES_CLUSTER" \
    "crd/$PC_RES_CLUSTER" "crd/$PC_RES_NS" "crd/$CPC_RES" --timeout=5m || fatal "provider CRDs are not established"
  safestart_info
  setup_configs
  setup_vmfs_ref
  render_vms
  run_vm_setup_checks
  run_ac005
  run_initlate_checks
  run_steady_state
  run_ac022_rotation_start
  run_ac019
  run_ac006_update
  run_ac006_delete
  run_ac022_rotation_finish
}

labelled_vms_gone() {
  local a b=""
  a=$(get_names "$VM_RES_CLUSTER" -l "$RUN_LABEL_KEY=$RUN_ID") || return 1
  if [[ $NS_CREATED == true ]]; then
    b=$(get_names -n "$NS" "$VM_RES_NS" -l "$RUN_LABEL_KEY=$RUN_ID") || return 1
  fi
  if is_dry; then return 0; fi
  [[ -z $a && -z $b ]]
}

# print_manual_cleanup lists, in cleanup's order, what a human deletes by hand, and only what the
# state flags say this run created and has not removed: the VirtualMachine deletes while
# VMS_APPLIED (the provider must still run while they go), the VmfsDatastore while VMFS_APPLIED,
# the ProviderConfig, namespace and Secret deletes while NS_CREATED, then the Provider's removal
# and the Crossplane uninstall as print_removal_steps gives them. Those are the same steps as the
# recovery print_provider_removal_diag prints: wait for Crossplane to finish removing the provider
# before any helm uninstall. A dry run created nothing, so its heading says whose cleanup it is.
print_manual_cleanup() {
  local sel="$RUN_LABEL_KEY=$RUN_ID" kc n=0 head="Manual cleanup" types
  kc="kubectl --context $KUBE_CONTEXT"
  if is_dry; then head="Manual cleanup a real run that ends here needs"; fi
  if [[ $VMS_APPLIED == true ]]; then
    say "$head, on this dedicated lab cluster only, in this order (the provider must still run while VMs are deleted):"
    say "  $((n += 1)). $kc delete $VM_RES_CLUSTER -l $sel"
    say "  $((n += 1)). $kc -n $NS delete $VM_RES_NS -l $sel"
  else
    say "$head, on this dedicated lab cluster only, in this order:"
  fi
  if [[ $NS_CREATED == true ]]; then
    types="$PC_RES_CLUSTER,$CPC_RES"
    if [[ $VMFS_APPLIED == true ]]; then types="$VMFS_RES_CLUSTER,$types"; fi
    say "  $((n += 1)). $kc delete $types -l $sel"
    say "  $((n += 1)). $kc -n $NS delete $PC_RES_NS -l $sel"
    say "  $((n += 1)). $kc delete namespace -l $sel; $kc -n $CP_NS delete secret -l $sel"
  fi
  print_removal_steps "$((n + 1))"
}

# collect_left fills LEFT_IN_PLACE with what this run created and may not have removed, in the
# order print_manual_cleanup removes it, from the state flags alone (never from the phase or the
# mode): each flag is set where the object is created and cleared once it is confirmed gone.
collect_left() {
  local sel="$RUN_LABEL_KEY=$RUN_ID" rest="its ProviderRevision or its Deployment may remain"
  LEFT_IN_PLACE=()
  if [[ $VMS_APPLIED == true ]]; then
    LEFT_IN_PLACE+=("any VirtualMachine MR labelled $sel still present, with its vCenter VM")
  fi
  if [[ $VMFS_APPLIED == true ]]; then
    LEFT_IN_PLACE+=("the Observe-only VmfsDatastore $VMFS_MR_NAME (it does not change the vCenter datastore)")
  fi
  if [[ $NS_CREATED == true ]]; then
    LEFT_IN_PLACE+=("the ProviderConfigs, ClusterProviderConfig, credentials Secrets and namespace $NS labelled $sel")
  fi
  if [[ $PROVIDER_APPLIED == true ]]; then
    LEFT_IN_PLACE+=("Provider $PROVIDER_NAME and DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME")
  elif [[ $PROVIDER_REMOVAL_OK != true ]]; then
    if [[ $EXISTING != true ]]; then rest="its ProviderRevision, its Deployment or the Lock's finalizer may remain"; fi
    LEFT_IN_PLACE+=("Crossplane's unfinished removal of $PROVIDER_NAME: this run deleted its Provider and DeploymentRuntimeConfig, but $rest")
  fi
  if [[ $CP_INSTALLED_BY_RUN == true ]]; then
    LEFT_IN_PLACE+=("$CP_INSTALLED_NAME, which this run installed (Helm release $CP_RELEASE in $CP_NS)")
  fi
}

# crossplane_remainder prints what uninstalling the Crossplane this run installed leaves on the
# cluster, or nothing when this run installed none (CP_INSTALLED_NAME unset: existing mode, or a
# run that stopped before any helm install). None of it carries this run's label: helm uninstall
# removes only what the chart rendered. Checked against the Crossplane source at v1.20.13, v2.2.0
# and v2.4.2:
#   - Crossplane's init container applies its *.crossplane.io CRDs and its webhook
#     configurations itself (cmd/crossplane/core/init.go:86-92 at v1.20.13, :103-110 at v2.x).
#   - The ValidatingWebhookConfigurations: crossplane-no-usages (cluster/webhookconfigurations
#     /usage.yaml:8), and from 1.x only crossplane as well (manifests.yaml:5, renamed by
#     internal/initializer/webhook_configurations.go:119-122 at v1.20.13). A v2 init container
#     deletes that one (init.go:86-91 at v2.x; webhook_configurations.go:191-194 deletes it once
#     its two webhooks are gone): LEGACY_WEBHOOK_LEFT.
#   - No chart template renders a Namespace. helm --create-namespace creates crossplane-system
#     outside the release (helm v3.19.0 pkg/action/install.go:366-389), so helm uninstall leaves
#     it, as docs.crossplane.io guides/uninstall-crossplane says.
#   - What does go: everything the chart rendered, its TLS Secrets included (templates
#     /secret.yaml:2-4), and the provider's ServiceAccount, Deployment, Service, Secrets and
#     ClusterRoles, which its ProviderRevision owns, so they are garbage-collected once
#     remove_provider's wait has seen that revision go.
# The CRDs are what makes preflight refuse the next managed run on this context.
crossplane_remainder() {
  local vwc="ValidatingWebhookConfiguration crossplane-no-usages"
  [[ -n $CP_INSTALLED_NAME ]] || return 0
  if [[ $LEGACY_WEBHOOK_LEFT == true ]]; then vwc="ValidatingWebhookConfigurations crossplane and crossplane-no-usages"; fi
  printf '%s' "Uninstalling Crossplane leaves what its init container and helm --create-namespace made, which carries no run label: the *.crossplane.io CRDs, the $vwc, and namespace $CP_NS. A later managed run on context $KUBE_CONTEXT refuses to start while those CRDs remain: remove all of it as RELEASING.md section 8 shows, or use a fresh cluster"
}

# print_left_in_place ends a --skip-cleanup run: it names what this run left in place
# (collect_left) and lists the commands that remove exactly that (print_manual_cleanup), or says
# that nothing labelled with this run's label is left. Each flag is set just before its object is
# created, so the list says "whichever of these it created". When the version gate's teardown
# finished (GATE_TEARDOWN), it also says so, since that teardown runs even with --skip-cleanup.
# Either way, a run that installed Crossplane also names what uninstalling it leaves
# (crossplane_remainder), which no label covers. A dry run created nothing, so it says what a real
# run that ends here would leave.
print_left_in_place() {
  local what gate="" rest
  collect_left
  if [[ $GATE_TEARDOWN == finished ]]; then
    if is_dry; then
      gate="the version gate removes its own Provider and DeploymentRuntimeConfig and uninstalls Crossplane ${LEGACY_VERSION:-?} even with --skip-cleanup"
    else
      gate="the version gate removed its own Provider and DeploymentRuntimeConfig and uninstalled Crossplane ${LEGACY_VERSION:-?}, as it does even with --skip-cleanup"
    fi
  fi
  rest=$(crossplane_remainder)
  if ((${#LEFT_IN_PLACE[@]} == 0)); then
    if is_dry; then
      say "--skip-cleanup (dry run, nothing was created): a real run that ends here leaves nothing labelled $RUN_LABEL_KEY=$RUN_ID in place${gate:+: $gate}${rest:+. $rest}"
    else
      say "--skip-cleanup: nothing labelled $RUN_LABEL_KEY=$RUN_ID is left in place${gate:+: $gate}${rest:+. $rest}"
    fi
    return 0
  fi
  printf -v what '%s; ' "${LEFT_IN_PLACE[@]}"
  what=${what%; }
  if is_dry; then
    say "--skip-cleanup (dry run, nothing was created): a real run that ends here leaves in place whichever of these it created: $what${gate:+. ${gate^}}${rest:+. $rest}"
  else
    warn "--skip-cleanup: this run leaves in place whichever of these it created: $what${gate:+. ${gate^}}${rest:+. $rest}"
  fi
  print_manual_cleanup
}

# cleanup deletes only objects labelled with this run's label (or by exact name for the AC-007
# copy), and uninstalls Crossplane only when this run installed it. It is idempotent and keeps
# the provider running until every VM MR is gone.
cleanup() {
  local sel="$RUN_LABEL_KEY=$RUN_ID" name path configs_left=false
  [[ $CLEANUP_STARTED == false ]] || return 0
  CLEANUP_STARTED=true
  say ""
  say "== Cleanup: objects labelled $sel"
  if [[ $PROVIDER_APPLIED == true ]]; then
    if [[ $NS_CREATED == true ]]; then delete_ac007_object; fi
    del "$VM_RES_CLUSTER" -l "$sel" --ignore-not-found --wait=false || true
    if [[ $NS_CREATED == true ]]; then del -n "$NS" "$VM_RES_NS" -l "$sel" --ignore-not-found --wait=false || true; fi
    if ! poll_until 1200 15 "no VirtualMachine labelled $sel remains" labelled_vms_gone; then
      CLEANUP_OK=false
      warn "VirtualMachine MRs are still present; the provider and Crossplane are left running so they can finish"
      print_manual_cleanup
      return 1
    fi
    VMS_APPLIED=false
  fi
  if phase_has_vm && [[ -n ${VM_NAME_CLUSTER:-} && $CLUSTER_TOUCHED == true ]] && ! is_dry; then
    # A govc failure (for example a login vCenter rejects) shows nothing about leaks, so it is
    # reported as unverified cleanup, never read as "no VM left".
    for name in "$VM_NAME_CLUSTER" "$VM_NAME_NS" "$INITLATE_NAME"; do
      if ! path=$(vm_path "$name"); then
        CLEANUP_OK=false
        warn "cannot check vCenter for a leaked VM $name: govc failed (its error is above); check by hand"
      elif [[ -n $path ]]; then
        CLEANUP_OK=false
        warn "LEAKED VM in vCenter: $path (delete it by hand)"
      fi
    done
  fi
  if del "$VMFS_RES_CLUSTER" -l "$sel" --ignore-not-found --timeout=2m; then VMFS_APPLIED=false; fi
  del "$PC_RES_CLUSTER" -l "$sel" --ignore-not-found --timeout=2m || configs_left=true
  del "$CPC_RES" -l "$sel" --ignore-not-found --timeout=2m || configs_left=true
  if [[ $NS_CREATED == true ]]; then
    del -n "$NS" "$PC_RES_NS" -l "$sel" --ignore-not-found --timeout=2m || configs_left=true
    del -n "$NS" secret -l "$sel" --ignore-not-found || configs_left=true
  fi
  del -n "$CP_NS" secret -l "$sel" --ignore-not-found || configs_left=true
  if [[ $NS_CREATED == true ]]; then del namespace -l "$sel" --ignore-not-found --timeout=5m || configs_left=true; fi
  if [[ $configs_left == false ]]; then NS_CREATED=false; fi
  if [[ $PROVIDER_APPLIED == true ]]; then remove_provider || true; fi
  if [[ $CP_INSTALLED_BY_RUN == true ]]; then
    uninstall_crossplane || true
  fi
}

print_report() {
  local r line
  say ""
  say "== e2e-lab report: run $RUN_ID, context $KUBE_CONTEXT, Crossplane $(crossplane_label report), package $PACKAGE"
  printf -v line '%-22s | %-34s | %-34s | %-34s' criterion cluster namespaced package
  say "$line"
  say "$(printf '%.0s-' {1..132})"
  for r in "${ROWS[@]}"; do
    printf -v line '%-22s | %-34s | %-34s | %-34s' "$r" "${RESULT[$r|cluster]}" "${RESULT[$r|namespaced]}" "${RESULT[$r|package]}"
    say "$line"
  done
  if [[ -n $ABORT_REASON ]]; then say "ABORTED: $ABORT_REASON"; fi
  if [[ $CLEANUP_OK != true ]]; then
    # Under --skip-cleanup the end-of-run cleanup never ran, so what is incomplete is the version
    # gate's own teardown, the only other step that deletes what the run labelled or uninstalls
    # the Crossplane it installed.
    if [[ $SKIP_CLEANUP == true && $CLEANUP_STARTED != true && $GATE_TEARDOWN == started ]]; then
      say "CLEANUP INCOMPLETE: the version gate could not finish removing its own Provider and Crossplane ${LEGACY_VERSION:-?} (it does so even with --skip-cleanup, which skipped only the end-of-run cleanup); see the warnings above"
    else
      say "CLEANUP INCOMPLETE: see the warnings above"
    fi
  fi
  if ! is_dry && [[ $REQUIRE_AC022 == true ]] && ! ac022_passed; then
    say "REQUIRED AC-022 NOT PASSED: E2E_REQUIRE_AC022=true and the AC-022 row is not PASS in every column; counted as a failure"
  fi
  say "$(result_line)"
}

on_exit() {
  local rc=$? rest
  set +e
  trap - EXIT INT TERM
  if ((rc != 0)) && [[ -z $ABORT_REASON && $STARTED == true ]]; then ABORT_REASON="unexpected error (exit $rc)"; fi
  if [[ $CLUSTER_TOUCHED == true ]]; then
    if [[ $SKIP_CLEANUP == true ]]; then
      print_left_in_place
    else
      # cleanup deletes only what this run labelled and helm-uninstalls its Crossplane, which
      # leaves what no label covers; under --skip-cleanup print_left_in_place says the same.
      cleanup
      rest=$(crossplane_remainder)
      if [[ -n $rest ]]; then say "$rest"; fi
    fi
  fi
  if [[ -n $WORKDIR && -d $WORKDIR ]]; then rm -rf "$WORKDIR"; fi
  if [[ $STARTED == true ]]; then print_report; fi
  if ((rc == 0)) && ! is_dry; then
    if any_fail || [[ $CLEANUP_OK != true ]]; then rc=1; fi
  fi
  exit "$rc"
}

main() {
  local r
  exec 3>&1
  parse_args "$@"
  resolve_settings
  validate
  # Keep both passwords out of the environment of every child except govc (NFR-103).
  export -n VSPHERE_PASSWORD 2>/dev/null || true
  export -n E2E_VSPHERE_ROTATED_PASSWORD 2>/dev/null || true
  check_tools
  resolve_context
  RUN_ID="$(date -u +%m%d%H%M%S)$(printf '%04x' "$RANDOM")"
  VM_NAME_CLUSTER="e2e-$RUN_ID-cluster"
  VM_NAME_NS="e2e-$RUN_ID-ns"
  AC007_NAME="e2e-$RUN_ID-ac007"
  MISSING_PC="e2e-missing-$RUN_ID"
  VMFS_MR_NAME="e2e-$RUN_ID-vmfs"
  SECRET_NAME="e2e-lab-creds-$RUN_ID"
  INITLATE_NAME="e2e-$RUN_ID-initlate"
  INITLATE_ANNOTATION="e2e-init-$RUN_ID"
  INITLATE_OOB="e2e-lateinit-oob-$RUN_ID"
  print_plan
  init_results
  trap on_exit EXIT
  trap 'ABORT_REASON="interrupted"; exit 130' INT TERM
  STARTED=true
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/e2e-lab.XXXXXX")
  preflight
  if phase_has_gate; then
    if [[ $EXISTING == true ]]; then
      record AC-008 package "SKIPPED(existing-crossplane)"
    else
      phase_version_gate
    fi
  else
    record AC-008 package "SKIPPED(phase=$PHASE)"
  fi
  if phase_has_vm; then
    phase_vm
  else
    for r in AC-005 AC-006-update AC-006-delete/OT-021 AC-016 AC-018 AC-019 AC-022; do
      record "$r" cluster "SKIPPED(phase=$PHASE)"
      record "$r" namespaced "SKIPPED(phase=$PHASE)"
    done
    record AC-007 namespaced "SKIPPED(phase=$PHASE)"
    record AC-021 package "SKIPPED(phase=$PHASE)"
    record AC-022 package "SKIPPED(phase=$PHASE)"
    record INITPROVIDER namespaced "SKIPPED(phase=$PHASE)"
    record LATEINIT-DISABLED namespaced "SKIPPED(phase=$PHASE)"
    record DEFAULTED-DRIFT-CORRECTED namespaced "SKIPPED(phase=$PHASE)"
    record "SafeStart(info)" package "SKIPPED(phase=$PHASE)"
  fi
}

# Run only when executed (bash cluster/test/e2e-lab.sh, as make e2e-lab does). Sourcing the
# file, as cluster/test/e2e-lab-selftest.sh does, defines the functions and settings and does
# not run main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
