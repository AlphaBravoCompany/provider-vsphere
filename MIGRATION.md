# Migrating from provider-vsphere 2.12.0 to v2.15.1

This guide maps the legacy AlphaBravo `2.12.0-terraform-vsphere*` provider (hashicorp/vsphere
2.12.0, upjet 0.9) to `v2.15.1` (vmware/vsphere 2.15.1, upjet v2, Crossplane v2). It is written for
the Pioneer follow-up change, but applies to any consumer.

## Summary

- **This is a breaking API change.** Every API group and every managed resource Kind changed. The
  StoreConfig type is gone, and the provider now needs Crossplane v2.0.0 or newer.
- **There is no in-place upgrade path.** No live managed resources of the legacy provider exist, so
  nothing is converted. Consumers switch their manifests to the new groups and Kinds and install
  the new package.
- **Two scopes.** Every resource is now generated twice:
  - cluster-scoped in `<group>.vsphere.alphabravo.io/v1alpha1`, the closest match to the legacy
    behavior;
  - namespaced in `<group>.vsphere.m.alphabravo.io/v1alpha1`.
- **Kinds lose the `VSphere` prefix.** The rest of the name keeps its casing, for example
  `VSphereVirtualMachine` becomes `VirtualMachine`.
- **Attributes are unchanged.** vmware/vsphere 2.15.1 changes no attribute on the 44 resources
  shared with 2.12.0, so `spec.forProvider` and `status.atProvider` field names carry over
  unchanged. One exception: on namespaced MRs the `*SecretRef` fields have no `namespace`, so the
  Secret must be in the MR's namespace. This affects Host `passwordSecretRef` and the
  customization secrets of GuestOsCustomization and VirtualMachine.

## Package

