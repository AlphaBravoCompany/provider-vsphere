/*
Copyright 2021 Upbound Inc.
*/

package config

import (
	// Note(turkenh): we are importing this to embed provider schema document
	_ "embed"

	vspherecomputecluster "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_compute_cluster"
	vspherecontentlibrary "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_content_library"
	vspherecustomattribute "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_custom_attribute"
	vspheredatacenter "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_datacenter"
	vspheredatastorecluster "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_datastore_cluster"
	vspheredistributedportgroup "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_distributed_port_group"
	vspheredistributedvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_distributed_virtual_switch"
	vspheredpmhostoverride "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_dpm_host_override"
	vspheredrsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_drs_vm_override"
	vsphereentitypermissions "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_entity_permissions"
	vspherefile "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_file"
	vspherefolder "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_folder"
	vsphereguestoscustomization "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_guest_os_customization"
	vspherehavmoverride "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_ha_vm_override"
	vspherehost "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_host"
	vspherehostportgroup "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_host_port_group"
	vspherehostvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_host_virtual_switch"
	vspherelicense "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_license"
	vspherenasdatastore "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_nas_datastore"
	vsphereofflinesoftwaredepot "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_offline_software_depot"
	vsphereresourcepool "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_resource_pool"
	vsphererole "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_role"
	vspherestoragedrsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_storage_drs_vm_override"
	vspheresupervisor "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_supervisor"
	vspheretag "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_tag"
	vspherevappcontainer "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_vapp_container"
	vspherevappentity "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_vapp_entity"
	vspherevirtualdisk "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_virtual_disk"
	vspherevirtualmachine "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_virtual_machine"
	vspherevirtualmachineclass "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_virtual_machine_class"
	vspherevmstoragepolicy "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_vm_storage_policy"
	vspherevmfsdatastore "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_vmfs_datastore"
	vspherevnic "github.com/AlphaBravoCompany/provider-vsphere/config/vsphere_vnic"
	ujconfig "github.com/upbound/upjet/pkg/config"
)

const (
	resourcePrefix = "vsphere"
	modulePath     = "github.com/AlphaBravoCompany/provider-vsphere"
)

//go:embed schema.json
var providerSchema string

//go:embed provider-metadata.yaml
var providerMetadata string

// GetProvider returns provider configuration
func GetProvider() *ujconfig.Provider {
	pc := ujconfig.NewProvider([]byte(providerSchema), resourcePrefix, modulePath, []byte(providerMetadata),
		ujconfig.WithRootGroup("crossplane.io"),
		ujconfig.WithIncludeList(ExternalNameConfigured()),
		ujconfig.WithFeaturesPackage("internal/features"),
		ujconfig.WithDefaultResourceOptions(
			ExternalNameConfigurations(),
		))

	for _, configure := range []func(provider *ujconfig.Provider){
		// add custom config functions
		vspherelicense.Configure,
		vspherecomputecluster.Configure,
		vspheredpmhostoverride.Configure,
		vspheredrsvmoverride.Configure,
		vspherehavmoverride.Configure,
		vspherehost.Configure,
		vsphereresourcepool.Configure,
		vspherevnic.Configure,
		vspherecustomattribute.Configure,
		vspheredatacenter.Configure,
		vspherefolder.Configure,
		vspheretag.Configure,
		vspheredistributedportgroup.Configure,
		vspheredistributedvirtualswitch.Configure,
		vspherehostportgroup.Configure,
		vspherehostvirtualswitch.Configure,
		vsphereentitypermissions.Configure,
		vsphererole.Configure,
		vspheredatastorecluster.Configure,
		vspherefile.Configure,
		vspherenasdatastore.Configure,
		vspherestoragedrsvmoverride.Configure,
		vspherevmstoragepolicy.Configure,
		vspherevmfsdatastore.Configure,
		vspherecontentlibrary.Configure,
		vspherevappcontainer.Configure,
		vspherevappentity.Configure,
		vspherevirtualdisk.Configure,
		vspherevirtualmachine.Configure,
		vsphereofflinesoftwaredepot.Configure,
		vsphereguestoscustomization.Configure,
		vspherevirtualmachineclass.Configure,
		vspheresupervisor.Configure,
	} {
		configure(pc)
	}

	pc.ConfigureResources()
	return pc
}
