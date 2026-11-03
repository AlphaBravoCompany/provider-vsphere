# Provider vSphere

`provider-vsphere` is a [Crossplane](https://crossplane.io/) provider for VMware vSphere, built
with [upjet](https://github.com/crossplane/upjet) v2. The
[vmware/vsphere Terraform provider](https://github.com/vmware/terraform-provider-vsphere) 2.15.1
is compiled into the provider binary and runs in-process ("no-fork"), so no Terraform CLI and no
Terraform provider plugin are used at runtime. Every vSphere resource is available both as a
cluster-scoped managed resource (`*.vsphere.alphabravo.io`) and as a namespaced managed resource
(`*.vsphere.m.alphabravo.io`).

Upgrading from the `2.12.0-terraform-vsphere*` packages? The API groups and Kinds changed; see
[MIGRATION.md](MIGRATION.md).

## Requirements

- Crossplane **v2.0.0 or newer**. The package declares `crossplane.version: ">=v2.0.0"`, so
  Crossplane v1.x rejects it.
- Each release is gated on the lab end-to-end test passing on Crossplane v2.2.0 and v2.4.2
  (see [RELEASING.md](RELEASING.md)).
- A vCenter Server reachable from the provider pod.

## Install

The package is one multi-arch OCI index (linux/amd64 and linux/arm64) under a single tag. Use
the fully qualified reference; Crossplane v2 does not assume a default registry.

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-vsphere
spec:
  package: docker.io/alphabravodevops/provider-vsphere:v2.15.1
```

```sh
kubectl apply -f examples/install.yaml
kubectl wait provider.pkg provider-vsphere --for condition=Healthy --timeout 5m
```

Release tags follow the embedded Terraform provider version:

- `v2.15.1` is the first release built on vmware/vsphere 2.15.1.
- `v2.15.1-1`, `v2.15.1-2`, and so on are provider-only fixes on the same Terraform provider
  version.
- Pin an exact tag. Semver sorts `v2.15.1-1` below `v2.15.1`, so do not use version ranges.
  `latest` moves only after a release has passed the lab end-to-end test.

The file is [examples/install.yaml](examples/install.yaml).

### Activate only the resources you use (optional)

The package ships 96 CRDs: 90 managed resource CRDs (45 Kinds in each scope) and 6 provider
configuration CRDs. It declares the `SafeStart` capability, so Crossplane v2 installs each managed
resource CRD as an inactive ManagedResourceDefinition (MRD). A
[ManagedResourceActivationPolicy](https://docs.crossplane.io/latest/managed-resources/managed-resource-activation-policies/)
(MRAP) picks which MRDs become real CRDs. On k3s, where the API server runs in one process with
the other Kubernetes components, this saves about 3 MiB of API server memory per CRD you leave
inactive.

- **The default Helm install activates everything.** The Crossplane chart value
  `provider.defaultActivations` defaults to `["*"]`. It creates an MRAP named `default` that
  activates every MRD of every provider. To activate selectively, install or upgrade Crossplane
  with `--set provider.defaultActivations={}`. This setting affects every safe-start provider on
  the cluster, so give each of them an MRAP too. Deleting the `default` MRAP by hand works only
  until the next Crossplane pod restart, which re-creates it.
- **Activation is one-way.** An Active MRD never returns to Inactive. If an MRAP that matches
  everything, such as the chart's `default`, exists when the provider is first installed, every
  MRD becomes Active and stays Active. Turn the default off and apply your MRAP before the
  provider is first installed.

This MRAP activates only the cluster-scoped VirtualMachine:

```yaml
apiVersion: apiextensions.crossplane.io/v1alpha1
kind: ManagedResourceActivationPolicy
metadata:
  name: provider-vsphere-virtualmachines
spec:
  activate:
    - virtualmachines.virtualmachine.vsphere.alphabravo.io
    # Needed only on Crossplane v2.0.0 and v2.0.1, which also turn the provider configuration
    # CRDs into MRDs. Crossplane v2.0.2 and newer always install them, so these lines do nothing.
    - providerconfigs.vsphere.alphabravo.io
    - providerconfigusages.vsphere.alphabravo.io
```

- **Namespaced VMs.** Use `virtualmachines.virtualmachine.vsphere.m.alphabravo.io` instead. On
  v2.0.0 and v2.0.1, also list `providerconfigs`, `providerconfigusages`, `clusterproviderconfigs`
  and `clusterproviderconfigusages` in `vsphere.m.alphabravo.io`.
- **Other Kinds.** An entry is the CRD name `<plural>.<group>`, for example
  `datacenters.inventory.vsphere.alphabravo.io`. For 37 Kinds the plural is the lowercased Kind
  plus `s`. The other 8, such as `tagcategories`, are listed in
  [MIGRATION.md](MIGRATION.md#plural-resource-names). List every Kind you create, and every Kind a
  `*Ref` or `*Selector` field points at. A leading `*` activates a whole scope:
  `"*.vsphere.alphabravo.io"` or `"*.vsphere.m.alphabravo.io"`. [API groups](#api-groups) lists
  every group and Kind.
- **Check the result.** Run `kubectl get mrap provider-vsphere-virtualmachines -o
  jsonpath='{.status.activated}'` and `kubectl get mrds | grep alphabravo`.

## Credentials

The provider reads one JSON object from the Secret key that the ProviderConfig names in
`spec.credentials.secretRef` (`credentials` in the examples):

| Key | Required | Type | Meaning |
|---|---|---|---|
| `user` | yes | string | vCenter user, for example `administrator@vsphere.local`. The key is `user`, not `username`. |
| `password` | yes | string | Password of that user. |
| `vsphere_server` | yes | string | vCenter host name or IP address. |
| `allow_unverified_ssl` | no | boolean, or a string such as `"true"` / `"false"` | Skip TLS certificate verification (self-signed vCenter certificates). |
| `api_timeout` | no | positive whole number, or an integer string such as `"5"` | Timeout in minutes for the vCenter login and some vSphere API calls, not all of them. Mostly shared by the whole provider pod, not just this ProviderConfig (see the note below). |

If a required key is missing, or a value has the wrong type, the managed resource reports a
reconcile error that names the key. The error never contains the value.

> **Note:** `api_timeout` is not a timeout for every vSphere call, and for most calls it is not
> kept per ProviderConfig. The vSphere provider (vmware/vsphere 2.15.1) runs in-process. It uses
> the value in two ways, and many operations ignore it:
>
> - **Pod-wide `api_timeout`.** The vCenter login and a subset of API calls read a package-level
>   variable (`defaultAPITimeout`). Examples are calls in the tag, custom attribute, folder,
>   switch, port group, datastore and VM snapshot resources. Each vCenter login of a
>   ProviderConfig or ClusterProviderConfig overwrites that variable, so the value from the most
>   recent login applies to every ProviderConfig the pod serves. A login whose Secret omits
>   `api_timeout` overwrites it too, with the default: 5 minutes, or the provider pod's
>   `VSPHERE_API_TIMEOUT` environment variable when it is set.
> - **Per-ProviderConfig `api_timeout`.** VirtualMachine create and reconfigure tasks use the
>   `api_timeout` of the MR's own ProviderConfig. A clone uses the MR's `clone.timeout` instead.
> - **Fixed 5 minutes.** Many other resource operations use the provider's fixed 5-minute
>   timeout, whatever `api_timeout` says.
>
> Give every ProviderConfig and ClusterProviderConfig served by one provider pod the same
> `api_timeout`, or omit it from all of them. The other keys apply only to their own
> ProviderConfig.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: example-creds
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "user": "administrator@vsphere.local",
      "password": "REPLACE_WITH_PASSWORD",
      "vsphere_server": "vcenter.example.com",
      "allow_unverified_ssl": "true",
      "api_timeout": 5
    }
```

Copy [examples/providerconfig/secret.yaml.tmpl](examples/providerconfig/secret.yaml.tmpl), replace
the placeholders and apply the copy. Never commit real credentials.

The provider logs in to vCenter once per ProviderConfig or ClusterProviderConfig. That login opens
a SOAP session and, when vCenter offers the REST API, a REST session for tags and content
libraries. The provider reuses both for every managed resource that uses the ProviderConfig. When
the credentials JSON changes, the next reconcile logs in again with the new credentials. When a
managed resource reports a vCenter authentication or session error, such as `NotAuthenticated`,
the provider drops that login and logs in again on the next reconcile.

## ProviderConfig

Which ProviderConfig type a managed resource (MR) uses depends on its scope:

| MR scope | MR API groups | ProviderConfig types | `providerConfigRef` |
|---|---|---|---|
| Cluster | `*.vsphere.alphabravo.io` | `ProviderConfig` in `vsphere.alphabravo.io/v1beta1` (cluster-scoped) | `name`, and no `kind` field; an omitted `providerConfigRef` defaults to `name: default` |
| Namespaced | `*.vsphere.m.alphabravo.io` | `ProviderConfig` in `vsphere.m.alphabravo.io/v1beta1` (same namespace as the MR), or `ClusterProviderConfig` in `vsphere.m.alphabravo.io/v1beta1` (cluster-scoped) | `kind` and `name`, both required; only an omitted `providerConfigRef` defaults to `kind: ClusterProviderConfig, name: default` |

- **Cluster-scoped ProviderConfig:**
  [examples/providerconfig/providerconfig.yaml](examples/providerconfig/providerconfig.yaml).
  Reads the Secret named in `spec.credentials.secretRef`, including its namespace.
- **ClusterProviderConfig:**
  [examples/providerconfig/clusterproviderconfig.yaml](examples/providerconfig/clusterproviderconfig.yaml).
  Serves namespaced MRs in every namespace, and reads the Secret from `secretRef.namespace`.
- **Namespaced ProviderConfig:**
  [examples/providerconfig/namespaced-providerconfig.yaml](examples/providerconfig/namespaced-providerconfig.yaml).
  Serves MRs in its own namespace. It always reads the Secret from the MR's namespace:
  `secretRef.namespace` is required by the schema but ignored. Keep the Secret
  ([examples/providerconfig/namespaced-secret.yaml.tmpl](examples/providerconfig/namespaced-secret.yaml.tmpl))
  in that namespace.

> **Warning:** a namespaced MR that omits `providerConfigRef` entirely is defaulted to the
> **ClusterProviderConfig named `default`**, not a ProviderConfig in its own namespace. The default
> applies only when the whole field is absent. A `providerConfigRef` that sets `name` without
> `kind` is rejected by the API server with `spec.providerConfigRef.kind: Required value`.

Always set both fields on a namespaced MR. To use a namespaced ProviderConfig in the MR's
namespace:

```yaml
spec:
  providerConfigRef:
    kind: ProviderConfig
    name: default
```

To use a ClusterProviderConfig:

```yaml
spec:
  providerConfigRef:
    kind: ClusterProviderConfig
    name: default
```

## VirtualMachine examples

Cluster-scoped VM (abbreviated). The full file is
[examples/cluster/virtualmachine/virtualmachine.yaml](examples/cluster/virtualmachine/virtualmachine.yaml).

```yaml
apiVersion: virtualmachine.vsphere.alphabravo.io/v1alpha1
kind: VirtualMachine
metadata:
  name: example-vm-cluster
spec:
  forProvider:
    name: example-vm-cluster
    numCpus: 2
    memory: 4096
    disk:
      - label: disk0
        unitNumber: 0
        size: 40
        thinProvisioned: true
    waitForGuestNetTimeout: 0
    waitForGuestIpTimeout: 0
    networkInterface:
      - networkId: REPLACE_WITH_NETWORK_ID
    datastoreId: REPLACE_WITH_DATASTORE_ID
    resourcePoolId: REPLACE_WITH_RESOURCE_POOL_ID
    folder: REPLACE_WITH_FOLDER
    clone:
      - templateUuid: REPLACE_WITH_TEMPLATE_UUID
    guestId: REPLACE_WITH_GUEST_ID
    firmware: REPLACE_WITH_FIRMWARE
  providerConfigRef:
    name: default
```

Namespaced VM (abbreviated). The full file is
[examples/namespaced/virtualmachine/virtualmachine.yaml](examples/namespaced/virtualmachine/virtualmachine.yaml).

```yaml
apiVersion: virtualmachine.vsphere.m.alphabravo.io/v1alpha1
kind: VirtualMachine
metadata:
  name: example-vm-namespaced
  namespace: default
spec:
  forProvider:
    name: example-vm-namespaced
    numCpus: 2
    memory: 4096
    disk:
      - label: disk0
        unitNumber: 0
        size: 40
        thinProvisioned: true
    waitForGuestNetTimeout: 0
    waitForGuestIpTimeout: 0
    networkInterface:
      - networkId: REPLACE_WITH_NETWORK_ID
    datastoreId: REPLACE_WITH_DATASTORE_ID
    resourcePoolId: REPLACE_WITH_RESOURCE_POOL_ID
    folder: REPLACE_WITH_FOLDER
    clone:
      - templateUuid: REPLACE_WITH_TEMPLATE_UUID
    guestId: REPLACE_WITH_GUEST_ID
    firmware: REPLACE_WITH_FIRMWARE
  providerConfigRef:
    kind: ProviderConfig
    name: default
```

Replace each `REPLACE_WITH_*` value with the value from your vCenter: the managed object IDs of the
network, datastore and resource pool, the VM folder path, the template's UUID, and the template's
guest OS ID (for example `ubuntu64Guest`) and firmware (`bios` or `efi`).

- **Placement references.** Instead of literal IDs, a VirtualMachine can point at other managed
  resources with `*Ref` or `*Selector` fields. These exist for `datacenterId` (Datacenter),
  `resourcePoolId` (ResourcePool), `datastoreId` (VmfsDatastore), `datastoreClusterId`
  (DatastoreCluster), `hostSystemId` (Host), `folder` (Folder), `networkInterface[].networkId`
  (DistributedPortGroup) and `storagePolicyId` (VmStoragePolicy).
- **NFS datastores.** A reference targets exactly one Kind, so `datastoreIdRef` resolves only
  against a VmfsDatastore. For an NFS datastore (NasDatastore), set `datastoreId` literally.
- **Power state.** vSphere provider 2.15.1 powers the VM on after every reconfigure that updates
  it. See
  [Power state and out-of-band changes](#power-state-and-out-of-band-changes) for which vCenter
  changes cause one.

### Power state and out-of-band changes

vSphere provider 2.15.1 powers a VM on after every reconfigure that updates it. So when the provider
corrects drift with a reconfigure on a VM that someone powered off in vCenter, the VM comes back
on. Whether a change made in vCenter counts as drift, and whether correcting it needs a
reconfigure, depends on the field:

| Field | Examples | Change made in vCenter |
|---|---|---|
| Set in `spec.forProvider` | any field you set | reverted to your value. Most fields are reverted with a reconfigure, and the VM powers on. `folder`, `resourcePoolId`, `hostSystemId`, `datastoreId`, `tags` and `customAttributes` are reverted by a move, a migration, or a tag or custom attribute call, which on its own does not power the VM on |
| Not set; vCenter picks it (excluded from late-initialization), or the provider does not read it back | `extraConfig` keys you do not list (only listed keys are read back); `annotation`, `guestId`, `hvMode`, `eptRviMode`, `hostSystemId`, `datastoreId`, `storagePolicyId`, `hardwareVersion`, `cpuShareCount`, `memoryShareCount`; `networkInterface[].macAddress` and `bandwidthShareCount`; `disk[].datastoreId`, `path` and `storagePolicyId` | ignored; a VM powered off in vCenter stays off |
| Not set; has a Terraform schema default | `cpuLimit` and `memoryLimit` (`-1`), `cpuShareLevel` and `memoryShareLevel` (`normal`), `latencySensitivity`, `swapPlacementPolicy` | reverted to the default; the VM powers on |
| Not set; no default, so Terraform enforces zero or `false` | `cpuReservation` and `memoryReservation` (`0`), `cpuHotAddEnabled`, `memoryHotAddEnabled`, `nestedHvEnabled` | reset to `0` or `false`, and the VM powers on. Late-initialization then copies the vCenter value into `spec.forProvider`, and the next reconcile applies it in a second reconfigure. |

The lab e2e checks the `customAttributes` case of the first row against a real vCenter. Its
CUSTOM-ATTR-POWER check, in the vm phase of `cluster/test/e2e-lab.sh` (see
[RELEASING.md, section 8](RELEASING.md#8-lab-e2e-gate)), changes a custom attribute value in
vCenter on a VM powered off there, and requires the value to be reverted with the VM still off.
It does not exercise the other fields of that row.

Only the fields in the second row are left alone when you omit them. Every other optional field
that vCenter stores is managed even when it is not in `spec.forProvider`. Settings that only the
provider uses, such as `waitForGuestNetTimeout`, have no vCenter value to change. To avoid unwanted
power-ons:

- **Own these settings in the MR.** Set the values you want explicitly in `spec.forProvider`, for
  example `cpuReservation: 0`. A change in vCenter is then reverted to your value in one
  reconfigure. The VM still powers on, so do not change these settings in vCenter.
- **Stop reconciling while a VM must stay off.** Leave `Update` out of `spec.managementPolicies`,
  for example `["Observe", "Create", "Delete", "LateInitialize"]`, or pause the MR with the
  annotation `crossplane.io/paused: "true"`. Drift is left alone, and spec changes are not applied
  either. When `Update` comes back or the pause ends, pending drift is corrected, and that powers
  the VM on.
- **Set externally owned fields at creation only.** A field set only in `spec.initProvider` is
  applied when the VM is created and is not enforced afterwards. This works on its own for the
  fields in the second row, such as `annotation`. For any other field, also leave `LateInitialize`
  out of `spec.managementPolicies`. Otherwise late-initialization copies the observed value into
  `spec.forProvider`, where it is enforced again.

## API groups

All managed resources are `v1alpha1`. Each of the 43 Kinds that existed before is the old Kind
without its `VSphere` prefix, for example `VSphereVirtualMachine` became `VirtualMachine`.
`ConfigurationProfile` and `DistributedVirtualSwitchPvlanMapping` are new.
[MIGRATION.md](MIGRATION.md) has the per-resource map.

| Short group | Cluster-scoped API group | Namespaced API group | Kinds |
|---|---|---|---|
| `administration` | `administration.vsphere.alphabravo.io` | `administration.vsphere.m.alphabravo.io` | License |
| `hostandclustermanagement` | `hostandclustermanagement.vsphere.alphabravo.io` | `hostandclustermanagement.vsphere.m.alphabravo.io` | ComputeCluster, ComputeClusterHostGroup, ComputeClusterVmAffinityRule, ComputeClusterVmAntiAffinityRule, ComputeClusterVmDependencyRule, ComputeClusterVmGroup, ComputeClusterVmHostRule, ConfigurationProfile, DpmHostOverride, DrsVmOverride, HaVmOverride, Host, ResourcePool, Vnic |
| `inventory` | `inventory.vsphere.alphabravo.io` | `inventory.vsphere.m.alphabravo.io` | CustomAttribute, Datacenter, Folder, Tag, TagCategory |
| `lifecycle` | `lifecycle.vsphere.alphabravo.io` | `lifecycle.vsphere.m.alphabravo.io` | OfflineSoftwareDepot |
| `networking` | `networking.vsphere.alphabravo.io` | `networking.vsphere.m.alphabravo.io` | DistributedPortGroup, DistributedVirtualSwitch, DistributedVirtualSwitchPvlanMapping, HostPortGroup, HostVirtualSwitch |
| `security` | `security.vsphere.alphabravo.io` | `security.vsphere.m.alphabravo.io` | EntityPermissions, Role |
| `storage` | `storage.vsphere.alphabravo.io` | `storage.vsphere.m.alphabravo.io` | DatastoreCluster, DatastoreClusterVmAntiAffinityRule, File, NasDatastore, StorageDrsVmOverride, VmStoragePolicy, VmfsDatastore |
| `virtualmachine` | `virtualmachine.vsphere.alphabravo.io` | `virtualmachine.vsphere.m.alphabravo.io` | ContentLibrary, ContentLibraryItem, GuestOsCustomization, VappContainer, VappEntity, VirtualDisk, VirtualMachine, VirtualMachineSnapshot |
| `workloadmanagement` | `workloadmanagement.vsphere.alphabravo.io` | `workloadmanagement.vsphere.m.alphabravo.io` | Supervisor, VirtualMachineClass |

The provider configuration types live in `vsphere.alphabravo.io/v1beta1` (cluster-scoped
`ProviderConfig`, `ProviderConfigUsage`) and `vsphere.m.alphabravo.io/v1beta1` (namespaced
`ProviderConfig`, `ProviderConfigUsage`; cluster-scoped `ClusterProviderConfig`,
`ClusterProviderConfigUsage`).

## Lineage

1. **Ankasoft fork.** This repository started as a fork of the
   [Ankasoft vSphere provider](https://github.com/ankasoftco/provider-vsphere), to pick up newer
   Terraform vSphere provider fixes for deploying OVF/OVA files directly to an ESXi host.
2. **AlphaBravo 2.12.0.** Built on hashicorp/vsphere 2.12.0 with upjet 0.9 in CLI mode: a
   Terraform binary and provider plugin ran inside the image. It had cluster-scoped resources only,
   in `*.crossplane.io` groups with `VSphere`-prefixed Kinds. Its `2.12.0-terraform-vsphere*` tags
   stay published.
3. **v2.15.1 (current).** Built on vmware/vsphere 2.15.1 with upjet v2 in no-fork mode, so there is
   no Terraform at runtime. Every resource is available in both scopes, in the
   `vsphere.alphabravo.io` groups. [MIGRATION.md](MIGRATION.md) maps every old group and Kind to
   the new ones.

## Developing

```sh
make submodules      # fetch the crossplane/build submodule (first run)
make generate        # regenerate config/schema.json, apis/, controllers, CRDs and examples-generated/
make build           # build the provider binary, image and xpkg for linux on the host CPU architecture
make build.all       # the same for linux_amd64 and linux_arm64
make test            # unit tests, including the credential and session-cache tests in internal/clients
make lint            # golangci-lint v2 with .golangci.yml
make reviewable      # make generate, make lint and make test: run before opening a pull request
make run             # run the provider out-of-cluster against the current kube context
```

- **goimports.** `make generate` runs `goimports` from your `PATH`. Install the version pinned in
  `go.mod` by running `go install golang.org/x/tools/cmd/goimports` in the repository, as CI's
  `check-diff` job does.
- **Terraform at build time only.** `make generate` uses the MPL-licensed Terraform 1.5.7, which
  it downloads into the build tools directory the first time, only to read the vmware/vsphere
  provider schema. The Makefile refuses any Terraform release from 1.6.0 on, because those
  releases are BSL-licensed.
- **Generated files.** `zz_*` files, `package/crds` and `examples-generated` are generated. Never
  edit them by hand; change `config/` and run `make generate`.
- **Lab script checks.** When you change anything under `cluster/test/`, or the lab runbook in
  [RELEASING.md](RELEASING.md) (sections 2 and 8), also run the two checks that CI's `unit-tests`
  job runs on the lab scripts. `make reviewable` does not run them. Both must exit 0.

  ```sh
  bash cluster/test/e2e-lab-selftest.sh
  shellcheck -x cluster/test/e2e-lab.sh cluster/test/e2e-lab-selftest.sh
  ```

  The self-test is offline. It sources `e2e-lab.sh` and runs its functions against a fake vCenter
  and stub `kubectl`, `helm`, `docker` and `crossplane` binaries, and never contacts a cluster, a
  vCenter or a registry. It needs bash 4 or newer to run it and `jq` 1.6 or newer, plus these
  commands on `PATH`, in their GNU, BSD/macOS or BusyBox versions: `awk`, `bash` (the fake govc
  runs as `#!/usr/bin/env bash`), `cat`, `chmod`, `cut`, `date`, `dirname`, `grep`, `head`, `ls`,
  `mkdir`, `mktemp`, `paste`, `rm`, `sed`, `sleep`, `sort`, `tail` and `tr`. It needs no network, cluster,
  vCenter, `kubectl`, `helm`, `govc`, `docker` or `crossplane`. Before the first case it checks
  all of these requirements and names every one that is missing. `shellcheck` is needed only for
  the second command.
- **Lab end-to-end test.** `make e2e-lab` runs
  [cluster/test/e2e-lab.sh](cluster/test/e2e-lab.sh) against the current kube context and a lab
  vCenter. A human runs it by hand from the published tag, on a dedicated lab cluster only, never on
  a shared or production cluster. See
  [RELEASING.md, section 8](RELEASING.md#8-lab-e2e-gate) for the required environment variables.
  Its vm phase creates VirtualMachines in both scopes, a cluster-scoped CustomAttribute (for its
  CUSTOM-ATTR-POWER check) and, when `E2E_VMFS_DATASTORE_ID` is set or
  `E2E_DATASTORE_ID` is a VMFS datastore, an Observe-only cluster-scoped VmfsDatastore. If the
  lab cluster activates selectively (see
  [Activate only the resources you use](#activate-only-the-resources-you-use-optional)), those
  Kinds must be active.

### Pull request CI

[.github/workflows/ci.yml](.github/workflows/ci.yml) (workflow `CI`) runs on every pull request,
on pushes to `main` and `release-*`, and on manual dispatch. Its token can only read the
repository (`permissions: contents: read`, plus `actions: read` for `detect-noop`). CI never logs
in to a registry and never publishes, and
it does not gate a release: the lab e2e in [RELEASING.md](RELEASING.md) does.

| Job | Steps that check something |
|---|---|
| `detect-noop` | **Detect No-op Changes** (fkirc/skip-duplicate-actions). On a pull request, every other job is skipped when the changes since the last passing run touch only `**.md`, `**.png` or `**.jpg` files, or when a run on the same content already passed. Pushes and manual runs are never skipped. |
| `report-breaking-changes` | Pull requests only. **Get modified CRDs** (`package/crds/**`). If any changed: **Fetch Base Branch**, then **Report breaking CRD OpenAPI v3 schema changes** (`make crddiff`). Breaking changes are printed, not fatal; the step fails only when crddiff cannot run. |
| `lint` | **Vendor Dependencies** (`make vendor vendor.check`; fails if `go.mod` or `go.sum` is not tidy), then **Lint** (golangci-lint-action, same golangci-lint version as `make lint`). |
| `check-diff` | **Vendor Dependencies**, **Install goimports** (`go install golang.org/x/tools/cmd/goimports`), then **Check Diff** (`make check-diff`: `make generate`, then fail on any changed or untracked file). |
| `unit-tests` | **Self-test the Lab E2E Script** (`bash cluster/test/e2e-lab-selftest.sh`), **Lint the Lab E2E Scripts** (`shellcheck -x cluster/test/e2e-lab.sh cluster/test/e2e-lab-selftest.sh`), **Vendor Dependencies**, then **Run Unit Tests** (`make -j2 test`). |
| `build` | **Setup QEMU**, **Setup Docker Buildx**, **Vendor Dependencies**, then **Build Artifacts** (`make -j2 build.all` with `BUILD_ARGS: "--load"`: binary, image and xpkg for linux_amd64 and linux_arm64; nothing is pushed). |

All jobs except `detect-noop` also run **Checkout** (with submodules) and **Setup Go** (the Go
version in `go.mod`). `lint`, `check-diff`, `unit-tests` and `build` also run
**Find the Go Caches**, **Cache the Go Build Cache** and **Cache Go Dependencies**, and
`unit-tests` and `build` run **Fetch History** (`git fetch --prune --unshallow`).

## Releasing

Releases are cut by hand with `make publish` after an interactive `docker login`. No registry
credential is stored in this repository or in CI. See [RELEASING.md](RELEASING.md).

## Report a Bug

For filing bugs, suggesting improvements, or requesting new features, please open an
[issue](https://github.com/AlphaBravoCompany/provider-vsphere/issues).

## License

[Apache 2.0](LICENSE).
