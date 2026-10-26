// Author: Chris Polewiak
// Description: Assigns AMBA service alert policies (definitions from the AMBA repository, templates/policy-arm)
//              at a management group and gives the system-assigned identity of each assignment the roles
//              listed in the policy definition (needed by the deployIfNotExists remediation).
targetScope = 'managementGroup'

@description('Region of the policy assignments (needed by the system-assigned identity).')
param param_location string

@description('Policy assignments. Fields: name (max 24 characters), displayName, definitionId, parameters (policy parameter values).')
param param_assignments array

@description('Roles for the identities of the assignments. Fields: assignmentIndex (index in param_assignments), roleDefinitionId (GUID).')
param param_roleAssignments array

resource assignments 'Microsoft.Authorization/policyAssignments@2022-06-01' = [for a in param_assignments: {
  name: a.name
  location: param_location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: a.displayName
    description: 'Deployed by the AMBA pipeline (services)'
    metadata: {
      _deployed_by_amba: 'True'
    }
    policyDefinitionId: a.definitionId
    enforcementMode: 'Default'
    parameters: a.parameters
  }
}]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for r in param_roleAssignments: {
  name: guid(managementGroup().id, param_assignments[r.assignmentIndex].name, r.roleDefinitionId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', r.roleDefinitionId)
    principalId: assignments[r.assignmentIndex].identity.principalId
    principalType: 'ServicePrincipal'
    description: '_deployed_by_amba_pipeline'
  }
}]
