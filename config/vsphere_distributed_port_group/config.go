package vspheredistributedportgroup

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_distributed_port_group", func(r *config.Resource) {
		r.ShortGroup = "networking"
		r.Kind = "DistributedPortGroup"
		r.Version = "v1alpha1"
	})
}
