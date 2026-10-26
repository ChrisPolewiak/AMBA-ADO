// Author: Chris Polewiak
// Description: Assigns "Managed Identity Operator" on the AMBA user-assigned managed identity (bring your own)
//              to the system-assigned identities of the AMBA policy assignments.
//              AMBA does this itself only when it creates the identity (bringYourOwnUserAssignedManagedIdentity = No).
targetScope = 'resourceGroup'

@description('Name of the AMBA user-assigned managed identity (it must exist in this resource group)')
param param_userAssignedIdentityName string

@description('Object IDs (principalId) of the system-assigned identities of the AMBA policy assignments')
param param_principalIds array

// Managed Identity Operator
var managedIdentityOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: param_userAssignedIdentityName
}

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in param_principalIds: {
  name: guid(userAssignedIdentity.id, principalId, managedIdentityOperatorRoleId)
  scope: userAssignedIdentity
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperatorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
    description: '_deployed_by_amba_pipeline'
  }
}]