| | Legacy | New |
|---|---|---|
| Package | `docker.io/alphabravodevops/provider-vsphere:2.12.0-terraform-vsphere-1.21-go` | `docker.io/alphabravodevops/provider-vsphere:v2.15.1` |
| Architectures | no publishing set up in the repository (empty `XPKG_REG_ORGS`); the old install example used a per-architecture repository, `provider-vsphere-amd64:latest` | one multi-arch OCI index: linux/amd64 and linux/arm64 under the same tag |
| Terraform at runtime | Terraform CLI and provider plugin inside the image | none; the provider runs in-process |
| Crossplane | no `crossplane.version` constraint in the package (Pioneer's BOM pairs it with Crossplane v2.2.0) | `>=v2.0.0` (each release is gated on the lab e2e passing on v2.2.0 and v2.4.2) |

- **Tag scheme.** Tags mirror the embedded Terraform provider version. `v2.15.1` is the first
  release. Provider-only fixes on the same Terraform provider version are `v2.15.1-1`,
  `v2.15.1-2`, and so on.
- **Pin exact tags.** Semver sorts `v2.15.1-1` below `v2.15.1`, so never use a range.
- **Legacy tags stay.** All `2.12.0-terraform-vsphere*` tags stay published and unchanged.
- **`latest`.** It moves to `v2.15.1` only after the lab end-to-end test passes against the
  published index (see [RELEASING.md](RELEASING.md)).
- **Airgap mirrors.** Mirror the tag as an index, for example with `crane copy`. A
  `docker pull` + `docker push` copies only one architecture, and it can also lose the xpkg layer
  annotation.

## Resource map

This table was generated from the migration spec's Source Inventory using its Destination Naming
Rule:

- **Legacy:** `<group>.crossplane.io/v1alpha1` and the legacy Kind.
- **Cluster-scoped:** `<group>.vsphere.alphabravo.io/v1alpha1` and the new Kind.
- **Namespaced:** `<group>.vsphere.m.alphabravo.io/v1alpha1` and the new Kind.

Two resources are new and have no legacy Kind:

- `vsphere_distributed_virtual_switch_pvlan_mapping` has resource code in 2.12.0 but was never
  generated.
- `vsphere_configuration_profile` was added upstream in 2.15.x.

All legacy resources were cluster-scoped.

| Terraform resource | Legacy apiVersion / kind (cluster-scoped) | Cluster-scoped apiVersion / kind | Namespaced apiVersion / kind |
|---|---|---|---|
| `vsphere_compute_cluster` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeCluster` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeCluster` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeCluster` |
| `vsphere_compute_cluster_host_group` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterHostGroup` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterHostGroup` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterHostGroup` |
| `vsphere_compute_cluster_vm_affinity_rule` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterVmAffinityRule` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterVmAffinityRule` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterVmAffinityRule` |
| `vsphere_compute_cluster_vm_anti_affinity_rule` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterVmAntiAffinityRule` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterVmAntiAffinityRule` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterVmAntiAffinityRule` |
| `vsphere_compute_cluster_vm_dependency_rule` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterVmDependencyRule` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterVmDependencyRule` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterVmDependencyRule` |
| `vsphere_compute_cluster_vm_group` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterVmGroup` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterVmGroup` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterVmGroup` |
| `vsphere_compute_cluster_vm_host_rule` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereComputeClusterVmHostRule` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ComputeClusterVmHostRule` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ComputeClusterVmHostRule` |
| `vsphere_configuration_profile` | — (new) | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ConfigurationProfile` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ConfigurationProfile` |
| `vsphere_content_library` | `virtualmachine.crossplane.io/v1alpha1` `VSphereContentLibrary` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `ContentLibrary` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `ContentLibrary` |
| `vsphere_content_library_item` | `virtualmachine.crossplane.io/v1alpha1` `VSphereContentLibraryItem` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `ContentLibraryItem` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `ContentLibraryItem` |
| `vsphere_custom_attribute` | `inventory.crossplane.io/v1alpha1` `VSphereCustomAttribute` | `inventory.vsphere.alphabravo.io/v1alpha1` `CustomAttribute` | `inventory.vsphere.m.alphabravo.io/v1alpha1` `CustomAttribute` |
| `vsphere_datacenter` | `inventory.crossplane.io/v1alpha1` `VSphereDatacenter` | `inventory.vsphere.alphabravo.io/v1alpha1` `Datacenter` | `inventory.vsphere.m.alphabravo.io/v1alpha1` `Datacenter` |
| `vsphere_datastore_cluster` | `storage.crossplane.io/v1alpha1` `VSphereDatastoreCluster` | `storage.vsphere.alphabravo.io/v1alpha1` `DatastoreCluster` | `storage.vsphere.m.alphabravo.io/v1alpha1` `DatastoreCluster` |
| `vsphere_datastore_cluster_vm_anti_affinity_rule` | `storage.crossplane.io/v1alpha1` `VSphereDatastoreClusterVmAntiAffinityRule` | `storage.vsphere.alphabravo.io/v1alpha1` `DatastoreClusterVmAntiAffinityRule` | `storage.vsphere.m.alphabravo.io/v1alpha1` `DatastoreClusterVmAntiAffinityRule` |
| `vsphere_distributed_port_group` | `networking.crossplane.io/v1alpha1` `VSphereDistributedPortGroup` | `networking.vsphere.alphabravo.io/v1alpha1` `DistributedPortGroup` | `networking.vsphere.m.alphabravo.io/v1alpha1` `DistributedPortGroup` |
| `vsphere_distributed_virtual_switch` | `networking.crossplane.io/v1alpha1` `VSphereDistributedVirtualSwitch` | `networking.vsphere.alphabravo.io/v1alpha1` `DistributedVirtualSwitch` | `networking.vsphere.m.alphabravo.io/v1alpha1` `DistributedVirtualSwitch` |
| `vsphere_distributed_virtual_switch_pvlan_mapping` | — (new) | `networking.vsphere.alphabravo.io/v1alpha1` `DistributedVirtualSwitchPvlanMapping` | `networking.vsphere.m.alphabravo.io/v1alpha1` `DistributedVirtualSwitchPvlanMapping` |
| `vsphere_dpm_host_override` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereDpmHostOverride` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `DpmHostOverride` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `DpmHostOverride` |
| `vsphere_drs_vm_override` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereDrsVmOverride` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `DrsVmOverride` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `DrsVmOverride` |
| `vsphere_entity_permissions` | `security.crossplane.io/v1alpha1` `VSphereEntityPermissions` | `security.vsphere.alphabravo.io/v1alpha1` `EntityPermissions` | `security.vsphere.m.alphabravo.io/v1alpha1` `EntityPermissions` |
| `vsphere_file` | `storage.crossplane.io/v1alpha1` `VSphereFile` | `storage.vsphere.alphabravo.io/v1alpha1` `File` | `storage.vsphere.m.alphabravo.io/v1alpha1` `File` |
| `vsphere_folder` | `inventory.crossplane.io/v1alpha1` `VSphereFolder` | `inventory.vsphere.alphabravo.io/v1alpha1` `Folder` | `inventory.vsphere.m.alphabravo.io/v1alpha1` `Folder` |
| `vsphere_guest_os_customization` | `virtualmachine.crossplane.io/v1alpha1` `VSphereGuestOsCustomization` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `GuestOsCustomization` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `GuestOsCustomization` |
| `vsphere_ha_vm_override` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereHaVmOverride` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `HaVmOverride` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `HaVmOverride` |
| `vsphere_host` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereHost` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `Host` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `Host` |
| `vsphere_host_port_group` | `networking.crossplane.io/v1alpha1` `VSphereHostPortGroup` | `networking.vsphere.alphabravo.io/v1alpha1` `HostPortGroup` | `networking.vsphere.m.alphabravo.io/v1alpha1` `HostPortGroup` |
| `vsphere_host_virtual_switch` | `networking.crossplane.io/v1alpha1` `VSphereHostVirtualSwitch` | `networking.vsphere.alphabravo.io/v1alpha1` `HostVirtualSwitch` | `networking.vsphere.m.alphabravo.io/v1alpha1` `HostVirtualSwitch` |
| `vsphere_license` | `administration.crossplane.io/v1alpha1` `VSphereLicense` | `administration.vsphere.alphabravo.io/v1alpha1` `License` | `administration.vsphere.m.alphabravo.io/v1alpha1` `License` |
| `vsphere_nas_datastore` | `storage.crossplane.io/v1alpha1` `VSphereNasDatastore` | `storage.vsphere.alphabravo.io/v1alpha1` `NasDatastore` | `storage.vsphere.m.alphabravo.io/v1alpha1` `NasDatastore` |
| `vsphere_offline_software_depot` | `lifecycle.crossplane.io/v1alpha1` `VSphereOfflineSoftwareDepot` | `lifecycle.vsphere.alphabravo.io/v1alpha1` `OfflineSoftwareDepot` | `lifecycle.vsphere.m.alphabravo.io/v1alpha1` `OfflineSoftwareDepot` |
| `vsphere_resource_pool` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereResourcePool` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `ResourcePool` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `ResourcePool` |
| `vsphere_role` | `security.crossplane.io/v1alpha1` `VSphereRole` | `security.vsphere.alphabravo.io/v1alpha1` `Role` | `security.vsphere.m.alphabravo.io/v1alpha1` `Role` |
| `vsphere_storage_drs_vm_override` | `storage.crossplane.io/v1alpha1` `VSphereStorageDrsVmOverride` | `storage.vsphere.alphabravo.io/v1alpha1` `StorageDrsVmOverride` | `storage.vsphere.m.alphabravo.io/v1alpha1` `StorageDrsVmOverride` |
| `vsphere_supervisor` | `workloadmanagement.crossplane.io/v1alpha1` `VSphereSupervisor` | `workloadmanagement.vsphere.alphabravo.io/v1alpha1` `Supervisor` | `workloadmanagement.vsphere.m.alphabravo.io/v1alpha1` `Supervisor` |
| `vsphere_tag` | `inventory.crossplane.io/v1alpha1` `VSphereTag` | `inventory.vsphere.alphabravo.io/v1alpha1` `Tag` | `inventory.vsphere.m.alphabravo.io/v1alpha1` `Tag` |
| `vsphere_tag_category` | `inventory.crossplane.io/v1alpha1` `VSphereTagCategory` | `inventory.vsphere.alphabravo.io/v1alpha1` `TagCategory` | `inventory.vsphere.m.alphabravo.io/v1alpha1` `TagCategory` |
| `vsphere_vapp_container` | `virtualmachine.crossplane.io/v1alpha1` `VSphereVappContainer` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `VappContainer` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `VappContainer` |
| `vsphere_vapp_entity` | `virtualmachine.crossplane.io/v1alpha1` `VSphereVappEntity` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `VappEntity` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `VappEntity` |
| `vsphere_virtual_disk` | `virtualmachine.crossplane.io/v1alpha1` `VSphereVirtualDisk` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `VirtualDisk` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `VirtualDisk` |
| `vsphere_virtual_machine` | `virtualmachine.crossplane.io/v1alpha1` `VSphereVirtualMachine` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `VirtualMachine` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `VirtualMachine` |
| `vsphere_virtual_machine_class` | `workloadmanagement.crossplane.io/v1alpha1` `VSphereVirtualMachineClass` | `workloadmanagement.vsphere.alphabravo.io/v1alpha1` `VirtualMachineClass` | `workloadmanagement.vsphere.m.alphabravo.io/v1alpha1` `VirtualMachineClass` |
| `vsphere_virtual_machine_snapshot` | `virtualmachine.crossplane.io/v1alpha1` `VSphereVirtualMachineSnapshot` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` `VirtualMachineSnapshot` | `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` `VirtualMachineSnapshot` |
| `vsphere_vm_storage_policy` | `storage.crossplane.io/v1alpha1` `VSphereVmStoragePolicy` | `storage.vsphere.alphabravo.io/v1alpha1` `VmStoragePolicy` | `storage.vsphere.m.alphabravo.io/v1alpha1` `VmStoragePolicy` |
| `vsphere_vmfs_datastore` | `storage.crossplane.io/v1alpha1` `VSphereVmfsDatastore` | `storage.vsphere.alphabravo.io/v1alpha1` `VmfsDatastore` | `storage.vsphere.m.alphabravo.io/v1alpha1` `VmfsDatastore` |
| `vsphere_vnic` | `hostandclustermanagement.crossplane.io/v1alpha1` `VSphereVnic` | `hostandclustermanagement.vsphere.alphabravo.io/v1alpha1` `Vnic` | `hostandclustermanagement.vsphere.m.alphabravo.io/v1alpha1` `Vnic` |

### Plural resource names

GVRs, RBAC rules, MRAP entries and `kubectl get` use the plural in the CRD's `spec.names.plural`,
and the CRD name is `<plural>.<group>`. Each Kind has the same plural in both scopes.

- **37 of the 45 Kinds** use the lowercased Kind plus `s`. For example,
  `vspherevirtualmachines.virtualmachine.crossplane.io` becomes
  `virtualmachines.virtualmachine.vsphere.alphabravo.io` (cluster-scoped) or
  `virtualmachines.virtualmachine.vsphere.m.alphabravo.io` (namespaced).
- **The other 8 Kinds** have irregular plurals:

| Kind | Plural | Cluster-scoped CRD | Namespaced CRD |
|---|---|---|---|
| `ContentLibrary` | `contentlibraries` | `contentlibraries.virtualmachine.vsphere.alphabravo.io` | `contentlibraries.virtualmachine.vsphere.m.alphabravo.io` |
| `DistributedVirtualSwitch` | `distributedvirtualswitches` | `distributedvirtualswitches.networking.vsphere.alphabravo.io` | `distributedvirtualswitches.networking.vsphere.m.alphabravo.io` |
| `EntityPermissions` | `entitypermissions` | `entitypermissions.security.vsphere.alphabravo.io` | `entitypermissions.security.vsphere.m.alphabravo.io` |
| `HostVirtualSwitch` | `hostvirtualswitches` | `hostvirtualswitches.networking.vsphere.alphabravo.io` | `hostvirtualswitches.networking.vsphere.m.alphabravo.io` |
| `TagCategory` | `tagcategories` | `tagcategories.inventory.vsphere.alphabravo.io` | `tagcategories.inventory.vsphere.m.alphabravo.io` |
| `VappEntity` | `vappentities` | `vappentities.virtualmachine.vsphere.alphabravo.io` | `vappentities.virtualmachine.vsphere.m.alphabravo.io` |
| `VirtualMachineClass` | `virtualmachineclasses` | `virtualmachineclasses.workloadmanagement.vsphere.alphabravo.io` | `virtualmachineclasses.workloadmanagement.vsphere.m.alphabravo.io` |
| `VmStoragePolicy` | `vmstoragepolicies` | `vmstoragepolicies.storage.vsphere.alphabravo.io` | `vmstoragepolicies.storage.vsphere.m.alphabravo.io` |

To read a plural from a cluster, run
`kubectl get crd -o custom-columns=NAME:.metadata.name,PLURAL:.spec.names.plural | grep alphabravo`.

## Provider configuration map

| Legacy | New | Used by |
|---|---|---|
| `vsphere.crossplane.io/v1beta1` `ProviderConfig` (cluster-scoped) | `vsphere.alphabravo.io/v1beta1` `ProviderConfig` (cluster-scoped) | cluster-scoped MRs (`*.vsphere.alphabravo.io`) |
| (none) | `vsphere.m.alphabravo.io/v1beta1` `ProviderConfig` (namespaced) | namespaced MRs in the same namespace |
| (none) | `vsphere.m.alphabravo.io/v1beta1` `ClusterProviderConfig` (cluster-scoped) | namespaced MRs in any namespace |
| `vsphere.crossplane.io/v1beta1` `ProviderConfigUsage` | `vsphere.alphabravo.io/v1beta1` `ProviderConfigUsage` (cluster-scoped); `vsphere.m.alphabravo.io/v1beta1` `ProviderConfigUsage` (namespaced) and `ClusterProviderConfigUsage` | written by the provider; never created by hand |
| `vsphere.crossplane.io/v1alpha1` `StoreConfig` | **removed** | External Secret Stores were removed in Crossplane v2 |

Notes:

- **Same spec shape.** The ProviderConfig `spec.credentials` block is unchanged: `source: Secret`,
  plus `secretRef` with `name`, `namespace` and `key`. For a cluster-scoped MR, only the
  `apiVersion` changes.
- **Namespaced ProviderConfig reads the MR's namespace.** It always reads its Secret from the
  namespace of the MR that uses it. `secretRef.namespace` is required by the schema but is
  replaced with the MR's namespace. A ClusterProviderConfig reads the Secret from
  `secretRef.namespace`.
- **Where ClusterProviderConfig usage appears.** Usage of a ClusterProviderConfig is recorded as a
  namespaced `ProviderConfigUsage` in each MR's namespace. The package includes the
  `ClusterProviderConfigUsage` type, but the provider never writes it.
- **Removed provider flag.** The `--enable-external-secret-stores` flag is gone. A
  DeploymentRuntimeConfig that still passes it makes the provider fail to start with
  `unknown long flag`.

Examples:

- [examples/providerconfig/providerconfig.yaml](examples/providerconfig/providerconfig.yaml)
- [examples/providerconfig/clusterproviderconfig.yaml](examples/providerconfig/clusterproviderconfig.yaml)
- [examples/providerconfig/namespaced-providerconfig.yaml](examples/providerconfig/namespaced-providerconfig.yaml)

## Credentials Secret (unchanged)

The Secret format is unchanged. The Secret key named in `secretRef.key` (`credentials` in the
examples and in Pioneer's Secret) holds one JSON object:

| Key | Required | Accepted values |
|---|---|---|
| `user` | yes | string |
| `password` | yes | string |
| `vsphere_server` | yes | string (vCenter host name or IP) |
| `allow_unverified_ssl` | no | JSON boolean, or a string such as `"true"` |
| `api_timeout` | no | positive whole number of minutes, as a JSON number or an integer string such as `"5"`; bounds the vCenter login and some API calls, not all, and is mostly shared by the whole provider pod (see below) |

- **Pioneer's Secret keeps working.** A legacy Secret keeps working when `user`, `password` and
  `vsphere_server` hold non-empty strings, `allow_unverified_ssl` is a boolean string such as
  `"true"`, and `api_timeout`, if present, is a positive whole number. Pioneer's current Secret
  (all values as strings, including `"allow_unverified_ssl": "true"`, and no `api_timeout`) meets
  this. Native JSON booleans and numbers are now also accepted.
- **`api_timeout` is mostly shared by the whole provider pod, and it does not bound every call.**
  The vSphere provider (vmware/vsphere 2.15.1) runs in-process. It uses the value in two ways, and
  many operations ignore it:
  - The vCenter login and a subset of API calls read a package-level variable
    (`defaultAPITimeout`). Examples are calls in the tag, custom attribute, folder, switch, port
    group, datastore and VM snapshot resources. Each vCenter login of a ProviderConfig or
    ClusterProviderConfig overwrites that variable, so the value from the most recent login
    applies to every ProviderConfig the pod serves. A Secret that omits `api_timeout` overwrites
    it too, with the default: 5 minutes, or the provider pod's `VSPHERE_API_TIMEOUT` environment
    variable when it is set.
  - VirtualMachine create and reconfigure tasks use the `api_timeout` of the MR's own
    ProviderConfig. A clone uses the MR's `clone.timeout` instead.
  - Many other resource operations use the provider's fixed 5-minute timeout, whatever
    `api_timeout` says.

  Use the same `api_timeout` in every ProviderConfig and ClusterProviderConfig served by one
  provider pod, or omit it from all of them. Pioneer's Secret omits it today and Pioneer sets no
  `VSPHERE_API_TIMEOUT`, so every Pioneer ProviderConfig gets 5 minutes. The other keys apply only
  to their own ProviderConfig.
- **Errors name the key.** A missing required key, or a value of the wrong type, fails the
  reconcile with an error that names the key, never the value.
- **One vCenter login per ProviderConfig.** The provider now logs in to vCenter once per
  ProviderConfig or ClusterProviderConfig. That login opens a SOAP session and, when vCenter
  offers the REST API, a REST session for tags and content libraries, and the provider reuses both.
  Changing the credentials JSON makes the next reconcile log in again. The template is
  [examples/providerconfig/secret.yaml.tmpl](examples/providerconfig/secret.yaml.tmpl).

## Managed resource spec changes

These follow from Crossplane v2 and upjet v2. The table matches the generated CRDs in
`package/crds`, where every managed resource CRD of a scope has these fields. For VirtualMachine
they are in `package/crds/virtualmachine.vsphere.alphabravo.io_virtualmachines.yaml`
(cluster-scoped) and `package/crds/virtualmachine.vsphere.m.alphabravo.io_virtualmachines.yaml`
(namespaced).

| Field | Legacy (cluster-scoped) | New cluster-scoped MR | New namespaced MR |
|---|---|---|---|
| Management policy | `managementPolicy` (one of `FullControl`, `ObserveOnly`, `OrphanOnDelete`) | `managementPolicies` (a list, default `["*"]`; for example `["Observe"]` replaces `ObserveOnly`) | same as cluster-scoped |
| Deletion policy | `deletionPolicy` (`Delete` / `Orphan`) | `deletionPolicy` (unchanged) | **not present**; to keep the external resource on delete, leave `Delete` out of `managementPolicies` |
| Connection secret | `writeConnectionSecretToRef` with `name` and `namespace` | unchanged | `writeConnectionSecretToRef` with `name` only; the Secret is written in the MR's namespace |
| External secret store | `publishConnectionDetailsTo` | **removed** | **removed** |
| Provider reference | `providerConfigRef: {name}` (plus the deprecated `providerRef`) | `providerConfigRef: {name}`; when the field is omitted it defaults to `name: default` | `providerConfigRef: {kind, name}`, both required; only when the whole field is omitted does it default to `kind: ClusterProviderConfig, name: default` (see the warning below) |
| Create-only values | (none) | `spec.initProvider` | `spec.initProvider` |

VirtualMachine specifics:

- **Placement references.** The legacy `datastoreIdRef` and `resourcePoolIdRef` resolved to the
  wrong IDs. The new VirtualMachine has working `*Ref` / `*Selector` fields for:
  - `datacenterId` (Datacenter; resolves the datacenter's managed object ID)
  - `resourcePoolId` (ResourcePool)
  - `datastoreId` (VmfsDatastore)
  - `datastoreClusterId` (DatastoreCluster)
  - `hostSystemId` (Host)
  - `folder` (Folder path)
  - `networkInterface[].networkId` (DistributedPortGroup)
  - `storagePolicyId` (VmStoragePolicy)

  A reference to an MR that is not Ready yet leaves the VM unresolved instead of sending an empty
  ID.
- **NFS datastores.** An upjet reference field targets exactly one Kind, so `datastoreIdRef`
  resolves only against a VmfsDatastore. For an NFS datastore (NasDatastore), set `datastoreId`
  literally to its managed object ID.
- **Fields vCenter owns are no longer pinned.** These are `annotation`, `guestId`, `hvMode`,
  `eptRviMode`, `hostSystemId`, `datastoreId`, `storagePolicyId`, `hardwareVersion`, share counts,
  MAC addresses and disk placement, which are no longer late-initialized into `spec.forProvider`.
  `extraConfig` keys you do not list get the same protection, because the vSphere provider reads
  back only the `extraConfig` keys in your spec. When you leave one of them unset, a change made to
  it in vCenter does not trigger a reconfigure, so a VM powered off in vCenter stays off.
  **Only these fields get this protection.**
- **Fields you set are enforced.** A field you set in `spec.forProvider` is still enforced. If it
  is changed, in the spec or in vCenter, the provider corrects it. Most fields are corrected with a
  reconfigure, and vSphere provider 2.15.1 powers the VM on after a reconfigure that updates it.
  `folder`, `resourcePoolId`, `hostSystemId`, `datastoreId`, `tags` and `customAttributes` are
  corrected by a move, a migration, or a tag or custom attribute call instead. On its own, such a
  correction does not power the VM on. Put values that must only be applied at creation under
  `spec.initProvider`.
- **Unset fields with a Terraform value are enforced too.** Every other optional field that
  vCenter stores is managed even when it is not in `spec.forProvider`. Terraform applies its schema
  default, or zero, `false` or empty when it has none. Examples: `cpuLimit` and `memoryLimit`
  (`-1`), `cpuShareLevel` and `memoryShareLevel` (`normal`), `cpuReservation` and
  `memoryReservation` (`0`). A change to one of these examples in vCenter is corrected with a
  reconfigure, which powers the VM on. Settings that only the provider uses, such as
  `waitForGuestNetTimeout`, have no vCenter value to change. See
  [Power state after out-of-band changes](#power-state-after-out-of-band-changes).

## Warning: providerConfigRef defaults on namespaced MRs

> A namespaced MR (`*.vsphere.m.alphabravo.io`) that **omits `providerConfigRef` entirely** is
> defaulted by the API server to **`kind: ClusterProviderConfig, name: default`**. It does not use
> a ProviderConfig in its own namespace, even one named `default`. The MR silently binds to the
> cluster-wide `default` ClusterProviderConfig, or fails to reconcile when that
> ClusterProviderConfig does not exist.

The default applies only when the whole `providerConfigRef` field is absent. When the field is
present, the CRD requires both `kind` and `name`, and nothing inside it is defaulted:

| `providerConfigRef` on a namespaced MR | Result |
|---|---|
| omitted | defaulted to `{kind: ClusterProviderConfig, name: default}` |
| `{name: <name>}` (no `kind`) | **rejected** by the API server with `spec.providerConfigRef.kind: Required value`; the MR is not created |
| `{kind: ProviderConfig, name: <name>}` | the namespaced ProviderConfig `<name>` in the MR's own namespace |
| `{kind: ClusterProviderConfig, name: <name>}` | the ClusterProviderConfig `<name>` |

Pioneer renders `providerConfigRef` with only a name today
(`internal/operator/manifest/resources_vmware.go:320`). On the namespaced path the API server
rejects that manifest, so every namespaced MR Pioneer renders must set `kind` explicitly. To use a
namespaced ProviderConfig in the MR's namespace:

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

Cluster-scoped MRs keep the legacy behavior: `providerConfigRef: {name: <name>}` selects a
`vsphere.alphabravo.io/v1beta1` ProviderConfig, and an omitted `providerConfigRef` defaults to
`name: default`. Their `providerConfigRef` has no `kind` field.

## Pioneer change list

Line numbers are from `/home/dev/pioneer` at commit `bb9f1cf13`.

- **Cluster-scoped path.** Choosing the cluster-scoped groups is the smallest change: string
  updates only, and `providerConfigRef: {name}` keeps working.
- **Namespaced path.** Choosing the namespaced groups additionally needs `metadata.namespace` on
  every MR, a namespaced ProviderConfig with its Secret in that namespace (or a
  ClusterProviderConfig), and `providerConfigRef.kind`, which is required: a name-only
  `providerConfigRef` is rejected.

| Pioneer file | Line | Current value | New value |
|---|---|---|---|
| `internal/operator/manifest/machines_network.go` | 39 | `vmAPIVersion("vmware")` returns `virtualmachine.crossplane.io/v1alpha1` | `virtualmachine.vsphere.alphabravo.io/v1alpha1` (cluster-scoped) or `virtualmachine.vsphere.m.alphabravo.io/v1alpha1` (namespaced) |
| `internal/operator/manifest/machines_network.go` | 51 | `vmKind("vmware")` returns `VSphereVirtualMachine` | `VirtualMachine` |
| `internal/operator/manifest/resources_vmware.go` | 309-324 (`providerConfigRef` at 320) | VM MR envelope with `"providerConfigRef": map[string]any{"name": provCfgName}` | Cluster-scoped: unchanged. Namespaced: set the MR namespace and add `"kind": "ProviderConfig"` (or `"ClusterProviderConfig"`); without `kind` the API server rejects the MR (see the warning above). The `forProvider` field profile is unchanged. |
| `internal/operator/manifest/resources_vmware.go` | 194 | `"annotation"` set in `forProvider` | Optional: move it to `spec.initProvider`. While it is in `forProvider`, an annotation edit made in vCenter is reverted, and that revert powers a powered-off VM on. |
| `internal/operator/statussync/watcher.go` | 488 | GVR `{Group: "virtualmachine.crossplane.io", Version: "v1alpha1", Resource: "vspherevirtualmachines"}` | `{Group: "virtualmachine.vsphere.alphabravo.io", Version: "v1alpha1", Resource: "virtualmachines"}`, or `virtualmachine.vsphere.m.alphabravo.io` for namespaced MRs (watch all namespaces) |
| `internal/operator/lifecycle/seed_ip_resolver.go` | 18-22 | `vsphereVMGVR` = `virtualmachine.crossplane.io` / `v1alpha1` / `vspherevirtualmachines` | the same GVR as `watcher.go:488`; for namespaced MRs, list in the deployment's namespace |
| `internal/operator/manifest/crossplane.go` | 213 | `providerConfigAPIVersion(PROVIDER_VMWARE)` returns `vsphere.crossplane.io/v1beta1` | `vsphere.alphabravo.io/v1beta1` (cluster-scoped ProviderConfig) or `vsphere.m.alphabravo.io/v1beta1` (namespaced ProviderConfig / ClusterProviderConfig). The value is used by `internal/operator/manifest/network.go:386-388`, which sets `Kind: "ProviderConfig"`. |
| `internal/airgap/bom/registry.go` | 169 | `Package: "docker.io/alphabravodevops/provider-vsphere:2.12.0-terraform-vsphere-1.21-go"` | `Package: "docker.io/alphabravodevops/provider-vsphere:v2.15.1"` (one multi-arch index; mirror it as an index) |
| `internal/airgap/bom/registry.go` | 849-851 | Crossplane chart `2.2.0`, image `v2.2.0` | no change: v2.2.0 satisfies `>=v2.0.0` |

Other Pioneer code keyed on the old Kind (not in the list above, but it breaks silently):

- **Compute-node sync (`syncer.go:191-193`).** `internal/operator/statussync/syncer.go:191-193`
  lists `computeResourceKinds`. `"VirtualMachine"` is already present (commented "generic Azure"),
  so VMware VMs keep syncing to deployment nodes. Remove or re-comment the stale
  `"VSphereVirtualMachine"` entry.
- **Readiness map (`syncer.go:506`).** `internal/operator/statussync/syncer.go:506` keys
  `resourceReadinessSpecs` by `"VSphereVirtualMachine"`. Rename the key to `"VirtualMachine"`.
  `IsResourceReady` treats an unknown Kind with no conditions as ready, so without this change a
  just-created VM counts as ready before its first reconcile.
- **apiVersion fallback (`syncer.go:787`).** `InferAPIVersion("VirtualMachine")` at
  `internal/operator/statussync/syncer.go:787` returns `compute.azure.upbound.io/v1beta1`. It is
  used only when an event has no apiVersion (`syncer.go:101-104`). Make sure VMware events carry
  their apiVersion, or VMs are recorded with the Azure apiVersion.
- **Worker category (`syncer.go:843-844`).** `internal/operator/statussync/syncer.go:843-844`
  already lists `"VirtualMachine"` in the workers category; drop `"VSphereVirtualMachine"`.
- **Tests and docs with the old strings.** Update these files, which contain
  `VSphereVirtualMachine`, `virtualmachine.crossplane.io`, `vspherevirtualmachines`,
  `vsphere.crossplane.io` or the old tag:
  - `internal/operator/deletion/stages_test.go`
  - `internal/operator/deployment/applier_pauseddelete_test.go`
  - `internal/operator/deployment/stages/provision_machine_not_ready_test.go`
  - `internal/operator/manifest/machines_test.go`
  - `internal/operator/manifest/vmware_size_mapping_test.go`
  - `tests/e2e/framework/specs/instances.go`
  - `tests/e2e/operator/expectations_test.go`
  - `tests/e2e/operator/v2/expectations.go`
  - `docs/vmware/README.md`

  To list them again:
  `git grep -n -e VSphereVirtualMachine -e virtualmachine.crossplane.io -e vspherevirtualmachines -e vsphere.crossplane.io -e 2.12.0-terraform-vsphere`.

The watcher's status reads keep working. `status.atProvider.defaultIpAddress`, which
`watcher.go:1011-1021` and `seed_ip_resolver.go` read, is unchanged in 2.15.1.

## Power state after out-of-band changes

vSphere provider 2.15.1 powers a VM on after every reconfigure it performs to update the VM. The
reconfigure that detaches disks before a delete is the only one without a power-on. So whenever
the provider corrects drift with a reconfigure on a VM that someone powered off in vCenter, the VM
comes back on. Drift only in `folder`, `resourcePoolId`, `hostSystemId`, `datastoreId`, `tags` or
`customAttributes` is corrected without a reconfigure. This is accepted, documented behavior. What
matters is which vCenter changes count as drift:

- **Not drift.** `annotation` and the other fields listed as protected under
  [Managed resource spec changes](#managed-resource-spec-changes), when they are not in
  `spec.forProvider`. A VM powered off in vCenter stays off after someone edits them.
- **Drift: fields with a Terraform schema default.** `cpuLimit` and `memoryLimit` default to `-1`
  (unlimited), and `cpuShareLevel` and `memoryShareLevel` default to `normal`. Other examples are
  `latencySensitivity` and `swapPlacementPolicy`. These defaults are copied into
  `spec.forProvider` when the VM is created (late-initialization). A change made in vCenter is
  reverted to the default in one reconfigure.
- **Drift: fields with no default.** `cpuReservation` and `memoryReservation` are enforced as `0`,
  and flags such as `cpuHotAddEnabled`, `memoryHotAddEnabled` and `nestedHvEnabled` as `false`.
  Late-initialization skips zero values, so these are not in `spec.forProvider`. After a change in
  vCenter, the provider first resets the field to `0` or `false`. In the same reconcile,
  late-initialization copies the vCenter value into `spec.forProvider`, and the next reconcile
  applies it again. The vCenter value ends up pinned in the spec after two reconfigures. With
  `LateInitialize` left out of `spec.managementPolicies`, the field just stays reset.

**What this means for Pioneer.** Pioneer's VM envelope
(`internal/operator/manifest/resources_vmware.go:189-311`) sets none of the CPU or memory
reservation, limit or share-level fields. Suppose an operator powers a Pioneer VM off in vCenter
and then changes one of those settings, for example a CPU reservation while troubleshooting. The
provider reconfigures the VM, and the VM powers on.

Mitigations, in order of preference:

1. **Own these settings in the MR.** If Pioneer needs specific values, render them explicitly in
   `forProvider`, for example `"cpuReservation": 0`. A change in vCenter is then reverted to that
   value in one reconfigure instead of the reset-then-copy sequence. The VM still powers on, so
   operators should not change these settings in vCenter on Pioneer-managed VMs.
2. **Stop reconciling while a VM must stay off.** Leave `Update` out of `spec.managementPolicies`,
   for example `["Observe", "Create", "Delete", "LateInitialize"]`, or set the annotation
   `crossplane.io/paused: "true"` on the MR. Drift is left alone, and spec changes are not applied
   either. When `Update` comes back or the annotation is removed, pending drift is corrected, and
   that powers the VM on. Pioneer could use this for a maintenance or power-off workflow.
3. **Set externally owned fields at creation only.** A field set only in `spec.initProvider` is
   applied at creation and not enforced afterwards. For `annotation`, which Pioneer sets today, this
   works on its own: move it to `spec.initProvider` (change list row `resources_vmware.go:194`).
   For a field that is not vCenter-owned, such as `cpuReservation`, also leave `LateInitialize` out
   of `spec.managementPolicies`. Otherwise late-initialization copies the observed value into
   `forProvider`, where it is enforced again.

## Recommended: activate only the resources Pioneer uses

The new package ships 90 managed resource CRDs, against 43 in the legacy package. Pioneer renders
only VirtualMachine, so on k3s it should activate just that Kind with a Crossplane
ManagedResourceActivationPolicy (MRAP). The ready-to-apply MRAP, and the reasons for each entry,
are in
[README.md, "Activate only the resources you use"](README.md#activate-only-the-resources-you-use-optional).
For the cluster-scoped path it is `virtualmachines.virtualmachine.vsphere.alphabravo.io`; for the
namespaced path it is `virtualmachines.virtualmachine.vsphere.m.alphabravo.io`.

- **Helm values.** Pioneer installs Crossplane with only `"args": []any{"--enable-usages"}`
  (`internal/server/bootstrap/components.go:154-156`). The chart's default
  `provider.defaultActivations: ["*"]` therefore activates every MRD, and an MRAP alone changes
  nothing. Add `"provider": map[string]any{"defaultActivations": []any{}}` to those values.
- **Other providers.** That value applies to every safe-start provider. Pioneer must then also
  apply MRAPs for the AWS and Azure family providers it installs, for example `"*.aws.upbound.io"`
  and `"*.azure.upbound.io"` to keep their current behavior.
- **Order.** Apply the MRAPs together with the Provider objects, before any provider is first
  installed. An MRD that is already Active stays Active, so on an existing cluster where the
  provider was installed under the default MRAP, all 90 CRDs stay active.
- **Airgap.** An MRAP is a plain manifest (`apiextensions.crossplane.io/v1alpha1`), so the BOM
  needs no new image.

## Validation checklist (Pioneer follow-up)

1. `git grep -n -e VSphereVirtualMachine -e virtualmachine.crossplane.io -e vspherevirtualmachines -e vsphere.crossplane.io -e 2.12.0-terraform-vsphere`
   in Pioneer returns nothing, or only intentional history and comments.
2. Rendered VM manifests use `virtualmachine.vsphere.alphabravo.io/v1alpha1` (or `.m.`) and
   `kind: VirtualMachine`. The ProviderConfig uses `vsphere.alphabravo.io/v1beta1` (or `.m.`).
   Namespaced MRs carry `providerConfigRef.kind`.
3. The airgap BOM pins `docker.io/alphabravodevops/provider-vsphere:v2.15.1`. The mirrored copy is
   an OCI index with linux/amd64 and linux/arm64:
   `crane manifest <mirror>/provider-vsphere:v2.15.1 | jq '.mediaType, [.manifests[].platform]'`.
4. On a lab cluster with Crossplane v2.2.0, the provider becomes Healthy, a VMware deployment
   creates `VirtualMachine` MRs that become `Synced=True` and `Ready=True`, and Pioneer's status
   sync reports the VM IP from `status.atProvider.defaultIpAddress`.
5. A freshly created VM is not reported ready before its first reconcile, which confirms the
   readiness-map rename at `syncer.go:506`.
6. The seed IP resolver finds a standalone seed VM through the new GVR.
7. Deleting the deployment deletes the VMs. The watcher sees the delete events on the new GVR.
8. If the MRAP recommendation is adopted: on a freshly bootstrapped cluster,
   `kubectl get crds | grep -c 'vsphere.*alphabravo.io'` counts only the activated VirtualMachine
   CRD plus the 6 provider configuration CRDs, and AWS and Azure resources still reconcile.
9. Power state (see [Power state after out-of-band changes](#power-state-after-out-of-band-changes)).
   Power a Pioneer VM off in vCenter.
   - With `annotation` rendered under `spec.initProvider`, an annotation edit in vCenter leaves the
     VM off.
   - A CPU reservation or limit change in vCenter powers the VM on. This is the documented,
     accepted behavior.
   - With `Update` left out of `spec.managementPolicies`, or with `crossplane.io/paused: "true"`,
     the VM stays off.
