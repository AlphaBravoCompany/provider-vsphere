package vsphereofflinesoftwaredepot

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_offline_software_depot", func(r *config.Resource) {
		r.ShortGroup = "lifecycle"
		r.Kind = "OfflineSoftwareDepot"
		r.Version = "v1alpha1"
	})
}
