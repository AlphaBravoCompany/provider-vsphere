package vspherelicense

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_license", func(r *config.Resource) {
		r.ShortGroup = "administration"
		r.Kind = "License"
		r.Version = "v1alpha1"
	})
}
