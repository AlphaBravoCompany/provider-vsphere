package vspherehavmoverride

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_ha_vm_override", func(r *config.Resource) {
		r.ShortGroup = "hostandclustermanagement"
		r.Kind = "HaVmOverride"
		r.Version = "v1alpha1"
	})
}
