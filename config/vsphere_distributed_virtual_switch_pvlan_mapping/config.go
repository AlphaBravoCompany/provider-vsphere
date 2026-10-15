package vspheredistributedvirtualswitchpvlanmapping

import (
	"github.com/crossplane/upjet/v2/pkg/config"
	"github.com/crossplane/upjet/v2/pkg/registry"
)

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_distributed_virtual_switch_pvlan_mapping", func(r *config.Resource) {
		r.ShortGroup = "networking"
		r.Kind = "DistributedVirtualSwitchPvlanMapping"
		r.Version = "v1alpha1"
		// vmware/vsphere v2.15.1 ships no registry doc page for this resource, so
		// the scraper leaves it out of provider-metadata.yaml and the generated
		// Kind description would be empty. Describe it from the provider schema;
		// a scraped entry, if upstream adds one later, still takes precedence.
		if r.MetaResource == nil {
			r.MetaResource = &registry.Resource{
				Name:  r.Name,
				Title: r.Name,
				Description: "Provides a vSphere Distributed Switch private VLAN (PVLAN) mapping resource. " +
					"This can be used to add a single PVLAN map entry (a primary VLAN ID, a secondary VLAN ID " +
					"and a PVLAN type of promiscuous, community or isolated) to an existing vSphere Distributed " +
					"Switch in vCenter Server. If the switch is also managed by a DistributedVirtualSwitch resource, " +
					"set ignoreOtherPvlanMappings to true on it so that it ignores PVLAN mappings it does not manage.",
			}
		}
	})
}
