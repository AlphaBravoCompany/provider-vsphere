# Releasing provider-vsphere

A release engineer cuts every release by hand from a workstation, with `make` targets and this
runbook. CI only builds, lints and tests (on pull requests, on pushes to `main` and `release-*`,
and on manual runs); it never publishes, and it holds no Docker Hub credentials. The only
registry credential is the one you type into `docker login` during a release. No credential of
any kind (Docker Hub token, `~/.docker/config.json`, vCenter password, kubeconfig) is ever
committed to this repository or stored in CI.

The package is published as **one multi-arch OCI index** (`linux/amd64` + `linux/arm64`) at
`docker.io/alphabravodevops/provider-vsphere:<tag>`. Pioneer and its airgap mirror pin that
single, fully qualified tag.

## 1. Versioning

- The release tag mirrors the embedded Terraform provider version: `v<vmware/vsphere version>`.
  For vmware/vsphere 2.15.1 the first release is **`v2.15.1`**. The same version is in the
  `Makefile` (`TERRAFORM_PROVIDER_VERSION`) and in `package/crossplane.yaml`
  (`alphabravo.io/terraform-provider-version`).
- A provider-only fix, released while the Terraform provider is still 2.15.1, adds a counter:
  **`v2.15.1-1`**, then `v2.15.1-2`, and so on (see [section 11](#11-provider-only-fix-release)).
  When the Terraform provider moves (for example to 2.16.0), the next tag is `v2.16.0` and the
  counter starts again.
- Semver treats `-N` as a pre-release, so it sorts `v2.15.1-1` *below* `v2.15.1`. Consumers must
  therefore pin exact tags, never a semver range, and `latest` is always moved explicitly
  (section 9).
- Create `-N` tags with `git tag -a`. Never use `make release.tag`: its `VERSION_REGEX` accepts
  only `vX.Y.Z`, and it also re-creates the tag with `git tag -f`, pushes it, and, when the
  remote has no `release-*` branch for that minor version yet, creates and pushes one.
- A published version tag is never reused, moved or deleted; only `latest` moves (section 9). A
  broken release is followed by a `-N` fix.

## 2. Prerequisites

- Go as pinned in `go.mod` (`GOTOOLCHAIN=auto` fetches it).
- Docker with buildx, plus arm64 emulation for the arm64 image:
  `docker run --privileged --rm tonistiigi/binfmt --install arm64`
- Build submodule: `make submodules`
- A clean tree on `main` (or a `release-*` branch) at the commit you release.
- Push rights to `docker.io/alphabravodevops/provider-vsphere` and a Docker Hub access token
  with read and write scope.
- `crane` for verification:
  `go install github.com/google/go-containerregistry/cmd/crane@latest`
- Tools for the lab e2e gate (`cluster/test/e2e-lab.sh`): **bash 4+, jq 1.6+, govc 0.32.0+**,
  plus `kubectl` and `helm` in any version supported by your cluster. These are the script's
  `MIN_BASH`, `MIN_JQ` and `MIN_GOVC`. The script checks them before any cluster call. A tool
  the run needs that is older than its minimum (only the vm phase needs govc), or a govc whose
  version the script cannot determine, stops the run with exit 2, and nothing is changed. The
  same holds for its `--dry-run`, so the dry run in section 8 catches it first:
  - jq older than 1.6 has no `--rawfile`, which the script uses to pipe the vCenter password into
    the credentials Secret.
  - govc older than 0.32.0 prints `-json` output with PascalCase field names (0.31.0 still does
    for `vm.info`), while the script reads the camelCase ones (`.sessionList`,
    `.virtualMachines[0].runtime.powerState`). A correct provider would then FAIL checks such as
    AC-006 and AC-019, and below 0.31.0 also AC-021 and AC-022.

  Get govc in one of these ways; the script accepts each, as the recorded builds in
  `cluster/test/e2e-lab-selftest.sh` show:
  - A release binary from https://github.com/vmware/govmomi/releases (for example
    `govc_Linux_x86_64.tar.gz`). It prints its own version, such as `govc 0.56.0`.
  - `go install github.com/vmware/govmomi/govc@vX.Y.Z` for a release from 0.32.0 up to 0.46.3
    (the script's `GOVC_LAST_GO_INSTALL`). It fails for every release from 0.47.0 on, and so
    does `@latest`: govmomi 0.47.0 moved govc into its own module,
    `github.com/vmware/govmomi/govc`, which has no version tags of its own and whose `go.mod`
    replaces `github.com/vmware/govmomi` with `../`.
  - For 0.47.0 or later without a release binary, a build in a clone:
    `git clone --branch v0.56.0 https://github.com/vmware/govmomi.git && cd govmomi/govc && go install .`

  A govc built with `go install` or in a clone prints `govc 0.0.0`, so the script reads its
  version from the binary's Go build info with `go version -m`, which needs Go on `PATH` (the
  first item above). The script stops with exit 2 on a build it cannot date: a pre-0.47.0 build
  in a clone at a commit between release tags or without VCS information (`-buildvcs=false`), or
  a wrapper script (such as a version-manager shim) in front of any build that prints
  `govc 0.0.0`, since Go cannot read build info from a script.
- Also for the lab e2e gate: a dedicated lab k3s kube context, the lab vCenter settings
  (section 8), the right to change the lab user's vCenter password by hand (AC-022), and an
  interactive terminal for that run.
- The lab vCenter user (`VSPHERE_USER`) needs the **`Sessions.TerminateSession`** privilege
  ("Sessions > View and stop sessions" in the vSphere Client role editor) on the vCenter root
  object. It is what lets `govc session.ls` list other sessions (`SessionManager.sessionList`);
  without it govc sees only its own session. AC-021 and AC-022 need to see the provider's
  sessions, so the script treats fewer visible provider sessions than the provider must hold (one
  per ProviderConfig in use) as a measurement failure and FAILs the check rather than passing it
  on a count of zero. Use a dedicated lab user that nobody logs in as during the run, because
  every session of that user that starts after the script installs the provider counts, except
  govc's own. Change its password (AC-022) from an administrator account.
- For the CUSTOM-ATTR-POWER check (section 8) the lab user also needs, on the vCenter root
  object, **`Global.ManageCustomFields`** ("Global > Manage custom attributes"), for the
  provider to create and delete the run's custom attribute, and **`Global.SetCustomField`**
  ("Global > Set custom attribute"), for the provider and govc to set its value on the test VMs.
  Without the first the run's CustomAttribute never becomes Ready; without the second the value
  never reaches the VMs or `govc fields.set` fails. Either way CUSTOM-ATTR-POWER FAILs and the
  script names the privilege to check.
- Set `VSPHERE_USER` in the form the provider logs in with, normally `account@domain`, for example
  `svc-pioneer@lab.local`. vCenter reports session users as `DOMAIN\account`, with the domain as
  the identity source names it, for example `LAB\svc-pioneer`, `LAB.LOCAL\svc-pioneer` or
  `VSPHERE.LOCAL\Administrator`. By default (`E2E_SESSION_USER_MATCH=account`) the script counts a
  session as the provider's when:
  - the account names match, ignoring case, and
  - the domains agree: they are equal, or one side gives no domain, or one side is a short name
    (`LAB`) equal to the first label of the other (`lab.local`).

  So `svc-pioneer@lab.local` matches `LAB\svc-pioneer`, but not `LAB\svc-other`,
  `CORP\svc-pioneer` or `svc-pioneer@corp.example.com`. A `VSPHERE_USER` without a domain matches
  that account in any domain. `E2E_SESSION_USER_MATCH=exact` requires the same account and the
  same domain, still ignoring case: then `svc-pioneer@lab.local` matches `LAB.LOCAL\svc-pioneer`
  but not `LAB\svc-pioneer`. The plan line `session user` states the rule for your
  `VSPHERE_USER`, and every AC-021 sample prints the userNames it counted. If a sample shows too
  few sessions, the script prints the userName vCenter gave govc's own login as `VSPHERE_USER`
  and the distinct userNames of the other listed sessions. Compare them with `VSPHERE_USER`.
- Keep the workstation and vCenter clocks in sync with NTP. This is good practice, because it lets
  you read the script's output and the vCenter logs side by side, but the AC-022 check does not
  depend on it. It recognizes the new session by its session key rather than by vCenter's
  `loginTime`, and it times the delayed-logout wait on the workstation clock from the moment it
  first sees that session. `E2E_LOGOUT_SLACK` absorbs any remaining skew and timer jitter.

## 3. Tag and build

```sh
git checkout main && git pull --ff-only
git status --porcelain                  # must print nothing
git status --ignored --short examples/  # must print nothing -- see below
git tag -a v2.15.1 -m "v2.15.1"
git describe --dirty --always --tags    # must print exactly: v2.15.1
make -j2 build.all
ls -l _output/xpkg/linux_amd64/provider-vsphere-v2.15.1.xpkg \
      _output/xpkg/linux_arm64/provider-vsphere-v2.15.1.xpkg
```

The build derives `VERSION` from `git describe`, so do not pass `VERSION=...` by hand. The
`git describe` check matters: on an exact tag with a dirty tree, `VERSION` becomes
`v2.15.1-dirty`, and `make publish`'s `version.isdirty` guard only rejects versions ending in
`.dirty`, so it would not stop that publish.

The `git status --ignored --short examples/` check matters for a different reason: `.gitignore`
keeps a filled-in `examples/providerconfig/secret.yaml` or `namespaced-secret.yaml` out of `git
status --porcelain` and out of a plain `git add`, but `crossplane xpkg build --examples-root
examples` walks the `examples/` directory on disk and does not consult `.gitignore` at all: it
packs every `*.yaml` and `*.yml` file there, git-ignored or not (NFR-103, OT-025). The Makefile's
`check-examples-untracked` guard therefore stops `make build.all` and `make publish` while
`examples/` holds any untracked or git-ignored file, and this check finds such a file before you
tag. If it prints anything (`!! examples/providerconfig/secret.yaml` or similar), delete the
offending file and start again.

`make build.all` builds the provider for both platforms, builds each runtime image locally
(alpine with ca-certificates and bash, plus the provider binary; UID 65532, no Terraform), and
embeds each image in its platform's `.xpkg` with `crossplane xpkg build --embed-runtime-image`.
Nothing is pushed.

## 4. Negative check: publishing without a login fails

```sh
docker logout docker.io
make publish BRANCH_NAME=main           # must FAIL: unauthorized / authentication required
crane manifest docker.io/alphabravodevops/provider-vsphere:v2.15.1   # must fail: MANIFEST_UNKNOWN
git status --porcelain                  # must print nothing: no credential file was written
```

## 5. Log in interactively

```sh
docker login docker.io -u <dockerhub-user>
# Paste the access token at the "Password:" prompt.
```

Never pass `--password` or `-p` on the command line, and never commit or copy
`~/.docker/config.json` into the repository. `crossplane xpkg push` reads the credential from
the local docker configuration; there is no other login.

## 6. Publish

```sh
make -n publish BRANCH_NAME=main        # preview: one `crossplane xpkg push` with both .xpkg files
make publish BRANCH_NAME=main
git push origin v2.15.1
```

- `BRANCH_NAME=main` is required. A tag checkout has `BRANCH_NAME=HEAD`, and the build library
  only defines the publish step for `main`, `master` and `release-*`. Without it,
  `make publish` silently pushes nothing.
- The Makefile sets `XPKG_REG_ORGS ?= docker.io/alphabravodevops`, so the publish runs:
  `crossplane xpkg push --package-files _output/xpkg/linux_amd64/provider-vsphere-v2.15.1.xpkg --package-files _output/xpkg/linux_arm64/provider-vsphere-v2.15.1.xpkg docker.io/alphabravodevops/provider-vsphere:v2.15.1`
  That builds one index from both files and keeps each package's xpkg annotation layer.
- Never `docker push` the package, and never pull and re-push it to retag it. Docker's re-push
  drops the xpkg annotation layer and produces per-arch images. Never publish per-arch tags.
- `make promote` does nothing for Docker Hub (`XPKG_REG_ORGS_NO_PROMOTE`). `latest` is moved by
  hand in section 9.
- If the push fails with a registry host error, retry once with
  `make publish BRANCH_NAME=main XPKG_REG_ORGS=index.docker.io/alphabravodevops` and record which
  host worked. Consumers still pin `docker.io/alphabravodevops/provider-vsphere:<tag>`.

## 7. Verify the index

```sh
crane manifest docker.io/alphabravodevops/provider-vsphere:v2.15.1 | jq '.mediaType, [.manifests[].platform]'
# expected: "application/vnd.oci.image.index.v1+json" and the platforms linux/amd64 and linux/arm64
docker buildx imagetools inspect docker.io/alphabravodevops/provider-vsphere:v2.15.1   # alternative
crane digest docker.io/alphabravodevops/provider-vsphere:v2.15.1                      # note the digest
```

## 8. Lab e2e gate

Run the lab e2e from the **published** tag on Crossplane v2.2.0 (Pioneer's pin) and on v2.4.2
(current stable). Use a dedicated lab k3s context. In managed mode (the default) the script
installs Crossplane itself, and it refuses to start, with exit 2 and nothing changed, if it finds
any sign of Crossplane: a Deployment, in any namespace, with a `crossplane/crossplane` image, a
`crossplane` Helm release in `crossplane-system`, or the `providers.pkg.crossplane.io` CRD.
Unless `E2E_SKIP_CLEANUP=true`, at
the end it deletes only the objects it labelled and uninstalls the Crossplane it installed; if a
VirtualMachine MR or the CustomAttribute cannot be deleted, it leaves the provider, Crossplane and
the remaining objects in place and prints the manual cleanup commands. It uninstalls Crossplane only once Crossplane
has finished removing the provider (no ProviderRevision or provider Deployment left, and the
Lock's own finalizer cleared), and it waits up to `E2E_PROVIDER_REMOVAL_TIMEOUT` (default 10m)
for that: uninstalling earlier leaves objects whose finalizers nothing can clear. So a removal
timeout, or a failed delete of the Provider, leaves Crossplane installed too: the run reports
`CLEANUP INCOMPLETE` and `Result: FAIL`, and prints what is left and the recovery, the same
steps as the between-runs commands below. In the version gate it then stops the run there, so
nothing else runs on the legacy Crossplane. With `E2E_EXISTING_CROSSPLANE=true` it never
uninstalls Crossplane, but a removal that does not finish still reports `CLEANUP INCOMPLETE`, and
its recovery leaves that shared Crossplane running, which removes the ProviderRevision's finalizer
itself: it offers the finalizer patch only as a last resort, after the Crossplane pod logs, for
the installation's operator to decide on, and never for the Lock's own finalizer.
`E2E_SKIP_CLEANUP=true` skips only that end-of-run cleanup: the version gate still removes its
own Provider and uninstalls its Crossplane 1.x, and the run ends by listing what it left in place
with the commands to remove it. A passing run that left anything it labelled, or its Crossplane,
in place says `cleanup skipped` on its Result line and exits 0, but it is not a gate run, because
a gate run deletes everything it labelled and uninstalls the Crossplane it installed.
`--dry-run` (or `E2E_DRY_RUN=true`) prints every command of the run and executes none of them;
the local tool checks of section 2 still run.

A managed run that installed Crossplane, a gate-only run included, leaves objects that carry no
run label, with or without `E2E_SKIP_CLEANUP`, because `helm uninstall` removes only what the
Crossplane chart rendered:
- Crossplane's init container creates its `*.crossplane.io` CRDs (and a few objects of them, such
  as the Lock and the default DeploymentRuntimeConfig) and its ValidatingWebhookConfigurations
  itself: `crossplane-no-usages`, plus `crossplane` from Crossplane 1.x, which a v2 init
  container deletes.
- `helm install --create-namespace` creates the `crossplane-system` namespace outside the
  release.

The run ends by naming them. Because the CRDs remain, each later managed run on the same context
refuses to start until they are gone: remove them, the webhook configurations and the namespace,
as the commands below do between the two runs, or use a fresh lab cluster.

AC-022 (password rotation, US-006) is part of the gate. **At least one of the two runs must set
`E2E_REQUIRE_AC022=true` together with `E2E_VSPHERE_ROTATED_PASSWORD`, and that run must end in
a plain `Result: PASS`**, with no "AC-022 not asserted" suffix. The commands below do this on
the v2.2.0 run.

```sh
export KUBE_CONTEXT=<lab-k3s-context>
export VSPHERE_SERVER=<vcenter-host> VSPHERE_USER=<lab-user>
read -rs VSPHERE_PASSWORD && export VSPHERE_PASSWORD       # typed; never in shell history
export E2E_RESOURCE_POOL_ID=<resgroup-moid> E2E_DATASTORE_ID=<datastore-moid> \
       E2E_NETWORK_ID=<network-moid> E2E_TEMPLATE_UUID=<template-uuid> \
       E2E_GUEST_ID=<template-guest-id> E2E_FOLDER=<vm-folder>
# optional: E2E_FIRMWARE=efi E2E_HOST_SYSTEM_ID=<host-moid> E2E_DATACENTER=<dc> E2E_DISK_GB=40
# optional: E2E_VMFS_DATASTORE_ID=<vmfs-datastore-moid> for the AC-016 datastoreIdRef check
#           (defaults to E2E_DATASTORE_ID when that datastore is VMFS)
# optional: E2E_SESSION_USER_MATCH=exact to count only sessions of exactly VSPHERE_USER's account
#           and domain (section 2)

# Run 1: Crossplane v2.2.0 with AC-022 required. E2E_VSPHERE_ROTATED_PASSWORD is the NEW password
# you give VSPHERE_USER in vCenter by hand when the run pauses. Start it from an interactive
# terminal: it waits up to 30m on /dev/tty for you to confirm the change.
read -rs E2E_VSPHERE_ROTATED_PASSWORD && export E2E_VSPHERE_ROTATED_PASSWORD
# The dry run runs no kubectl, helm or vCenter command. It exits 2 on a missing setting, on a
# tool older than its section 2 minimum, or on a govc whose version it cannot determine.
E2E_DRY_RUN=true E2E_REQUIRE_AC022=true make e2e-lab E2E_CROSSPLANE_VERSION=2.2.0 E2E_PROVIDER_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
E2E_REQUIRE_AC022=true make e2e-lab E2E_CROSSPLANE_VERSION=2.2.0 E2E_PROVIDER_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
# must end with exactly: Result: PASS

# Run 1 changed the lab user's vCenter password: the rotated value is now the current one.
export VSPHERE_PASSWORD="$E2E_VSPHERE_ROTATED_PASSWORD" && unset E2E_VSPHERE_ROTATED_PASSWORD

# Run 1's Crossplane created its CRDs and webhook configurations itself, helm --create-namespace
# created crossplane-system, and helm uninstall left all of them, so the script refuses Run 2
# until the CRDs are gone. On this dedicated lab cluster only, delete the webhook configurations,
# the namespace and every *.crossplane.io CRD (with any objects of them left), or point
# KUBE_CONTEXT at a fresh lab k3s cluster instead.
# Keep the removal order of docs.crossplane.io guides/uninstall-crossplane: XRDs, then managed
# resources, then providers, then `helm uninstall`, then the namespace, with CRDs removed
# manually afterwards. So if Run 1 reported CLEANUP INCOMPLETE, first finish what it printed.
# When Crossplane had not finished removing the provider, Crossplane is still installed; then,
# in this order:
#   1. check the Crossplane pod logs, and wait until the second command lists no ProviderRevision,
#      no Deployment the third lists shows pkg.crossplane.io/provider=provider-vsphere under
#      SELECTOR, and the fourth no longer prints lock.pkg.crossplane.io (the same wait the script
#      makes before its own helm uninstall):
#      kubectl --context "$KUBE_CONTEXT" -n crossplane-system logs deploy/crossplane
#      kubectl --context "$KUBE_CONTEXT" get providerrevisions.pkg.crossplane.io -l pkg.crossplane.io/package=provider-vsphere
#      kubectl --context "$KUBE_CONTEXT" -n crossplane-system get deployments -o wide
#      kubectl --context "$KUBE_CONTEXT" get locks.pkg.crossplane.io lock -o jsonpath='{.metadata.finalizers}'
#   2. only then uninstall that Crossplane:
#      helm --kube-context "$KUBE_CONTEXT" uninstall crossplane --namespace crossplane-system
# Only then delete what that Crossplane left: its webhook configurations (their service is gone),
# its namespace, and its CRDs:
kubectl --context "$KUBE_CONTEXT" delete validatingwebhookconfigurations crossplane crossplane-no-usages --ignore-not-found
kubectl --context "$KUBE_CONTEXT" delete namespace crossplane-system --ignore-not-found --timeout=5m
kubectl --context "$KUBE_CONTEXT" get crd -o name | grep '\.crossplane\.io$' | xargs -r kubectl --context "$KUBE_CONTEXT" delete --timeout=5m

# If a delete still hangs past --timeout=5m, an object carries a finalizer that nothing is left
# running to clear. Only then, with Crossplane itself gone, and on this dedicated lab cluster
# only, clear it by hand:
#   kubectl --context "$KUBE_CONTEXT" patch <TYPE> <NAME> -p '{"metadata":{"finalizers": []}}' --type=merge

# Run 2: Crossplane v2.4.2 (E2E_REQUIRE_AC022 defaults to false)
make e2e-lab E2E_CROSSPLANE_VERSION=2.4.2 E2E_PROVIDER_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1
# ends with: Result: PASS (AC-022 not asserted: E2E_REQUIRE_AC022=false) -- fine, run 1 asserted it
```

Once you confirm the password change at the prompt, the lab user's vCenter password is the
rotated value, whether that run then passes or fails. Use it as `VSPHERE_PASSWORD` for the next
run, and pick a new `E2E_VSPHERE_ROTATED_PASSWORD` for any repeat of the AC-022 run. To rotate on
v2.4.2 as well, give that run its own `E2E_REQUIRE_AC022=true` and another new password.

During the AC-022 run the script first records the provider's vCenter session keys, still logged
in with the original password, and checks that it can see those sessions (section 2). If it
cannot, AC-022 FAILs at once and the script does not ask you to change the password. Otherwise it
pauses on `/dev/tty` for you to change the password and answer `yes` (or `no`; any other answer
is asked again). From your `yes` on, every govc call logs in with `E2E_VSPHERE_ROTATED_PASSWORD`,
because vCenter rejects the original password once it is changed; this includes the later
checks and the cleanup. The script lists the sessions once more with the rotated password, which
shows vCenter accepts it, then rotates the credentials Secrets and touches each VM. If vCenter
rejects the rotated password at that point, AC-022 FAILs and the script tells you to set the lab
user's password to exactly `E2E_VSPHERE_ROTATED_PASSWORD`, so the rest of the run can finish.
vCenter keeps a session alive across a password change, so Synced=True alone cannot prove the
provider rebuilt its client. The run therefore also requires, for each touched VM's
ProviderConfig, a NEW vCenter session before it counts a pass. A new session is one whose session
key was not listed before the rotation. The script compares keys, not vCenter's `loginTime`, so
the result does not depend on the vCenter and workstation clocks agreeing. Then it waits out
`E2E_LOGOUT_DELAY` (default 70m) plus `E2E_LOGOUT_SLACK` (default 10m) and confirms that every
pre-rotation session key is gone and that at least one provider session is still visible, so this
check cannot pass blind either. The wait is timed on the workstation clock from the moment the
script first saw a new session, not from the moment the Secret was rotated, since the provider's
own client swap can come up to one poll interval later. With the default delays, an AC-022 run
that sees the new sessions therefore lasts at least 80 minutes past the rotation.

In managed mode, each run's default phase (`all`) starts with the version gate (AC-008):
Crossplane 1.20.x must reject the package because `package/crossplane.yaml` requires `>=v2.0.0`.
If you run with `E2E_PHASE=vm` or `E2E_EXISTING_CROSSPLANE=true`, run the gate on its own:
`E2E_PHASE=version-gate E2E_REQUIRE_AC022=false make e2e-lab E2E_CROSSPLANE_VERSION=2.4.2 E2E_PROVIDER_PACKAGE=docker.io/alphabravodevops/provider-vsphere:v2.15.1`
(the script rejects `E2E_REQUIRE_AC022=true` with `E2E_PHASE=version-gate`, which never runs
AC-022). The gate installs its own Crossplane, so it needs a context without Crossplane or its
CRDs, and its Crossplane 1.x leaves CRDs and webhook configurations of its own: before the gate,
and before the next managed run after it, remove what the earlier Crossplane left as between the
two runs above.

The script prints a PASS/FAIL table and exits 0 only when nothing failed. It covers AC-005,
AC-006, AC-016, AC-018, AC-019, AC-022 and CUSTOM-ATTR-POWER (below) for both the cluster-scoped
and the namespaced VM,
AC-007 for the namespaced VM, and AC-008, AC-021 and AC-022's delayed-logout check for the
package as a whole, and it records SafeStart as information only. How AC-022 counts depends on
`E2E_REQUIRE_AC022`:
- `true`: AC-022 must PASS in every column. A missing `E2E_VSPHERE_ROTATED_PASSWORD` is rejected
  before anything is touched (exit 2). An AC-022 that ends SKIPPED for any other reason, for
  example no `yes` at the prompt within 30m, fails the run (`Result: FAIL`, exit 1).
- `false` (the default): AC-022 runs only when `E2E_VSPHERE_ROTATED_PASSWORD` is set. A passing
  run that did not assert it says `AC-022 not asserted: E2E_REQUIRE_AC022=false` on its Result
  line, as in `Result: PASS (AC-022 not asserted: E2E_REQUIRE_AC022=false)`, and exits 0. On its
  own, that is not a full gate run.

A third, namespaced-only VM exercises three known upjet/vSphere-provider behaviors in this provider
lineage (FR-105, FR-111). The last two follow OT-019: an out-of-band change to a field Crossplane
does not manage (an optional, provider-computed, late-init-ignored field that is not set in
`forProvider`, such as `annotation`) is left alone, while drift on other fields, including unset
fields enforced as their schema default or zero value, is corrected.
- INITPROVIDER (ankasoft #5) -- `spec.initProvider.annotation` must be applied on create.
- LATEINIT-DISABLED (ankasoft #7) -- this VM sets `annotation` only under `spec.initProvider`,
  and its `managementPolicies` exclude `LateInitialize`. `annotation` is Optional and Computed in
  the vSphere provider schema and late-init-ignored by this provider, so it is a field Crossplane
  does not manage, and an out-of-band change to it must not be reverted.
- DEFAULTED-DRIFT-CORRECTED (A-036/OT-019) -- `cpu_reservation` is also absent from
  `forProvider`, but it is not provider-computed: the schema gives it no default, so the provider
  enforces its zero value, `0`. An out-of-band change to it must be corrected back to `0` on the
  next reconcile, even though `LateInitialize` is excluded: that policy only stops Crossplane
  from copying observed values into `spec`, not the provider from enforcing an unset field. With
  vSphere provider 2.15.1 this correction may power a powered-off VM back on, the same as any
  other reconfigure (AC-019).

CUSTOM-ATTR-POWER (ankasoft #6) runs on the cluster-scoped and the namespaced VM right after
AC-019, which leaves them powered off out of band (a VM that is on is powered off with govc
first). The script creates a cluster-scoped CustomAttribute `e2e-<run>-attr` for
`VirtualMachine`, labelled like everything else it creates, and waits until it is Ready with its
key in `status.atProvider.id`. It sets `spec.forProvider.customAttributes` to
`{<key>: <value>}` on each VM and waits until vCenter shows that value with the VM still off.
Then it changes the value in vCenter with `govc fields.set`, waits one poll interval, and
requires both: the value is back to the spec value, and the VM is still `poweredOff`. vSphere
provider 2.15.1 corrects custom attribute drift with a custom attribute call and no
reconfigure, so it does not power the VM on. If AC-019 also failed for that VM, other drift may
be what powered it on: start there. The cleanup deletes the CustomAttribute after the VMs, while
the provider still runs, and then checks that vCenter no longer lists the attribute. The check
needs the privileges in section 2.

If any row fails, stop: do not move `latest`. Fix the problem and release `v2.15.1-1`. If no
`E2E_REQUIRE_AC022=true` run ended in a plain `Result: PASS`, AC-022 was not asserted: `latest`
does not move either. Repeat that run.

**Known risk: REST sessions in the AC-021 and AC-022 counts.** Nobody has yet checked this
against a lab vCenter. For each ProviderConfig, the provider's cached client holds two vCenter
logins: a SOAP (VIM) session, and a REST (CIS) session that the vmware/vsphere provider opens
for tags and content libraries. The client's delayed logout ends both. The script counts every
session in `SessionManager.sessionList` whose userName matches `VSPHERE_USER`, except govc's
own and those listed before the provider was installed, and it cannot tell a SOAP session from a
REST one. If your vCenter lists the REST logins
there too, a correct provider shows twice the expected count. With one provider pod and the two
ProviderConfigs the samples look like this:

```text
[AC-021] interval 1: 4 provider-user session(s); allowed 2..2 (at least 1 per ProviderConfig in use; at most 2 ProviderConfigs x 1 provider pod(s))
      <userName> via <userAgent> from <ipAddress> since <loginTime>
      (four such lines, where two are expected)
[AC-022] provider-user sessions after the delayed logout: 4; allowed 1..2; pre-rotation keys still alive: 0
```

AC-021 and the AC-022 `package` cell then FAIL. The AC-022 `cluster` and `namespaced` cells
still pass, because they need at least one new session per ProviderConfig. The `userAgent` value
on each session line is the only field that may tell the two kinds of login apart. Two lines
with one value and two with another point at doubled logins. If vCenter records the same value
for both kinds, only the count shows it. The pass/fail rule stays as it is: AC-021's bound comes
from the spec, so such a run has failed and `latest` does not move. For the spec owner, record:
- one complete `[AC-021] interval` sample: the count line and every session line, with its
  `userAgent`;
- the AC-022 delayed-logout lines, if the run got that far;
- the number of provider pods;
- the vCenter version and build.

## 9. Move latest, then check the tags

Only after **both** e2e runs passed, and the `E2E_REQUIRE_AC022=true` run ended in a plain
`Result: PASS` (section 8):

```sh
crane digest docker.io/alphabravodevops/provider-vsphere:latest    # record: previous latest digest (rollback)
docker buildx imagetools create -t docker.io/alphabravodevops/provider-vsphere:latest \
  docker.io/alphabravodevops/provider-vsphere:v2.15.1
test "$(crane digest docker.io/alphabravodevops/provider-vsphere:latest)" = \
     "$(crane digest docker.io/alphabravodevops/provider-vsphere:v2.15.1)" && echo "latest == v2.15.1"
crane ls docker.io/alphabravodevops/provider-vsphere | grep 2.12.0-terraform-vsphere
for t in $(crane ls docker.io/alphabravodevops/provider-vsphere | grep '^2\.12\.0-terraform-vsphere'); do
  echo "$t $(crane digest "docker.io/alphabravodevops/provider-vsphere:$t")"
done
```

`imagetools create` copies the index by digest, so the xpkg layers are untouched. Every legacy
`2.12.0-terraform-vsphere*` tag must still resolve. On 2026-09-24 they were
`2.12.0-terraform-vsphere`, `2.12.0-terraform-vsphere-1.19-go` and
`2.12.0-terraform-vsphere-1.21-go`, and `latest` pointed at
`sha256:144b0c827e3dc2029bd4f35ea97e430be245ce9794a833eddec860d57c126a20`, the same digest as
`2.12.0-terraform-vsphere`.

## 10. Log out

```sh
docker logout docker.io
```

## 11. Provider-only fix release

Use this when a fix changes only this repository and the Terraform provider stays at 2.15.1:

1. Merge the fix to `main`.
2. Pick the next counter: `git tag -l 'v2.15.1-*'`.
3. `git tag -a v2.15.1-1 -m "v2.15.1-1"`, then check that `git describe --dirty --always --tags`
   prints exactly `v2.15.1-1`.
4. Repeat sections 3 to 10 with `v2.15.1-1` in place of `v2.15.1`. The build files are then
   `provider-vsphere-v2.15.1-1.xpkg`, and the e2e runs against
   `docker.io/alphabravodevops/provider-vsphere:v2.15.1-1`.
5. Pioneer bumps its exact pin to the new tag.

## 12. Rollback

Point `latest` back at the digest recorded in section 9:

```sh
docker buildx imagetools create -t docker.io/alphabravodevops/provider-vsphere:latest \
  docker.io/alphabravodevops/provider-vsphere@sha256:<previous-latest-digest>
```

Leave the bad version tag in place and publish a `-N` fix. Consumers that pin exact tags are not
affected.

## 13. Never

- Delete or overwrite any published version tag, including the legacy
  `2.12.0-terraform-vsphere*` tags. `latest` is the only tag that moves (section 9).
- Publish from CI, or store Docker Hub credentials in CI.
- Commit credentials: Docker Hub tokens, `~/.docker/config.json`, vCenter passwords, kubeconfigs.
- `docker push` the package, or retag it with `docker pull` + `docker push`. Use
  `crossplane xpkg push` (through `make publish`) and `docker buildx imagetools create`.
- Publish per-arch tags.
- Use `make release.tag` for a `-N` tag.
- Run the lab e2e against a production or shared cluster.
