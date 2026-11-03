package vspherevirtualdisk

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {

	p.AddResourceConfigurator("vsphere_virtual_disk", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VirtualDisk"
		r.Version = "v1alpha1"
		// datacenter and datastore take NAMES, not IDs. The Terraformed
		// observation map is keyed by Terraform snake_case names, so the key
		// is "name". Reading status.atProvider, not spec, keeps the reference
		// unresolved until the target has been observed.
		r.References["datacenter"] = config.Reference{
			TerraformName: "vsphere_datacenter",
			Extractor:     `github.com/crossplane/upjet/v2/pkg/resource.ExtractParamPath("name",true)`,
		}
		// One Reference per Terraform field: datastoreRef targets
		// VmfsDatastore; set datastore literally for an NFS datastore.
		r.References["datastore"] = config.Reference{
			TerraformName: "vsphere_vmfs_datastore",
			Extractor:     `github.com/crossplane/upjet/v2/pkg/resource.ExtractParamPath("name",true)`,
		}
	})

}
