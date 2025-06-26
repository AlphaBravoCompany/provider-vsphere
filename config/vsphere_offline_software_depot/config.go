package vsphereofflinesoftwaredepot

import "github.com/upbound/upjet/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_offline_software_depot", func(r *config.Resource) {
		r.ShortGroup = "Lifecycle"
		r.Kind = "VSphereOfflineSoftwareDepot"
		r.Version = "v1alpha1"
	})
}
