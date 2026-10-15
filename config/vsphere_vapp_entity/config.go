package vspherevappentity

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_vapp_entity", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "VappEntity"
		r.Version = "v1alpha1"
	})
}
