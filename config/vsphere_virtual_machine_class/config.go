package vspherevirtualmachineclass

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_virtual_machine_class", func(r *config.Resource) {
		r.ShortGroup = "workloadmanagement"
		r.Kind = "VirtualMachineClass"
		r.Version = "v1alpha1"
	})
}
