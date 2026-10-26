// AMBA init (1/2): resource group (+ lock) and user-assigned managed identity.
// Deployed at subscription scope (management subscription).
targetScope = 'subscription'

@description('Azure region of the resource group and the managed identity.')
param param_location string

@description('Name of the resource group that holds the AMBA user-assigned managed identity.')
param param_resourceGroupName string

@description('Lock configuration for the resource group. Fields: kind, name, notes. Empty object = no lock.')
param param_resourceGroupLock object = {}

@description('Name of the user-assigned managed identity (used as bringYourOwnUserAssignedManagedIdentity).')
param param_userAssignedIdentityName string

@description('Azure tags applied to the resource group and the managed identity.')
param param_tags object = {}

// Resource group (shared AVM wrapper module)
module module_resourceGroup '../modules/resourceGroup.bicep' = {
  name: 'deploy-${param_resourceGroupName}'
  params: {
    param_name: param_resourceGroupName
    param_location: param_location
    param_lock: param_resourceGroupLock
    param_tags: param_tags
  }
}

// User-assigned managed identity inside the resource group
module module_userAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'deploy-${param_userAssignedIdentityName}'
  scope: resourceGroup(param_resourceGroupName)
  dependsOn: [
    module_resourceGroup
  ]
  params: {
    name: param_userAssignedIdentityName
    location: param_location
    tags: param_tags
  }
}

output userAssignedIdentityResourceId string = module_userAssignedIdentity.outputs.resourceId
output userAssignedIdentityPrincipalId string = module_userAssignedIdentity.outputs.principalId
output userAssignedIdentityClientId string = module_userAssignedIdentity.outputs.clientId
