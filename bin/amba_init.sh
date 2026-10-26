#!/usr/bin/env bash
# Author: Chris Polewiak
# Date: 2026-10-12
# Description: AMBA init. Creates the resource group and the user-assigned managed identity (UAMI)
#              that AMBA uses as "bring your own" identity (bringYourOwnUserAssignedManagedIdentityResourceId)
#              and assigns the required roles to that identity at the pseudo root management group.
#              Safe to run repeatedly (idempotent).
# Usage: ./bin/amba_init.sh -deployMode [whatif|lint|deploy]
#
# Values are taken from:
#   configuration/alzArm.param.json  managementSubscriptionId, ALZMonitorResourceGroupLocation,
#                       userAssignedManagedIdentityName, enterpriseScaleCompanyPrefix
#   configuration/amba.yaml    section "init" (resource group name/lock/tags, roles, default tags)
#
# Permissions needed by the identity running this script (details: documentation, RBAC section):
#   - management subscription: create resource groups, locks and managed identities
#   - pseudo root management group: assign roles (Monitoring Reader) to the new identity

# Load common functions
source "$(dirname "$0")/_deployment_wrapper.sh"

# Load common args and validation (parsing -deployMode, config helpers, pipelineTags)
source "$(dirname "$0")/_common_args.sh"

echo "AMBA init. Deploy Mode: $deployMode"

##################################################
### CONFIGURATION
##################################################
managementSubscriptionId="$(_param managementSubscriptionId)"
location="$(_param ALZMonitorResourceGroupLocation)"
userAssignedIdentityName="$(_param userAssignedManagedIdentityName)"

# Pseudo root management group: explicit value from config, otherwise the ALZ company prefix
pseudoRootManagementGroupId="$(_config '.init.pseudoRootManagementGroupId')"
if [[ -z "$pseudoRootManagementGroupId" ]]; then
  pseudoRootManagementGroupId="$(_param enterpriseScaleCompanyPrefix)"
fi

resourceGroupName="$(_config '.init.resourceGroup.name')"
resourceGroupLock="$(_configJson '.init.resourceGroup.lock // {}')"
resourceGroupTags="$(_configJson '.init.resourceGroup.tags // {}')"
defaultTags="$(_configJson '.init.tags // {}')"
roleAssignments="$(_configJson '.init.pseudoRootRoleAssignments // []')"

_require "managementSubscriptionId in $(basename "$ambaParamFile")" "$managementSubscriptionId"
_require "ALZMonitorResourceGroupLocation in $(basename "$ambaParamFile")" "$location"
_require "userAssignedManagedIdentityName in $(basename "$ambaParamFile")" "$userAssignedIdentityName"
_require "pseudo root management group (init.pseudoRootManagementGroupId in $(basename "$ambaConfigFile") or enterpriseScaleCompanyPrefix in $(basename "$ambaParamFile"))" "$pseudoRootManagementGroupId"
_require "init.resourceGroup.name in $(basename "$ambaConfigFile")" "$resourceGroupName"

tags="$(printf '%s\n%s\n%s' "$defaultTags" "$pipelineTags" "$resourceGroupTags" | jq -s -c 'reduce .[] as $item ({}; . * $item)')"

identityResourceId="/subscriptions/${managementSubscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${userAssignedIdentityName}"

echo "  Management subscription : $managementSubscriptionId"
echo "  Location                : $location"
echo "  Resource group          : $resourceGroupName"
echo "  Resource group lock     : $resourceGroupLock"
echo "  Managed identity        : $userAssignedIdentityName"
echo "  Pseudo root MG          : $pseudoRootManagementGroupId"
echo "  Role assignments (MG)   : $roleAssignments"

# Set the Azure subscription context for deployment (not needed for lint)
if [[ "$deployMode" != "lint" ]]; then
  echo "Set subscription: '$managementSubscriptionId'"
  az account set --subscription "$managementSubscriptionId"
fi

##################################################
### MAIN CODE
##################################################
rc=0

# 1. Resource group (+ lock) and user-assigned managed identity - subscription scope
_az_deployment sub "amba-init-identity" "$repoRoot/bicep/init/identity.bicep" \
  --location "$location" \
  --parameters "param_location=$location" \
               "param_resourceGroupName=$resourceGroupName" \
               "param_resourceGroupLock=$resourceGroupLock" \
               "param_userAssignedIdentityName=$userAssignedIdentityName" \
               "param_tags=$tags" || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "! Resource group / identity step failed (exit code $rc)" >&2
  exit $rc
fi

# 2. Roles for the identity at the pseudo root management group - management group scope
if [[ "$deployMode" == "lint" ]]; then
  principalId="00000000-0000-0000-0000-000000000000"
else
  principalId="$(az identity show \
    --subscription "$managementSubscriptionId" \
    --resource-group "$resourceGroupName" \
    --name "$userAssignedIdentityName" \
    --query principalId -o tsv 2>/dev/null || true)"
fi

if [[ -z "$principalId" && "$deployMode" == "whatif" ]]; then
  echo "Role assignments: identity '$userAssignedIdentityName' does not exist yet - what-if for the role assignments is skipped."
  echo "  After 'deploy' the following roles will be assigned at management group '$pseudoRootManagementGroupId':"
  echo "$roleAssignments" | jq -r '.[] | "    - \(.roleName) (\(.roleDefinitionId))"'
elif [[ -z "$principalId" ]]; then
  echo "! Cannot read principalId of identity '$userAssignedIdentityName'" >&2
  exit 1
else
  _az_deployment mg "amba-init-roles" "$repoRoot/bicep/init/roleAssignments.bicep" \
    --management-group-id "$pseudoRootManagementGroupId" \
    --location "$location" \
    --parameters "param_principalId=$principalId" \
                 "param_roleAssignments=$roleAssignments" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "! Role assignment step failed (exit code $rc)" >&2
    exit $rc
  fi
fi

##################################################
### SUMMARY
##################################################
echo ""
echo "AMBA init finished (deployMode=$deployMode)."
echo "Parameters for alzArm.param.json:"
echo "  bringYourOwnUserAssignedManagedIdentity           = Yes"
echo "  bringYourOwnUserAssignedManagedIdentityResourceId = $identityResourceId"

if [[ "$(_param bringYourOwnUserAssignedManagedIdentity)" != "Yes" ]]; then
  _warn "alzArm.param.json: bringYourOwnUserAssignedManagedIdentity is not 'Yes'."
fi
# Azure resource IDs are case-insensitive, so compare in lower case
paramResourceId="$(_param bringYourOwnUserAssignedManagedIdentityResourceId)"
if [[ "${paramResourceId,,}" != "${identityResourceId,,}" ]]; then
  _warn "alzArm.param.json: bringYourOwnUserAssignedManagedIdentityResourceId does not match the identity managed by init."
  _warn "  in alzArm.param.json : ${paramResourceId:-<empty>}"
  _warn "  managed by init      : $identityResourceId"
  _warn "  (init builds the ID from managementSubscriptionId, init.resourceGroup.name in amba.yaml and userAssignedManagedIdentityName)"
fi
