package vspheretag

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_tag", func(r *config.Resource) {
		r.ShortGroup = "inventory"
		r.Kind = "Tag"
		r.Version = "v1alpha1"
	})

	p.AddResourceConfigurator("vsphere_tag_category", func(r *config.Resource) {
		r.ShortGroup = "inventory"
		r.Kind = "TagCategory"
		r.Version = "v1alpha1"
	})
}
