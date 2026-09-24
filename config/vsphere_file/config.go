package vspherefile

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_file", func(r *config.Resource) {
		r.ShortGroup = "storage"
		r.Kind = "File"
		r.Version = "v1alpha1"
	})
}
