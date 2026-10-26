#!/usr/bin/env bash
# Author: Chris Polewiak
# Date: 2026-10-12
# Description: AMBA deploy. Deploys AMBA-ALZ from an official release (no fork) with configuration/alzArm.param.json
#              and gives the AMBA policy assignments the Managed Identity Operator role on the AMBA identity.
#              Run 'amba_init.sh' first (it creates the identity referenced in alzArm.param.json).
# Usage: ./bin/amba_deploy.sh -deployMode [whatif|lint|deploy]
#
# Values are taken from:
#   configuration/alzArm.param.json  the AMBA parameters (passed to the AMBA deployment as they are), plus
#                       enterpriseScaleCompanyPrefix, ALZMonitorResourceGroupLocation, managementSubscriptionId,
#                       bringYourOwnUserAssignedManagedIdentityResourceId and the management group names
#   configuration/amba.yaml    section "deploy" (release tag, deployment name, policy assignments that need the operator role)
#
# Permissions needed by the identity running this script (details: documentation, RBAC section):
#   - pseudo root management group: create policy definitions, assignments and role assignments
#   - AMBA identity: assign roles (Managed Identity Operator)

# Load common functions
source "$(dirname "$0")/_deployment_wrapper.sh"

# Load common args and validation (parsing -deployMode, config helpers, pipelineTags)
source "$(dirname "$0")/_common_args.sh"

echo "AMBA deploy. Deploy Mode: $deployMode"

##################################################
### CONFIGURATION
##################################################
pseudoRootManagementGroupId="$(_config '.init.pseudoRootManagementGroupId')"
if [[ -z "$pseudoRootManagementGroupId" ]]; then
  pseudoRootManagementGroupId="$(_param enterpriseScaleCompanyPrefix)"
fi
location="$(_param ALZMonitorResourceGroupLocation)"
managementSubscriptionId="$(_param managementSubscriptionId)"
byoEnabled="$(_param bringYourOwnUserAssignedManagedIdentity)"
identityResourceId="$(_param bringYourOwnUserAssignedManagedIdentityResourceId)"

releaseTag="$(_config '.deploy.releaseTag')"
templateBaseUri="$(_config '.deploy.templateBaseUri')"
templateBaseUri="${templateBaseUri:-https://raw.githubusercontent.com/Azure/azure-monitor-baseline-alerts}"
deploymentName="$(_config '.deploy.deploymentName')"
deploymentName="${deploymentName:-amba-alz}"
operatorAssignments="$(_configJson '.deploy.managedIdentityOperatorAssignments // []')"
# Which pipeline tags (pipelineName, pipelineId, pipelineBuild) are added to the AMBA tags; empty list = none
pipelineTagNames="$(_configJson '.deploy.pipelineTags // ["pipelineName","pipelineId","pipelineBuild"]')"

_require "deploy.releaseTag in $(basename "$ambaConfigFile")" "$releaseTag"
_require "pseudo root management group (init.pseudoRootManagementGroupId in $(basename "$ambaConfigFile") or enterpriseScaleCompanyPrefix in $(basename "$ambaParamFile"))" "$pseudoRootManagementGroupId"
_require "ALZMonitorResourceGroupLocation in $(basename "$ambaParamFile")" "$location"
_require "managementSubscriptionId in $(basename "$ambaParamFile")" "$managementSubscriptionId"

if [[ "$byoEnabled" != "Yes" || -z "$identityResourceId" ]]; then
  echo "Error: set bringYourOwnUserAssignedManagedIdentity = Yes and bringYourOwnUserAssignedManagedIdentityResourceId in $(basename "$ambaParamFile") (the values are printed by amba_init.sh)." >&2
  exit 1
fi

# Identity ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>
shopt -s nocasematch
if [[ "$identityResourceId" =~ ^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/([^/]+)$ ]]; then
  identitySubscriptionId="${BASH_REMATCH[1]}"
  identityResourceGroup="${BASH_REMATCH[2]}"
  identityName="${BASH_REMATCH[3]}"
else
  shopt -u nocasematch
  echo "Error: bringYourOwnUserAssignedManagedIdentityResourceId is not a valid user-assigned identity resource ID: $identityResourceId" >&2
  exit 1
fi
shopt -u nocasematch

templateUri="${templateBaseUri}/${releaseTag}/patterns/alz/alzArm.json"

