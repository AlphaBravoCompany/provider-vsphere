/*
Copyright 2022 Upbound Inc.
*/
// Code generated by angryjet. DO NOT EDIT.

package v1alpha1

import xpv1 "github.com/crossplane/crossplane-runtime/apis/common/v1"

// GetCondition of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetCondition(ct xpv1.ConditionType) xpv1.Condition {
	return mg.Status.GetCondition(ct)
}

// GetDeletionPolicy of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetDeletionPolicy() xpv1.DeletionPolicy {
	return mg.Spec.DeletionPolicy
}

// GetManagementPolicy of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetManagementPolicy() xpv1.ManagementPolicy {
	return mg.Spec.ManagementPolicy
}

// GetProviderConfigReference of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetProviderConfigReference() *xpv1.Reference {
	return mg.Spec.ProviderConfigReference
}

/*
GetProviderReference of this VSphereSupervisor.
Deprecated: Use GetProviderConfigReference.
*/
func (mg *VSphereSupervisor) GetProviderReference() *xpv1.Reference {
	return mg.Spec.ProviderReference
}

// GetPublishConnectionDetailsTo of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetPublishConnectionDetailsTo() *xpv1.PublishConnectionDetailsTo {
	return mg.Spec.PublishConnectionDetailsTo
}

// GetWriteConnectionSecretToReference of this VSphereSupervisor.
func (mg *VSphereSupervisor) GetWriteConnectionSecretToReference() *xpv1.SecretReference {
	return mg.Spec.WriteConnectionSecretToReference
}

// SetConditions of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetConditions(c ...xpv1.Condition) {
	mg.Status.SetConditions(c...)
}

// SetDeletionPolicy of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetDeletionPolicy(r xpv1.DeletionPolicy) {
	mg.Spec.DeletionPolicy = r
}

// SetManagementPolicy of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetManagementPolicy(r xpv1.ManagementPolicy) {
	mg.Spec.ManagementPolicy = r
}

// SetProviderConfigReference of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetProviderConfigReference(r *xpv1.Reference) {
	mg.Spec.ProviderConfigReference = r
}

/*
SetProviderReference of this VSphereSupervisor.
Deprecated: Use SetProviderConfigReference.
*/
func (mg *VSphereSupervisor) SetProviderReference(r *xpv1.Reference) {
	mg.Spec.ProviderReference = r
}

// SetPublishConnectionDetailsTo of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetPublishConnectionDetailsTo(r *xpv1.PublishConnectionDetailsTo) {
	mg.Spec.PublishConnectionDetailsTo = r
}

// SetWriteConnectionSecretToReference of this VSphereSupervisor.
func (mg *VSphereSupervisor) SetWriteConnectionSecretToReference(r *xpv1.SecretReference) {
	mg.Spec.WriteConnectionSecretToReference = r
}

// GetCondition of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetCondition(ct xpv1.ConditionType) xpv1.Condition {
	return mg.Status.GetCondition(ct)
}

// GetDeletionPolicy of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetDeletionPolicy() xpv1.DeletionPolicy {
	return mg.Spec.DeletionPolicy
}

// GetManagementPolicy of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetManagementPolicy() xpv1.ManagementPolicy {
	return mg.Spec.ManagementPolicy
}

// GetProviderConfigReference of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetProviderConfigReference() *xpv1.Reference {
	return mg.Spec.ProviderConfigReference
}

/*
GetProviderReference of this VSphereVirtualMachineClass.
Deprecated: Use GetProviderConfigReference.
*/
func (mg *VSphereVirtualMachineClass) GetProviderReference() *xpv1.Reference {
	return mg.Spec.ProviderReference
}

// GetPublishConnectionDetailsTo of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetPublishConnectionDetailsTo() *xpv1.PublishConnectionDetailsTo {
	return mg.Spec.PublishConnectionDetailsTo
}

// GetWriteConnectionSecretToReference of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) GetWriteConnectionSecretToReference() *xpv1.SecretReference {
	return mg.Spec.WriteConnectionSecretToReference
}

// SetConditions of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetConditions(c ...xpv1.Condition) {
	mg.Status.SetConditions(c...)
}

// SetDeletionPolicy of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetDeletionPolicy(r xpv1.DeletionPolicy) {
	mg.Spec.DeletionPolicy = r
}

// SetManagementPolicy of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetManagementPolicy(r xpv1.ManagementPolicy) {
	mg.Spec.ManagementPolicy = r
}

// SetProviderConfigReference of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetProviderConfigReference(r *xpv1.Reference) {
	mg.Spec.ProviderConfigReference = r
}

/*
SetProviderReference of this VSphereVirtualMachineClass.
Deprecated: Use SetProviderConfigReference.
*/
func (mg *VSphereVirtualMachineClass) SetProviderReference(r *xpv1.Reference) {
	mg.Spec.ProviderReference = r
}

// SetPublishConnectionDetailsTo of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetPublishConnectionDetailsTo(r *xpv1.PublishConnectionDetailsTo) {
	mg.Spec.PublishConnectionDetailsTo = r
}

// SetWriteConnectionSecretToReference of this VSphereVirtualMachineClass.
func (mg *VSphereVirtualMachineClass) SetWriteConnectionSecretToReference(r *xpv1.SecretReference) {
	mg.Spec.WriteConnectionSecretToReference = r
}
