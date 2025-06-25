package vspheresupervisor

import "github.com/upbound/upjet/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_supervisor", func(r *config.Resource) {
		r.ShortGroup = "WorkloadManagement"
		r.Kind = "VSphereSupervisor"
		r.Version = "v1alpha1"
	})
}
