package vspherevirtualmachine

import "github.com/upbound/upjet/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_virtual_machine", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VSphereVirtualMachine"
		r.Version = "v1alpha1"
		r.References["resource_pool_id"] = config.Reference{
			Type:      "github.com/kirillinda/provider-vsphere/apis/hostandclustermanagement/v1alpha1.VSphereComputeCluster",
			Extractor: `github.com/upbound/upjet/pkg/resource.ExtractParamPath("ID", true)`,
		}
		r.References["datastore_id"] = config.Reference{
			Type:      "github.com/kirillinda/provider-vsphere/apis/storage/v1alpha1.VSphereVmfsDatastore",
			Extractor: `github.com/upbound/upjet/pkg/resource.ExtractParamPath("ID", true)`,
		}
	})

	p.AddResourceConfigurator("vsphere_virtual_machine_snapshot", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VSphereVirtualMachineSnapshot"
		r.Version = "v1alpha1"
	})
}
