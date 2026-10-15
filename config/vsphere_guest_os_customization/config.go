package vsphereguestoscustomization

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_guest_os_customization", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "GuestOsCustomization"
		r.Version = "v1alpha1"
	})
}
