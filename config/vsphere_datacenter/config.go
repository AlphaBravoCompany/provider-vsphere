package vspheredatacenter

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_datacenter", func(r *config.Resource) {
		r.ShortGroup = "inventory"
		r.Kind = "Datacenter"
		r.Version = "v1alpha1"
	})
}
