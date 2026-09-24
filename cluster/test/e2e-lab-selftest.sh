#!/usr/bin/env bash
#
# Offline self-test of the vCenter session and password-rotation logic of cluster/test/e2e-lab.sh:
# AC-021 (session count) and AC-022 (password rotation), FR-111, US-006; and of its tool check
# (check_tools), which must stop a real run and a dry run before any command when jq or govc is
# older than its minimum; of its managed-mode preflight, which must refuse when Crossplane is
# already present; and of its provider teardown: remove_provider's wait for Crossplane to finish
# removing the Provider, and how cleanup and the version gate act on that wait's outcome. It needs
# no network, no cluster, no vCenter and no real govc, kubectl or helm, and it finishes in well
# under a minute. CI runs it.
#
#   bash cluster/test/e2e-lab-selftest.sh [path/to/e2e-lab.sh]
#
# The script is sourced in a subshell; its source guard keeps main from running, and every
# function under test is the script's own. In-process stubs replace only the kubectl and helm
# wrappers (k, h), poll_until (one attempt, no sleep), sleep_poll, and rotate_confirm, which plays
# the human at the AC-022 prompt: it changes the fake vCenter's password, or not, and answers.
# The (r) cases run the real rotate_confirm against a file instead of /dev/tty. The (t) cases run
# the script's own validate() with CONFIRM_TTY naming a path that cannot be opened, which is what
# a run with no terminal attached sees. The (v) cases run the script's own check_tools with PATH
# naming only a directory of stub kubectl, helm, jq, govc and go binaries; the stub govc and go
# replay the recorded output of real govc binaries (GOVC_FIXTURES). The (p) cases put the
# script's own k and h back and run its preflight against stub kubectl and helm binaries that
# serve fixtures (pf_stubs). The (q) and (u) cases put the script's own k, h and poll_until back
# and run, against the stub kubectl and helm binaries of rp_stubs, its remove_provider and
# uninstall_crossplane (q), and their callers (u): cleanup, through the script's own on_exit as
# main arms it, and phase_version_gate; plus the plan print_plan prints and the first line of the
# report print_report prints, for each phase and mode, and what on_exit prints under --skip-cleanup;
# and that every manual list (the manual cleanup, the recovery, uninstall_crossplane's warning and
# RELEASING.md section 8's between-runs commands) gives the teardown's steps in its order. The (u8)
# to (u13) cases sweep what the run says about --skip-cleanup over the phase x mode x
# --skip-cleanup x outcome matrix: the dry-run plan and end of run of every cell through the
# script's own main (u8); the end of run and exit code after the version gate's removal wait runs
# out (u9), after the vm phase stops right after its helm install (u10), after a clean gate-only
# run (u11) and after a failed gate Provider delete (u12), through the script's own phase code and
# on_exit; and --help against what on_exit prints and returns for each end state (u13). Across
# them, the end of every run that installed Crossplane names what uninstalling it leaves, which no
# label covers (its CRDs, its webhook configurations and namespace crossplane-system), and no line
# says nothing is left without it.
#
# govc is not replaced in-process: the script's own g wrapper runs a fake govc, first on PATH,
# that models a vCenter. It checks the password of every login against the vCenter's current one
# (the script sets GOVC_PERSIST_SESSION=false, so every govc call is a fresh login), fails like
# govc does on a mismatch, and logs each login. It serves queued synthetic `govc session.ls -json`
# documents (the mo.SessionManager shape govc prints: currentSession plus sessionList of {key,
# userName, loginTime, ipAddress, userAgent}) and a small VM inventory, and it reports every
# datastore as VMFS. Stub kubectl, helm, docker and crossplane binaries record any call, and
# KUBECONFIG points nowhere, so nothing can reach a cluster, a vCenter or a registry.
#
# The output is deterministic: it prints no value read from the clock, no password and no temp
# path, and the only session keys and times it prints are the fixed ones of its own fixtures.
# Exit 0 when every case passes, 1 otherwise. The optional argument runs the same cases against
# another copy of e2e-lab.sh, for example an older revision, to show which cases it fails.
#
# Requirements: bash 4 or newer, jq 1.6 or newer, and on PATH bash (the fake govc's interpreter)
# and the utilities in SELFTEST_TOOLS below, in their GNU, BSD/macOS or BusyBox versions. Every
# option used is POSIX, or common to all three (mktemp -d, date -u +%s); none is GNU-only. The
# stubs start with #!/bin/sh and the fake govc with #!/usr/bin/env bash, so /bin/sh and
# /usr/bin/env must exist too. sleep is needed because the (q) and (u) cases drive the script's
# own poll_until for real, sleep(1) included, rather than the one-shot stub every other case uses.
# The check below runs first and names every other missing requirement, so none of those surfaces
# as a failed case.
#
# SC2317: the case functions and stubs are called indirectly (run_case "${@:2}", or by the
# sourced script). SC2016: single-quoted eval and jq programs expand later, on purpose.
# shellcheck disable=SC2317,SC2016
set -u
# The self-test's own requirement check, in plain POSIX sh so that bash 3 (the macOS default) or
# a non-bash shell still reaches it and gets every missing requirement it checks named at once. The
# functions under test need bash 4 (associative arrays, ${var,,}) and jq 1.6 (--rawfile), as
# e2e-lab.sh's MIN_BASH and MIN_JQ say; its MIN_GOVC does not apply here, as no real govc runs.
SELFTEST_TOOLS="bash jq awk cat chmod cut date dirname grep head ls mkdir mktemp paste rm sed sleep sort tail tr"
missing=""
if [ -z "${BASH_VERSION-}" ] || ((BASH_VERSINFO[0] < 4)); then
  missing="$missing
  bash 4 or newer to run the self-test (this is ${BASH_VERSION:-not bash}); on macOS, install a newer bash and run it as: /path/to/that/bash $0"
fi
for t in $SELFTEST_TOOLS; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing
  $t"
done
if command -v jq >/dev/null 2>&1 && ! jq -n --rawfile f /dev/null '$f' >/dev/null 2>&1; then
  missing="$missing
  jq 1.6 or newer, for --rawfile (this is $(jq --version 2>&1))"
fi
if [ -n "$missing" ]; then
  printf 'e2e-lab-selftest: missing requirement(s):%s\n' "$missing" >&2
  printf 'e2e-lab-selftest: it needs bash 4+ and jq 1.6+, and on PATH: %s\n' "$SELFTEST_TOOLS" >&2
  exit 1
fi

cd "$(dirname "$0")/../.." || exit 1
SCRIPT=${1:-cluster/test/e2e-lab.sh}
if [[ ! -f $SCRIPT ]]; then
  echo "e2e-lab-selftest: no such file: $SCRIPT" >&2
  exit 1
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
for b in kubectl helm docker crossplane; do
  # $0 and $* belong to the stub, not to this script.
  printf '#!/bin/sh\necho "$0 $*" >>"%s/CALLED"\nexit 99\n' "$T" >"$T/bin/$b"
  chmod +x "$T/bin/$b"
done

# The fake govc. E2E_SELFTEST_VC is the per-case vCenter state directory: password (the current
# one), auth.log (one line per login: ok|rejected, the password used, the command), q/ (queued
# session.ls documents; "FAIL" makes that call fail like an unreachable vCenter) and vms/NAME/
# (power, cpu, mem, annotation, res). Paths it prints are /lab/vm/e2e/NAME.
cat >"$T/bin/govc" <<'EOF'
#!/usr/bin/env bash
set -u
vc=${E2E_SELFTEST_VC:?E2E_SELFTEST_VC is not set}
if [[ ${GOVC_PASSWORD-} != "$(<"$vc/password")" ]]; then
  printf 'rejected\t%s\t%s\n' "${GOVC_PASSWORD-}" "$*" >>"$vc/auth.log"
  echo "govc: ServerFaultCode: Cannot complete login due to an incorrect user name or password." >&2
  exit 1
fi
printf 'ok\t%s\t%s\n' "$GOVC_PASSWORD" "$*" >>"$vc/auth.log"
last=${!#}
d=$vc/vms/${last##*/}
case $1 in
  about) echo "Name: fake vCenter" ;;
  object.collect) echo VMFS ;;
  session.ls)
    n=$(<"$vc/q/next")
    count=$(<"$vc/q/count")
    if ((n > count)); then n=$count; fi
    echo "$((n + 1))" >"$vc/q/next"
    if [[ $(<"$vc/q/$n.json") == FAIL ]]; then
      echo 'govc: Post "https://vc.example.test/sdk": context deadline exceeded' >&2
      exit 1
    fi
    cat "$vc/q/$n.json"
    ;;
  find) if [[ -d $d ]]; then echo "/lab/vm/e2e/${last##*/}"; fi ;;
  vm.info)
    [[ -d $d ]] || { echo '{"virtualMachines":null}'; exit 0; }
    jq -n --arg p "$(<"$d/power")" --arg u "uuid-${last##*/}" --arg a "$(<"$d/annotation")" \
      --argjson c "$(<"$d/cpu")" --argjson m "$(<"$d/mem")" \
      '{virtualMachines: [{runtime: {powerState: $p}, config: {instanceUuid: $u, annotation: $a,
        hardware: {numCPU: $c, memoryMB: $m}, cpuAllocation: {reservation: 0}}}]}'
    ;;
  vm.power) [[ $2 != -off ]] || echo poweredOff >"$d/power" ;;
  vm.change)
    d=$vc/vms/${3##*/}
    [[ $4 != -annotation ]] || printf '%s' "$5" >"$d/annotation"
    ;;
  *)
    echo "fake govc: unexpected command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$T/bin/govc"
# None of the caller's govc settings or vCenter credentials reach the script or its children.
unset "${!GOVC_@}" E2E_DATACENTER VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER E2E_VSPHERE_ROTATED_PASSWORD
export PATH="$T/bin:$PATH" KUBECONFIG=/nonexistent

# sessions_json CURRENT_USER ENTRY...: a `govc session.ls -json` document. govc's own current
# session (key govc-self, user agent govc/0.54.0, userName CURRENT_USER) is listed first; each
# ENTRY is key|userName|userAgent|loginTime.
sessions_json() {
  local cur=$1
  shift
  printf '%s\n' "$@" | jq -c -R -s --arg cur "$cur" '
    {key: "govc-self", userName: $cur, userAgent: "govc/0.54.0",
     loginTime: "2026-09-25T09:00:00Z", ipAddress: "10.0.0.5"} as $self
    | [split("\n")[] | select(length > 0) | split("|")
       | {key: .[0], userName: .[1], userAgent: .[2], loginTime: .[3], ipAddress: "10.0.0.21"}] as $l
    | {currentSession: $self, sessionList: ([$self] + $l)}'
}

