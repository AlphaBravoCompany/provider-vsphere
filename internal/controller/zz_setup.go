/*
Copyright 2021 Upbound Inc.
*/

package controller

import (
	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/upbound/upjet/pkg/controller"

	vspherelicense "github.com/Kumlin/provider-vsphere/internal/controller/administration/vspherelicense"
	vspherecomputecluster "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputecluster"
	vspherecomputeclusterhostgroup "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclusterhostgroup"
	vspherecomputeclustervmaffinityrule "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmaffinityrule"
	vspherecomputeclustervmantiaffinityrule "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmantiaffinityrule"
	vspherecomputeclustervmdependencyrule "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmdependencyrule"
	vspherecomputeclustervmgroup "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmgroup"
	vspherecomputeclustervmhostrule "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherecomputeclustervmhostrule"
	vspheredpmhostoverride "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspheredpmhostoverride"
	vspheredrsvmoverride "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspheredrsvmoverride"
	vspherehavmoverride "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherehavmoverride"
	vspherehost "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherehost"
	vsphereresourcepool "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vsphereresourcepool"
	vspherevnic "github.com/Kumlin/provider-vsphere/internal/controller/hostandclustermanagement/vspherevnic"
	vspherecustomattribute "github.com/Kumlin/provider-vsphere/internal/controller/inventory/vspherecustomattribute"
	vspheredatacenter "github.com/Kumlin/provider-vsphere/internal/controller/inventory/vspheredatacenter"
	vspherefolder "github.com/Kumlin/provider-vsphere/internal/controller/inventory/vspherefolder"
	vspheretag "github.com/Kumlin/provider-vsphere/internal/controller/inventory/vspheretag"
	vspheretagcategory "github.com/Kumlin/provider-vsphere/internal/controller/inventory/vspheretagcategory"
	vspheredistributedportgroup "github.com/Kumlin/provider-vsphere/internal/controller/networking/vspheredistributedportgroup"
	vspheredistributedvirtualswitch "github.com/Kumlin/provider-vsphere/internal/controller/networking/vspheredistributedvirtualswitch"
	vspherehostportgroup "github.com/Kumlin/provider-vsphere/internal/controller/networking/vspherehostportgroup"
	vspherehostvirtualswitch "github.com/Kumlin/provider-vsphere/internal/controller/networking/vspherehostvirtualswitch"
	providerconfig "github.com/Kumlin/provider-vsphere/internal/controller/providerconfig"
	vsphereentitypermissions "github.com/Kumlin/provider-vsphere/internal/controller/security/vsphereentitypermissions"
	vsphererole "github.com/Kumlin/provider-vsphere/internal/controller/security/vsphererole"
	vspheredatastorecluster "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspheredatastorecluster"
	vspheredatastoreclustervmantiaffinityrule "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspheredatastoreclustervmantiaffinityrule"
	vspherefile "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspherefile"
	vspherenasdatastore "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspherenasdatastore"
	vspherestoragedrsvmoverride "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspherestoragedrsvmoverride"
	vspherevmfsdatastore "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspherevmfsdatastore"
	vspherevmstoragepolicy "github.com/Kumlin/provider-vsphere/internal/controller/storage/vspherevmstoragepolicy"
	vspherecontentlibrary "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherecontentlibrary"
	vspherecontentlibraryitem "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherecontentlibraryitem"
	vspherevappcontainer "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherevappcontainer"
	vspherevappentity "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherevappentity"
	vspherevirtualdisk "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherevirtualdisk"
	vspherevirtualmachine "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherevirtualmachine"
	vspherevirtualmachinesnapshot "github.com/Kumlin/provider-vsphere/internal/controller/virtualmachine/vspherevirtualmachinesnapshot"
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
		vspherevappcontainer.Setup,
		vspherevappentity.Setup,
		vspherevirtualdisk.Setup,
		vspherevirtualmachine.Setup,
		vspherevirtualmachinesnapshot.Setup,
	} {
		if err := setup(mgr, o); err != nil {
			return err
		}
	}
	return nil
}
