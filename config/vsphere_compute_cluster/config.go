package vspherecomputecluster

import "github.com/crossplane/upjet/v2/pkg/config"

const shortGroup string = "hostandclustermanagement"
const version string = "v1alpha1"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_compute_cluster", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeCluster"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_host_group", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterHostGroup"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_vm_affinity_rule", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterVmAffinityRule"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_vm_anti_affinity_rule", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterVmAntiAffinityRule"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_vm_dependency_rule", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterVmDependencyRule"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_vm_group", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterVmGroup"
		r.Version = version
	})

	p.AddResourceConfigurator("vsphere_compute_cluster_vm_host_rule", func(r *config.Resource) {
		r.ShortGroup = shortGroup
		r.Kind = "ComputeClusterVmHostRule"
		r.Version = version
	})
}
