package vspherestoragedrsvmoverride

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_storage_drs_vm_override", func(r *config.Resource) {
		r.ShortGroup = "storage"
		r.Kind = "StorageDrsVmOverride"
		r.Version = "v1alpha1"
	})
}
