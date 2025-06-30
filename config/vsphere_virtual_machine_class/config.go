package vspherevirtualmachineclass

import "github.com/crossplane/upjet/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_virtual_machine_class", func(r *config.Resource) {
		r.ShortGroup = "WorkloadManagement"
		r.Kind = "VSphereVirtualMachineClass"
		r.Version = "v1alpha1"
	})
}