(
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=e2e-lab.sh
  source "$SCRIPT"
  # Each case runs in its own subshell with the script's own `set -e` re-enabled. The script's
  # pipefail stays on, so text is captured first and then matched, never piped into a reader
  # that can exit before its input ends (grep -q, head): the writer would die of SIGPIPE, and the
  # pipeline would fail at random, turning a passing check into a NOT OK or aborting its case.
  set +e
  if [[ $(command -v govc) != "$T/bin/govc" ]]; then
    echo "e2e-lab-selftest: govc does not resolve to the fake vCenter; refusing to run" >&2
    exit 1
  fi

  readonly AGENT="terraform-provider-vsphere/2.15.1 govmomi/0.52.0"
  readonly U_NB='LAB\svc-pioneer' # how vCenter reports the provider user (NetBIOS form)
  readonly U_ADMIN='VSPHERE.LOCAL\Administrator'
  readonly P_ORIGINAL=dummy-original P_ROTATED=dummy-rotated
  FAILS=0 PODS=1 C="" VC="" HUMAN_SETS=rotated HUMAN_ANSWER=yes

  # The script's own rotate_confirm, kept for the (r) cases before the stub below replaces it.
  eval "real_rotate_confirm() $(declare -f rotate_confirm | tail -n +2)"
  # The script's own kubectl and helm wrappers, kept for the (p) cases before the stubs below
  # replace them.
  eval "script_k() $(declare -f k | tail -n +2)"
  eval "script_h() $(declare -f h | tail -n +2)"
  # The script's own poll_until (real retrying, real sleep), kept for the (q) cases before the
  # one-shot, no-sleep stub below replaces it for every other case.
  eval "script_poll_until() $(declare -f poll_until | tail -n +2)"
  # The script's own sleep_poll, kept for the (u8) cases, which run the script's own main.
  eval "script_sleep_poll() $(declare -f sleep_poll | tail -n +2)"
  # The script's own CONFIRM_TTY default, before any case points it elsewhere.
  readonly DEFAULT_CONFIRM_TTY=${CONFIRM_TTY-}
  # The (v) cases' stubs run with PATH naming only their own directory, so they call cat by path.
  CAT=$(command -v cat)
  # The self-test's PATH (the call-recording stubs and the fake govc first), which the (p) cases
  # put their fixture stubs in front of.
  readonly SELFTEST_PATH=$PATH

  # --- stubs for the script's kubectl/helm wrappers and its slow or interactive steps ---
  # k_vm prints the VirtualMachine name in a kubectl argument list (RESOURCE/NAME or RESOURCE NAME).
  k_vm() {
    local a before_a=""
    for a in "$@"; do
      case $a in
        "$VM_RES_CLUSTER"/* | "$VM_RES_NS"/*)
          printf '%s' "${a##*/}"
          return 0
          ;;
      esac
      if [[ ($before_a == "$VM_RES_CLUSTER" || $before_a == "$VM_RES_NS") && $a != -* ]]; then
        printf '%s' "$a"
        return 0
      fi
      before_a=$a
    done
  }
  # k plays the cluster: MRs are Ready and Synced, the AC-006 numCpus/memory patch reaches the
  # fake VM, deleting an MR deletes its VM (by name, or by label for every VM of that resource),
  # and the credentials Secret the script pipes through `create secret | label | apply` lands in
  # $C/secrets.
  k() {
    local vm res a
    case " $* " in
      *" create secret generic "*) printf 'namespace=%s credentials=%s\n' "$2" "$(cat)" ;;
      *" label --local "*) cat ;;
      *" apply -f - "*) cat >>"$C/secrets" ;;
      *" annotate "*) return 0 ;;
      *" get events "*) printf '{"items":[]}\n' ;;
      *" get pods "*) jq -cn --argjson n "$PODS" '{items: [range($n) | {}]}' ;;
      # remove_provider's deployment_gone check (no Deployment left selecting the provider), so
      # cleanup's Provider teardown (cases i/j/k) sees it as already gone.
      *" get deployments "*) printf '{"items":[]}\n' ;;
      *"jsonpath={.metadata.annotations"*) printf 'ext-%s' "$(k_vm "$@")" ;;
      *" patch "*numCpus*)
        vm=$(k_vm "$@")
        printf 4 >"$VC/vms/$vm/cpu"
        printf 6144 >"$VC/vms/$vm/mem"
        ;;
      *" delete "*)
        vm=$(k_vm "$@")
        if [[ -n $vm ]]; then
          rm -rf "${VC:?}/vms/$vm"
          return 0
        fi
        for a in "$@"; do
          for res in "$VM_RES_CLUSTER" "$VM_RES_NS"; do
            if [[ $a == "$res" ]]; then
              for vm in "$VC"/vms/*/res; do
                if [[ -f $vm && $(<"$vm") == "$res" ]]; then rm -rf "${vm%/res}"; fi
              done
            fi
          done
        done
        return 0
        ;;
      *" -o json "*) printf '{"metadata":{"generation":2},"status":{"conditions":[{"type":"Ready","status":"True"},{"type":"Synced","status":"True"}]}}\n' ;;
      *) return 0 ;;
    esac
  }
  h() {
    printf 'unexpected helm call: %s\n' "$*" >&2
    return 1
  }
  # One attempt and no sleep: a regression must fail its case, not stall it for the timeout.
  poll_until() {
    shift 3
    "$@"
  }
  sleep_poll() { :; }
  # The human at the AC-022 prompt: sets the vCenter password to the rotated one (HUMAN_SETS),
  # then answers (HUMAN_ANSWER). A yes adds a "confirmed" marker to the login log, so auth_scan
  # can tell the logins before the confirmation from those after it.
  rotate_confirm() {
    : >"$C/prompted"
    if [[ $HUMAN_SETS == rotated ]]; then printf '%s' "$P_ROTATED" >"$VC/password"; fi
    [[ $HUMAN_ANSWER == yes ]] || return 1
    printf 'confirmed\n' >>"$VC/auth.log"
  }

  # --- test helpers ---
  setup() {
    C=$(mktemp -d "$T/case.XXXXXX")
    VC=$C/vc
    mkdir -p "$C/wd" "$VC/q" "$VC/vms"
    export E2E_SELFTEST_VC=$VC
    printf '%s' "$P_ORIGINAL" >"$VC/password"
    : >"$VC/auth.log"
    WORKDIR=$C/wd
    printf '["pre-install-1"]\n' >"$WORKDIR/session-baseline.json"
    DRY_RUN=false KUBE_CONTEXT=lab-k3s RUN_ID=t0 NS=vsphere-e2e POLL_INTERVAL=1m PHASE=all
    EXISTING=false SKIP_CLEANUP=false XP_VERSION=2.2.0 LEGACY_VERSION=1.20.13
    PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
    VM_NAME_CLUSTER=e2e-t0-cluster VM_NAME_NS=e2e-t0-ns INITLATE_NAME=e2e-t0-initlate
    AC007_NAME=e2e-t0-ac007 SECRET_NAME=e2e-lab-creds-t0
    VSPHERE_USER=svc-pioneer@lab.local VSPHERE_SERVER=vc.example.test SESSION_USER_MATCH=account
    ALLOW_UNVERIFIED_SSL=true GOVC_INSECURE_VALUE=1
    VSPHERE_PASSWORD=$P_ORIGINAL ROTATED_PASSWORD=$P_ROTATED HUMAN_SETS=rotated HUMAN_ANSWER=yes
    ALIVE=(cluster namespaced) PODS=1 FAILS=0
    NEW_LOGIN_EPOCH=0 NEW_LOGIN_COUNT=0 ROTATE_STARTED=false PRE_ROTATION_SESSION_KEYS='[]'
    # Never wait out the real 70m + 10m delayed-logout window in a test.
    LOGOUT_DELAY_SECONDS=0 LOGOUT_SLACK_SECONDS=0
    # Never wait out a real poll interval for remove_provider's removal wait in a test either; the
    # (q) and (u) cases override both explicitly.
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=600 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0 PROVIDER_REMOVAL_OK=true
    STARTED=false CLUSTER_TOUCHED=false PROVIDER_APPLIED=false NS_CREATED=false
    CP_INSTALLED_BY_RUN=false CLEANUP_STARTED=false CLEANUP_OK=true ABORT_REASON=""
    VMFS_APPLIED=false VMS_APPLIED=false CP_INSTALLED_NAME="" GATE_TEARDOWN="" VMFS_MR_NAME=e2e-t0-vmfs
    LEGACY_WEBHOOK_LEFT=false
    init_results
    exec 3>"$C/say.txt"
  }
  queue() {
    local i=0 f
    for f in "$@"; do
      i=$((i + 1))
      printf '%s\n' "$f" >"$VC/q/$i.json"
    done
    printf '1\n' >"$VC/q/next"
    printf '%s\n' "$i" >"$VC/q/count"
  }
  # add_vm NAME RESOURCE: a powered-on VM with 2 vCPUs and 4096 MB in the fake vCenter.
  add_vm() {
    mkdir -p "$VC/vms/$1"
    printf '%s\n' "$2" >"$VC/vms/$1/res"
    printf poweredOn >"$VC/vms/$1/power"
    printf 2 >"$VC/vms/$1/cpu"
    printf 4096 >"$VC/vms/$1/mem"
    printf 'pioneer/example' >"$VC/vms/$1/annotation"
  }
  add_lab_vms() {
    add_vm e2e-t0-cluster "$VM_RES_CLUSTER"
    add_vm e2e-t0-ns "$VM_RES_NS"
    add_vm e2e-t0-initlate "$VM_RES_NS"
  }
  expect() {
    if "${@:2}"; then
      printf 'ok     - %s\n' "$1"
    else
      printf 'NOT OK - %s\n' "$1"
      FAILS=$((FAILS + 1))
    fi
  }
  said() { grep -qF -- "$1" "$C/say.txt"; }
  show() { grep -F -- "$1" "$C/say.txt" | sed 's/^/           | /'; }
  cell_is() { [[ ${RESULT[$1]} == "$2" ]]; }
  # cells_pass ROW...: each row is PASS in both the cluster and the namespaced column.
  cells_pass() {
    local r
    for r in "$@"; do
      cell_is "$r|cluster" PASS && cell_is "$r|namespaced" PASS || return 1
    done
  }
  # logins_of TEXT: how many logged govc commands contain TEXT.
  logins_of() { grep -cF -- "$1" "$VC/auth.log"; }
  all_cells_are() { [[ ${RESULT[AC-022|cluster]} == "$1" && ${RESULT[AC-022|namespaced]} == "$1" && ${RESULT[AC-022|package]} == "$1" ]]; }
  not_file() { [[ ! -e $1 ]]; }
  contains() { [[ $1 == *"$2"* ]]; }
  finish_case() { ((FAILS == 0)); }
  # secrets_hold PASSWORD: both credentials Secrets, crossplane-system then the test namespace,
  # were written through the script's own create_secret with that password.
  secrets_hold() {
    [[ -s $C/secrets ]] &&
      [[ $(cut -d' ' -f1 "$C/secrets" | tr '\n' ' ') == "namespace=crossplane-system namespace=vsphere-e2e " ]] &&
      [[ $(grep -cF "\"password\":\"$1\"" "$C/secrets") -eq 2 ]]
  }
  # auth_scan reads the fake vCenter's login log. A_BEFORE / A_AFTER: accepted logins before and
  # after the confirmation marker. A_WRONG: logins that used another password than the one in
  # effect on their side of the marker (the original before it, the rotated one after it).
  # A_REJECTED: logins vCenter refused. A_CMDS_BEFORE / A_CMDS_AFTER: the distinct govc commands.
  auth_scan() {
    local st pw cmd side=before
    local -A before=() after=()
    A_BEFORE=0 A_AFTER=0 A_WRONG=0 A_REJECTED=0
    while IFS=$'\t' read -r st pw cmd; do
      if [[ $st == confirmed ]]; then
        side=after
        continue
      fi
      if [[ $st == rejected ]]; then A_REJECTED=$((A_REJECTED + 1)); fi
      if [[ $side == before ]]; then
        if [[ $pw != "$P_ORIGINAL" ]]; then A_WRONG=$((A_WRONG + 1)); fi
        if [[ $st == ok ]]; then A_BEFORE=$((A_BEFORE + 1)); fi
        before[${cmd%% *}]=1
      else
        if [[ $pw != "$P_ROTATED" ]]; then A_WRONG=$((A_WRONG + 1)); fi
        if [[ $st == ok ]]; then A_AFTER=$((A_AFTER + 1)); fi
        after[${cmd%% *}]=1
      fi
    done <"$VC/auth.log"
    A_CMDS_BEFORE=$(printf '%s\n' "${!before[@]}" | sort | paste -sd' ' -)
    A_CMDS_AFTER=$(printf '%s\n' "${!after[@]}" | sort | paste -sd' ' -)
  }

  # Sessions of the provider's two cached clients (cluster and namespaced ProviderConfig) before
  # the rotation, plus an unrelated administrator browser session.
  S_A="sess-a|$U_NB|$AGENT|2026-09-25T09:10:00Z"
  S_B="sess-b|$U_NB|$AGENT|2026-09-25T09:10:05Z"
  S_C="sess-c|$U_NB|$AGENT|2026-09-25T09:40:00Z"
  S_D="sess-d|$U_NB|$AGENT|2026-09-25T09:40:01Z"
  S_E="sess-e|$U_NB|$AGENT|2026-09-25T09:20:00Z" # opened during the pause, before the change
  S_ADMIN="sess-admin|$U_ADMIN|Mozilla/5.0|2026-09-25T08:00:00Z"
  PRE=$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_ADMIN")
  PRE_E=$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_E" "$S_ADMIN")
  POST_CD=$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_ADMIN" "$S_C" "$S_D")
  FINISH_CD=$(sessions_json "$U_NB" "$S_C" "$S_D" "$S_ADMIN")

  # (a) AC-022: new session keys after the rotation, whose vCenter loginTime is skewed against
  # this workstation's clock by SKEW seconds. At -30s the new sessions' loginTime is earlier than
  # this workstation's time at the rotation, so a check that compared the two would take them
  # for old sessions.
  case_a() {
    local skew=$1 before after lt vc_epoch
    before=$(date -u +%s)
    vc_epoch=$((before + skew))
    # jq, not `date -d @N`, which BSD/macOS date does not accept.
    lt=$(jq -rn --argjson e "$vc_epoch" '$e | strftime("%Y-%m-%dT%H:%M:%S.123456Z")')
    queue "$PRE" "$PRE" "$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_ADMIN" \
      "sess-c|$U_NB|$AGENT|$lt" "sess-d|$U_NB|$AGENT|$lt")"
    run_ac022_rotation_start
    after=$(date -u +%s)
    expect "vCenter clock ${skew}s: AC-022 cluster = PASS" cell_is 'AC-022|cluster' PASS
    expect "vCenter clock ${skew}s: AC-022 namespaced = PASS" cell_is 'AC-022|namespaced' PASS
    expect "vCenter clock ${skew}s: 2 session keys absent before the rotation seen (2 needed)" test "$NEW_LOGIN_COUNT" -eq 2
    expect "vCenter clock ${skew}s: NEW_LOGIN_EPOCH is the workstation time the new key was first seen" \
      test "$NEW_LOGIN_EPOCH" -ge "$before" -a "$NEW_LOGIN_EPOCH" -le "$after"
    if ((skew != 0)); then
      expect "vCenter clock ${skew}s: ... and not vCenter's loginTime, which lies outside that window" \
        test "$vc_epoch" -lt "$before" -o "$vc_epoch" -gt "$after"
    fi
    expect "vCenter clock ${skew}s: the pre-rotation keys are recorded for the finish check" \
      test "$PRE_ROTATION_SESSION_KEYS" = '["sess-a","sess-b"]'
    expect "vCenter clock ${skew}s: both credentials Secrets rotated to the rotated password" secrets_hold "$P_ROTATED"
    finish_case
  }

  # (b) AC-022: only the pre-rotation keys are listed after the rotation (a reused client).
  case_b() {
    queue "$PRE" "$PRE" "$PRE"
    run_ac022_rotation_start
    expect "only pre-rotation keys: AC-022 cluster = FAIL" cell_is 'AC-022|cluster' FAIL
    expect "only pre-rotation keys: AC-022 namespaced = FAIL" cell_is 'AC-022|namespaced' FAIL
    expect "only pre-rotation keys: no new login detected (NEW_LOGIN_COUNT=0, NEW_LOGIN_EPOCH unset)" \
      test "$NEW_LOGIN_COUNT" -eq 0 -a "$NEW_LOGIN_EPOCH" -eq 0
    run_ac022_rotation_finish
    expect "only pre-rotation keys: AC-022 package = FAIL (no post-rotation login ever observed)" cell_is 'AC-022|package' FAIL
    finish_case
  }

  # (b2) AC-022: one new key for two rotated ProviderConfigs: one client was reused.
  case_b2() {
    queue "$PRE" "$PRE" "$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_C")"
    run_ac022_rotation_start
    expect "1 new key for 2 touched VMs: AC-022 cluster = FAIL" cell_is 'AC-022|cluster' FAIL
    expect "1 new key for 2 touched VMs: AC-022 namespaced = FAIL" cell_is 'AC-022|namespaced' FAIL
    show "[AC-022] provider-user sessions with a key absent"
    finish_case
  }

  # (b3) AC-022: govc fails on the pre-rotation sample, before the pause. An empty key list would
  # make the old clients' sessions look new, so AC-022 FAILs without asking for a password change.
  case_b3() {
    queue FAIL "$PRE"
    run_ac022_rotation_start
    expect "pre-rotation sample unusable: AC-022 = FAIL in every column" all_cells_are FAIL
    expect "pre-rotation sample unusable: no /dev/tty prompt, no Secret rotated, no finish check armed" \
      eval 'not_file "$C/prompted" && not_file "$C/secrets" && [[ $ROTATE_STARTED == false ]]'
    expect "pre-rotation sample unusable: says it cannot list the sessions" said "[AC-022] cannot list the vCenter sessions"
    finish_case
  }

  # (b4) AC-022: you answer yes, but the vCenter password was not changed to the rotated one.
  case_b4() {
    HUMAN_SETS=unchanged
    queue "$PRE" "$PRE" "$POST_CD"
    run_ac022_rotation_start
    auth_scan
    expect "rotated password rejected: AC-022 = FAIL in every column" all_cells_are FAIL
    expect "rotated password rejected: both Secrets still rotated to the rotated password (you confirmed the change)" \
      secrets_hold "$P_ROTATED"
    expect "rotated password rejected: no finish check armed" test "$ROTATE_STARTED" = false
    expect "rotated password rejected: tells you to set the lab user's password to E2E_VSPHERE_ROTATED_PASSWORD" \
      said "set it to exactly that value now"
    expect "rotated password rejected: 1 login before the confirmation, with the original password; after it only the rotated one, rejected once" \
      test "$A_BEFORE:$A_AFTER:$A_REJECTED:$A_WRONG" = "1:0:1:0"
    finish_case
  }

  # (g) AC-022: no provider session visible before the pause: FAIL without asking for a password change.
  case_g() {
    queue "$(sessions_json "$U_NB" "$S_ADMIN")"
    run_ac022_rotation_start
    expect "blind before the pause: AC-022 = FAIL in every column" all_cells_are FAIL
    expect "blind before the pause: no /dev/tty prompt, no Secret rotated" eval 'not_file "$C/prompted" && not_file "$C/secrets"'
    expect "blind before the pause: measurement-failure diagnostic printed" said "[AC-022] MEASUREMENT FAILURE"
    finish_case
  }

  # (n) AC-022: no confirmation. The password is taken as unchanged, so govc keeps the original.
  case_n() {
    HUMAN_SETS=unchanged HUMAN_ANSWER=no
    add_lab_vms
    queue "$PRE"
    run_ac022_rotation_start
    expect "no confirmation: AC-022 = SKIPPED(no confirmation) in every column" all_cells_are "SKIPPED(no confirmation)"
    expect "no confirmation: VSPHERE_PASSWORD stays the original, no Secret rotated, no finish check armed" \
      eval '[[ $VSPHERE_PASSWORD == "$P_ORIGINAL" && $ROTATE_STARTED == false ]] && not_file "$C/secrets"'
    expect "no confirmation: a later govc call still logs in with the original password" \
      eval '[[ $(vm_path e2e-t0-cluster) == /lab/vm/e2e/e2e-t0-cluster ]]'
    auth_scan
    expect "no confirmation: 2 logins, both with the original password, none rejected" test "$A_BEFORE:$A_REJECTED:$A_WRONG" = "2:0:0"
    finish_case
  }

  # (h) AC-022 start and finish against a vCenter that rejects the original password once you
  # change it. The pre-rotation keys are sampled before the pause with the original password and
  # right after the confirmation with the rotated one; every later login uses the rotated one.
  case_h() {
    queue "$PRE" "$PRE_E" "$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_E" "$S_ADMIN" "$S_C" "$S_D")" "$FINISH_CD"
    run_ac022_rotation_start
    run_ac022_rotation_finish
    auth_scan
    expect "rotation start + finish: AC-022 cluster, namespaced and package = PASS" all_cells_are PASS
    expect "the pre-rotation keys are both samples' keys: sess-a, sess-b and sess-e (opened during the pause)" \
      test "$PRE_ROTATION_SESSION_KEYS" = '["sess-a","sess-b","sess-e"]'
    expect "2 new session keys after the Secret rotation (sess-e, opened during the pause, is not one)" test "$NEW_LOGIN_COUNT" -eq 2
    expect "1 govc login before the confirmation (sample 1), with the original password" test "$A_BEFORE:$A_CMDS_BEFORE" = "1:session.ls"
    expect "3 govc logins after it (sample 2, the post-touch sample, the finish check), all with the rotated password" \
      test "$A_AFTER:$A_WRONG" = "3:0"
    expect "vCenter rejected no login" test "$A_REJECTED" -eq 0
    expect "both credentials Secrets carry the rotated password" secrets_hold "$P_ROTATED"
    show "[AC-022] pre-rotation provider sessions recorded"
    finish_case
  }

  # (h2) AC-022: a session the provider opened with the original password during the pause is
  # not taken for a rebuilt client. Here only one client was rebuilt for two ProviderConfigs.
  case_h2() {
    queue "$PRE" "$PRE_E" "$(sessions_json "$U_NB" "$S_A" "$S_B" "$S_E" "$S_C")"
    run_ac022_rotation_start
    expect "1 rebuilt client + 1 session from the pause: AC-022 cluster = FAIL" cell_is 'AC-022|cluster' FAIL
    expect "1 rebuilt client + 1 session from the pause: AC-022 namespaced = FAIL" cell_is 'AC-022|namespaced' FAIL
    expect "1 rebuilt client + 1 session from the pause: only sess-c counts as new" test "$NEW_LOGIN_COUNT" -eq 1
    finish_case
  }

  # (i) Password audit over the rest of the vm phase: rotation start, AC-019, AC-006 update and
  # delete, the rotation finish and the cleanup, each with its real govc calls.
  case_i() {
    add_lab_vms
    STARTED=true CLUSTER_TOUCHED=true PROVIDER_APPLIED=true NS_CREATED=true
    queue "$PRE" "$PRE" "$POST_CD" "$FINISH_CD"
    run_ac022_rotation_start
    run_ac019
    run_ac006_update
    run_ac006_delete
    run_ac022_rotation_finish
    cleanup 2>"$C/err.txt"
    auth_scan
    expect "after the rotation: AC-022 = PASS in every column" all_cells_are PASS
    expect "after the rotation: AC-019, AC-006-update and AC-006-delete/OT-021 = PASS in both scopes" \
      cells_pass AC-019 AC-006-update AC-006-delete/OT-021
    expect "cleanup finds no leaked VM and reports nothing" eval '[[ $CLEANUP_OK == true && ! -s $C/err.txt ]]'
    expect "every VM is gone from the fake vCenter" eval '[[ -z $(ls -A "$VC/vms") ]]'
    expect "govc used the original password only before the confirmation: $A_CMDS_BEFORE" test "$A_BEFORE" -eq 1
    expect "every govc login after it used the rotated password: $A_CMDS_AFTER" test "$A_WRONG:$A_REJECTED" = "0:0"
    expect "those logins include AC-019's, AC-006's, the finish check's and cleanup's" \
      test "$A_CMDS_AFTER" = "find session.ls vm.change vm.info vm.power"
    finish_case
  }

  # (j) A fatal error right after the rotation: the EXIT trap's cleanup logs in with the rotated
  # password, so its leak check still works.
  case_j() {
    add_lab_vms
    STARTED=true CLUSTER_TOUCHED=true PROVIDER_APPLIED=true NS_CREATED=true
    queue "$PRE" "$PRE" "$POST_CD"
    # `|| true` keeps the case's set -e from stopping at this subshell's exit status 1.
    (
      trap on_exit EXIT
      run_ac022_rotation_start
      fatal "simulated failure right after the rotation"
    ) 2>"$C/err.txt" || true
    auth_scan
    expect "fatal after the rotation: the run is reported as aborted" said "ABORTED: simulated failure right after the rotation"
    expect "fatal after the rotation: cleanup's govc logins used the rotated password, none rejected" \
      test "$A_WRONG:$A_REJECTED" = "0:0"
    expect "fatal after the rotation: cleanup checked vCenter for each of the 3 VMs and found no leaked VM" \
      eval '! grep -qE "LEAKED|cannot check vCenter" "$C/err.txt" && [[ $(logins_of "find / -type m -name") -eq 3 ]]'
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }

  # (k) Cleanup when vCenter rejects govc's login (its password changed behind the script's back):
  # the leak check cannot run, so the cleanup is unverified, never "no VM left".
  case_k() {
    add_lab_vms
    STARTED=true CLUSTER_TOUCHED=true PROVIDER_APPLIED=true NS_CREATED=true
    printf 'dummy-changed-elsewhere' >"$VC/password"
    cleanup 2>"$C/err.txt"
    expect "rejected login in cleanup: CLEANUP_OK=false" test "$CLEANUP_OK" = false
    expect "rejected login in cleanup: each of the 3 VM names is reported as unchecked" \
      test "$(grep -c 'cannot check vCenter for a leaked VM' "$C/err.txt")" -eq 3
    expect "rejected login in cleanup: no VM is claimed leaked (none could be checked)" eval '! grep -q LEAKED "$C/err.txt"'
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }

  # (r) The real rotate_confirm, reading from a file instead of /dev/tty: yes/y confirm, no/n and
  # a closed input decline, anything else is asked again, and no answer is echoed.
  case_r() {
    local f=$C/answers rc
    if [[ $(declare -f real_rotate_confirm) != *CONFIRM_TTY* ]]; then
      expect "rotate_confirm reads its answer from CONFIRM_TTY, so it can be tested without a terminal" false
      finish_case
      return
    fi
    CONFIRM_TTY=$f
    while IFS='|' read -r answers want label; do
      printf '%b' "$answers" >"$f"
      rc=0
      real_rotate_confirm 2>"$C/err.txt" || rc=$?
      expect "$label -> $want" test "$rc" -eq "$want"
      sed 's/^/  stderr: /' "$C/err.txt"
    done <<'EOF'
yes\n|0|yes
y\n|0|y
YES\n|0|YES
maybe\nY\n|0|maybe, asked again, then Y
no\n|1|no
N\n|1|N
|1|input closed without an answer
pasted-pw-9x7Q2\nno\n|1|a pasted password, asked again, then no
EOF
    expect "the pasted password is never echoed" eval '! grep -qF pasted-pw "$C/err.txt" "$C/say.txt"'
    finish_case
  }

  # (t) The script's own validate(). With E2E_VSPHERE_ROTATED_PASSWORD set, a vm-phase run that is
  # not a dry run needs the terminal the AC-022 prompt reads (CONFIRM_TTY, /dev/tty by default).
  # When that cannot be opened -- no controlling terminal, as in CI or under setsid -- the run must
  # stop in validate() with exit 2, before any command. CONFIRM_TTY names a path that cannot be
  # opened, or a readable file standing in for a working terminal. validate()'s messages hold that
  # temp path, so they are matched, never printed.
  case_t() {
    local tty dry rotated phase want label rc
    if [[ $(declare -f validate) != *CONFIRM_TTY* ]]; then
      expect "validate() probes CONFIRM_TTY, so the no-tty rejection can be tested without a terminal" false
      finish_case
      return
    fi
    expect "CONFIRM_TTY defaults to /dev/tty: a real run probes, and then reads, /dev/tty" test "$DEFAULT_CONFIRM_TTY" = /dev/tty
    # validate()'s inputs as resolve_settings leaves them for a v2.2.0 run, on top of setup's. No
    # E2E_* setting from the caller's environment reaches validate().
    unset "${!E2E_@}"
    XP_VERSION_RAW=v2.2.0 LEGACY_RAW=1.20.13 REQUIRE_AC022=false FIRMWARE=bios
    LOGOUT_DELAY_RAW=70m LOGOUT_SLACK_RAW=10m PROVIDER_REMOVAL_TIMEOUT_RAW=10m
    E2E_RESOURCE_POOL_ID=resgroup-1 E2E_DATASTORE_ID=datastore-1 E2E_NETWORK_ID=dvportgroup-1
    E2E_TEMPLATE_UUID=42000000-0000-0000-0000-000000000000 E2E_GUEST_ID=ubuntu64Guest E2E_FOLDER=e2e
    printf 'stand-in terminal\n' >"$C/tty-file"
    while IFS='|' read -r tty dry rotated phase want label; do
      case $tty in
        missing) CONFIRM_TTY=$C/no-such-tty ;;
        file) CONFIRM_TTY=$C/tty-file ;;
      esac
      DRY_RUN=$dry PHASE=$phase ROTATED_PASSWORD=""
      if [[ $rotated == set ]]; then ROTATED_PASSWORD=$P_ROTATED; fi
      rc=0
      (validate) >"$C/validate.out" 2>"$C/validate.err" || rc=$?
      expect "$label -> exit $want" test "$rc" -eq "$want"
      if ((want == 2)); then
        expect "$label: names CONFIRM_TTY as unavailable for the AC-022 prompt, and says nothing was changed" \
          eval 'grep -qF "is set but $CONFIRM_TTY is not available for the AC-022 confirmation prompt" "$C/validate.err" && grep -qF "nothing was changed" "$C/validate.err"'
        expect "$label: that is the only problem reported" test "$(grep -c '^  ' "$C/validate.err")" -eq 1
      else
        expect "$label: nothing reported" eval '[[ ! -s $C/validate.err && ! -s $C/validate.out ]]'
      fi
    done <<'EOF'
missing|false|set|all|2|no terminal, rotation requested, real run
missing|false|set|vm|2|no terminal, rotation requested, real run, --phase vm
file|false|set|all|0|terminal available, rotation requested, real run
missing|true|set|all|0|no terminal, rotation requested, dry run (never prompts)
missing|false|unset|all|0|no terminal, no rotation requested (AC-022 skipped, never prompts)
missing|false|set|version-gate|0|no terminal, rotation requested, --phase version-gate (no AC-022)
EOF
    finish_case
  }

  # GOVC_FIXTURES: what real govc binaries print, recorded for the (v) cases below. Each binary
  # was downloaded, or built with go1.26.3, as its "how" lines say, on linux/amd64 on 2026-09-25.
  # Its two outputs were captured in the binary's own directory with `./govc version 2>&1` and
  # `GOTOOLCHAIN=local go version -m govc` (go1.26.3). A marker line gives the command's exit
  # status, and "stderr" when the lines under it are what it wrote to stderr (else they are its
  # stdout; the other stream was empty). Those lines are verbatim, tabs included, trailing tabs
  # and tab-only lines too: keep them exactly as they are. tool_dir's stub govc and go replay
  # them. The first line of a `go version -m` recording names the binary as the capture did
  # (govc); check_tools passes the full path and ignores that line.
  GOVC_FIXTURES=$(
    cat <<'EOF'
@@ fixture rel-0.31.0
@@ how: the v0.31.0 release binary: curl -fsSL -o govc.tgz https://github.com/vmware/govmomi/releases/download/v0.31.0/govc_Linux_x86_64.tar.gz && tar -xzf govc.tgz govc
@@ govc version (exit 0):
govc 0.31.0
@@ go version -m (exit 0):
govc: go1.20.8
	path	command-line-arguments
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	(devel)	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	-ldflags="-X github.com/vmware/govmomi/govc/flags.BuildVersion=0.31.0 -X github.com/vmware/govmomi/govc/flags.BuildCommit=2fab8d53 -X github.com/vmware/govmomi/govc/flags.BuildDate=2023-09-25T19:12:44Z"
	build	CGO_ENABLED=0
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture rel-0.32.0
@@ how: the v0.32.0 release binary: curl -fsSL -o govc.tgz https://github.com/vmware/govmomi/releases/download/v0.32.0/govc_Linux_x86_64.tar.gz && tar -xzf govc.tgz govc
@@ govc version (exit 0):
govc 0.32.0
@@ go version -m (exit 0):
govc: go1.20.8
	path	command-line-arguments
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	(devel)	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	-ldflags="-X github.com/vmware/govmomi/govc/flags.BuildVersion=0.32.0 -X github.com/vmware/govmomi/govc/flags.BuildCommit=a8d705a0 -X github.com/vmware/govmomi/govc/flags.BuildDate=2023-09-28T20:44:06Z"
	build	CGO_ENABLED=0
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture rel-0.54.0
@@ how: the v0.54.0 release binary: curl -fsSL -o govc.tgz https://github.com/vmware/govmomi/releases/download/v0.54.0/govc_Linux_x86_64.tar.gz && tar -xzf govc.tgz govc
@@ govc version (exit 0):
govc 0.54.0
@@ go version -m (exit 0):
govc: go1.24.0
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi/govc	v0.54.0	
	dep	github.com/a8m/tree	v0.0.0-20240104212747-2c8764a5f17e	h1:KMVieI1/Ub++GYfnhyFPoGE3g5TUiG4srE3TMGr5nM4=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	v0.0.0-00010101000000-000000000000
	=>	../	(devel)	
	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.34.0	h1:oL/Qq0Kdaqxa1KbNeMKwQq0reLCCaFtqu2eNuSeNHbk=
	build	-buildmode=exe
	build	-compiler=gc
	build	-ldflags="-X github.com/vmware/govmomi/cli/flags.BuildVersion=0.54.0 -X github.com/vmware/govmomi/cli/flags.BuildCommit=df7c057a -X github.com/vmware/govmomi/cli/flags.BuildDate=2026-05-08T21:11:31Z"
	build	CGO_ENABLED=0
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=df7c057af6c06430955ce56d6f04b7e49138f9b3
	build	vcs.time=2026-05-08T21:11:24Z
	build	vcs.modified=false
@@ end
@@ fixture rel-0.56.0
@@ how: the v0.56.0 release binary: curl -fsSL -o govc.tgz https://github.com/vmware/govmomi/releases/download/v0.56.0/govc_Linux_x86_64.tar.gz && tar -xzf govc.tgz govc
@@ govc version (exit 0):
govc 0.56.0
@@ go version -m (exit 0):
govc: go1.26.6
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi/govc	v0.0.0-20260821034451-81608f9b9725	
	dep	github.com/a8m/tree	v0.0.0-20240104212747-2c8764a5f17e	h1:KMVieI1/Ub++GYfnhyFPoGE3g5TUiG4srE3TMGr5nM4=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	v0.0.0-00010101000000-000000000000
	=>	../	(devel)	
	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.41.0	h1:vz/seA0lnX87Othu2f/0L24RcgrXD9/YFTSuGjj3rH8=
	build	-buildmode=exe
	build	-compiler=gc
	build	-ldflags="-X github.com/vmware/govmomi/cli/flags.BuildVersion=0.56.0 -X github.com/vmware/govmomi/cli/flags.BuildCommit=81608f9b -X github.com/vmware/govmomi/cli/flags.BuildDate=2026-08-21T03:45:00Z"
	build	DefaultGODEBUG=cryptocustomrand=1,tlssecpmlkem=0,urlstrictcolons=0
	build	CGO_ENABLED=0
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=81608f9b9725d64e4ed447b9a338c9f03dbf8840
	build	vcs.time=2026-08-21T03:44:51Z
	build	vcs.modified=false
@@ end
@@ fixture goinst-v0.31.0
@@ how: GOBIN=$PWD go install github.com/vmware/govmomi/govc@v0.31.0
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.31.0	h1:+NC7le8yeXj7f4YUC841jgdWsehN7A3ivqLxm79eKyo=
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture goinst-v0.32.0
@@ how: GOBIN=$PWD go install github.com/vmware/govmomi/govc@v0.32.0
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.32.0	h1:Rsdi/HAX5Ebf9Byp/FvBir4sfM7yP5DBUeRlbC6vLBo=
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture goinst-v0.46.3
@@ how: GOBIN=$PWD go install github.com/vmware/govmomi/govc@v0.46.3 (the last release this works for:
@@ how: every release from v0.47.0 on fails, and so does @latest)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.46.3	h1:zBn42Rl0WZBFhGao8Dy0MFRkbE4YNPqOu0OBd+ww6VM=
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.19.0	h1:kTxAhCbGbxhK0IwgSKiMO5awPoDQ0RpfiVYBfK860YM=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httpservecontentkeepheaders=1,multipathtcp=0,randseednop=0,rsa1024min=0,tls3des=1,tlsmlkem=0,tlssecpmlkem=0,tlssha1=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture goinst-v0.47.0-alpha.0
@@ how: GOBIN=$PWD go install github.com/vmware/govmomi/govc@v0.47.0-alpha.0 (a pre-release tagged
@@ how: before govc moved into its own module)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.47.0-alpha.0	h1:wmfS2DyynuqKdsYZjQ4xT/KvnkCS09iqxO31ibbgFlg=
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.19.0	h1:kTxAhCbGbxhK0IwgSKiMO5awPoDQ0RpfiVYBfK860YM=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httpservecontentkeepheaders=1,multipathtcp=0,randseednop=0,rsa1024min=0,tls3des=1,tlsmlkem=0,tlssecpmlkem=0,tlssha1=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture checkout-v0.56.0
@@ how: git clone --filter=blob:none --branch v0.56.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi/govc && go install . (a clean clone: git status prints nothing)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi/govc	v0.0.0-20260821034451-81608f9b9725	
	dep	github.com/a8m/tree	v0.0.0-20240104212747-2c8764a5f17e	h1:KMVieI1/Ub++GYfnhyFPoGE3g5TUiG4srE3TMGr5nM4=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	v0.0.0-00010101000000-000000000000
	=>	../	(devel)	
	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.41.0	h1:vz/seA0lnX87Othu2f/0L24RcgrXD9/YFTSuGjj3rH8=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=cryptocustomrand=1,tlssecpmlkem=0,urlstrictcolons=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=81608f9b9725d64e4ed447b9a338c9f03dbf8840
	build	vcs.time=2026-08-21T03:44:51Z
	build	vcs.modified=false
@@ end
@@ fixture checkout-v0.56.0-novcs
@@ how: git clone --filter=blob:none --branch v0.56.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi/govc && go build -buildvcs=false .
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi/govc	(devel)	
	dep	github.com/a8m/tree	v0.0.0-20240104212747-2c8764a5f17e	h1:KMVieI1/Ub++GYfnhyFPoGE3g5TUiG4srE3TMGr5nM4=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.6.0	h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/vmware/govmomi	v0.0.0-00010101000000-000000000000
	=>	../	(devel)	
	
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	dep	golang.org/x/text	v0.41.0	h1:vz/seA0lnX87Othu2f/0L24RcgrXD9/YFTSuGjj3rH8=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=cryptocustomrand=1,tlssecpmlkem=0,urlstrictcolons=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture gobuild-v0.32.0
@@ how: git clone --filter=blob:none --branch v0.32.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi && go build -o ../out/govc ./govc (a clean tree at the tag. Without -o,
@@ how: go build stops: its default output, govc, is the govc/ directory. ../out is outside the clone)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.32.0	
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=a8d705a003ec4a4316a38af03bcca56e5e4eedd1
	build	vcs.time=2023-09-28T20:44:01Z
	build	vcs.modified=false
@@ end
@@ fixture gobuild-v0.32.0-dirty
@@ how: git clone --filter=blob:none --branch v0.32.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi && echo scratch >local-notes.txt && go build -o ../out/govc ./govc (an untracked file)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.32.0+dirty	
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=a8d705a003ec4a4316a38af03bcca56e5e4eedd1
	build	vcs.time=2023-09-28T20:44:01Z
	build	vcs.modified=true
@@ end
@@ fixture gobuild-v0.32.0-novcs
@@ how: git clone --filter=blob:none --branch v0.32.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi && go build -buildvcs=false -o ../out/govc ./govc
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	(devel)	
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture gobuild-untagged
@@ how: git clone --filter=blob:none --branch v0.32.0 https://github.com/vmware/govmomi.git govmomi
@@ how: then: cd govmomi && git checkout fc117d63069edb062c3fba246554fdb15697ea75 && go build -o ../out/govc ./govc
@@ how: (v0.33.0~1: no tag on it; git describe --tags prints v0.31.0-35-gfc117d63)
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.31.1-0.20231025064746-fc117d63069e	
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	DefaultGODEBUG=asynctimerchan=1,containermaxprocs=0,cryptocustomrand=1,decoratemappings=0,gotestjsonbuildtext=1,gotypesalias=0,httpcookiemaxnum=0,httplaxcontentlength=1,httpmuxgo121=1,httpservecontentkeepheaders=1,multipathtcp=0,panicnil=1,randseednop=0,rsa1024min=0,tls10server=1,tls3des=1,tlsmlkem=0,tlsrsakex=1,tlssecpmlkem=0,tlssha1=1,tlsunsafeekm=1,updatemaxprocs=0,urlmaxqueryparams=0,urlstrictcolons=0,winreadlinkvolume=0,winsymlink=0,x509keypairleaf=0,x509negativeserial=1,x509rsacrt=0,x509sha256skid=0,x509usepolicies=0
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
	build	vcs=git
	build	vcs.revision=fc117d63069edb062c3fba246554fdb15697ea75
	build	vcs.time=2023-10-25T06:47:46Z
	build	vcs.modified=false
@@ end
@@ fixture dep-replace
@@ how: in a new module: go mod init example.com/govc-dep-replace && go get github.com/vmware/govmomi@v0.32.0
@@ how: && go mod edit -replace github.com/vmware/govmomi=github.com/vmware/govmomi@v0.31.0 && go mod tidy
@@ how: && go get github.com/vmware/govmomi/govc@v0.32.0 && go build github.com/vmware/govmomi/govc
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 0):
govc: go1.26.3
	path	github.com/vmware/govmomi/govc
	mod	github.com/vmware/govmomi	v0.32.0
	=>	github.com/vmware/govmomi	v0.31.0	h1:+NC7le8yeXj7f4YUC841jgdWsehN7A3ivqLxm79eKyo=
	
	dep	github.com/a8m/tree	v0.0.0-20210115125333-10a5fd5b637d	h1:4E8RufAN3UQ/weB6AnQ4y5miZCO0Yco8ZdGId41WuQs=
	dep	github.com/dougm/pretty	v0.0.0-20171025230240-2ee9d7453c02	h1:tR3jsKPiO/mb6ntzk/dJlHZtm37CPfVp1C9KIo534+4=
	dep	github.com/google/uuid	v1.3.1	h1:KjJaJ9iWZ3jOFZIf1Lqf4laDRCasjl0BCmnEGxkdLb4=
	dep	github.com/kr/text	v0.2.0	h1:5Nx0Ya0ZqY2ygV366QzturHI13Jq95ApcVaJBhpS+AY=
	dep	github.com/xlab/treeprint	v1.2.0	h1:HzHnuAF1plUN2zGlAFHbSQP2qJ0ZAD3XF5XD7OesXRQ=
	build	-buildmode=exe
	build	-compiler=gc
	build	CGO_ENABLED=1
	build	CGO_CFLAGS=
	build	CGO_CPPFLAGS=
	build	CGO_CXXFLAGS=
	build	CGO_LDFLAGS=
	build	GOARCH=amd64
	build	GOOS=linux
	build	GOAMD64=v1
@@ end
@@ fixture shim
@@ how: an asdf-style shim: a shell script named govc that runs exec /path/to/goinst-v0.32.0/govc "$@"
@@ govc version (exit 0):
govc 0.0.0
@@ go version -m (exit 1, stderr):
govc: could not read Go build info from govc: unrecognized file format
@@ end
EOF
  )
  # fixture NAME DIR: writes the recording NAME of GOVC_FIXTURES into DIR: govc.out and govc.rc
  # for `govc version`, and go.out, go.err and go.rc for `go version -m`. Fails if there is no
  # recording NAME.
  fixture() {
    local name=$1 dir=$2 line cur="" to="" hit=false
    local mark='^@@ (govc version|go version -m) \(exit ([0-9]+)(, stderr)?\):$'
    : >"$dir/govc.out"
    : >"$dir/go.out"
    : >"$dir/go.err"
    while IFS= read -r line; do
      case $line in
        "@@ fixture "*) cur=${line#"@@ fixture "} to="" ;;
        "@@ end") cur="" to="" ;;
        "@@ how: "*) ;;
        *)
          if [[ $cur != "$name" ]]; then continue; fi
          hit=true
          if [[ $line =~ $mark ]]; then
            if [[ ${BASH_REMATCH[1]} == "govc version" ]]; then
              to=govc.out
              printf '%s\n' "${BASH_REMATCH[2]}" >"$dir/govc.rc"
            else
              to=go.out
              if [[ -n ${BASH_REMATCH[3]} ]]; then to=go.err; fi
              printf '%s\n' "${BASH_REMATCH[2]}" >"$dir/go.rc"
            fi
          elif [[ -n $to ]]; then
            printf '%s\n' "$line" >>"$dir/$to"
          fi
          ;;
      esac
    done <<<"$GOVC_FIXTURES"
    [[ $hit == true ]]
  }

  # tool_dir DIR REAL_JQ JQ GOVC GO: one PATH directory of stubs for check_tools. kubectl and helm
  # record any call, like the stubs above. JQ: real (runs REAL_JQ) or 1.5. GOVC: none; broken, a
  # synthetic govc whose `govc version` fails (it models no output format); or the name of a
  # GOVC_FIXTURES recording, whose `govc version` output the stub govc replays. GO: none (no go on
  # PATH), or go: a stub go that replays that recording's `go version -m`, and only under
  # GOTOOLCHAIN=local, which check_tools sets so that go never switches to, or downloads, another
  # toolchain. The recording is unpacked into DIR/fixture, which is not on PATH. Fails if GOVC
  # names no recording.
  tool_dir() {
    local d=$1 real_jq=$2 jqv=$3 govcv=$4 gov=$5 f=$1/fixture b
    mkdir -p "$f"
    for b in kubectl helm; do
      printf '#!/bin/sh\necho "$0 $*" >>"%s/CALLED"\nexit 99\n' "$T" >"$d/$b"
    done
    case $jqv in
      real) printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_jq" >"$d/jq" ;;
      1.5)
        cat >"$d/jq" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then echo jq-1.5; exit 0; fi
for a in "$@"; do
  if [ "$a" = --rawfile ]; then echo "jq: Unknown option --rawfile" >&2; exit 2; fi
done
echo "fake jq 1.5: unexpected call: $*" >&2
exit 1
EOF
        ;;
    esac
    case $govcv in
      none) ;;
      broken) printf '#!/bin/sh\necho "fake govc: cannot execute binary file" >&2\nexit 126\n' >"$d/govc" ;;
      *)
        fixture "$govcv" "$f" || return 1
        printf '#!/bin/sh\nif [ "$*" = version ]; then "%s" "%s/govc.out"; exit %s; fi\necho "fake govc: unexpected command: $*" >&2\nexit 1\n' \
          "$CAT" "$f" "$(<"$f/govc.rc")" >"$d/govc"
        if [[ $gov == go ]]; then
          printf '#!/bin/sh\n[ "$1 $2" = "version -m" ] && [ "${GOTOOLCHAIN-}" = local ] || { echo "fake go: unexpected call: $*" >&2; exit 1; }\n"%s" "%s/go.out"\n"%s" "%s/go.err" >&2\nexit %s\n' \
            "$CAT" "$f" "$CAT" "$f" "$(<"$f/go.rc")" >"$d/go"
        fi
        ;;
    esac
    chmod +x "$d"/*
  }

  # (v) The script's own check_tools(), which runs before any cluster call. A jq without
  # --rawfile, a govc older than MIN_GOVC and a govc whose version cannot be determined stop a
  # real run and a dry run alike with exit 2, naming what was found and the minimum; a govc at or
  # above MIN_GOVC passes. The govc and go stubs replay GOVC_FIXTURES, the recorded output of real
  # govc binaries: release binaries, go install builds, builds in a govmomi clone (clean, with an
  # untracked file, without VCS information, at an untagged commit, and after govc moved into its
  # own module in v0.47.0), a build in another module with a replace directive, and a shell-script
  # shim. The jq 1.5 stub models the jq 1.5 release binary as measured: it prints jq-1.5 for
  # --version and rejects --rawfile as an unknown option. Against vcsim, govc 0.31.0 still prints
  # vm.info -json as VirtualMachines, where 0.32.0 prints the camelCase virtualMachines the script
  # reads: 0.31.0 must fail and 0.32.0 pass. Each row: jq|govc|go|dry run|phase|exit|message(s),
  # ^-separated|problem lines|label.
  case_v() {
    local real_jq d n=0 jqv govcv gov dry phase want frags lines label rc f tools_line usage_text
    local -a want_msgs=()
    if [[ $(declare -f check_tools) != *--rawfile* ]]; then
      expect "check_tools probes jq for --rawfile and reads the govc version" false
      finish_case
      return
    fi
    expect "MIN_BASH, MIN_JQ and MIN_GOVC are 4, 1.6 and 0.32.0, the floors measured on the real jq and govc" \
      test "$MIN_BASH $MIN_JQ $MIN_GOVC" = "4 1.6 0.32.0"
    expect "GOVC_LAST_GO_INSTALL is 0.46.3, the last release go install github.com/vmware/govmomi/govc@vX.Y.Z builds" \
      test "${GOVC_LAST_GO_INSTALL-unset}" = 0.46.3
    expect "version_ge compares numerically: 0.9.0 is older than 0.32.0, though it sorts after it as text" \
      eval '! version_ge 0.9.0 0.32.0'
    tools_line=$(usage | grep -F "Tools:") || tools_line=""
    expect "usage's Tools line states them: bash 4+, jq 1.6+ ... govc 0.32.0+" \
      test "$tools_line" = "Tools: bash 4+, jq 1.6+ and kubectl (every phase), helm (managed mode), govc 0.32.0+"
    usage_text=$(usage | tr '\n' ' ' | tr -s ' ')
    expect "usage names the go install range: 'go install github.com/vmware/govmomi/govc@vX.Y.Z' with X.Y.Z from 0.32.0 to 0.46.3" \
      contains "$usage_text" "'go install github.com/vmware/govmomi/govc@vX.Y.Z' with X.Y.Z from 0.32.0 to 0.46.3"
    sed -n '/^## 2\./,/^## 3\./p' RELEASING.md >"$C/section2.txt"
    expect "RELEASING.md section 2 states exactly: bash 4+, jq 1.6+, govc 0.32.0+" \
      grep -qF "bash 4+, jq 1.6+, govc 0.32.0+" "$C/section2.txt"
    expect "RELEASING.md section 2 names the same go install range: 0.32.0 up to 0.46.3" \
      contains "$(tr '\n' ' ' <"$C/section2.txt" | tr -s ' ')" '`go install github.com/vmware/govmomi/govc@vX.Y.Z` for a release from 0.32.0 up to 0.46.3'
    real_jq=$(command -v jq)
    while IFS='|' read -r jqv govcv gov dry phase want frags lines label; do
      n=$((n + 1))
      d=$C/tools-$n
      if ! tool_dir "$d" "$real_jq" "$jqv" "$govcv" "$gov"; then
        expect "$label: GOVC_FIXTURES holds the recording $govcv" false
        continue
      fi
      DRY_RUN=$dry PHASE=$phase
      rc=0
      (
        PATH=$d
        check_tools
      ) >"$C/tools.out" 2>"$C/tools.err" || rc=$?
      expect "$label -> exit $want" test "$rc" -eq "$want"
      want_msgs=()
      if [[ -n $frags ]]; then IFS='^' read -r -a want_msgs <<<"$frags"; fi
      for f in ${want_msgs[@]+"${want_msgs[@]}"}; do
        expect "$label: says: $f" grep -qF -- "$f" "$C/tools.err"
      done
      if ((want == 2)); then
        expect "$label: $lines problem line(s), and says nothing was changed" \
          eval '[[ $(grep -c "^  " "$C/tools.err") -eq $lines ]] && grep -qF "nothing was changed" "$C/tools.err"'
      elif [[ -z $frags ]]; then
        expect "$label: nothing reported" eval '[[ ! -s $C/tools.err && ! -s $C/tools.out ]]'
      fi
      sed 's/^/           | /' "$C/tools.err"
    done <<'EOF'
1.5|rel-0.32.0|go|false|all|2|jq 1.6 or newer is required, for --rawfile (found: jq-1.5)|1|jq 1.5 (no --rawfile), govc 0.32.0 release binary, real run
1.5|rel-0.32.0|go|true|all|2|jq 1.6 or newer is required, for --rawfile (found: jq-1.5)|1|jq 1.5 (no --rawfile), govc 0.32.0 release binary, dry run
real|rel-0.31.0|go|false|all|2|govc 0.32.0 or newer is required, for the camelCase -json fields this script reads (found: govc 0.31.0)|1|govc 0.31.0 release binary, real run
real|rel-0.31.0|go|true|all|2|govc 0.32.0 or newer is required, for the camelCase -json fields this script reads (found: govc 0.31.0)|1|govc 0.31.0 release binary, dry run
1.5|rel-0.31.0|go|true|all|2|jq 1.6 or newer is required, for --rawfile (found: jq-1.5)^govc 0.32.0 or newer is required, for the camelCase -json fields this script reads (found: govc 0.31.0)|2|jq 1.5 and govc 0.31.0 release binary, dry run: both named at once
real|rel-0.32.0|go|false|all|0||0|govc 0.32.0 release binary, real run
real|rel-0.32.0|go|true|all|0||0|govc 0.32.0 release binary, dry run
real|rel-0.54.0|go|true|vm|0||0|govc 0.54.0 release binary, dry run, --phase vm
real|rel-0.56.0|none|false|all|0||0|govc 0.56.0 release binary, no go on PATH (a release binary needs none), real run
real|rel-0.31.0|go|false|version-gate|0||0|govc 0.31.0 release binary, --phase version-gate (needs no govc, so none is checked)
real|goinst-v0.31.0|go|false|all|2|govc 0.32.0 or newer is required, for the camelCase -json fields this script reads (found: govc 0.0.0, built from govmomi v0.31.0 per 'go version -m')|1|go install govc@v0.31.0 (prints 0.0.0), real run
real|goinst-v0.32.0|go|true|all|0||0|go install govc@v0.32.0 (prints 0.0.0), dry run
real|goinst-v0.46.3|go|false|all|0||0|go install govc@v0.46.3, the last release go install builds, real run
real|goinst-v0.47.0-alpha.0|go|false|all|0||0|go install govc@v0.47.0-alpha.0, a pre-release newer than 0.32.0, real run
real|checkout-v0.56.0|go|false|all|0||0|v0.56.0 clone, cd govc && go install . (the govc module, at a pseudo-version), real run
real|checkout-v0.56.0|go|true|all|0||0|v0.56.0 clone, cd govc && go install . (the govc module, at a pseudo-version), dry run
real|checkout-v0.56.0-novcs|go|false|all|0||0|v0.56.0 clone, cd govc && go build -buildvcs=false . (the govc module, at (devel)), real run
real|checkout-v0.56.0|none|false|all|2|govc 0.32.0 or newer is required, and its version cannot be determined (found: govc 0.0.0; no go on PATH to read its build info with 'go version -m'): put go on PATH, or use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from 0.32.0 to 0.46.3|1|v0.56.0 clone build, no go on PATH, real run
real|checkout-v0.56.0|none|true|all|2|govc 0.32.0 or newer is required, and its version cannot be determined (found: govc 0.0.0; no go on PATH to read its build info with 'go version -m'): put go on PATH, or use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from 0.32.0 to 0.46.3|1|v0.56.0 clone build, no go on PATH, dry run
real|gobuild-v0.32.0|go|false|all|0||0|v0.32.0 clone, go build -o ../out/govc ./govc on the clean tag (govmomi v0.32.0), real run
real|gobuild-v0.32.0-dirty|go|false|all|0||0|v0.32.0 clone with an untracked file, go build -o ../out/govc ./govc (govmomi v0.32.0+dirty), real run
real|gobuild-v0.32.0-novcs|go|false|all|2|govc 0.32.0 or newer is required, and its version cannot be determined (found: govc 0.0.0; 'go version -m' gives github.com/vmware/govmomi (devel), which is not a release version): use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from 0.32.0 to 0.46.3|1|v0.32.0 clone, go build -buildvcs=false -o ../out/govc ./govc (govmomi (devel)), real run
real|gobuild-untagged|go|false|all|2|govc 0.32.0 or newer is required, and its version cannot be determined (found: govc 0.0.0; 'go version -m' gives github.com/vmware/govmomi v0.31.1-0.20231025064746-fc117d63069e, which is not a release version): use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from 0.32.0 to 0.46.3|1|clone at an untagged commit, go build -o ../out/govc ./govc (a pseudo-version, not 0.31.1), real run
real|dep-replace|go|false|all|2|govc 0.32.0 or newer is required, for the camelCase -json fields this script reads (found: govc 0.0.0, built from govmomi v0.31.0 per 'go version -m')|1|a module requiring govmomi v0.32.0 that replaces it with v0.31.0 (the "=>" version is compiled in), real run
real|shim|go|false|all|2|govc 0.32.0 or newer is required, and its version cannot be determined (found: govc 0.0.0; 'go version -m' cannot read Go build info from it (a wrapper script in front of govc has none)): use a govc release binary, or go install github.com/vmware/govmomi/govc@vX.Y.Z with X.Y.Z from 0.32.0 to 0.46.3|1|a shell-script shim in front of a go install build, real run
real|broken|none|false|all|2|govc 0.32.0 or newer is required, and its version cannot be read (found: fake govc: cannot execute binary file)|1|govc version fails (synthetic stub), real run
real|none|none|true|all|0|e2e-lab: WARNING: missing tool(s) that a real run needs: govc|0|govc missing, dry run: only a warning, as before
real|none|none|false|all|2|missing required tool(s): govc|1|govc missing, real run
EOF
    finish_case
  }

  # (c) AC-021: fewer visible provider sessions than the ProviderConfigs in use.
  case_c() {
    local label=$1 fixture=$2
    queue "$fixture"
    run_steady_state
    expect "$label: AC-021 = FAIL" cell_is 'AC-021|package' FAIL
    expect "$label: AC-018 unaffected (cluster and namespaced PASS)" \
      eval '[[ ${RESULT[AC-018|cluster]} == PASS && ${RESULT[AC-018|namespaced]} == PASS ]]'
    expect "$label: diagnostic names VSPHERE_USER, the reported userNames and the likely causes" \
      eval 'said "configured VSPHERE_USER: $VSPHERE_USER" && said "reports the govc session" && said "distinct userNames" && said Sessions.TerminateSession'
    expect "$label: diagnostic printed once, not once per sample" test "$(grep -c 'MEASUREMENT FAILURE' "$C/say.txt")" -eq 1
    show "[AC-021] "
    finish_case
  }
  case_c1() { case_c "0 visible, sessionList holds only govc's own session (no privilege)" "$(sessions_json "$U_NB")"; }
  case_c2() {
    SESSION_USER_MATCH=exact
    case_c "0 visible, E2E_SESSION_USER_MATCH=exact and vCenter reports $U_NB" "$PRE"
  }
  case_c3() { case_c "1 visible, 2 ProviderConfigs in use" "$(sessions_json "$U_NB" "$S_A" "$S_ADMIN")"; }

  # (d) AC-021 within bounds, and the upper bound still enforced.
  case_d1() {
    local lines
    queue "$PRE"
    run_steady_state
    expect "2 visible, 1 pod (allowed 2..2): AC-021 = PASS" cell_is 'AC-021|package' PASS
    expect "2 visible, 1 pod: 3 samples taken, no diagnostic" eval '[[ $(grep -c "^\[AC-021\] interval" "$C/say.txt") -eq 3 ]] && ! said "MEASUREMENT FAILURE"'
    show "[AC-021] interval 1:"
    lines=$(show "via $AGENT")
    head -n 2 <<<"$lines"
    finish_case
  }
  case_d2() {
    queue "$(sessions_json "$U_NB" "$S_A" "$S_B" "sess-c|$U_NB|$AGENT|2026-09-25T09:11:00Z")"
    run_steady_state
    expect "3 visible, 1 pod (allowed 2..2): AC-021 = FAIL (upper bound)" cell_is 'AC-021|package' FAIL
    finish_case
  }
  case_d3() {
    ALIVE=(namespaced)
    queue "$(sessions_json "$U_NB" "$S_B")"
    run_steady_state
    expect "only the namespaced VM Ready, 1 visible (allowed 1..2): AC-021 = PASS" cell_is 'AC-021|package' PASS
    finish_case
  }

  # (e) which vCenter userNames count as VSPHERE_USER's, through the script's own jq filter.
  case_e() {
    local names
    queue "$(sessions_json "$U_NB" \
      "pre-install-1|$U_NB|$AGENT|2026-09-25T07:00:00Z" \
      "s1|LAB\\svc-pioneer|$AGENT|2026-09-25T09:10:00Z" \
      "s2|LAB.LOCAL\\SVC-PIONEER|$AGENT|2026-09-25T09:10:01Z" \
      "s3|svc-pioneer@lab.local|$AGENT|2026-09-25T09:10:02Z" \
      "s4|Svc-Pioneer@LAB.local|$AGENT|2026-09-25T09:10:03Z" \
      "s5|LAB\\svc-other|$AGENT|2026-09-25T09:10:04Z" \
      "s6|CORP\\svc-pioneer|$AGENT|2026-09-25T09:10:05Z" \
      "s7|$U_ADMIN|Mozilla/5.0|2026-09-25T09:10:06Z" \
      "s8|svc-pioneer@corp.example.com|$AGENT|2026-09-25T09:10:07Z" \
      "s9|LAB\\svc-pioneer|govc/0.54.0|2026-09-25T09:10:08Z")"
    printf '  fixture userNames besides govc: s1 LAB\\svc-pioneer, s2 LAB.LOCAL\\SVC-PIONEER, s3 svc-pioneer@lab.local, s4 Svc-Pioneer@LAB.local, s5 LAB\\svc-other, s6 CORP\\svc-pioneer, s7 %s, s8 svc-pioneer@corp.example.com; excluded up front: pre-install-1 (baseline) and s9 (another govc process)\n' "$U_ADMIN"
    while IFS='|' read -r mode user want; do
      SESSION_USER_MATCH=$mode VSPHERE_USER=$user
      names=$(provider_session_records | jq -r '[.[].key] | join(",")')
      expect "$mode '$user' counts exactly [$want] -- $(session_user_rule)" test "$names" = "$want"
    done <<'EOF'
account|svc-pioneer@lab.local|s1,s2,s3,s4
account|LAB\svc-pioneer|s1,s2,s3,s4
account|SVC-PIONEER@LAB.LOCAL|s1,s2,s3,s4
account|svc-pioneer|s1,s2,s3,s4,s6,s8
account|administrator@vsphere.local|s7
exact|svc-pioneer@lab.local|s2,s3,s4
exact|LAB\svc-pioneer|s1
EOF
    SESSION_USER_MATCH=account VSPHERE_USER=svc-pioneer@lab.local
    names=$(provider_session_records | jq -r '[.[] | select(.key == "s5" or .key == "s6" or .key == "s7" or .key == "s8")] | length')
    expect "a different user never matches svc-pioneer@lab.local: LAB\\svc-other, CORP\\svc-pioneer, $U_ADMIN, svc-pioneer@corp.example.com" test "$names" -eq 0
    finish_case
  }

  # (f) AC-022 package-level finish: every pre-rotation key gone, and never a blind pass. The
  # finish runs after the rotation, so govc and the fake vCenter both hold the rotated password.
  case_f() {
    local label=$1 fixture=$2 want=$3
    VSPHERE_PASSWORD=$P_ROTATED
    printf '%s' "$P_ROTATED" >"$VC/password"
    ROTATE_STARTED=true PRE_ROTATION_SESSION_KEYS='["sess-a","sess-b"]'
    NEW_LOGIN_EPOCH=$(($(date -u +%s) - 5)) LOGOUT_DELAY_SECONDS=1 LOGOUT_SLACK_SECONDS=1
    queue "$fixture"
    run_ac022_rotation_finish
    expect "$label: AC-022 package = $want" cell_is 'AC-022|package' "$want"
    finish_case
  }
  case_f1() { case_f "finish, pre-rotation keys gone, 2 rebuilt clients visible" "$FINISH_CD" PASS; }
  case_f2() { case_f "finish, pre-rotation key sess-a still alive" "$(sessions_json "$U_NB" "$S_A" "$S_C" "$S_D")" FAIL; }
  case_f3() {
    case_f "finish, 0 provider sessions visible (blind)" "$(sessions_json "$U_NB" "$S_ADMIN")" FAIL
    expect "finish, 0 visible: measurement-failure diagnostic printed" said "[AC-022] MEASUREMENT FAILURE"
    finish_case
  }
  case_f4() { case_f "finish, govc session.ls fails" FAIL FAIL; }

  # deployments_json NS/NAME=IMAGE...: a `kubectl get deployments -A -o json` document, one
  # Deployment with one container per argument.
  deployments_json() {
    printf '%s\n' "$@" | jq -c -R -s '{items: [split("\n")[] | select(length > 0)
      | split("=") as [$nn, $img] | ($nn | split("/")) as [$ns, $n]
      | {metadata: {namespace: $ns, name: $n}, spec: {template: {spec: {containers: [{name: "main", image: $img}]}}}}]}'
  }
  # pf_stubs DEPLOYMENTS RELEASE CRD: stub kubectl and helm binaries in $C/pf, which pf_run puts
  # first on PATH for the script's own preflight, k and h. kubectl serves DEPLOYMENTS for `get
  # deployments -A -o json`, lists the providers.pkg.crossplane.io CRD when CRD is yes, and finds
  # nothing for any other get; helm status finds the crossplane release when RELEASE is yes. Any
  # other call fails. Both log every call to $C/pf/calls (arguments only, so no temp path).
  pf_stubs() {
    local d=$C/pf
    mkdir -p "$d"
    printf '%s\n' "$1" >"$d/deployments.json"
    if [[ $2 == yes ]]; then : >"$d/release"; fi
    if [[ $3 == yes ]]; then : >"$d/crd"; fi
    cat >"$d/kubectl" <<EOF
#!/bin/sh
echo "kubectl \$*" >>"$d/calls"
case " \$* " in
  *" get deployments -A -o json "*) cat "$d/deployments.json" ;;
  *" get $CRD_RES $PROVIDER_RES "*) if [ -e "$d/crd" ]; then echo "customresourcedefinition.apiextensions.k8s.io/$PROVIDER_RES"; fi ;;
  *" get "*) ;;
  *) echo "fixture kubectl: unexpected call: \$*" >&2; exit 99 ;;
esac
EOF
    cat >"$d/helm" <<EOF
#!/bin/sh
echo "helm \$*" >>"$d/calls"
case " \$* " in
  *" status $CP_RELEASE "*) if [ -e "$d/release" ]; then echo "NAME: $CP_RELEASE"; exit 0; fi; echo "Error: release: not found" >&2; exit 1 ;;
  *) echo "fixture helm: unexpected call: \$*" >&2; exit 99 ;;
esac
EOF
    chmod +x "$d/kubectl" "$d/helm"
    : >"$d/calls"
  }
  # pf_run: the script's own preflight with the script's own k and h and the pf_stubs binaries
  # first on PATH, in a subshell whose EXIT trap keeps ABORT_REASON (which the real run's report
  # prints). Sets PF_RC.
  pf_run() {
    k() { script_k "$@"; }
    h() { script_h "$@"; }
    unset E2E_VMFS_DATASTORE_ID
    E2E_DATASTORE_ID=datastore-1
    PF_RC=0
    (
      PATH=$C/pf:$SELFTEST_PATH
      trap 'printf "%s\n" "$ABORT_REASON" >"$C/pf/abort"' EXIT
      preflight
    ) >"$C/pf/out" 2>"$C/pf/err" || PF_RC=$?
  }
  pf_calls_read_only() { ! grep -qE ' (apply|create|delete|install|uninstall|upgrade|patch|label|annotate) ' "$C/pf/calls"; }
  pf_calls_pinned() { ! grep -qvE '^(kubectl --context lab-k3s |helm --kube-context lab-k3s )' "$C/pf/calls"; }
  PF_CRD_CHECK="kubectl --context lab-k3s get $CRD_RES $PROVIDER_RES --ignore-not-found -o name"

  # (p) The script's own preflight, k and h against stub kubectl and helm fixtures. Managed mode
  # installs its own Crossplane, so it must refuse (exit 2, nothing changed) on any sign of one:
  # a crossplane/crossplane Deployment, a crossplane Helm release in crossplane-system, or the
  # providers.pkg.crossplane.io CRD. --existing-crossplane keeps its own checks.
  case_p1() {
    EXISTING=false
    pf_stubs "$(deployments_json 'upbound-system/crossplane=xpkg.upbound.io/upbound/crossplane:v2.2.0' 'kube-system/coredns=registry.k8s.io/coredns/coredns:v1.12.0')" no yes
    pf_run
    expect "CRD only (foreign image and release names): refused with exit 2" test "$PF_RC" -eq 2
    expect "CRD only: names the CRD as the only sign found, and says nothing was changed" \
      eval 'grep -qF "(CRD $PROVIDER_RES)" "$C/pf/err" && grep -qF "nothing was changed" "$C/pf/err"'
    expect "CRD only: the run's report would name the refusal (ABORT_REASON)" \
      grep -qF "managed mode found Crossplane already present on context lab-k3s" "$C/pf/abort"
    expect "CRD only: the CRD check ran through the script's own kubectl wrapper" grep -qxF "$PF_CRD_CHECK" "$C/pf/calls"
    expect "CRD only: every kubectl and helm call is read-only and pinned to context lab-k3s" \
      eval 'pf_calls_read_only && pf_calls_pinned'
    expect "CRD only: stopped before the vm-phase checks (no namespace check, no vCenter login)" \
      eval '! grep -q " get namespace " "$C/pf/calls" && [[ ! -s $VC/auth.log ]]'
    sed 's/^/  stderr: /' "$C/pf/err"
    finish_case
  }
  case_p2() {
    EXISTING=false
    pf_stubs "$(deployments_json 'kube-system/coredns=registry.k8s.io/coredns/coredns:v1.12.0')" no no
    pf_run
    expect "nothing present: preflight proceeds (exit 0, nothing reported)" \
      eval '[[ $PF_RC -eq 0 && ! -s $C/pf/err ]]'
    expect "nothing present: it checked the Deployments, the Helm release and the CRD" \
      eval 'grep -qF "kubectl --context lab-k3s get deployments -A -o json" "$C/pf/calls" && grep -qF "helm --kube-context lab-k3s status $CP_RELEASE --namespace $CP_NS" "$C/pf/calls" && grep -qxF "$PF_CRD_CHECK" "$C/pf/calls"'
    expect "nothing present: every kubectl and helm call is read-only and pinned to context lab-k3s" \
      eval 'pf_calls_read_only && pf_calls_pinned'
    expect "nothing present: it went on to the vm-phase checks (namespace, vCenter, datastore type)" \
      eval 'grep -q " get namespace $NS " "$C/pf/calls" && said "Datastore datastore-1 type: VMFS"'
    finish_case
  }
  case_p3() {
    EXISTING=true
    pf_stubs "$(deployments_json 'crossplane-system/crossplane=xpkg.crossplane.io/crossplane/crossplane:v2.2.0')" yes yes
    pf_run
    expect "--existing-crossplane with the CRD present: preflight proceeds (exit 0, nothing reported)" \
      eval '[[ $PF_RC -eq 0 && ! -s $C/pf/err ]]'
    expect "--existing-crossplane: uses the running Crossplane" said "Existing Crossplane: xpkg.crossplane.io/crossplane/crossplane:v2.2.0"
    expect "--existing-crossplane: unchanged, it neither runs helm nor checks the CRD" \
      eval '! grep -q "^helm " "$C/pf/calls" && ! grep -qxF "$PF_CRD_CHECK" "$C/pf/calls"'
    finish_case
  }

  # (q) remove_provider waits for Crossplane to finish removing a Provider (no ProviderRevision,
  # no Deployment selecting it in crossplane-system, and, in managed mode, the Lock's own
  # finalizer cleared) before uninstall_crossplane runs helm uninstall. Driven for real, the same
  # way the (p) cases drive preflight: the script's own k/h wrappers, and stub kubectl/helm
  # fixtures first on PATH.
  # rp_stubs REVISION_GONE_AFTER DEPLOY_GONE LOCK_GONE [FAIL_DELETE [CRD_WAIT]]: stub kubectl and
  # helm in $C/rp.
  #   REVISION_GONE_AFTER: the call number (1-based) of `get providerrevisions ... -o name` at,
  #     and after, which no ProviderRevision is reported; 0 means it is never reported gone.
  #   DEPLOY_GONE / LOCK_GONE: yes/no, whether the Deployment / Lock finalizer already read as
  #     gone from the first call.
  #   FAIL_DELETE: provider or drc makes `kubectl delete` of this run's Provider or
  #     DeploymentRuntimeConfig fail as an unavailable API server does, and both are then still
  #     listed; none (the default) lets every delete succeed.
  #   CRD_WAIT: crd-timeout makes phase_vm's wait for the Crossplane package CRDs time out, as
  #     when the vm phase stops right after its helm install; ok (the default) lets it pass.
  # For the callers the (u) cases drive, it also answers the version gate's ProviderRevision
  # query with a revision the version constraint rejected, lists nothing for any other `get -o
  # name` (cleanup finds no VirtualMachine left), and takes `apply -f -`. helm upgrade --install
  # and helm uninstall of $CP_RELEASE always succeed. Every call is recorded (arguments only, no
  # temp path) to $C/rp/calls; any other call fails loudly (exit 99), as pf_stubs does.
  rp_stubs() {
    local d=$C/rp
    mkdir -p "$d"
    : >"$d/calls"
    printf '%s' "$1" >"$d/revision-gone-after"
    printf 0 >"$d/revision-calls"
    if [[ $2 == yes ]]; then : >"$d/deploy-gone"; fi
    if [[ $3 == yes ]]; then : >"$d/lock-gone"; fi
    printf '%s' "${4:-none}" >"$d/fail-delete"
    if [[ ${5:-ok} == crd-timeout ]]; then : >"$d/crd-timeout"; fi
    cat >"$d/kubectl" <<EOF
#!/bin/sh
echo "kubectl \$*" >>"$d/calls"
case " \$* " in
  *" wait --for=condition=Established crd/$PROVIDER_RES "*)
    if [ -e "$d/crd-timeout" ]; then echo 'error: timed out waiting for the condition on customresourcedefinitions/$PROVIDER_RES' >&2; exit 1; fi
    ;;
  *" delete $PROVIDER_RES "*)
    if [ "\$(cat "$d/fail-delete")" = provider ]; then echo 'Error from server (InternalError): etcdserver: request timed out' >&2; exit 1; fi
    ;;
  *" delete $DRC_RES "*)
    if [ "\$(cat "$d/fail-delete")" = drc ]; then echo 'Error from server (InternalError): etcdserver: request timed out' >&2; exit 1; fi
    ;;
  *" get $PROVIDER_RES,$DRC_RES -l "*)
    if [ "\$(cat "$d/fail-delete")" != none ]; then
      echo "provider.pkg.crossplane.io/$PROVIDER_NAME"
      echo "deploymentruntimeconfig.pkg.crossplane.io/$RUNTIME_CONFIG_NAME"
    fi
    ;;
  *" get $REVISION_RES -l pkg.crossplane.io/package=$PROVIDER_NAME -o json "*)
    echo '{"items":[{"status":{"conditions":[{"type":"Healthy","status":"False","reason":"UnhealthyPackageRevision","message":"incompatible Crossplane version: package is not compatible with Crossplane version (v1.20.13)"}]}}]}'
    ;;
  *" get $REVISION_RES -l pkg.crossplane.io/package=$PROVIDER_NAME -o name "*)
    n=\$(( \$(cat "$d/revision-calls") + 1 )); echo "\$n" >"$d/revision-calls"
    after=\$(cat "$d/revision-gone-after")
    if [ "\$after" = 0 ] || [ "\$n" -lt "\$after" ]; then echo "providerrevision.pkg.crossplane.io/$PROVIDER_NAME-0"; fi
    ;;
  *" -n $CP_NS get deployments -o json "*)
    if [ -e "$d/deploy-gone" ]; then
      echo '{"items":[]}'
    else
      echo '{"items":[{"metadata":{"name":"$PROVIDER_NAME-0","namespace":"$CP_NS"},"spec":{"selector":{"matchLabels":{"pkg.crossplane.io/provider":"$PROVIDER_NAME"}}}}]}'
    fi
    ;;
  *" get $LOCK_RES $LOCK_NAME -o json --ignore-not-found "*)
    if [ -e "$d/lock-gone" ]; then
      echo '{"metadata":{"name":"$LOCK_NAME","finalizers":[]}}'
    else
      echo '{"metadata":{"name":"$LOCK_NAME","finalizers":["lock.pkg.crossplane.io"]}}'
    fi
    ;;
  *" get "*" -o name "*) ;;
  *" apply -f - "*) cat >/dev/null ;;
  *" delete "*) ;;
  *) echo "fixture kubectl: unexpected call: \$*" >&2; exit 99 ;;
esac
EOF
    cat >"$d/helm" <<EOF
#!/bin/sh
echo "helm \$*" >>"$d/calls"
case " \$* " in
  *" upgrade --install $CP_RELEASE "*) exit 0 ;;
  *" uninstall $CP_RELEASE --namespace $CP_NS "*) exit 0 ;;
  *) echo "fixture helm: unexpected call: \$*" >&2; exit 99 ;;
esac
EOF
    chmod +x "$d/kubectl" "$d/helm"
  }
  # rp_run FUNC ARGS...: FUNC (the script's own remove_provider / uninstall_crossplane, or a
  # caller of them) with the script's own k/h wrappers, the script's own real (retrying,
  # sleeping) poll_until -- not the one-shot stub every other case uses -- and $C/rp's fixture
  # kubectl/helm first on PATH. Each wait is capped at 5s and its poll interval at 1s, which is
  # more than any case needs, so a regression fails its case instead of stalling it for the
  # script's own timeout (cleanup's 20m, the version gate's 5m). Sets RP_RC.
  rp_run() {
    k() { script_k "$@"; }
    h() { script_h "$@"; }
    poll_until() { script_poll_until "$(($1 < 5 ? $1 : 5))" "$(($2 < 1 ? $2 : 1))" "${@:3}"; }
    PATH=$C/rp:$SELFTEST_PATH
    RP_RC=0
    "$@" || RP_RC=$?
    PATH=$SELFTEST_PATH
  }
  # trap_run CMD...: CMD in a subshell whose EXIT trap is the script's own on_exit, armed as main
  # arms it, so the script's own cleanup and PASS/FAIL report run exactly as when a real run
  # ends. Its status is on_exit's exit code.
  trap_run() { (
    trap on_exit EXIT
    "$@"
  ); }
  # in_order FILE FRAGMENT...: each fragment is in FILE, each first on a later line than the one
  # before it. said_in_order FRAGMENT...: the same for what the script said.
  in_order() {
    local file=$1 f out n last=0
    shift
    for f in "$@"; do
      out=$(grep -nF -- "$f" "$file") || return 1
      n=${out%%:*}
      ((n > last)) || return 1
      last=$n
    done
  }
  said_in_order() { in_order "$C/say.txt" "$@"; }
  RECOVERY_HEAD="Recovery, on this dedicated lab cluster only, in this order:"
  # The recovery steps, as they must appear for run t0 on context lab-k3s.
  STEP_REDELETE="kubectl --context lab-k3s delete $PROVIDER_RES,$DRC_RES -l $RUN_LABEL_KEY=t0"
  STEP_WAIT_REVISION="kubectl --context lab-k3s get $REVISION_RES -l pkg.crossplane.io/package=$PROVIDER_NAME"
  STEP_UNINSTALL="helm --kube-context lab-k3s uninstall $CP_RELEASE --namespace $CP_NS"
  STEP_WAIT_DEPLOY="kubectl --context lab-k3s -n $CP_NS get deployments -o wide"
  STEP_WAIT_LOCK="kubectl --context lab-k3s get $LOCK_RES $LOCK_NAME -o jsonpath='{.metadata.finalizers}'"
  STEP_FINALIZER="only if an object is still stuck after Crossplane is gone, and only on this dedicated lab cluster, clear its finalizer by hand: kubectl --context lab-k3s patch <TYPE> <NAME>"
  STEP_PATCH="kubectl --context lab-k3s patch <TYPE> <NAME> -p '{\"metadata\":{\"finalizers\": []}}' --type=merge"
  # Existing mode never uninstalls Crossplane, whose running controllers remove these finalizers
  # themselves (the Lock's own one only once no package is left), so there the patch is a last
  # resort, after the Crossplane pod logs, that the shared installation's operator decides on.
  STEP_FINALIZER_EXISTING="only as a last resort, if the ProviderRevision is still there after that wait: the running Crossplane removes it from the Lock and drops its revision.pkg.crossplane.io finalizer itself (its Deployment then goes by garbage collection), so check the Crossplane pod logs first (kubectl --context lab-k3s -n $CP_NS logs deploy/$CP_RELEASE); only if they show it cannot finish, only on this dedicated lab cluster, and only if you, as the operator of this shared Crossplane, decide to, clear the leftover finalizer by hand: $STEP_PATCH. Never clear the Lock's own lock.pkg.crossplane.io finalizer: Crossplane keeps it while any other package is installed"
  case_q1() {
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=5 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0
    rp_stubs 3 yes yes
    rp_run remove_provider
    expect "revision gone after 3 polls: remove_provider itself returns 0 (deletes were issued)" test "$RP_RC" -eq 0
    expect "revision gone after 3 polls: remove_provider's wait succeeded" test "$PROVIDER_REMOVAL_OK" = true
    expect "revision gone after 3 polls: it polled the ProviderRevision 3 times before succeeding" \
      test "$(cat "$C/rp/revision-calls")" -eq 3
    expect "revision gone after 3 polls: no helm call yet" eval '! grep -q "^helm " "$C/rp/calls"'
    rp_run uninstall_crossplane
    expect "revision gone after 3 polls: uninstall_crossplane returns 0" test "$RP_RC" -eq 0
    expect "revision gone after 3 polls: helm uninstall then runs, exactly once" \
      test "$(grep -cE "^helm .*uninstall $CP_RELEASE --namespace $CP_NS" "$C/rp/calls")" -eq 1
    expect "revision gone after 3 polls: cleanup is not marked incomplete" test "$CLEANUP_OK" = true
    finish_case
  }
  case_q2() {
    # Managed mode: this run installed the Crossplane it would uninstall.
    CP_INSTALLED_BY_RUN=true
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 yes yes
    rp_run remove_provider 2>"$C/err.txt"
    expect "revision never gone: remove_provider itself still returns 0 (the wait's outcome never fails the caller)" \
      test "$RP_RC" -eq 0
    expect "revision never gone: remove_provider's wait failed" test "$PROVIDER_REMOVAL_OK" = false
    expect "revision never gone: remove_provider itself marks cleanup incomplete and warns" \
      eval '[[ $CLEANUP_OK == false ]] && grep -qF "Crossplane has not finished removing $PROVIDER_NAME within E2E_PROVIDER_REMOVAL_TIMEOUT=1s; cleanup is incomplete" "$C/err.txt"'
    rp_run uninstall_crossplane 2>>"$C/err.txt"
    expect "revision never gone: uninstall_crossplane returns 1" test "$RP_RC" -eq 1
    expect "revision never gone: helm uninstall never ran" eval '! grep -q "^helm " "$C/rp/calls"'
    expect "revision never gone: cleanup is marked incomplete" test "$CLEANUP_OK" = false
    expect "revision never gone: it names the leftover ProviderRevision" \
      said "ProviderRevision still present: providerrevision.pkg.crossplane.io/$PROVIDER_NAME-0"
    expect "revision never gone: the recovery, in order: Crossplane logs and wait for no ProviderRevision, then helm uninstall, then (only with Crossplane gone) the finalizer patch" \
      eval 'said_in_order "$RECOVERY_HEAD" "$STEP_WAIT_REVISION" "$STEP_UNINSTALL" "$STEP_FINALIZER" && said "logs deploy/$CP_RELEASE) and wait until"'
    expect "revision never gone: the patch recipe is the merge patch that empties finalizers" \
      said "-p '{\"metadata\":{\"finalizers\": []}}' --type=merge"
    expect "revision never gone: a longer timeout is offered only for next time, never as this cluster's recovery" \
      eval 'said "Next time, a longer E2E_PROVIDER_REMOVAL_TIMEOUT (this run: 1s)" && ! said "raise E2E_PROVIDER_REMOVAL_TIMEOUT"'
    expect "revision never gone: the recovery's wait step also waits for no provider Deployment and the Lock finalizer cleared, as the automated wait does" \
      eval 'said "$STEP_WAIT_DEPLOY" && said "$STEP_WAIT_LOCK"'
    expect "revision never gone: the recovery is printed once, by remove_provider (uninstall_crossplane only skips)" \
      test "$(grep -cF "$RECOVERY_HEAD" "$C/say.txt")" -eq 1
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }
  case_q3() {
    DRY_RUN=true
    rp_run remove_provider
    expect "dry run: remove_provider returns 0" test "$RP_RC" -eq 0
    expect "dry run: the wait is printed as a plan line" said "poll every"
    expect "dry run: it names what the wait is for" said "Crossplane has finished removing $PROVIDER_NAME"
    finish_case
  }
  case_q4() {
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=5 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0
    rp_stubs 1 yes yes
    rp_run eval 'remove_provider && uninstall_crossplane'
    expect "version-gate teardown: the combined call returns 0" test "$RP_RC" -eq 0
    expect "version-gate teardown: remove_provider's wait succeeded on the first poll" test "$PROVIDER_REMOVAL_OK" = true
    expect "version-gate teardown: helm uninstall ran" eval 'grep -qE "^helm .*uninstall $CP_RELEASE --namespace $CP_NS" "$C/rp/calls"'
    expect "version-gate teardown: cleanup is not marked incomplete" test "$CLEANUP_OK" = true
    finish_case
  }
  case_q5() {
    EXISTING=true
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=5 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0
    rp_stubs 1 yes no
    rp_run remove_provider
    expect "existing mode: remove_provider returns 0" test "$RP_RC" -eq 0
    expect "existing mode: remove_provider's wait succeeds without the Lock ever clearing" test "$PROVIDER_REMOVAL_OK" = true
    expect "existing mode: it never checks the Lock's finalizer" eval '! grep -q "get $LOCK_RES $LOCK_NAME" "$C/rp/calls"'
    expect "existing mode: remove_provider itself never calls helm" eval '! grep -q "^helm " "$C/rp/calls"'
    finish_case
  }

  # (u) The callers of remove_provider and uninstall_crossplane, through the script's own code
  # paths and the rp_stubs fixtures: cleanup, through the script's own on_exit as at the end of a
  # real run (trap_run), and phase_version_gate followed by phase_vm, as main runs them. The (q)
  # cases above drive the two functions directly; these check that their callers act on the
  # outcome.
  # (u1) Managed mode, and the run's Provider delete fails, so remove_provider's wait never
  # starts: Crossplane may still hold the revision, so helm uninstall must not run.
  case_u1() {
    STARTED=true CLUSTER_TOUCHED=true PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=true
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 yes no provider
    rp_run trap_run true 2>"$C/err.txt"
    expect "Provider delete fails: the run exits 1" test "$RP_RC" -eq 1
    expect "Provider delete fails: no helm call at all, so Crossplane stays installed" eval '! grep -q "^helm " "$C/rp/calls"'
    expect "Provider delete fails: the kubectl error and a cleanup-incomplete warning are shown" \
      eval 'grep -qF "etcdserver: request timed out" "$C/err.txt" && grep -qF "Provider or DeploymentRuntimeConfig; cleanup is incomplete" "$C/err.txt"'
    expect "Provider delete fails: it names the Provider and DeploymentRuntimeConfig still present" \
      said "still present: provider.pkg.crossplane.io/$PROVIDER_NAME, deploymentruntimeconfig.pkg.crossplane.io/$RUNTIME_CONFIG_NAME"
    expect "Provider delete fails: the recovery, in order: delete again, Crossplane logs and wait for no ProviderRevision, helm uninstall, then the finalizer patch" \
      said_in_order "$RECOVERY_HEAD" "$STEP_REDELETE" "$STEP_WAIT_REVISION" "$STEP_UNINSTALL" "$STEP_FINALIZER"
    expect "Provider delete fails: the report says CLEANUP INCOMPLETE and Result: FAIL" \
      eval 'said "CLEANUP INCOMPLETE" && said "Result: FAIL"'
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }
  # (u2) --existing-crossplane, and the ProviderRevision and its Deployment never go away. This
  # mode has no helm uninstall to skip, so remove_provider itself must mark cleanup incomplete:
  # the run must not report PASS and exit 0 with the provider still running.
  case_u2() {
    EXISTING=true STARTED=true CLUSTER_TOUCHED=true PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=false
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 no no
    rp_run trap_run true 2>"$C/err.txt"
    expect "existing mode, revision never gone: the run exits 1, not 0" test "$RP_RC" -eq 1
    expect "existing mode, revision never gone: the report says CLEANUP INCOMPLETE and ends Result: FAIL" \
      eval 'said "CLEANUP INCOMPLETE" && said "Result: FAIL" && ! said "Result: PASS"'
    expect "existing mode, revision never gone: it names the leftover ProviderRevision and Deployment" \
      eval 'said "ProviderRevision still present: providerrevision.pkg.crossplane.io/$PROVIDER_NAME-0" && said "Deployment in $CP_NS still selecting it: $PROVIDER_NAME-0"'
    expect "existing mode, revision never gone: the recovery leaves the existing Crossplane installed, and offers the finalizer patch only as a last resort after the Crossplane logs" \
      said_in_order "$RECOVERY_HEAD" "$STEP_WAIT_REVISION" "leave Crossplane installed: it is not this run" "$STEP_FINALIZER_EXISTING"
    expect "existing mode, revision never gone: the recovery gives no helm command" eval '! said "helm --kube-context"'
    expect "existing mode, revision never gone: no step waits for Crossplane to be gone, which this mode never makes happen" \
      eval '! said "after Crossplane is gone"'
    expect "existing mode, revision never gone: the recovery waits for no provider Deployment, not for the Lock finalizer, which other packages keep" \
      eval 'said "$STEP_WAIT_DEPLOY" && ! said "$LOCK_RES"'
    expect "existing mode, revision never gone: no helm call, and the Lock is never checked" \
      eval '! grep -q "^helm " "$C/rp/calls" && ! grep -q "get $LOCK_RES" "$C/rp/calls"'
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }
  # (u3) The version gate, and the ProviderRevision never goes away, so the gate cannot uninstall
  # Crossplane 1.20.13. Run as main runs it (phase_vm next), the run must stop in the gate: no helm
  # upgrade of that legacy release to Crossplane v2, and the EXIT trap's cleanup reports cleanup
  # incomplete without trying the uninstall again.
  case_u3() {
    STARTED=true LEGACY_VERSION=1.20.13
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 yes no
    rp_run trap_run eval 'phase_version_gate; phase_vm' 2>"$C/err.txt"
    expect "gate teardown times out: the run exits 1" test "$RP_RC" -eq 1
    expect "gate teardown times out: the gate itself passed (AC-008 = PASS in the report)" \
      grep -qE '^AC-008 .*[|] PASS +$' "$C/say.txt"
    expect "gate teardown times out: the run stops in the gate, naming Crossplane 1.20.13" \
      said "ABORTED: the version gate could not uninstall Crossplane 1.20.13"
    expect "gate teardown times out: exactly one helm install, of Crossplane 1.20.13" \
      eval '[[ $(grep -c "^helm .* upgrade --install " "$C/rp/calls") -eq 1 ]] && grep -q -- "--version 1.20.13 " "$C/rp/calls"'
    expect "gate teardown times out: no Crossplane v2 install follows (no helm call names 2.2.0)" \
      eval '! grep -q "2\.2\.0" "$C/rp/calls"'
    expect "gate teardown times out: no helm uninstall, in the gate or in the EXIT trap's cleanup" \
      eval '! grep -q "^helm .* uninstall " "$C/rp/calls"'
    expect "gate teardown times out: the trap's report says CLEANUP INCOMPLETE and Result: FAIL" \
      eval 'said "CLEANUP INCOMPLETE" && said "Result: FAIL"'
    expect "gate teardown times out: the recovery, printed once, gives the helm uninstall after the wait for no ProviderRevision" \
      eval 'said_in_order "$RECOVERY_HEAD" "$STEP_WAIT_REVISION" "$STEP_UNINSTALL" "$STEP_FINALIZER" && [[ $(grep -cF "$RECOVERY_HEAD" "$C/say.txt") -eq 1 ]]'
    sed 's/^/  stderr: /' "$C/err.txt"
    finish_case
  }
  # (u4) The plan a dry run prints (RELEASING.md section 8 has you read it before the real run):
  # what follows the provider-removal wait, and which Crossplane the run installs, per mode.
  case_u4() {
    local p
    DRY_RUN=true REQUIRE_AC022=false ROTATED_PASSWORD="" LEGACY_VERSION=1.20.13 FIRMWARE=bios
    PROVIDER_REMOVAL_TIMEOUT_RAW=10m
    E2E_RESOURCE_POOL_ID=resgroup-1 E2E_DATASTORE_ID=datastore-1 E2E_NETWORK_ID=dvportgroup-1
    E2E_TEMPLATE_UUID=42000000-0000-0000-0000-000000000000 E2E_GUEST_ID=ubuntu64Guest E2E_FOLDER=e2e
    unset E2E_HOST_SYSTEM_ID E2E_DISK_GB E2E_DATACENTER
    EXISTING=true PHASE=all
    print_plan 3>"$C/plan-existing.txt"
    EXISTING=false PHASE=version-gate
    print_plan 3>"$C/plan-gate.txt"
    EXISTING=false PHASE=all
    print_plan 3>"$C/plan-managed.txt"
    for p in existing gate managed; do
      grep -F -e "  crossplane       :" -e "  provider removal :" "$C/plan-$p.txt" | sed "s/^/           | $p:/" || true
    done
    expect "existing mode: the provider removal line says no helm uninstall follows the wait" \
      grep -qF "provider removal : after deleting the Provider this run applied, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=10m for the existing Crossplane to finish removing it; no helm uninstall follows" "$C/plan-existing.txt"
    expect "existing mode: every plan line that mentions helm uninstall says none follows" \
      eval '[[ $(grep -cF "helm uninstall" "$C/plan-existing.txt") -eq $(grep -cF "no helm uninstall" "$C/plan-existing.txt") ]]'
    expect "version-gate only: the Crossplane line names only Crossplane 1.20.13, the one this phase installs" \
      eval 'grep -qF "  crossplane       : managed: installs only Crossplane 1.20.13 with helm" "$C/plan-gate.txt" && ! grep -qF "2.2.0" "$C/plan-gate.txt"'
    expect "version-gate only: the gate step says the run stops there if its teardown does not complete" \
      grep -qF "if that teardown does not complete, the run stops there" "$C/plan-gate.txt"
    expect "managed, --phase all: the Crossplane line names 1.20.13 for the gate, then v2.2.0" \
      grep -qF "  crossplane       : managed: installs Crossplane 1.20.13 with helm for the version gate and uninstalls it, then installs Crossplane v2.2.0" "$C/plan-managed.txt"
    expect "managed, --phase all: helm uninstall follows the wait only once it succeeds" \
      grep -qF "for Crossplane to finish removing it, and only then helm uninstall Crossplane; if the wait runs out, Crossplane is left installed" "$C/plan-managed.txt"
    finish_case
  }
  # plan_env: the print_plan inputs resolve_settings and validate leave for a dry run with the
  # required vm-phase environment set, on top of setup's.
  plan_env() {
    DRY_RUN=true REQUIRE_AC022=false ROTATED_PASSWORD="" FIRMWARE=bios PROVIDER_REMOVAL_TIMEOUT_RAW=10m
    E2E_RESOURCE_POOL_ID=resgroup-1 E2E_DATASTORE_ID=datastore-1 E2E_NETWORK_ID=dvportgroup-1
    E2E_TEMPLATE_UUID=42000000-0000-0000-0000-000000000000 E2E_GUEST_ID=ubuntu64Guest E2E_FOLDER=e2e
    unset E2E_HOST_SYSTEM_ID E2E_DISK_GB E2E_DATACENTER
  }
  # versions_of TEXT: the X.Y.Z versions in TEXT, in order, space-separated.
  versions_of() {
    local s=$1 out=""
    while [[ $s =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; do
      out+="${out:+ }${BASH_REMATCH[0]}"
      s=${s#*"${BASH_REMATCH[0]}"}
    done
    printf '%s' "$out"
  }
  # (u5) The report's first line names the Crossplane the run uses, per phase and mode, as the
  # plan's "crossplane" line does: a version-gate-only run installs only Crossplane 1.20.13, even
  # with E2E_CROSSPLANE_VERSION=2.4.2 as RELEASING.md section 8 runs it; a vm-only run only
  # v2.4.2; --phase all both; existing mode none. The script's own print_report and print_plan
  # print both lines, and each row checks the report's exact header and that it names the same
  # Crossplane versions as the plan.
  case_u5() {
    local p existing phase want head seg plan_line
    plan_env
    XP_VERSION=2.4.2 LEGACY_VERSION=1.20.13
    record AC-008 package PASS
    while IFS='|' read -r p existing phase want; do
      EXISTING=$existing PHASE=$phase
      print_report 3>"$C/report-$p.txt"
      print_plan 3>"$C/plan-$p.txt"
      head=$(grep -F "== e2e-lab report:" "$C/report-$p.txt") || head=""
      plan_line=$(grep -F "  crossplane       :" "$C/plan-$p.txt") || plan_line=""
      printf '           | %s: %s\n' "$p" "$head"
      expect "$p: the report header says Crossplane $want" \
        test "$head" = "== e2e-lab report: run t0, context lab-k3s, Crossplane $want, package $PACKAGE"
      seg=${head#*, Crossplane }
      seg=${seg%, package *}
      expect "$p: the report header and the plan's crossplane line name the same Crossplane versions ($(versions_of "${plan_line#*: }"))" \
        test "$(versions_of "$seg")" = "$(versions_of "${plan_line#*: }")"
    done <<'EOF'
version-gate only|false|version-gate|managed 1.20.13 (version gate only)
vm only|false|vm|managed v2.4.2
all|false|all|managed 1.20.13 (version gate), then v2.4.2
existing|true|all|existing
EOF
    finish_case
  }
  # (u6) The other plan steps and end-of-run lines that depend on the phase, the mode or
  # --skip-cleanup. Only the vm phase's preflight checks the namespace. An existing Crossplane is
  # tested at whatever v2 release it runs, so the plan does not state the requested version as
  # its version. --skip-cleanup skips the cleanup step. And under --skip-cleanup, on_exit (run as
  # main arms it) says nothing labelled with the run's label is left once the version gate removed
  # its own Provider and Crossplane, and names what uninstalling that Crossplane 1.20.13 leaves;
  # and it lists VM, ProviderConfig, namespace and Secret deletes only once the vm phase created
  # them (the state flags NS_CREATED and VMS_APPLIED).
  case_u6() {
    local step1 end
    plan_env
    XP_VERSION=2.4.2
    EXISTING=false PHASE=version-gate
    print_plan 3>"$C/plan-gate.txt"
    step1=$(grep -E '^  1\. preflight' "$C/plan-gate.txt") || step1=""
    printf '           | version-gate only:%s\n' "$step1"
    expect "version-gate only: the preflight step names no namespace check (only the vm phase's preflight checks it)" \
      eval '[[ -n $step1 ]] && ! contains "$step1" "namespace"'
    EXISTING=false PHASE=vm
    print_plan 3>"$C/plan-vm.txt"
    expect "vm only: the preflight step names the namespace check" grep -qE "^  1\. preflight .*or namespace $NS;" "$C/plan-vm.txt"
    expect "vm only, managed: the Crossplane step installs v2.4.2" \
      grep -qF "Crossplane v2.4.2: managed: installs Crossplane v2.4.2 with helm and uninstalls it at the end" "$C/plan-vm.txt"
    expect "vm only: without --skip-cleanup, the last step is the cleanup" grep -qE '^  [0-9]+\. cleanup, then the PASS/FAIL report$' "$C/plan-vm.txt"
    EXISTING=true PHASE=vm
    print_plan 3>"$C/plan-existing.txt"
    grep -E '^  [0-9]+\. Crossplane' "$C/plan-existing.txt" | sed 's/^/           | existing:/' || true
    expect "existing: the Crossplane step does not state the requested v2.4.2 as the existing Crossplane's version" \
      eval '! grep -qE "^  [0-9]+\. Crossplane v" "$C/plan-existing.txt" && grep -qF "Crossplane: existing installation in $CP_NS; this script never installs" "$C/plan-existing.txt"'
    EXISTING=false PHASE=vm SKIP_CLEANUP=true
    print_plan 3>"$C/plan-skip.txt"
    expect "--skip-cleanup: the last step says there is no cleanup, and no step says cleanup runs" \
      eval 'grep -qE "^  [0-9]+\. no cleanup \(--skip-cleanup\): list what this run left in place, if anything, and the commands to remove it; then the PASS/FAIL report$" "$C/plan-skip.txt" && ! grep -qF "cleanup, then the PASS/FAIL report" "$C/plan-skip.txt"'
    # End of run under --skip-cleanup, through the script's own on_exit.
    DRY_RUN=false STARTED=true CLUSTER_TOUCHED=true SKIP_CLEANUP=true
    record AC-008 package PASS
    # As the version gate leaves them: it installed Crossplane 1.20.13, then uninstalled it.
    EXISTING=false PHASE=version-gate PROVIDER_APPLIED=false NS_CREATED=false CP_INSTALLED_BY_RUN=false
    CP_INSTALLED_NAME="Crossplane 1.20.13" LEGACY_WEBHOOK_LEFT=true GATE_TEARDOWN=finished
    trap_run true 3>"$C/end-gate.txt" 2>"$C/end-gate.err" || true
    end=$(grep -F -- "--skip-cleanup:" "$C/end-gate.txt") || end=""
    printf '           | version gate only, torn down: %s\n' "$end"
    expect "--skip-cleanup after a version gate that removed its own Provider and Crossplane: says nothing labelled is left and what uninstalling Crossplane 1.20.13 leaves, lists no manual cleanup" \
      eval '[[ $end == "--skip-cleanup: nothing labelled $RUN_LABEL_KEY=t0 is left in place: the version gate removed its own Provider and DeploymentRuntimeConfig and uninstalled Crossplane 1.20.13, as it does even with --skip-cleanup. $REMAINDER_1X" ]] && ! grep -qF "Manual cleanup" "$C/end-gate.txt" && ! grep -qF "left in place" "$C/end-gate.err"'
    PHASE=vm PROVIDER_APPLIED=true NS_CREATED=false CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"
    LEGACY_WEBHOOK_LEFT=false GATE_TEARDOWN=""
    trap_run true 3>"$C/end-early.txt" 2>"$C/end-early.err" || true
    expect "--skip-cleanup before the vm phase created its namespace: the Provider and helm uninstall lines, no VM, ProviderConfig or namespace delete" \
      eval 'grep -qF "this run leaves in place whichever of these it created: Provider $PROVIDER_NAME and DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME; Crossplane v2.4.2, which this run installed" "$C/end-early.err" && grep -qxF "Manual cleanup, on this dedicated lab cluster only, in this order:" "$C/end-early.txt" && grep -qF "delete $PROVIDER_RES,$DRC_RES -l $RUN_LABEL_KEY=t0" "$C/end-early.txt" && grep -qF "helm --kube-context lab-k3s uninstall $CP_RELEASE" "$C/end-early.txt" && ! grep -qF -e "$VM_RES_CLUSTER" -e "delete namespace" -e "$PC_RES_CLUSTER" "$C/end-early.txt"'
    NS_CREATED=true VMS_APPLIED=true
    trap_run true 3>"$C/end-vm.txt" 2>"$C/end-vm.err" || true
    expect "--skip-cleanup after the vm phase created its objects: the VM deletes come first, while the provider still runs" \
      eval 'grep -qF "Manual cleanup, on this dedicated lab cluster only, in this order (the provider must still run while VMs are deleted):" "$C/end-vm.txt" && grep -qF "delete $VM_RES_CLUSTER -l $RUN_LABEL_KEY=t0" "$C/end-vm.txt"'
    finish_case
  }
  # in_text_order TEXT FRAGMENT...: TEXT holds each fragment, each after the one before it.
  in_text_order() {
    local s=$1 f
    shift
    for f in "$@"; do
      [[ $s == *"$f"* ]] || return 1
      s=${s#*"$f"}
    done
  }
  # (u7) Every manual list gives the automated teardown's steps in its order (cleanup, then
  # remove_provider, then uninstall_crossplane): delete this run's Provider and
  # DeploymentRuntimeConfig; wait until Crossplane has finished removing the provider (no
  # ProviderRevision, no Deployment selecting it and, in managed mode, the Lock's own finalizer
  # cleared); only then, and in managed mode only, helm uninstall; last, only once Crossplane is
  # gone and only on a dedicated lab cluster, the finalizer patch. Checked on the manual cleanup
  # list the script's own on_exit prints under --skip-cleanup (managed and existing mode), on
  # uninstall_crossplane's warning, and on RELEASING.md section 8's between-runs commands.
  case_u7() {
    local w f rel_q='"$KUBE_CONTEXT"'
    local -a rel=()
    DRY_RUN=false STARTED=true CLUSTER_TOUCHED=true SKIP_CLEANUP=true
    EXISTING=false PHASE=vm PROVIDER_APPLIED=true NS_CREATED=true VMS_APPLIED=true CP_INSTALLED_BY_RUN=true
    CP_INSTALLED_NAME="Crossplane v2.2.0"
    trap_run true 2>"$C/err.txt" || true
    sed -n '/^Manual cleanup/,/clear its finalizer/p' "$C/say.txt" | sed 's/^/           | /'
    expect "managed: the manual list deletes the VMs, then the Provider and DeploymentRuntimeConfig, waits, only then runs helm uninstall, and patches finalizers last" \
      said_in_order "Manual cleanup, on this dedicated lab cluster only, in this order (the provider must still run while VMs are deleted):" \
      "delete $VM_RES_CLUSTER -l $RUN_LABEL_KEY=t0" "$STEP_REDELETE" "$STEP_WAIT_REVISION" "$STEP_UNINSTALL" "$STEP_FINALIZER"
    w=$(grep -F "$STEP_WAIT_REVISION" "$C/say.txt") || w=""
    expect "managed: the wait step also waits for no provider Deployment and the Lock finalizer cleared, as the automated wait does" \
      in_text_order "$w" "$STEP_WAIT_REVISION" "$STEP_WAIT_DEPLOY" "$STEP_WAIT_LOCK"
    expect "managed: the helm uninstall step comes only then" said "only then uninstall the Crossplane this run installed, which the script leaves in place: $STEP_UNINSTALL"
    EXISTING=true CP_INSTALLED_BY_RUN=false
    trap_run true 3>"$C/existing.txt" 2>"$C/existing.err" || true
    expect "existing: the manual list waits, then leaves Crossplane installed, gives no helm command, and ends with the last-resort finalizer step" \
      eval 'in_order "$C/existing.txt" "$STEP_REDELETE" "$STEP_WAIT_REVISION" "leave Crossplane installed: it is not this run" "$STEP_FINALIZER_EXISTING" && ! grep -qF "helm " "$C/existing.txt"'
    expect "existing: no step waits for Crossplane to be gone, which this mode never makes happen" \
      eval '! grep -qF "after Crossplane is gone" "$C/existing.txt"'
    expect "existing: the wait step waits for no provider Deployment, not for the Lock finalizer, which other packages keep" \
      eval 'grep -qF "$STEP_WAIT_DEPLOY" "$C/existing.txt" && ! grep -qF "$LOCK_RES" "$C/existing.txt"'
    EXISTING=false CP_INSTALLED_BY_RUN=true PROVIDER_REMOVAL_OK=false
    uninstall_crossplane 2>"$C/warn.txt" || true
    w=$(grep -F "skipping helm uninstall" "$C/warn.txt") || w=""
    expect "uninstall_crossplane, removal not finished: its warning gives the same wait, and only then the helm uninstall" \
      in_text_order "$w" "$STEP_WAIT_REVISION" "$STEP_WAIT_DEPLOY" "$STEP_WAIT_LOCK" "only then run: $STEP_UNINSTALL"
    sed -n '/^## 8\./,/^## 9\./p' RELEASING.md >"$C/section8.txt"
    for f in "$STEP_WAIT_REVISION" "$STEP_WAIT_DEPLOY" "$STEP_WAIT_LOCK" "$STEP_UNINSTALL" "$STEP_PATCH"; do
      f=${f//--context lab-k3s/--context $rel_q}
      rel+=("${f//--kube-context lab-k3s/--kube-context $rel_q}")
    done
    expect "RELEASING.md section 8 gives the same commands in the same order: the three waits, then helm uninstall, then the finalizer patch" \
      in_order "$C/section8.txt" "${rel[@]}"
    finish_case
  }

  # --- (u8)-(u13): what the run says about --skip-cleanup, over the state matrix ---
  PROVIDER_DELETE_STEP="delete this run's Provider and DeploymentRuntimeConfig"
  # What the end of a run that installed Crossplane says its uninstall leaves (crossplane_remainder),
  # for run t0 on context lab-k3s: after a Crossplane 1.x (the version gate), and after a Crossplane
  # v2 install, whose init container deletes the 1.x webhook configuration crossplane.
  REMAINDER_HEAD="Uninstalling Crossplane leaves what its init container and helm --create-namespace made, which carries no run label: the *.crossplane.io CRDs, the"
  REMAINDER_TAIL="and namespace $CP_NS. A later managed run on context lab-k3s refuses to start while those CRDs remain: remove all of it as RELEASING.md section 8 shows, or use a fresh cluster"
  REMAINDER_1X="$REMAINDER_HEAD ValidatingWebhookConfigurations crossplane and crossplane-no-usages, $REMAINDER_TAIL"
  REMAINDER_V2="$REMAINDER_HEAD ValidatingWebhookConfiguration crossplane-no-usages, $REMAINDER_TAIL"
  # end_of_run FILE...: what each FILE holds from the end of the run's phases on, that is from its
  # "== Cleanup:" line or its --skip-cleanup summary (said, or warned on stderr) to its end, so no
  # plan line counts.
  end_of_run() {
    local f
    for f in "$@"; do
      awk '/^== Cleanup:/ || /^--skip-cleanup/ || /^e2e-lab: WARNING: --skip-cleanup:/ { on = 1 } on' "$f"
    done
  }
  # names_remainder LINE: LINE names what uninstalling Crossplane leaves: the *.crossplane.io CRDs,
  # a ValidatingWebhookConfiguration, namespace crossplane-system, and that a later managed run on
  # this context refuses to start.
  names_remainder() {
    contains "$1" "*.crossplane.io CRDs" && contains "$1" "ValidatingWebhookConfiguration" &&
      contains "$1" "namespace $CP_NS" && contains "$1" "A later managed run on context lab-k3s refuses to start"
  }
  # remainder_stated TEXT: the end of a run that installed Crossplane says what its uninstall
  # leaves (some line names_remainder), and no line of it says nothing is left ("nothing ... left",
  # "leaves nothing") without naming that remainder too.
  remainder_stated() {
    local line named=false re='nothing.*left|leaves nothing'
    while IFS= read -r line; do
      if names_remainder "$line"; then
        named=true
      elif [[ $line =~ $re ]]; then
        return 1
      fi
    done <<<"$1"
    [[ $named == true ]]
  }
  # remainder_absent TEXT: no line of TEXT names a Crossplane remainder (a run that installed none).
  remainder_absent() {
    local line
    while IFS= read -r line; do
      ! names_remainder "$line" || return 1
    done <<<"$1"
  }
  # step_kinds FILE: one word per numbered step of the last "Manual cleanup" list in FILE, in
  # order, so a case compares the whole ordered list with the steps it expects.
  step_kinds() {
    local line k out="" in_list=false re='^  [0-9]+\. '
    while IFS= read -r line; do
      if [[ $line == "Manual cleanup"* ]]; then
        in_list=true out=""
        continue
      fi
      if [[ $in_list != true ]]; then continue; fi
      if [[ ! $line =~ $re ]]; then
        in_list=false
        continue
      fi
      case $line in
        *"delete $VM_RES_CLUSTER -l "*) k='vms-cluster' ;;
        *"delete $VM_RES_NS -l "*) k='vms-ns' ;;
        *"delete $VMFS_RES_CLUSTER,$PC_RES_CLUSTER,$CPC_RES -l "*) k='vmfs+configs' ;;
        *"delete $PC_RES_CLUSTER,$CPC_RES -l "*) k='configs' ;;
        *"delete $PC_RES_NS -l "*) k='pc-ns' ;;
        *"delete namespace -l "*) k='ns+secrets' ;;
        *"$PROVIDER_DELETE_STEP"*) k='delete-provider' ;;
        *"wait until this lists no ProviderRevision"*) k='wait' ;;
        *"only then uninstall the Crossplane this run installed"*) k='uninstall-after-wait' ;;
        *"uninstall the Crossplane this run installed"*) k='uninstall' ;;
        *"leave Crossplane installed"*) k='leave-crossplane' ;;
        *"clear its finalizer by hand"*) k='finalizer' ;;
        *"clear the leftover finalizer by hand"*) k='last-resort-finalizer' ;;
        *) k='UNKNOWN' ;;
      esac
      out+="${out:+ }$k"
    done <"$1"
    printf '%s' "$out"
  }
  # left_kinds LINE: one word per item of an end-of-run "leaves in place whichever of these it
  # created" LINE, in order (installed:VERSION for the Crossplane this run installed). The
  # sentences after the list, on the version gate's teardown and on what uninstalling Crossplane
  # leaves, are not items.
  left_kinds() {
    local s=$1 item k out=""
    [[ $s == *"whichever of these it created: "* ]] || return 0
    s=${s#*whichever of these it created: }
    s=${s%%". $REMAINDER_HEAD"*}
    s=${s%%. The version gate *}
    while [[ -n $s ]]; do
      item=${s%%; *}
      if [[ $s == *"; "* ]]; then s=${s#*; }; else s=""; fi
      case $item in
        "any VirtualMachine MR labelled "*) k=vms ;;
        "the Observe-only VmfsDatastore "*) k=vmfs ;;
        "the ProviderConfigs, ClusterProviderConfig, credentials Secrets and namespace "*) k=configs ;;
        "Provider $PROVIDER_NAME and DeploymentRuntimeConfig $RUNTIME_CONFIG_NAME") k=provider ;;
        "Crossplane's unfinished removal of $PROVIDER_NAME: "*) k=removal ;;
        "Crossplane "*", which this run installed (Helm release $CP_RELEASE in $CP_NS)")
          k=${item%%, which*}
          k="installed:${k#Crossplane }"
          ;;
        *) k="UNKNOWN($item)" ;;
      esac
      out+="${out:+ }$k"
    done
    printf '%s' "$out"
  }
  # end_summary FILE...: the --skip-cleanup line that ends a run (said, or warned on stderr).
  end_summary() { grep -h -e '^--skip-cleanup' -e '^e2e-lab: WARNING: --skip-cleanup:' "$@" || true; }
  # only_negated TEXT PHRASE: every line of TEXT that mentions PHRASE says "never" or "none:", so
  # none of them announces that action.
  only_negated() {
    local line
    while IFS= read -r line; do
      [[ $line != *"$2"* || $line == *never* || $line == *"none:"* ]] || return 1
    done <<<"$1"
  }
  # dry_main LABEL ARGS...: the script's own main, as `bash cluster/test/e2e-lab.sh --dry-run
  # --crossplane-version 2.4.2 --kube-context lab-k3s ARGS...` runs it, in a subshell with the
  # script's own k, h, poll_until and sleep_poll back, the required vm-phase settings set, every
  # E2E_* setting of the caller unset, and first on PATH a govc that answers only `govc version`
  # (check_tools runs it; any other call is recorded as an external call). Its stdout and stderr
  # go to $C/LABEL.out, with the run ID main draws from the clock replaced by t0, so what a case
  # prints from it is deterministic. Sets DRY_RC.
  dry_main() {
    local label=$1 rid text
    shift
    mkdir -p "$C/drybin"
    printf '#!/bin/sh\nif [ "$1" = version ]; then echo "govc 0.54.0"; exit 0; fi\necho "$0 $*" >>"%s/CALLED"\nexit 99\n' "$T" >"$C/drybin/govc"
    chmod +x "$C/drybin/govc"
    DRY_RC=0
    (
      k() { script_k "$@"; }
      h() { script_h "$@"; }
      poll_until() { script_poll_until "$@"; }
      sleep_poll() { script_sleep_poll; }
      unset "${!E2E_@}" CROSSPLANE_VERSION PROVIDER_PACKAGE LEGACY_CROSSPLANE_VERSION KUBE_CONTEXT VSPHERE_ALLOW_UNVERIFIED_SSL
      E2E_RESOURCE_POOL_ID=resgroup-1 E2E_DATASTORE_ID=datastore-1 E2E_NETWORK_ID=dvportgroup-1
      E2E_TEMPLATE_UUID=42000000-0000-0000-0000-000000000000 E2E_GUEST_ID=ubuntu64Guest E2E_FOLDER=e2e
      PATH=$C/drybin:$SELFTEST_PATH TMPDIR=$C
      main --dry-run --crossplane-version 2.4.2 --kube-context lab-k3s "$@"
    ) </dev/null >"$C/$label.out" 2>&1 || DRY_RC=$?
    rid=$(sed -n 's/^e2e-lab plan, run \([0-9a-f]*\) .*/\1/p' "$C/$label.out")
    if [[ -n $rid ]]; then
      text=$(sed "s/$rid/t0/g" "$C/$label.out")
      printf '%s\n' "$text" >"$C/$label.out"
    fi
  }

  # (u8) Every phase x mode x --skip-cleanup cell of a dry run, through the script's own main
  # (dry_main): the plan's crossplane, provider removal and cleanup lines, the vm phase's Crossplane
  # step and the last step, word for word; the helm uninstall and Provider delete commands the dry
  # run plans, which must be exactly the ones the plan announces, and no plan line may announce an
  # uninstall or a Provider removal the run does not plan. Under --skip-cleanup, the end of the dry
  # run says what a real run that ends there leaves in place, and its manual list, in cleanup's
  # order, without claiming that this run left anything. In managed mode, with or without
  # --skip-cleanup, the end of the dry run also names what uninstalling Crossplane leaves, with the
  # webhook configurations of the last Crossplane line installed, and no line of it says nothing
  # is left without that; in existing mode it names none. --phase version-gate with
  # --existing-crossplane is rejected before the plan.
  case_u8() {
    local rm_managed rm_existing rm_gate rm_vm_s rm_ex_s rm_all_s cl_del cl_skip cl_gate
    local xp_gate xp_existing xp_vm_m xp_vm_s xp_all_m xp_all_s lk_m lk_e sk_m sk_e note_text
    local phase existing skip want_rc want_xp want_rm want_cl want_un want_pd want_left want_steps want_note
    local mode label out plan steps lastline last vmstep sum eor rem rem_what
    local -a args=()
    rm_managed="after deleting each Provider this run applied, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=10m for Crossplane to finish removing it, and only then helm uninstall Crossplane; if the wait runs out, Crossplane is left installed and cleanup is reported incomplete"
    rm_existing="after deleting the Provider this run applied, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=10m for the existing Crossplane to finish removing it; no helm uninstall follows (this script never uninstalls an existing Crossplane); if the wait runs out, cleanup is reported incomplete"
    rm_gate="the version gate's Provider only: after deleting it, wait up to E2E_PROVIDER_REMOVAL_TIMEOUT=10m for Crossplane to finish removing it, and only then helm uninstall Crossplane 1.20.13; if the wait runs out, Crossplane 1.20.13 is left installed, the report says CLEANUP INCOMPLETE and the run stops there"
    rm_vm_s="none: --skip-cleanup leaves this run's Provider and Crossplane v2.4.2 in place"
    rm_ex_s="none: --skip-cleanup leaves this run's Provider in place, and this script never uninstalls an existing Crossplane"
    rm_all_s="$rm_gate; --skip-cleanup leaves the vm phase's Provider and Crossplane v2.4.2 in place"
    cl_del="delete everything labelled $RUN_LABEL_KEY=t0"
    cl_skip="skipped (--skip-cleanup): the end of the run deletes nothing; it lists what this run left in place and the commands to remove it"
    cl_gate="$cl_skip; the version gate still removes its own Provider and uninstalls Crossplane 1.20.13"
    xp_gate="managed: installs only Crossplane 1.20.13 with helm, for the version gate, and uninstalls it after the gate"
    xp_existing="existing installation in $CP_NS; this script never installs, upgrades or uninstalls it"
    xp_vm_m="managed: installs Crossplane v2.4.2 with helm and uninstalls it at the end"
    xp_vm_s="managed: installs Crossplane v2.4.2 with helm and leaves it installed (--skip-cleanup)"
    xp_all_m="managed: installs Crossplane 1.20.13 with helm for the version gate and uninstalls it, then installs Crossplane v2.4.2 and uninstalls it at the end"
    xp_all_s="managed: installs Crossplane 1.20.13 with helm for the version gate and uninstalls it, then installs Crossplane v2.4.2 and leaves it installed (--skip-cleanup)"
    lk_m="vms vmfs configs provider installed:v2.4.2"
    lk_e="vms vmfs configs provider"
    sk_m="vms-cluster vms-ns vmfs+configs pc-ns ns+secrets delete-provider wait uninstall-after-wait finalizer"
    sk_e="vms-cluster vms-ns vmfs+configs pc-ns ns+secrets delete-provider wait leave-crossplane last-resort-finalizer"
    note_text="the version gate removes its own Provider and DeploymentRuntimeConfig and uninstalls Crossplane 1.20.13 even with --skip-cleanup"
    # phase|existing|skip|exit|crossplane line|provider removal line|cleanup line|planned helm
    # uninstalls|planned Provider deletes|what a real run leaves (skip)|its manual list|gate note
    while IFS='|' read -r phase existing skip want_rc want_xp want_rm want_cl want_un want_pd want_left want_steps want_note; do
      mode=managed
      if [[ $existing == true ]]; then mode=existing; fi
      label=$phase-$mode-skip$skip
      args=(--phase "$phase")
      if [[ $existing == true ]]; then args+=(--existing-crossplane); fi
      if [[ $skip == true ]]; then args+=(--skip-cleanup); fi
      dry_main "$label" "${args[@]}"
      out=$C/$label.out
      expect "$label: exits $want_rc" test "$DRY_RC" -eq "$want_rc"
      if ((want_rc != 0)); then
        expect "$label: rejected in validate(), before the plan and before any command" \
          eval '! grep -q "^e2e-lab plan" "$out" && grep -qF "cannot run with --existing-crossplane" "$out"'
        continue
      fi
      plan=$(sed -n '/^e2e-lab plan/,/^$/p' "$out")
      grep -E '^  (crossplane|provider removal|cleanup) +:' "$out" | sed "s/^/           | $label:/" || true
      expect "$label: the crossplane line" grep -qxF "  crossplane       : $want_xp" "$out"
      expect "$label: the provider removal line" grep -qxF "  provider removal : $want_rm" "$out"
      expect "$label: the cleanup line" grep -qxF "  cleanup          : $want_cl" "$out"
      if [[ $phase != version-gate && $mode == managed ]]; then
        vmstep=$xp_vm_m
        if [[ $skip == true ]]; then vmstep=$xp_vm_s; fi
        expect "$label: the vm phase's Crossplane step" contains "$plan" ". Crossplane v2.4.2: $vmstep"
      fi
      steps=$(grep -E '^  [0-9]+\. ' <<<"$plan") || steps=""
      lastline=${steps##*$'\n'}
      last="cleanup, then the PASS/FAIL report"
      if [[ $skip == true ]]; then
        last="no cleanup (--skip-cleanup): list what this run left in place, if anything, and the commands to remove it; then the PASS/FAIL report"
      fi
      expect "$label: the last step" test "${lastline#*[0-9]. }" = "$last"
      expect "$label: the dry run plans $want_un helm uninstall(s), as the plan says" \
        test "$(grep -c "^+ helm --kube-context lab-k3s uninstall $CP_RELEASE " "$out")" -eq "$want_un"
      expect "$label: the dry run plans $want_pd Provider delete(s), as the plan says" \
        test "$(grep -c "^+ kubectl --context lab-k3s delete $PROVIDER_RES " "$out")" -eq "$want_pd"
      if ((want_un == 0)); then
        expect "$label: no plan line announces a helm uninstall (each one that mentions it says never or none)" \
          only_negated "$plan" uninstall
      fi
      if ((want_pd == 0)); then
        expect "$label: no plan line announces a Provider removal" only_negated "$plan" "after deleting"
      fi
      if [[ $skip == true ]]; then
        expect "$label: no plan line says the vm phase's Crossplane is uninstalled at the end" \
          eval '! contains "$plan" "uninstalls it at the end"'
        sum=$(end_summary "$out")
        printf '           | %s: end of the dry run: left=[%s] steps=[%s]\n' "$label" "$(left_kinds "$sum")" "$(step_kinds "$out")"
        expect "$label: the end of the dry run speaks of a real run, never of what this run left" \
          eval '[[ $sum == "--skip-cleanup (dry run, nothing was created): a real run that ends here "* ]] && ! grep -qF "WARNING: --skip-cleanup" "$out" && ! grep -qF "== Cleanup:" "$out"'
        if [[ -z $want_left ]]; then
          expect "$label: a real run that ends here leaves nothing labelled, the gate's own teardown is named, and so is what uninstalling Crossplane 1.20.13 leaves" \
            test "$sum" = "--skip-cleanup (dry run, nothing was created): a real run that ends here leaves nothing labelled $RUN_LABEL_KEY=t0 in place: $note_text. $REMAINDER_1X"
          expect "$label: no manual list" eval '! grep -qF "Manual cleanup" "$out"'
        else
          expect "$label: what a real run that ends here leaves in place: $want_left" test "$(left_kinds "$sum")" = "$want_left"
          expect "$label: its manual list: $want_steps" test "$(step_kinds "$out")" = "$want_steps"
          if [[ $mode == existing ]]; then
            expect "$label: no step waits for Crossplane to be gone, which existing mode never makes happen" \
              eval '! grep -qF "after Crossplane is gone" "$out"'
          fi
          if [[ $want_note == yes ]]; then
            expect "$label: names the version gate's own teardown, which runs even with --skip-cleanup" contains "$sum" ". ${note_text^}"
          else
            expect "$label: names no version gate teardown" eval '! contains "$sum" "version gate"'
          fi
        fi
      else
        expect "$label: the dry run plans the end-of-run cleanup, and prints no --skip-cleanup summary" \
          eval 'grep -qF "== Cleanup: objects labelled $RUN_LABEL_KEY=t0" "$out" && [[ -z $(end_summary "$out") ]]'
      fi
      eor=$(end_of_run "$out")
      if [[ $mode == existing ]]; then
        expect "$label: installs no Crossplane, so the end of the dry run names no Crossplane remainder" remainder_absent "$eor"
      else
        rem=$REMAINDER_V2 rem_what="a Crossplane v2 leaves (crossplane-no-usages)"
        if [[ $phase == version-gate ]]; then rem=$REMAINDER_1X rem_what="Crossplane 1.20.13 leaves (crossplane and crossplane-no-usages)"; fi
        expect "$label: the end of the dry run says what uninstalling Crossplane leaves, and no line says nothing is left without it" \
          remainder_stated "$eor"
        expect "$label: it names the webhook configurations $rem_what" contains "$eor" "$rem"
      fi
      expect "$label: Result: DRY RUN" grep -qxF "Result: DRY RUN (no planned command was executed)" "$out"
      expect "$label: the password is never printed" eval '! grep -qF "$P_ORIGINAL" "$out"'
    done <<EOF
version-gate|false|false|0|$xp_gate|$rm_managed|$cl_del|1|1|||no
version-gate|false|true|0|$xp_gate|$rm_gate|$cl_gate|1|1|||yes
version-gate|true|false|2|||||0|0|||no
version-gate|true|true|2|||||0|0|||no
vm|false|false|0|$xp_vm_m|$rm_managed|$cl_del|1|1|||no
vm|false|true|0|$xp_vm_s|$rm_vm_s|$cl_skip|0|0|$lk_m|$sk_m|no
vm|true|false|0|$xp_existing|$rm_existing|$cl_del|0|1|||no
vm|true|true|0|$xp_existing|$rm_ex_s|$cl_skip|0|0|$lk_e|$sk_e|no
all|false|false|0|$xp_all_m|$rm_managed|$cl_del|2|2|||no
all|false|true|0|$xp_all_s|$rm_all_s|$cl_gate|1|1|$lk_m|$sk_m|yes
all|true|false|0|$xp_existing|$rm_existing|$cl_del|0|1|||no
all|true|true|0|$xp_existing|$rm_ex_s|$cl_skip|0|0|$lk_e|$sk_e|no
EOF
    finish_case
  }

  # (u9) --skip-cleanup, and the version gate's removal wait runs out after its deletes succeeded
  # (the ProviderRevision never goes away), run as main runs it: the gate stops the run. The end
  # of the run must name only what is left -- Crossplane's unfinished removal of the provider and
  # Crossplane 1.20.13 -- never this run's Provider, which is deleted, and its manual list must
  # start with the wait, not with a Provider delete. --phase version-gate, and --phase all.
  case_u9() {
    local sum
    PHASE=$1 STARTED=true SKIP_CLEANUP=true XP_VERSION=2.4.2
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 yes no
    rp_run trap_run eval 'phase_version_gate; phase_vm' 2>"$C/err.txt"
    sum=$(end_summary "$C/say.txt" "$C/err.txt")
    printf '           | end of run: %s\n' "$sum"
    printf '           | manual list: %s\n' "$(step_kinds "$C/say.txt")"
    expect "--phase $1, gate removal wait ran out: exit 1 and Result: FAIL" eval '[[ $RP_RC -eq 1 ]] && said "Result: FAIL"'
    expect "--phase $1, gate removal wait ran out: left in place: Crossplane's unfinished removal of the provider, and Crossplane 1.20.13" \
      test "$(left_kinds "$sum")" = "removal installed:1.20.13"
    expect "--phase $1, gate removal wait ran out: it also names what uninstalling Crossplane 1.20.13 leaves, both of its webhook configurations included" \
      contains "$sum" ". $REMAINDER_1X"
    expect "--phase $1, gate removal wait ran out: never says this run's Provider, or everything labelled, is left in place" \
      eval '! contains "$sum" "Provider $PROVIDER_NAME and DeploymentRuntimeConfig" && ! grep -qF "everything labelled" "$C/say.txt" "$C/err.txt"'
    expect "--phase $1, gate removal wait ran out: the manual list starts with the wait (no Provider delete), then helm uninstall, then the finalizer patch" \
      test "$(step_kinds "$C/say.txt")" = "wait uninstall-after-wait finalizer"
    expect "--phase $1, gate removal wait ran out: the report says the version gate's own teardown is incomplete, not a cleanup --skip-cleanup skipped" \
      said "CLEANUP INCOMPLETE: the version gate could not finish removing its own Provider and Crossplane 1.20.13 (it does so even with --skip-cleanup, which skipped only the end-of-run cleanup); see the warnings above"
    expect "--phase $1, gate removal wait ran out: one helm install (1.20.13), no helm uninstall, no Crossplane v2 install" \
      eval '[[ $(grep -c "^helm .* upgrade --install " "$C/rp/calls") -eq 1 ]] && ! grep -q "^helm .* uninstall " "$C/rp/calls" && ! grep -q "2\.4\.2" "$C/rp/calls"'
    finish_case
  }

  # (u10) --skip-cleanup, managed mode, and the vm phase stops right after its helm install (the
  # Crossplane package CRDs never become Established), before any Provider of the vm phase
  # exists. The end of the run must name only Crossplane v2.4.2 and list only its helm uninstall:
  # no Provider delete and no wait for a ProviderRevision that never existed. --phase vm, and
  # --phase all after a version gate that removed its own Provider and Crossplane.
  case_u10() {
    local sum last
    PHASE=$1 STARTED=true SKIP_CLEANUP=true XP_VERSION=2.4.2
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=5 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0
    rp_stubs 1 yes yes none crd-timeout
    if [[ $1 == all ]]; then
      rp_run trap_run eval 'phase_version_gate; phase_vm' 2>"$C/err.txt"
    else
      rp_run trap_run phase_vm 2>"$C/err.txt"
    fi
    sum=$(end_summary "$C/say.txt" "$C/err.txt")
    printf '           | end of run: %s\n' "$sum"
    printf '           | manual list: %s\n' "$(step_kinds "$C/say.txt")"
    expect "--phase $1, stopped after the vm phase's helm install: exit 1, ABORTED at the CRD wait, Result: FAIL" \
      eval '[[ $RP_RC -eq 1 ]] && said "ABORTED: Crossplane package CRDs are not established" && said "Result: FAIL"'
    expect "--phase $1, stopped after the vm phase's helm install: left in place: Crossplane v2.4.2 only" \
      test "$(left_kinds "$sum")" = "installed:v2.4.2"
    expect "--phase $1, stopped after the vm phase's helm install: it also names what uninstalling Crossplane leaves, with only the v2 webhook configuration (a v2 install that succeeded deleted the 1.x one)" \
      contains "$sum" ". $REMAINDER_V2"
    expect "--phase $1, stopped after the vm phase's helm install: the manual list is its helm uninstall alone" \
      test "$(step_kinds "$C/say.txt")" = "uninstall"
    expect "--phase $1, stopped after the vm phase's helm install: no line mentions a Provider delete or a ProviderRevision wait" \
      eval '! grep -qF -e "$PROVIDER_DELETE_STEP" -e "lists no ProviderRevision" "$C/say.txt" "$C/err.txt"'
    if [[ $1 == all ]]; then
      expect "--phase all: it also names what the version gate removed, as it does even with --skip-cleanup" \
        contains "$sum" ". The version gate removed its own Provider and DeploymentRuntimeConfig and uninstalled Crossplane 1.20.13, as it does even with --skip-cleanup"
      last=$(grep '^helm ' "$C/rp/calls" | tail -n 1) || last=""
      expect "--phase all: helm installed 1.20.13 and uninstalled it, then installed 2.4.2 last" \
        eval '[[ $(grep -c "^helm .* upgrade --install .*--version 1.20.13 " "$C/rp/calls") -eq 1 && $(grep -c "^helm .* uninstall " "$C/rp/calls") -eq 1 && $last == *" upgrade --install "*"--version 2.4.2 "* ]]'
    else
      expect "--phase vm: it names no version gate" eval '! contains "$sum" "version gate"'
      expect "--phase vm: one helm install (2.4.2), no uninstall, and nothing applied" \
        eval '[[ $(grep -c "^helm " "$C/rp/calls") -eq 1 ]] && grep -q -- "--version 2.4.2 " "$C/rp/calls" && ! grep -q " apply " "$C/rp/calls"'
    fi
    finish_case
  }

  # (u11) --skip-cleanup, --phase version-gate, and the gate's teardown completes. Nothing labelled
  # with the run's label is left, so the end of the run says so and names what the gate removed.
  # Uninstalling Crossplane 1.20.13 left its CRDs, both of its webhook configurations and namespace
  # crossplane-system, which no label covers, so it names those too. It lists no manual cleanup
  # and warns about nothing, and the run exits 0 with no "cleanup skipped" note.
  case_u11() {
    local sum
    PHASE=version-gate STARTED=true SKIP_CLEANUP=true
    PROVIDER_REMOVAL_TIMEOUT_SECONDS=5 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=0
    rp_stubs 1 yes yes
    rp_run trap_run phase_version_gate 2>"$C/err.txt"
    sum=$(end_summary "$C/say.txt" "$C/err.txt")
    printf '           | end of run: %s\n' "$sum"
    expect "clean gate-only --skip-cleanup run: exit 0" test "$RP_RC" -eq 0
    expect "clean gate-only --skip-cleanup run: says nothing labelled is left, what the gate removed, and what uninstalling Crossplane 1.20.13 leaves" \
      test "$sum" = "--skip-cleanup: nothing labelled $RUN_LABEL_KEY=t0 is left in place: the version gate removed its own Provider and DeploymentRuntimeConfig and uninstalled Crossplane 1.20.13, as it does even with --skip-cleanup. $REMAINDER_1X"
    expect "clean gate-only --skip-cleanup run: no line of the end of the run says nothing is left without naming Crossplane's CRDs, webhook configurations and namespace" \
      remainder_stated "$(end_of_run "$C/say.txt" "$C/err.txt")"
    expect "clean gate-only --skip-cleanup run: no manual list and no warning" eval '! said "Manual cleanup" && [[ ! -s $C/err.txt ]]'
    expect "clean gate-only --skip-cleanup run: the Result line has no cleanup-skipped note, as it left nothing it labelled and ends as a run without --skip-cleanup would" \
      grep -qxF "Result: PASS (AC-022 not asserted: E2E_REQUIRE_AC022=false)" "$C/say.txt"
    expect "clean gate-only --skip-cleanup run: helm installed Crossplane 1.20.13, then uninstalled it" \
      eval '[[ $(grep -c "^helm " "$C/rp/calls") -eq 2 ]] && grep -q "^helm .* upgrade --install .*--version 1.20.13 " "$C/rp/calls" && grep -q "^helm .* uninstall " "$C/rp/calls"'
    finish_case
  }

  # (u12) --skip-cleanup, and deleting the version gate's Provider fails (an unavailable API
  # server): its Provider, DeploymentRuntimeConfig and Crossplane 1.20.13 are left, so the end of
  # the run names exactly those, and its manual list starts by deleting them again.
  case_u12() {
    local sum
    PHASE=version-gate STARTED=true SKIP_CLEANUP=true
    PROVIDER_REMOVAL_TIMEOUT_RAW=1s PROVIDER_REMOVAL_TIMEOUT_SECONDS=1 PROVIDER_REMOVAL_POLL_INTERVAL_SECONDS=1
    rp_stubs 0 yes yes provider
    rp_run trap_run phase_version_gate 2>"$C/err.txt"
    sum=$(end_summary "$C/say.txt" "$C/err.txt")
    printf '           | end of run: %s\n' "$sum"
    printf '           | manual list: %s\n' "$(step_kinds "$C/say.txt")"
    expect "gate Provider delete failed: exit 1 and Result: FAIL" eval '[[ $RP_RC -eq 1 ]] && said "Result: FAIL"'
    expect "gate Provider delete failed: left in place: the Provider and DeploymentRuntimeConfig, and Crossplane 1.20.13" \
      test "$(left_kinds "$sum")" = "provider installed:1.20.13"
    expect "gate Provider delete failed: it also names what uninstalling Crossplane 1.20.13 leaves, both of its webhook configurations included" \
      contains "$sum" ". $REMAINDER_1X"
    expect "gate Provider delete failed: the manual list deletes them again, waits, then helm uninstall, then the finalizer patch" \
      test "$(step_kinds "$C/say.txt")" = "delete-provider wait uninstall-after-wait finalizer"
    expect "gate Provider delete failed: the report says the version gate's own teardown is incomplete" \
      said "CLEANUP INCOMPLETE: the version gate could not finish removing its own Provider and Crossplane 1.20.13 (it does so even with --skip-cleanup, which skipped only the end-of-run cleanup); see the warnings above"
    expect "gate Provider delete failed: no helm uninstall" eval '! grep -q "^helm .* uninstall " "$C/rp/calls"'
    finish_case
  }

  # (u13) What --help says --skip-cleanup does and what each exit code means, against what the
  # script's own on_exit (run as main arms it) prints and returns for each end state, the state
  # flags set as the run's own steps leave them: what it names as left in place, its manual list,
  # the Result line and the exit code. Exit 0 goes with a Result line that starts "Result: PASS"
  # (or DRY RUN), which says "cleanup skipped" exactly when a --skip-cleanup run left something in
  # place; exit 1 goes with "Result: FAIL". With or without --skip-cleanup, the end of a run that
  # installed Crossplane names what uninstalling it leaves, and no line says nothing is left
  # without that; the end of one that installed none (existing mode) names no such remainder.
  case_u13() {
    local u rc name existing skip dry end flags want_left want_steps want_rc want_result res sum out eor
    u=$(usage | tr '\n' ' ' | tr -s ' ')
    expect "--help: --skip-cleanup no longer claims to leave everything in place" eval '! contains "$u" "Leave everything in place"'
    expect "--help: --skip-cleanup skips only the end-of-run cleanup, and names what still runs (the AC-006/AC-007 deletes and the version gate's own teardown)" \
      contains "$u" "--skip-cleanup Skip only the end-of-run cleanup: leave in place what this run created and has not removed, and list it with the commands to remove it. The run's own steps still delete what they test (the AC-006 and AC-007 VMs), and in managed mode the version gate still removes its own Provider and DeploymentRuntimeConfig and uninstalls its Crossplane 1.x."
    expect "--help: exit 0 covers a skipped cleanup" contains "$u" "Exit codes: 0 no criterion failed, and cleanup completed or --skip-cleanup skipped it"
    expect "--help: exit 0 says the Result line notes a skipped cleanup that left anything" contains "$u" 'after a skipped cleanup that left anything in place the Result line says "cleanup skipped"'
    expect "--help: exit 1 includes an incomplete version-gate teardown" \
      contains "$u" "1 a criterion failed, a required AC-022 did not pass, cleanup or the version gate's own teardown was incomplete, or the run aborted"
    expect "--help: no longer says exit 0 always means cleanup completed" eval '! contains "$u" "0 no criterion failed and cleanup completed"'
    rc=0
    (main --help) </dev/null >"$C/help.txt" 2>&1 || rc=$?
    expect "--help through main prints that usage and exits 0" eval '[[ $rc -eq 0 && $(<"$C/help.txt") == "$(usage)" ]]'
    record AC-022 cluster PASS
    record AC-022 namespaced PASS
    record AC-022 package PASS
    while IFS='|' read -r name existing skip dry end flags want_left want_steps want_rc want_result; do
      PROVIDER_APPLIED=false PROVIDER_REMOVAL_OK=true NS_CREATED=false VMFS_APPLIED=false VMS_APPLIED=false
      CP_INSTALLED_BY_RUN=false CP_INSTALLED_NAME="" GATE_TEARDOWN="" CLEANUP_OK=true CLEANUP_STARTED=false ABORT_REASON=""
      LEGACY_WEBHOOK_LEFT=false PHASE=all
      EXISTING=$existing SKIP_CLEANUP=$skip DRY_RUN=$dry STARTED=true CLUSTER_TOUCHED=true
      eval "$flags"
      # on_exit removed the previous row's WORKDIR, as it does at the end of a real run.
      mkdir -p "$WORKDIR"
      rc=0
      if [[ $end == abort ]]; then
        trap_run fatal "simulated stop" </dev/null 3>"$C/row.txt" 2>"$C/row.err" || rc=$?
      else
        trap_run true </dev/null 3>"$C/row.txt" 2>"$C/row.err" || rc=$?
      fi
      res=$(grep -h '^Result: ' "$C/row.txt") || res=""
      sum=$(end_summary "$C/row.txt" "$C/row.err")
      out=$(left_kinds "$sum")
      printf '           | %s: left=[%s] steps=[%s] exit=%s %s\n' "$name" "$out" "$(step_kinds "$C/row.txt")" "$rc" "$res"
      expect "$name: exit $want_rc" test "$rc" -eq "$want_rc"
      expect "$name: $want_result" test "$res" = "$want_result"
      expect "$name: the exit code and the Result line agree (0: PASS or DRY RUN; 1: FAIL)" \
        eval '[[ ($rc -eq 0 && ($res == "Result: PASS"* || $res == "Result: DRY RUN"*)) || ($rc -eq 1 && $res == "Result: FAIL") ]]'
      expect "$name: the Result line says cleanup skipped exactly when a passing --skip-cleanup run left something" \
        eval 'if [[ $skip == true && $dry == false && $rc -eq 0 && -n $want_left ]]; then contains "$res" "cleanup skipped: --skip-cleanup left objects in place"; else ! contains "$res" "cleanup skipped"; fi'
      expect "$name: never says everything labelled is left in place" eval '! grep -qF "everything labelled" "$C/row.txt" "$C/row.err"'
      if [[ $existing == true ]]; then
        expect "$name: no step waits for Crossplane to be gone, which existing mode never makes happen" \
          eval '! grep -qF "after Crossplane is gone" "$C/row.txt" "$C/row.err"'
      fi
      eor=$(end_of_run "$C/row.txt" "$C/row.err")
      if [[ -n $CP_INSTALLED_NAME ]]; then
        expect "$name: the end of the run says what uninstalling its Crossplane leaves, and no line says nothing is left without it" \
          remainder_stated "$eor"
      else
        expect "$name: installed no Crossplane, so the end of the run names no Crossplane remainder" remainder_absent "$eor"
      fi
      if [[ $skip == false ]]; then
        expect "$name: cleanup ran, and there is no --skip-cleanup summary or manual list" \
          eval '[[ -z $sum ]] && ! grep -qF "Manual cleanup" "$C/row.txt" && grep -qF "== Cleanup:" "$C/row.txt"'
        continue
      fi
      if [[ -z $want_left ]]; then
        expect "$name: says nothing labelled with the run's label is left in place, and lists no manual cleanup" \
          eval '[[ $sum == "--skip-cleanup: nothing labelled $RUN_LABEL_KEY=t0 is left in place"* ]] && ! grep -qF "Manual cleanup" "$C/row.txt"'
      else
        expect "$name: left in place: $want_left" test "$out" = "$want_left"
        expect "$name: manual list: $want_steps" test "$(step_kinds "$C/row.txt")" = "$want_steps"
        if [[ $dry == true ]]; then
          expect "$name: a dry run says what a real run would leave, and warns about nothing" \
            eval '[[ $sum == "--skip-cleanup (dry run, nothing was created): a real run that ends here "* ]] && ! grep -qF WARNING "$C/row.err"'
        else
          expect "$name: a real run warns what it left in place" \
            eval '[[ $sum == "e2e-lab: WARNING: --skip-cleanup: this run leaves in place whichever of these it created: "* ]]'
        fi
      fi
      expect "$name: names what the version gate removed exactly when its teardown finished" \
        eval 'if [[ $flags == *GATE_TEARDOWN=finished* ]]; then contains "$sum" "version gate remove"; else ! contains "$sum" "version gate"; fi'
      if [[ $flags == *CLEANUP_OK=false* ]]; then
        expect "$name: the report says the version gate's own teardown is incomplete" \
          grep -qF "CLEANUP INCOMPLETE: the version gate could not finish removing its own Provider and Crossplane 1.20.13 (it does so even with --skip-cleanup, which skipped only the end-of-run cleanup); see the warnings above" "$C/row.txt"
      fi
    done <<'EOF'
gate teardown finished, nothing labelled left|false|true|false|ok|GATE_TEARDOWN=finished CP_INSTALLED_NAME="Crossplane 1.20.13" LEGACY_WEBHOOK_LEFT=true|||0|Result: PASS
gate removal wait ran out|false|true|false|abort|GATE_TEARDOWN=started PROVIDER_REMOVAL_OK=false CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane 1.20.13" LEGACY_WEBHOOK_LEFT=true CLEANUP_OK=false|removal installed:1.20.13|wait uninstall-after-wait finalizer|1|Result: FAIL
gate Provider delete failed|false|true|false|abort|GATE_TEARDOWN=started PROVIDER_APPLIED=true PROVIDER_REMOVAL_OK=false CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane 1.20.13" LEGACY_WEBHOOK_LEFT=true CLEANUP_OK=false|provider installed:1.20.13|delete-provider wait uninstall-after-wait finalizer|1|Result: FAIL
stopped right after the vm phase's helm install|false|true|false|abort|CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"|installed:v2.4.2|uninstall|1|Result: FAIL
stopped right after the vm phase's Provider apply|false|true|false|abort|PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"|provider installed:v2.4.2|delete-provider wait uninstall-after-wait finalizer|1|Result: FAIL
vm phase finished|false|true|false|ok|VMS_APPLIED=true VMFS_APPLIED=true NS_CREATED=true PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"|vms vmfs configs provider installed:v2.4.2|vms-cluster vms-ns vmfs+configs pc-ns ns+secrets delete-provider wait uninstall-after-wait finalizer|0|Result: PASS (cleanup skipped: --skip-cleanup left objects in place)
version gate and vm phase finished|false|true|false|ok|GATE_TEARDOWN=finished VMS_APPLIED=true VMFS_APPLIED=true NS_CREATED=true PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"|vms vmfs configs provider installed:v2.4.2|vms-cluster vms-ns vmfs+configs pc-ns ns+secrets delete-provider wait uninstall-after-wait finalizer|0|Result: PASS (cleanup skipped: --skip-cleanup left objects in place)
existing, vm phase finished on an NFS datastore|true|true|false|ok|VMS_APPLIED=true NS_CREATED=true PROVIDER_APPLIED=true|vms configs provider|vms-cluster vms-ns configs pc-ns ns+secrets delete-provider wait leave-crossplane last-resort-finalizer|0|Result: PASS (cleanup skipped: --skip-cleanup left objects in place)
existing, stopped right after the Provider apply|true|true|false|abort|PROVIDER_APPLIED=true|provider|delete-provider wait leave-crossplane last-resort-finalizer|1|Result: FAIL
dry run of the version gate and vm phase|false|true|true|ok|GATE_TEARDOWN=finished VMS_APPLIED=true VMFS_APPLIED=true NS_CREATED=true PROVIDER_APPLIED=true CP_INSTALLED_BY_RUN=true CP_INSTALLED_NAME="Crossplane v2.4.2"|vms vmfs configs provider installed:v2.4.2|vms-cluster vms-ns vmfs+configs pc-ns ns+secrets delete-provider wait uninstall-after-wait finalizer|0|Result: DRY RUN (no planned command was executed)
existing, vm phase finished, without --skip-cleanup (cleanup runs)|true|false|false|ok|PROVIDER_APPLIED=true|||0|Result: PASS
version gate only, without --skip-cleanup (cleanup runs)|false|false|false|ok|PHASE=version-gate GATE_TEARDOWN=finished CP_INSTALLED_NAME="Crossplane 1.20.13" LEGACY_WEBHOOK_LEFT=true|||0|Result: PASS
EOF
    finish_case
  }

  total=0 failed=0
  run_case() {
    printf '\n## %s\n' "$1"
    total=$((total + 1))
    (
      set -e
      setup
      "${@:2}"
    ) 2>"$T/case.err"
    # Not `if ! ( ... )`: bash ignores set -e inside a subshell whose status an `if` tests.
    # shellcheck disable=SC2181
    if (($? != 0)); then failed=$((failed + 1)); fi
    if [[ -s $T/case.err ]]; then sed 's/^/  stderr: /' "$T/case.err"; fi
  }
  run_case "(a) new login key present, vCenter clock 30s behind" case_a -30
  run_case "(a) new login key present, vCenter clock in sync" case_a 0
  run_case "(a) new login key present, vCenter clock 30s ahead" case_a 30
  run_case "(b) only pre-rotation keys present" case_b
  run_case "(b2) one new key for two rotated ProviderConfigs" case_b2
  run_case "(b3) pre-rotation sample fails before the pause" case_b3
  run_case "(b4) you confirm, but the vCenter password is not the rotated one" case_b4
  run_case "(g) no provider session visible before the rotation pause" case_g
  run_case "(n) no confirmation at the prompt" case_n
  run_case "(h) rotation start + finish with a vCenter that checks every login" case_h
  run_case "(h2) a session opened during the pause is not a rebuilt client" case_h2
  run_case "(i) password in effect for every vCenter call after the rotation, through cleanup" case_i
  run_case "(j) fatal error right after the rotation: cleanup uses the rotated password" case_j
  run_case "(k) cleanup when vCenter rejects govc's login" case_k
  run_case "(r) answers at the rotation prompt" case_r
  run_case "(t) validate(): no terminal for the AC-022 prompt stops the run before any command" case_t
  run_case "(v) check_tools(): a tool older than its minimum stops a real run and a dry run before any command" case_v
  run_case "(c) steady state, 0 visible: lab user cannot list other sessions" case_c1
  run_case "(c) steady state, 0 visible: userName form does not match (exact mode)" case_c2
  run_case "(c) steady state, fewer than PROVIDER_CONFIGS_IN_USE visible" case_c3
  run_case "(d) steady state, normal count" case_d1
  run_case "(d) steady state, above the limit" case_d2
  run_case "(d) steady state, one Ready VM" case_d3
  run_case "(e) user forms" case_e
  run_case "(f) rotation finish, clean" case_f1
  run_case "(f) rotation finish, old session left" case_f2
  run_case "(f) rotation finish, blind" case_f3
  run_case "(f) rotation finish, govc fails" case_f4
  run_case "(p) preflight, managed mode: CRD present, image and release names foreign" case_p1
  run_case "(p) preflight, managed mode: nothing present" case_p2
  run_case "(p) preflight, --existing-crossplane with the CRD present" case_p3
  run_case "(q) remove_provider: revision gone after 3 polls, helm uninstall follows only then" case_q1
  run_case "(q) remove_provider: revision never gone, no helm uninstall, cleanup incomplete + recovery" case_q2
  run_case "(q) remove_provider: --dry-run prints the wait and executes nothing" case_q3
  run_case "(q) remove_provider + uninstall_crossplane: the version-gate teardown path" case_q4
  run_case "(q) remove_provider: existing mode never waits on the Lock or calls helm" case_q5
  run_case "(u) cleanup, managed mode: the Provider delete fails, so no helm uninstall and the report says CLEANUP INCOMPLETE" case_u1
  run_case "(u) cleanup, --existing-crossplane: the ProviderRevision never goes away, so CLEANUP INCOMPLETE, Result: FAIL, exit 1" case_u2
  run_case "(u) phase_version_gate: the ProviderRevision never goes away, so the run stops before any Crossplane v2 install" case_u3
  run_case "(u) print_plan: the provider removal and Crossplane lines per mode (existing, version-gate only, managed all)" case_u4
  run_case "(u) print_report: the report header names the Crossplane each phase and mode uses, as the plan does" case_u5
  run_case "(u) print_plan and on_exit: steps and end-of-run lines that depend on the phase, the mode or --skip-cleanup" case_u6
  run_case "(u) manual lists: the teardown's steps in its order, the wait before any helm uninstall (script and RELEASING.md)" case_u7
  run_case "(u) dry runs through main, every phase x mode x --skip-cleanup cell: plan lines, planned commands and end of run agree" case_u8
  run_case "(u) --skip-cleanup, --phase version-gate: the gate's removal wait runs out after its deletes succeeded" case_u9 version-gate
  run_case "(u) --skip-cleanup, --phase all: the gate's removal wait runs out after its deletes succeeded" case_u9 all
  run_case "(u) --skip-cleanup, --phase vm: the run stops right after its helm install, before any Provider exists" case_u10 vm
  run_case "(u) --skip-cleanup, --phase all: after the gate, the run stops right after the vm phase's helm install" case_u10 all
  run_case "(u) --skip-cleanup, --phase version-gate: the gate's teardown completes, so nothing labelled is left, only what uninstalling Crossplane leaves" case_u11
  run_case "(u) --skip-cleanup, --phase version-gate: deleting the gate's Provider fails" case_u12
  run_case "(u) --help and exit codes against on_exit's end-of-run text and exit code for each end state" case_u13
  printf '\n%s case(s), %s failed\n' "$total" "$failed"
  ((failed == 0))
)
rc=$?
if [[ -e $T/CALLED ]]; then
  echo "external binaries invoked:"
  cat "$T/CALLED"
  rc=1
else
  echo "no call reached the call-recording kubectl, helm, docker or crossplane stubs; the (p) cases' kubectl and helm calls went to their fixture stubs, and every govc call went to the fake vCenter, or in the (v) cases to their replay stubs"
fi
exit "$rc"
