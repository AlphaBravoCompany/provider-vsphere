package vspherecustomattribute

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_custom_attribute", func(r *config.Resource) {
		r.ShortGroup = "inventory"
		r.Kind = "CustomAttribute"
		r.Version = "v1alpha1"
	})
}
