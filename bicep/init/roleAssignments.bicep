// AMBA init (2/2): roles for the AMBA user-assigned managed identity at the pseudo root management group.
// Deployed at management group scope.
targetScope = 'managementGroup'

@description('Object ID (principalId) of the managed identity that receives the roles.')
param param_principalId string

@description('Roles to assign at this management group. Items: { roleName: string, roleDefinitionId: string (GUID) }.')
param param_roleAssignments array

// principalType is set explicitly so the assignment does not fail on Entra ID replication delay
// right after the managed identity has been created.
resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for item in param_roleAssignments: {
  name: guid(managementGroup().id, param_principalId, item.roleDefinitionId)
  properties: {
    principalId: param_principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', item.roleDefinitionId)
    description: 'AMBA init: ${item.roleName} for the AMBA user-assigned managed identity'
  }
}]
