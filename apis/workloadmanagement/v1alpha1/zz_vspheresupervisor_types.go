/*
Copyright 2022 Upbound Inc.
*/

// Code generated by upjet. DO NOT EDIT.

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"

	v1 "github.com/crossplane/crossplane-runtime/apis/common/v1"
)

type EgressCidrObservation struct {

	// Network address.
	Address *string `json:"address,omitempty" tf:"address,omitempty"`

	// Subnet prefix.
	Prefix *float64 `json:"prefix,omitempty" tf:"prefix,omitempty"`
}

type EgressCidrParameters struct {

	// Network address.
	// +kubebuilder:validation:Required
	Address *string `json:"address" tf:"address,omitempty"`

	// Subnet prefix.
	// +kubebuilder:validation:Required
	Prefix *float64 `json:"prefix" tf:"prefix,omitempty"`
}

type IngressCidrObservation struct {

	// Network address.
	Address *string `json:"address,omitempty" tf:"address,omitempty"`

	// Subnet prefix.
	Prefix *float64 `json:"prefix,omitempty" tf:"prefix,omitempty"`
}

type IngressCidrParameters struct {

	// Network address.
	// +kubebuilder:validation:Required
	Address *string `json:"address" tf:"address,omitempty"`

	// Subnet prefix.
	// +kubebuilder:validation:Required
	Prefix *float64 `json:"prefix" tf:"prefix,omitempty"`
}

type ManagementNetworkObservation struct {

	// Number of addresses to allocate. Starts from 'starting_address'
	AddressCount *float64 `json:"addressCount,omitempty" tf:"address_count,omitempty"`

	// Gateway IP address.
	Gateway *string `json:"gateway,omitempty" tf:"gateway,omitempty"`

	// ID of the network. (e.g. a distributed port group).
	Network *string `json:"network,omitempty" tf:"network,omitempty"`

	// Starting address of the management network range.
	StartingAddress *string `json:"startingAddress,omitempty" tf:"starting_address,omitempty"`

	// Subnet mask.
	SubnetMask *string `json:"subnetMask,omitempty" tf:"subnet_mask,omitempty"`
}

type ManagementNetworkParameters struct {

	// Number of addresses to allocate. Starts from 'starting_address'
	// +kubebuilder:validation:Required
	AddressCount *float64 `json:"addressCount" tf:"address_count,omitempty"`

	// Gateway IP address.
	// +kubebuilder:validation:Required
	Gateway *string `json:"gateway" tf:"gateway,omitempty"`

	// ID of the network. (e.g. a distributed port group).
	// +kubebuilder:validation:Required
	Network *string `json:"network" tf:"network,omitempty"`

	// Starting address of the management network range.
	// +kubebuilder:validation:Required
	StartingAddress *string `json:"startingAddress" tf:"starting_address,omitempty"`

	// Subnet mask.
	// +kubebuilder:validation:Required
	SubnetMask *string `json:"subnetMask" tf:"subnet_mask,omitempty"`
}

type NamespaceObservation struct {

	// A list of content libraries.
	ContentLibraries []*string `json:"contentLibraries,omitempty" tf:"content_libraries,omitempty"`

	// The name of the namespace.
	Name *string `json:"name,omitempty" tf:"name,omitempty"`

	// A list of virtual machine classes.
	VMClasses []*string `json:"vmClasses,omitempty" tf:"vm_classes,omitempty"`
}

type NamespaceParameters struct {

	// A list of content libraries.
	// +kubebuilder:validation:Optional
	ContentLibraries []*string `json:"contentLibraries,omitempty" tf:"content_libraries,omitempty"`

	// The name of the namespace.
	// +kubebuilder:validation:Required
	Name *string `json:"name" tf:"name,omitempty"`

	// A list of virtual machine classes.
	// +kubebuilder:validation:Optional
	VMClasses []*string `json:"vmClasses,omitempty" tf:"vm_classes,omitempty"`
}

type PodCidrObservation struct {

	// Network address.
	Address *string `json:"address,omitempty" tf:"address,omitempty"`

	// Subnet prefix.
	Prefix *float64 `json:"prefix,omitempty" tf:"prefix,omitempty"`
}

type PodCidrParameters struct {

	// Network address.
	// +kubebuilder:validation:Required
	Address *string `json:"address" tf:"address,omitempty"`

	// Subnet prefix.
	// +kubebuilder:validation:Required
	Prefix *float64 `json:"prefix" tf:"prefix,omitempty"`
}

type ServiceCidrObservation struct {

	// Network address.
	Address *string `json:"address,omitempty" tf:"address,omitempty"`

	// Subnet prefix.
	Prefix *float64 `json:"prefix,omitempty" tf:"prefix,omitempty"`
}

