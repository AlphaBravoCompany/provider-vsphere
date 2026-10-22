package vspherevnic

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_vnic", func(r *config.Resource) {
		r.ShortGroup = "hostandclustermanagement"
		r.Kind = "Vnic"
		r.Version = "v1alpha1"
	})
}
