package vspherecontentlibrary

import "github.com/crossplane/upjet/v2/pkg/config"

// Configure configures individual resources by adding custom ResourceConfigurators.
func Configure(p *config.Provider) {
	p.AddResourceConfigurator("vsphere_content_library", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "ContentLibrary"
		r.Version = "v1alpha1"
	})

	p.AddResourceConfigurator("vsphere_content_library_item", func(r *config.Resource) {
		r.ShortGroup = "virtualmachine"
		r.Kind = "ContentLibraryItem"
		r.Version = "v1alpha1"
	})
}