type ServiceCidrParameters struct {

	// Network address.
	// +kubebuilder:validation:Required
	Address *string `json:"address" tf:"address,omitempty"`

	// Subnet prefix.
	// +kubebuilder:validation:Required
	Prefix *float64 `json:"prefix" tf:"prefix,omitempty"`
}

type VSphereSupervisorObservation struct {

	// ID of the vSphere cluster on which workload management will be enabled.
	Cluster *string `json:"cluster,omitempty" tf:"cluster,omitempty"`

	// ID of the subscribed content library.
	ContentLibrary *string `json:"contentLibrary,omitempty" tf:"content_library,omitempty"`

	// The UUID (not ID) of the distributed switch.
	DvsUUID *string `json:"dvsUuid,omitempty" tf:"dvs_uuid,omitempty"`

	// ID of the NSX Edge Cluster.
	EdgeCluster *string `json:"edgeCluster,omitempty" tf:"edge_cluster,omitempty"`

	// CIDR blocks from which NSX assigns IP addresses used for performing SNAT from container IPs to external IPs.
	EgressCidr []EgressCidrObservation `json:"egressCidr,omitempty" tf:"egress_cidr,omitempty"`

	ID *string `json:"id,omitempty" tf:"id,omitempty"`

	// CIDR blocks from which NSX assigns IP addresses for Kubernetes Ingresses and Kubernetes Services of type LoadBalancer.
	IngressCidr []IngressCidrObservation `json:"ingressCidr,omitempty" tf:"ingress_cidr,omitempty"`

	// List of DNS servers to use on the Kubernetes API server.
	MainDNS []*string `json:"mainDns,omitempty" tf:"main_dns,omitempty"`

	// List of NTP servers to use on the Kubernetes API server.
	MainNtp []*string `json:"mainNtp,omitempty" tf:"main_ntp,omitempty"`

	// The configuration for the management network which the control plane VMs will be connected to.
	ManagementNetwork []ManagementNetworkObservation `json:"managementNetwork,omitempty" tf:"management_network,omitempty"`

	// List of namespaces associated with the cluster.
	Namespace []NamespaceObservation `json:"namespace,omitempty" tf:"namespace,omitempty"`

	// CIDR blocks from which Kubernetes allocates pod IP addresses. Minimum subnet size is 23.
	PodCidr []PodCidrObservation `json:"podCidr,omitempty" tf:"pod_cidr,omitempty"`

	// List of DNS search domains.
	SearchDomains []*string `json:"searchDomains,omitempty" tf:"search_domains,omitempty"`

	// CIDR block from which Kubernetes allocates service cluster IP addresses.
	ServiceCidr []ServiceCidrObservation `json:"serviceCidr,omitempty" tf:"service_cidr,omitempty"`

	// Size of the Kubernetes API server.
	SizingHint *string `json:"sizingHint,omitempty" tf:"sizing_hint,omitempty"`

	// The name of a storage policy associated with the datastore where the container images will be stored.
	StoragePolicy *string `json:"storagePolicy,omitempty" tf:"storage_policy,omitempty"`

	// List of DNS servers to use on the worker nodes.
	WorkerDNS []*string `json:"workerDns,omitempty" tf:"worker_dns,omitempty"`

	// List of NTP servers to use on the worker nodes.
	WorkerNtp []*string `json:"workerNtp,omitempty" tf:"worker_ntp,omitempty"`
}

