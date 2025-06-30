package vspherevirtualdisk

import "github.com/crossplane/upjet/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {

	p.AddResourceConfigurator("vsphere_virtual_disk", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VSphereVirtualDisk"
		r.Version = "v1alpha1"
		r.References["datacenter"] = config.Reference{
			Type:      "github.com/AlphaBravoCompany/provider-vsphere/apis/inventory/v1alpha1.VSphereDatacenter",
			Extractor: `github.com/crossplane/upjet/pkg/resource.ExtractParamPath("Name", true)`,
		}
		r.References["datastore"] = config.Reference{
			Type:      "github.com/AlphaBravoCompany/provider-vsphere/apis/storage/v1alpha1.VSphereVmfsDatastore",
			Extractor: `github.com/crossplane/upjet/pkg/resource.ExtractParamPath("Name", true)`,
		}
	})

}
