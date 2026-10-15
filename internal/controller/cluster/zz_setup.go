/*
Copyright 2022 Upbound Inc.
*/

package controller

import (
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/crossplane/upjet/v2/pkg/controller"

	license "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/administration/license"
	computecluster "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computecluster"
	computeclusterhostgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclusterhostgroup"
	computeclustervmaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclustervmaffinityrule"
	computeclustervmantiaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclustervmantiaffinityrule"
	computeclustervmdependencyrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclustervmdependencyrule"
	computeclustervmgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclustervmgroup"
	computeclustervmhostrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/computeclustervmhostrule"
	configurationprofile "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/configurationprofile"
	dpmhostoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/dpmhostoverride"
	drsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/drsvmoverride"
	havmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/havmoverride"
	host "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/host"
	resourcepool "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/resourcepool"
	vnic "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/hostandclustermanagement/vnic"
	customattribute "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/inventory/customattribute"
	datacenter "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/inventory/datacenter"
	folder "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/inventory/folder"
	tag "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/inventory/tag"
	tagcategory "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/inventory/tagcategory"
	offlinesoftwaredepot "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/lifecycle/offlinesoftwaredepot"
	distributedportgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/networking/distributedportgroup"
	distributedvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/networking/distributedvirtualswitch"
	distributedvirtualswitchpvlanmapping "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/networking/distributedvirtualswitchpvlanmapping"
	hostportgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/networking/hostportgroup"
	hostvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/networking/hostvirtualswitch"
	providerconfig "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/providerconfig"
	entitypermissions "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/security/entitypermissions"
	role "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/security/role"
	datastorecluster "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/datastorecluster"
	datastoreclustervmantiaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/datastoreclustervmantiaffinityrule"
	file "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/file"
	nasdatastore "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/nasdatastore"
	storagedrsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/storagedrsvmoverride"
	vmfsdatastore "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/vmfsdatastore"
	vmstoragepolicy "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/storage/vmstoragepolicy"
	contentlibrary "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/contentlibrary"
	contentlibraryitem "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/contentlibraryitem"
	guestoscustomization "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/guestoscustomization"
	vappcontainer "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/vappcontainer"
	vappentity "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/vappentity"
	virtualdisk "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/virtualdisk"
	virtualmachine "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/virtualmachine"
	virtualmachinesnapshot "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/virtualmachine/virtualmachinesnapshot"
	supervisor "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/workloadmanagement/supervisor"
	virtualmachineclass "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/cluster/workloadmanagement/virtualmachineclass"
)

// Setup creates all controllers with the supplied logger and adds them to
// the supplied manager.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	for _, setup := range []func(ctrl.Manager, controller.Options) error{
		license.Setup,
		computecluster.Setup,
		computeclusterhostgroup.Setup,
		computeclustervmaffinityrule.Setup,
		computeclustervmantiaffinityrule.Setup,
		computeclustervmdependencyrule.Setup,
		computeclustervmgroup.Setup,
		computeclustervmhostrule.Setup,
		configurationprofile.Setup,
		dpmhostoverride.Setup,
		drsvmoverride.Setup,
		havmoverride.Setup,
		host.Setup,
		resourcepool.Setup,
		vnic.Setup,
		customattribute.Setup,
		datacenter.Setup,
		folder.Setup,
		tag.Setup,
		tagcategory.Setup,
		offlinesoftwaredepot.Setup,
		distributedportgroup.Setup,
		distributedvirtualswitch.Setup,
		distributedvirtualswitchpvlanmapping.Setup,
		hostportgroup.Setup,
		hostvirtualswitch.Setup,
		providerconfig.Setup,
		entitypermissions.Setup,
		role.Setup,
		datastorecluster.Setup,
		datastoreclustervmantiaffinityrule.Setup,
		file.Setup,
		nasdatastore.Setup,
		storagedrsvmoverride.Setup,
		vmfsdatastore.Setup,
		vmstoragepolicy.Setup,
		contentlibrary.Setup,
		contentlibraryitem.Setup,
		guestoscustomization.Setup,
		vappcontainer.Setup,
		vappentity.Setup,
		virtualdisk.Setup,
		virtualmachine.Setup,
		virtualmachinesnapshot.Setup,
		supervisor.Setup,
		virtualmachineclass.Setup,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}

