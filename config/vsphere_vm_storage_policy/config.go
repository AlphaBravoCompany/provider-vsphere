package vspherevmstoragepolicy

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_vm_storage_policy", func(r *config.Resource) {
		r.ShortGroup = "storage"
		r.Kind = "VmStoragePolicy"
		r.Version = "v1alpha1"
	})
}