type VSphereSupervisorParameters struct {

	// ID of the vSphere cluster on which workload management will be enabled.
	// +kubebuilder:validation:Optional
	Cluster *string `json:"cluster,omitempty" tf:"cluster,omitempty"`

	// ID of the subscribed content library.
	// +kubebuilder:validation:Optional
	ContentLibrary *string `json:"contentLibrary,omitempty" tf:"content_library,omitempty"`

	// The UUID (not ID) of the distributed switch.
	// +kubebuilder:validation:Optional
	DvsUUID *string `json:"dvsUuid,omitempty" tf:"dvs_uuid,omitempty"`

	// ID of the NSX Edge Cluster.
	// +kubebuilder:validation:Optional
	EdgeCluster *string `json:"edgeCluster,omitempty" tf:"edge_cluster,omitempty"`

	// CIDR blocks from which NSX assigns IP addresses used for performing SNAT from container IPs to external IPs.
	// +kubebuilder:validation:Optional
	EgressCidr []EgressCidrParameters `json:"egressCidr,omitempty" tf:"egress_cidr,omitempty"`

	// CIDR blocks from which NSX assigns IP addresses for Kubernetes Ingresses and Kubernetes Services of type LoadBalancer.
	// +kubebuilder:validation:Optional
	IngressCidr []IngressCidrParameters `json:"ingressCidr,omitempty" tf:"ingress_cidr,omitempty"`

	// List of DNS servers to use on the Kubernetes API server.
	// +kubebuilder:validation:Optional
	MainDNS []*string `json:"mainDns,omitempty" tf:"main_dns,omitempty"`

	// List of NTP servers to use on the Kubernetes API server.
	// +kubebuilder:validation:Optional
	MainNtp []*string `json:"mainNtp,omitempty" tf:"main_ntp,omitempty"`

	// The configuration for the management network which the control plane VMs will be connected to.
	// +kubebuilder:validation:Optional
	ManagementNetwork []ManagementNetworkParameters `json:"managementNetwork,omitempty" tf:"management_network,omitempty"`

	// List of namespaces associated with the cluster.
	// +kubebuilder:validation:Optional
	Namespace []NamespaceParameters `json:"namespace,omitempty" tf:"namespace,omitempty"`

	// CIDR blocks from which Kubernetes allocates pod IP addresses. Minimum subnet size is 23.
	// +kubebuilder:validation:Optional
	PodCidr []PodCidrParameters `json:"podCidr,omitempty" tf:"pod_cidr,omitempty"`

	// List of DNS search domains.
	// +kubebuilder:validation:Optional
	SearchDomains []*string `json:"searchDomains,omitempty" tf:"search_domains,omitempty"`

	// CIDR block from which Kubernetes allocates service cluster IP addresses.
	// +kubebuilder:validation:Optional
	ServiceCidr []ServiceCidrParameters `json:"serviceCidr,omitempty" tf:"service_cidr,omitempty"`

	// Size of the Kubernetes API server.
	// +kubebuilder:validation:Optional
	SizingHint *string `json:"sizingHint,omitempty" tf:"sizing_hint,omitempty"`

	// The name of a storage policy associated with the datastore where the container images will be stored.
	// +kubebuilder:validation:Optional
	StoragePolicy *string `json:"storagePolicy,omitempty" tf:"storage_policy,omitempty"`

	// List of DNS servers to use on the worker nodes.
	// +kubebuilder:validation:Optional
	WorkerDNS []*string `json:"workerDns,omitempty" tf:"worker_dns,omitempty"`

	// List of NTP servers to use on the worker nodes.
	// +kubebuilder:validation:Optional
	WorkerNtp []*string `json:"workerNtp,omitempty" tf:"worker_ntp,omitempty"`
}

// VSphereSupervisorSpec defines the desired state of VSphereSupervisor
type VSphereSupervisorSpec struct {
	v1.ResourceSpec `json:",inline"`
	ForProvider     VSphereSupervisorParameters `json:"forProvider"`
}

// VSphereSupervisorStatus defines the observed state of VSphereSupervisor.
type VSphereSupervisorStatus struct {
	v1.ResourceStatus `json:",inline"`
	AtProvider        VSphereSupervisorObservation `json:"atProvider,omitempty"`
}

// +kubebuilder:object:root=true

// VSphereSupervisor is the Schema for the VSphereSupervisors API. <no value>
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,categories={crossplane,managed,vsphere}
type VSphereSupervisor struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.cluster)",message="cluster is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.contentLibrary)",message="contentLibrary is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.dvsUuid)",message="dvsUuid is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.edgeCluster)",message="edgeCluster is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.egressCidr)",message="egressCidr is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.ingressCidr)",message="ingressCidr is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.mainDns)",message="mainDns is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.mainNtp)",message="mainNtp is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.managementNetwork)",message="managementNetwork is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.podCidr)",message="podCidr is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.searchDomains)",message="searchDomains is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.serviceCidr)",message="serviceCidr is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.sizingHint)",message="sizingHint is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.storagePolicy)",message="storagePolicy is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.workerDns)",message="workerDns is a required parameter"
	// +kubebuilder:validation:XValidation:rule="self.managementPolicy == 'ObserveOnly' || has(self.forProvider.workerNtp)",message="workerNtp is a required parameter"
	Spec   VSphereSupervisorSpec   `json:"spec"`
	Status VSphereSupervisorStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// VSphereSupervisorList contains a list of VSphereSupervisors
type VSphereSupervisorList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []VSphereSupervisor `json:"items"`
}

// Repository type metadata.
var (
	VSphereSupervisor_Kind             = "VSphereSupervisor"
	VSphereSupervisor_GroupKind        = schema.GroupKind{Group: CRDGroup, Kind: VSphereSupervisor_Kind}.String()
	VSphereSupervisor_KindAPIVersion   = VSphereSupervisor_Kind + "." + CRDGroupVersion.String()
	VSphereSupervisor_GroupVersionKind = CRDGroupVersion.WithKind(VSphereSupervisor_Kind)
)

func init() {
	SchemeBuilder.Register(&VSphereSupervisor{}, &VSphereSupervisorList{})
}