# Tags of the AMBA resource group (ALZMonitorResourceGroupTags): tags from the parameter file + selected pipeline tags
selectedPipelineTags="$(jq -c --argjson names "$pipelineTagNames" 'with_entries(select(.key as $k | $names | index($k)))' <<< "$pipelineTags")"
amba_tags="$(jq -c '.parameters.ALZMonitorResourceGroupTags.value // {}' "$ambaParamFile" | jq -s -c --argjson p "$selectedPipelineTags" '.[0] * $p')"

# Management groups where AMBA creates policy assignments (names come from the AMBA parameter file)
managementGroups="$(jq -c '[ .parameters
    | (.enterpriseScaleCompanyPrefix, .platformManagementGroup, .IdentityManagementGroup, .managementManagementGroup,
       .connectivityManagementGroup, .LandingZoneManagementGroup)
    | .value // empty ] | unique' "$ambaParamFile")"

echo "  AMBA release tag        : $releaseTag"
echo "  Template                : $templateUri"
echo "  Pseudo root MG          : $pseudoRootManagementGroupId"
echo "  Deployment location     : $location"
echo "  AMBA identity           : $identityResourceId"
echo "  AMBA resource group tags: $amba_tags"
echo "  Operator role for       : $(echo "$operatorAssignments" | jq -r 'join(", ")')"

if [[ "$deployMode" != "lint" ]]; then
  echo "Set subscription: '$managementSubscriptionId'"
  az account set --subscription "$managementSubscriptionId"
fi

##################################################
### MAIN CODE
##################################################
rc=0

# The AMBA identity has to exist (it is created by amba_init.sh)
if [[ "$deployMode" != "lint" ]]; then
  if ! az identity show --ids "$identityResourceId" --query id -o tsv >/dev/null 2>&1; then
    if [[ "$deployMode" == "deploy" ]]; then
      echo "! The AMBA identity does not exist: $identityResourceId. Run amba_init.sh first." >&2
      exit 1
    fi
    _warn "The AMBA identity does not exist yet: $identityResourceId. Run amba_init.sh first."
  fi
fi

# 1. AMBA-ALZ from the release - management group scope.
#    The template must be deployed from its URL: it loads its linked templates relative to its own address.
_az_deployment mg "$deploymentName" "$templateUri" \
  --management-group-id "$pseudoRootManagementGroupId" \
  --location "$location" \
  --parameters "@$ambaParamFile" "ALZMonitorResourceGroupTags=$amba_tags" || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "! AMBA deployment step failed (exit code $rc)" >&2
  exit $rc
fi

# 2. Managed Identity Operator on the AMBA identity for the system-assigned identities of the policy assignments.
#    With "bring your own" identity AMBA does not do it itself.
principalIds="[]"
if [[ "$deployMode" == "lint" ]]; then
  principalIds='["00000000-0000-0000-0000-000000000000"]'
else
  while IFS= read -r assignmentName; do
    [[ -z "$assignmentName" ]] && continue
    while IFS= read -r mg; do
      principalId="$(az policy assignment show --name "$assignmentName" \
        --scope "/providers/Microsoft.Management/managementGroups/$mg" \
        --query identity.principalId -o tsv 2>/dev/null || true)"
      if [[ -n "$principalId" ]]; then
        echo "  Policy assignment $assignmentName (MG $mg): $principalId"
        principalIds="$(jq -c --arg p "$principalId" '. + [$p] | unique' <<< "$principalIds")"
      fi
    done < <(jq -r '.[]' <<< "$managementGroups")
  done < <(jq -r '.[]' <<< "$operatorAssignments")
fi

if [[ "$principalIds" == "[]" ]]; then
  if [[ "$deployMode" == "deploy" ]]; then
    _warn "No AMBA policy assignment with a system-assigned identity was found - the Managed Identity Operator role was not assigned."
  else
    echo "Operator role: the AMBA policy assignments do not exist yet - what-if for this step is skipped."
    echo "  After 'deploy' the role will be assigned on '$identityName' to the identities of: $(echo "$operatorAssignments" | jq -r 'join(", ")')"
  fi
else
  _az_deployment group "amba-deploy-operator" "$repoRoot/bicep/deploy/managedIdentityOperator.bicep" \
    --subscription "$identitySubscriptionId" \
    --resource-group "$identityResourceGroup" \
    --parameters "param_userAssignedIdentityName=$identityName" \
                 "param_principalIds=$principalIds" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "! Managed Identity Operator step failed (exit code $rc)" >&2
    exit $rc
  fi
fi

##################################################
### SUMMARY
##################################################
echo ""
echo "AMBA deploy finished (deployMode=$deployMode)."
if [[ "$deployMode" == "deploy" ]]; then
  echo "Next: run the remediation step to apply the policies to existing resources."
fi
