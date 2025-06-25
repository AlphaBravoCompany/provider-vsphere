/*
Copyright 2021 Upbound Inc.
*/

package controller

import (
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/upbound/upjet/pkg/controller"

	vspherelicense "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/administration/vspherelicense"
	vspherecomputecluster "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputecluster"
	vspherecomputeclusterhostgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclusterhostgroup"
	vspherecomputeclustervmaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmaffinityrule"
	vspherecomputeclustervmantiaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmantiaffinityrule"
	vspherecomputeclustervmdependencyrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmdependencyrule"
	vspherecomputeclustervmgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmgroup"
	vspherecomputeclustervmhostrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmhostrule"
	vspheredpmhostoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspheredpmhostoverride"
	vspheredrsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspheredrsvmoverride"
	vspherehavmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherehavmoverride"
	vspherehost "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherehost"
	vsphereresourcepool "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vsphereresourcepool"
	vspherevnic "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/hostandclustermanagement/vspherevnic"
	vspherecustomattribute "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/inventory/vspherecustomattribute"
	vspheredatacenter "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/inventory/vspheredatacenter"
	vspherefolder "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/inventory/vspherefolder"
	vspheretag "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/inventory/vspheretag"
	vspheretagcategory "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/inventory/vspheretagcategory"
	vsphereofflinesoftwaredepot "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/lifecycle/vsphereofflinesoftwaredepot"
	vspheredistributedportgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/networking/vspheredistributedportgroup"
	vspheredistributedvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/networking/vspheredistributedvirtualswitch"
	vspherehostportgroup "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/networking/vspherehostportgroup"
	vspherehostvirtualswitch "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/networking/vspherehostvirtualswitch"
	providerconfig "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/providerconfig"
	vsphereentitypermissions "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/security/vsphereentitypermissions"
	vsphererole "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/security/vsphererole"
	vspheredatastorecluster "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspheredatastorecluster"
	vspheredatastoreclustervmantiaffinityrule "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspheredatastoreclustervmantiaffinityrule"
	vspherefile "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspherefile"
	vspherenasdatastore "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspherenasdatastore"
	vspherestoragedrsvmoverride "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspherestoragedrsvmoverride"
	vspherevmfsdatastore "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspherevmfsdatastore"
	vspherevmstoragepolicy "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/storage/vspherevmstoragepolicy"
	vspherecontentlibrary "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherecontentlibrary"
	vspherecontentlibraryitem "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherecontentlibraryitem"
	vsphereguestoscustomization "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vsphereguestoscustomization"
	vspherevappcontainer "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherevappcontainer"
	vspherevappentity "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherevappentity"
	vspherevirtualdisk "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherevirtualdisk"
	vspherevirtualmachine "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherevirtualmachine"
	vspherevirtualmachinesnapshot "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/virtualmachine/vspherevirtualmachinesnapshot"
	vspheresupervisor "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/workloadmanagement/vspheresupervisor"
	vspherevirtualmachineclass "github.com/AlphaBravoCompany/provider-vsphere/internal/controller/workloadmanagement/vspherevirtualmachineclass"
)

// Setup creates all controllers with the supplied logger and adds them to
// the supplied manager.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	for _, setup := range []func(ctrl.Manager, controller.Options) error{
		vspherelicense.Setup,
		vspherecomputecluster.Setup,
		vspherecomputeclusterhostgroup.Setup,
		vspherecomputeclustervmaffinityrule.Setup,
		vspherecomputeclustervmantiaffinityrule.Setup,
		vspherecomputeclustervmdependencyrule.Setup,
		vspherecomputeclustervmgroup.Setup,
		vspherecomputeclustervmhostrule.Setup,
		vspheredpmhostoverride.Setup,
		vspheredrsvmoverride.Setup,
		vspherehavmoverride.Setup,
		vspherehost.Setup,
		vsphereresourcepool.Setup,
		vspherevnic.Setup,
		vspherecustomattribute.Setup,
		vspheredatacenter.Setup,
		vspherefolder.Setup,
		vspheretag.Setup,
		vspheretagcategory.Setup,
		vsphereofflinesoftwaredepot.Setup,
		vspheredistributedportgroup.Setup,
		vspheredistributedvirtualswitch.Setup,
		vspherehostportgroup.Setup,
		vspherehostvirtualswitch.Setup,
		providerconfig.Setup,
		vsphereentitypermissions.Setup,
		vsphererole.Setup,
		vspheredatastorecluster.Setup,
		vspheredatastoreclustervmantiaffinityrule.Setup,
		vspherefile.Setup,
		vspherenasdatastore.Setup,
		vspherestoragedrsvmoverride.Setup,
		vspherevmfsdatastore.Setup,
		vspherevmstoragepolicy.Setup,
		vspherecontentlibrary.Setup,
		vspherecontentlibraryitem.Setup,
		vsphereguestoscustomization.Setup,
		vspherevappcontainer.Setup,
		vspherevappentity.Setup,
		vspherevirtualdisk.Setup,
		vspherevirtualmachine.Setup,
		vspherevirtualmachinesnapshot.Setup,
		vspheresupervisor.Setup,
		vspherevirtualmachineclass.Setup,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}
