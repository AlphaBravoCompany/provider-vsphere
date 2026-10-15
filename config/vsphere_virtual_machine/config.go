package vspherevirtualmachine

import (
	"time"

	"github.com/crossplane/upjet/v2/pkg/config"
)

const (
	// extractResourceID resolves a reference to the referenced resource's
	// status.atProvider.id. It returns "" until that resource has been
	// observed, so crossplane-runtime reports "referenced field was empty
	// (referenced resource may not yet be ready)" rather than setting an
	// empty ID.
	extractResourceID = "github.com/crossplane/upjet/v2/pkg/resource.ExtractResourceID()"

	// vmLongOperationTimeout bounds VM create and update. upjet's async
	// connector gives every operation a 1h context deadline
	// (defaultAsyncTimeout in pkg/controller/external_async_tfpluginsdk.go),
	// so a value above 1h cannot take effect. 1h covers a clone at the
	// provider defaults (clone.timeout 30m + customize timeout 10m +
	// wait_for_guest_net_timeout 5m), OVF/OVA deploys, and vMotion or storage
	// vMotion updates (migrate_wait_timeout 30m) with shutdown/power-on waits.
	vmLongOperationTimeout = 1 * time.Hour
	// vmDeleteTimeout covers a graceful shutdown (shutdown_wait_timeout)
	// followed by destroying the VM and its disks.
	vmDeleteTimeout = 30 * time.Minute
)

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_virtual_machine", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VirtualMachine"
		r.Version = "v1alpha1"

		// Placement references. TerraformName (not the deprecated Type) is
		// resolved per scope, to apis/cluster/... or apis/namespaced/..., when
		// make generate runs.
		//
		// vsphere_datacenter stores the datacenter NAME as its Terraform ID
		// and the managed object ID in the computed "moid" attribute. The VM
		// looks datacenter_id up as a Datacenter managed object ID, so extract
		// moid from the observation instead of the resource ID.
		r.References["datacenter_id"] = config.Reference{
			TerraformName: "vsphere_datacenter",
			Extractor:     `github.com/crossplane/upjet/v2/pkg/resource.ExtractParamPath("moid",true)`,
		}
		r.References["resource_pool_id"] = config.Reference{
			TerraformName: "vsphere_resource_pool",
			Extractor:     extractResourceID,
		}
		// upjet allows one Reference (one target Kind) per Terraform field, so
		// datastoreIdRef/datastoreIdSelector target VmfsDatastore. For an NFS
		// datastore, set datastoreId literally, e.g. patched from a
		// NasDatastore's status.atProvider.id in a Composition.
		r.References["datastore_id"] = config.Reference{
			TerraformName: "vsphere_vmfs_datastore",
			Extractor:     extractResourceID,
		}
		r.References["datastore_cluster_id"] = config.Reference{
			TerraformName: "vsphere_datastore_cluster",
			Extractor:     extractResourceID,
		}
		r.References["host_system_id"] = config.Reference{
			TerraformName: "vsphere_host",
			Extractor:     extractResourceID,
		}
		// folder takes the folder path relative to the datacenter's VM root,
		// which is the form of vsphere_folder's observed path. Read it from
		// status.atProvider, not spec, so the reference stays unresolved
		// until the Folder has been observed, like the ID refs.
		r.References["folder"] = config.Reference{
			TerraformName: "vsphere_folder",
			Extractor:     `github.com/crossplane/upjet/v2/pkg/resource.ExtractParamPath("path",true)`,
		}
		r.References["network_interface.network_id"] = config.Reference{
			TerraformName: "vsphere_distributed_port_group",
			Extractor:     extractResourceID,
		}
		r.References["storage_policy_id"] = config.Reference{
			TerraformName: "vsphere_vm_storage_policy",
			Extractor:     extractResourceID,
		}

		// vCenter, DRS or the clone source picks these Optional+Computed
		// values. Late-initializing them would copy them into
		// spec.forProvider and pin them, so any later change in vCenter
		// becomes a diff that upjet keeps applying. When skipped, they stay
		// out of the Terraform config and the observed state is kept.
		// Explicit values and *Ref/*Selector values (resolved before Observe)
		// are still applied, because late-init only fills empty fields.
		r.LateInitializer = config.LateInitializer{
			IgnoredFields: []string{
				// Provider-defaulted; a change is restart-required, so a flap reboots the VM.
				"ept_rvi_mode",
				// Same as ept_rvi_mode.
				"hv_mode",
				// DRS picks and moves the host; a pinned host fights every DRS migration.
				"host_system_id",
				// vCenter/Storage DRS picks it; a pinned value also conflicts with datastore_cluster_id.
				"datastore_id",
				// vCenter assigns the default policy; pinning it turns vCenter-side changes into reconfigures.
				"storage_policy_id",
				// Can only go up (upgrade policy or admin); a pinned older value fails the no-downgrade check.
				"hardware_version",
				// Derived from cpu_share_level x vCPUs unless custom; a pinned count flaps after num_cpus changes.
				"cpu_share_count",
				// Derived from memory_share_level x memory unless custom; same flap as cpu_share_count.
				"memory_share_count",
				// Inherited from template notes; a pinned value makes out-of-band edits a reconfigure that powers the VM on.
				"annotation",
				// Inherited from the clone source/OVF; a pinned value makes out-of-band edits a restart-required reconfigure.
				"guest_id",
				// Generated by vCenter unless use_static_mac is set.
				"network_interface.mac_address",
				// Derived from bandwidth_share_level unless custom.
				"network_interface.bandwidth_share_count",
				// vCenter/Storage DRS places disks; a pinned value conflicts with datastore_cluster_id.
				"disk.datastore_id",
				// Read-only unless attach is true; a pinned value conflicts with datastore_cluster_id.
				"disk.path",
				// Same as storage_policy_id, per disk.
				"disk.storage_policy_id",
			},
		}

		// Clone and OVF deploys take minutes, far beyond the managed
		// reconciler's per-reconcile timeout, so run operations asynchronously.
		r.UseAsync = true
		// vSphere provider 2.15.1 implements VM CRUD with the non-context SDK
		// functions and never reads d.Timeout, so these values are recorded in
		// the SDK timeouts meta but bound nothing today. They take effect if
		// upstream moves the VM to context-aware CRUD, where the SDK default
		// of 20m would be too short for a clone.
		r.OperationTimeouts = config.OperationTimeouts{
			Create: vmLongOperationTimeout,
			Update: vmLongOperationTimeout,
			Delete: vmDeleteTimeout,
		}
	})

	p.AddResourceConfigurator("vsphere_virtual_machine_snapshot", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VirtualMachineSnapshot"
		r.Version = "v1alpha1"
	})
}