// SetupGated creates all controllers with the supplied logger and adds them to
// the supplied manager gated.
func SetupGated(mgr ctrl.Manager, o controller.Options) error {
	for _, setup := range []func(ctrl.Manager, controller.Options) error{
		license.SetupGated,
		computecluster.SetupGated,
		computeclusterhostgroup.SetupGated,
		computeclustervmaffinityrule.SetupGated,
		computeclustervmantiaffinityrule.SetupGated,
		computeclustervmdependencyrule.SetupGated,
		computeclustervmgroup.SetupGated,
		computeclustervmhostrule.SetupGated,
		configurationprofile.SetupGated,
		dpmhostoverride.SetupGated,
		drsvmoverride.SetupGated,
		havmoverride.SetupGated,
		host.SetupGated,
		resourcepool.SetupGated,
		vnic.SetupGated,
		customattribute.SetupGated,
		datacenter.SetupGated,
		folder.SetupGated,
		tag.SetupGated,
		tagcategory.SetupGated,
		offlinesoftwaredepot.SetupGated,
		distributedportgroup.SetupGated,
		distributedvirtualswitch.SetupGated,
		distributedvirtualswitchpvlanmapping.SetupGated,
		hostportgroup.SetupGated,
		hostvirtualswitch.SetupGated,
		providerconfig.SetupGated,
		entitypermissions.SetupGated,
		role.SetupGated,
		datastorecluster.SetupGated,
		datastoreclustervmantiaffinityrule.SetupGated,
		file.SetupGated,
		nasdatastore.SetupGated,
		storagedrsvmoverride.SetupGated,
		vmfsdatastore.SetupGated,
		vmstoragepolicy.SetupGated,
		contentlibrary.SetupGated,
		contentlibraryitem.SetupGated,
		guestoscustomization.SetupGated,
		vappcontainer.SetupGated,
		vappentity.SetupGated,
		virtualdisk.SetupGated,
		virtualmachine.SetupGated,
		virtualmachinesnapshot.SetupGated,
		supervisor.SetupGated,
		virtualmachineclass.SetupGated,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}

// SetupWebhookWithManager registers conversion webhooks for all resource kinds in the group.
func SetupWebhookWithManager(mgr ctrl.Manager) error {
	for _, setup := range []func(ctrl.Manager) error{
		license.SetupWebhookWithManager,
		computecluster.SetupWebhookWithManager,
		computeclusterhostgroup.SetupWebhookWithManager,
		computeclustervmaffinityrule.SetupWebhookWithManager,
		computeclustervmantiaffinityrule.SetupWebhookWithManager,
		computeclustervmdependencyrule.SetupWebhookWithManager,
		computeclustervmgroup.SetupWebhookWithManager,
		computeclustervmhostrule.SetupWebhookWithManager,
		configurationprofile.SetupWebhookWithManager,
		dpmhostoverride.SetupWebhookWithManager,
		drsvmoverride.SetupWebhookWithManager,
		havmoverride.SetupWebhookWithManager,
		host.SetupWebhookWithManager,
		resourcepool.SetupWebhookWithManager,
		vnic.SetupWebhookWithManager,
		customattribute.SetupWebhookWithManager,
		datacenter.SetupWebhookWithManager,
		folder.SetupWebhookWithManager,
		tag.SetupWebhookWithManager,
		tagcategory.SetupWebhookWithManager,
		offlinesoftwaredepot.SetupWebhookWithManager,
		distributedportgroup.SetupWebhookWithManager,
		distributedvirtualswitch.SetupWebhookWithManager,
		distributedvirtualswitchpvlanmapping.SetupWebhookWithManager,
		hostportgroup.SetupWebhookWithManager,
		hostvirtualswitch.SetupWebhookWithManager,
		providerconfig.SetupWebhookWithManager,
		entitypermissions.SetupWebhookWithManager,
		role.SetupWebhookWithManager,
		datastorecluster.SetupWebhookWithManager,
		datastoreclustervmantiaffinityrule.SetupWebhookWithManager,
		file.SetupWebhookWithManager,
		nasdatastore.SetupWebhookWithManager,
		storagedrsvmoverride.SetupWebhookWithManager,
		vmfsdatastore.SetupWebhookWithManager,
		vmstoragepolicy.SetupWebhookWithManager,
		contentlibrary.SetupWebhookWithManager,
		contentlibraryitem.SetupWebhookWithManager,
		guestoscustomization.SetupWebhookWithManager,
		vappcontainer.SetupWebhookWithManager,
		vappentity.SetupWebhookWithManager,
		virtualdisk.SetupWebhookWithManager,
		virtualmachine.SetupWebhookWithManager,
		virtualmachinesnapshot.SetupWebhookWithManager,
		supervisor.SetupWebhookWithManager,
		virtualmachineclass.SetupWebhookWithManager,
	} {
		if err := setup(mgr); err != nil {
			return err
		}
	}
	return nil
}
