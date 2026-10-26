#!/usr/bin/env bash
# Author: Chris Polewiak
# Date: 2026-10-12
# Description: AMBA services. Deploys the alert policies of additional Azure services from the AMBA repository
#              (services/<Provider>/<type>/templates/policy-arm), e.g. Network/applicationGateways, that are not
#              part of the AMBA-ALZ pattern. For every alert of a service it creates the policy definition
#              (management group) and a policy assignment with its identity and roles.
#              Needs the same release tag as 'deploy' (deploy.releaseTag in configuration/amba.yaml).
# Usage: ./bin/amba_services.sh -deployMode [whatif|lint|deploy]
#
# Values are taken from:
#   configuration/alzArm.param.json  enterpriseScaleCompanyPrefix, ALZMonitorResourceGroupLocation, LandingZoneManagementGroup
#   configuration/amba.yaml          sections "deploy" (releaseTag) and "services" (management groups for definitions and assignments)
#   configuration/services.yaml      list of services (enabled true/false) with the optional include, exclude, parameters, overrides
#
# Requires: git (the templates are read from a shallow, sparse clone of the AMBA repository at the release tag)
#
# Permissions needed by the identity running this script (details: documentation, RBAC section):
#   - definition management group: create policy definitions
#   - assignment management group: create policy assignments and role assignments

# Load common functions
source "$(dirname "$0")/_deployment_wrapper.sh"

# Load common args and validation (parsing -deployMode, config helpers, pipelineTags)
source "$(dirname "$0")/_common_args.sh"

echo "AMBA services. Deploy Mode: $deployMode"

##################################################
### CONFIGURATION
##################################################
pseudoRootManagementGroupId="$(_config '.init.pseudoRootManagementGroupId')"
if [[ -z "$pseudoRootManagementGroupId" ]]; then
  pseudoRootManagementGroupId="$(_param enterpriseScaleCompanyPrefix)"
fi
location="$(_param ALZMonitorResourceGroupLocation)"
releaseTag="$(_config '.deploy.releaseTag')"
gitUrl="$(_config '.deploy.gitUrl')"
gitUrl="${gitUrl:-https://github.com/Azure/azure-monitor-baseline-alerts.git}"

# Management group for the policy definitions (must be above every assignment scope) and the default assignment scope
definitionMg="$(_config '.services.definitionManagementGroupId')"
definitionMg="${definitionMg:-$pseudoRootManagementGroupId}"
defaultAssignmentMg="$(_config '.services.assignmentManagementGroupId')"
defaultAssignmentMg="${defaultAssignmentMg:-$(_param LandingZoneManagementGroup)}"
defaultAssignmentMg="${defaultAssignmentMg:-$pseudoRootManagementGroupId}"

# The list of services is a separate file (configuration/services.yaml); only services with enabled: true are used
servicesFile="${AMBA_SERVICES_FILE:-$repoRoot/configuration/services.yaml}"
if [[ ! -f "$servicesFile" ]]; then
  echo "Error: services file not found: $servicesFile (copy configuration/services.example.yaml to configuration/services.yaml)" >&2
  exit 1
fi
if ! services="$(yq -o=json '.services // []' "$servicesFile" | jq -c '[.[] | select(.enabled == true)]')"; then
  echo "Error: cannot read $servicesFile" >&2
  exit 1
fi
serviceCount="$(jq 'length' <<< "$services")"

_require "deploy.releaseTag in $(basename "$ambaConfigFile")" "$releaseTag"
_require "pseudo root management group" "$pseudoRootManagementGroupId"
_require "ALZMonitorResourceGroupLocation in $(basename "$ambaParamFile")" "$location"

echo "  AMBA release tag        : $releaseTag"
echo "  Definitions at MG       : $definitionMg"
echo "  Default assignment MG   : $defaultAssignmentMg"
echo "  Services                : $(jq -r 'map(.path) | join(", ")' <<< "$services")"

assignmentsBicep="$repoRoot/bicep/services/policyAssignments.bicep"

if [[ "$deployMode" == "lint" ]]; then
  _az_deployment mg "amba-services" "$assignmentsBicep" || exit $?
  exit 0
fi

if [[ "$serviceCount" -eq 0 ]]; then
  echo "No service is enabled in $(basename "$servicesFile") (enabled: true) - nothing to do."
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: 'git' is required but was not found in PATH." >&2
  exit 1
fi

az account set --subscription "$(_param managementSubscriptionId)" 2>/dev/null || true

##################################################
### SOURCE TEMPLATES (sparse clone at the release tag)
##################################################
workDir="$(mktemp -d)"
trap 'rm -rf "$workDir"' EXIT
srcDir="$workDir/amba"

sparsePaths=()
while IFS= read -r p; do
  sparsePaths+=("services/${p}/templates/policy-arm")
done < <(jq -r '.[].path' <<< "$services")

echo "Cloning $gitUrl (tag $releaseTag)"
export GIT_LFS_SKIP_SMUDGE=1
if ! git clone --quiet --depth 1 --branch "$releaseTag" --filter=blob:none --sparse "$gitUrl" "$srcDir" 2>/dev/null; then
  rm -rf "$srcDir"
  git clone --quiet --depth 1 --branch "$releaseTag" --sparse "$gitUrl" "$srcDir" || {
    echo "Error: cannot clone $gitUrl at tag $releaseTag" >&2; exit 1; }
fi
git -C "$srcDir" sparse-checkout set "${sparsePaths[@]}"

##################################################
### MAIN CODE
##################################################
_service_assignment_name() {
  local definitionName="$1" digest
  # Keep existing GUID-based assignments; descriptive names often share a prefix.
  if [[ "$definitionName" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    printf 'amba-x-%s\n' "${definitionName:0:8}"
  else
    if ! digest="$(printf '%s' "$definitionName" | sha256sum)"; then
      echo "Error: cannot hash policy definition name: $definitionName" >&2
      return 1
    fi
    printf 'amba-x-%s\n' "${digest:0:17}"
  fi
}

rc=0

for ((i = 0; i < serviceCount; i++)); do
  svc="$(jq -c ".[$i]" <<< "$services")"
  svcPath="$(jq -r '.path' <<< "$svc")"
  assignmentMg="$(jq -r '.assignmentManagementGroupId // empty' <<< "$svc")"
  assignmentMg="${assignmentMg:-$defaultAssignmentMg}"
  include="$(jq -c '.include // []' <<< "$svc")"
  exclude="$(jq -c '.exclude // []' <<< "$svc")"
  svcParameters="$(jq -c '.parameters // {}' <<< "$svc")"
  overrides="$(jq -c '.overrides // {}' <<< "$svc")"
  templateDir="$srcDir/services/${svcPath}/templates/policy-arm"
  svcSlug="${svcPath//\//-}"

  echo ""
  echo "=== Service: $svcPath (assignments at MG '$assignmentMg') ==="
  if [[ ! -d "$templateDir" ]]; then
    echo "! No policy templates for '$svcPath' in release $releaseTag (expected services/${svcPath}/templates/policy-arm)." >&2
    echo "  Use the path from the address of the service page: https://azure.github.io/azure-monitor-baseline-alerts/services/<path>/ (e.g. Network/applicationGateways)." >&2
    exit 1
  fi

  assignments="[]"
  roleAssignments="[]"
  templateFiles=()
  firstDefinition=""

  for file in "$templateDir"/*.json; do
    alert="$(basename "$file")"
    alert="${alert%%_*}"
    if [[ "$(jq 'length' <<< "$include")" -gt 0 ]] && ! jq -e --arg a "$alert" 'index($a)' <<< "$include" >/dev/null; then continue; fi
    if jq -e --arg a "$alert" 'index($a)' <<< "$exclude" >/dev/null; then continue; fi

    definition="$(jq -c '.resources[] | select(.type == "Microsoft.Authorization/policyDefinitions")' "$file")"
    definitionName="$(jq -r '.name' <<< "$definition")"
    # The display name in the definition is a template expression; the readable text is the template parameter default
    displayName="$(jq -r '.parameters.displayName.defaultValue // empty' "$file")"
    displayName="${displayName:-AMBA $svcPath $alert}"
    displayName="AMBA-Services | $displayName"
    roleIds="$(jq -c '[.properties.policyRule.then.details.roleDefinitionIds[]? | split("/") | last]' <<< "$definition")"
    definitionKeys="$(jq -c '.properties.parameters | keys' <<< "$definition")"

    # Parameter values: service parameters + overrides of this alert, only keys the definition knows
    values="$(jq -c --argjson o "$overrides" --arg a "$alert" '. + ($o[$a] // {})' <<< "$svcParameters")"
    unknown="$(jq -r --argjson k "$definitionKeys" 'keys - $k | join(", ")' <<< "$values")"
    if [[ -n "$unknown" ]]; then
      _warn "$alert: parameters not defined in the policy are ignored: $unknown"
    fi
    policyParameters="$(jq -c --argjson k "$definitionKeys" \
      'with_entries(select(.key as $x | $k | index($x)) | .value |= {value: (if type == "array" or type == "object" then . else tostring end)})' <<< "$values")"

    assignmentName="$(_service_assignment_name "$definitionName")" || exit $?
    index="$(jq 'length' <<< "$assignments")"
    assignments="$(jq -c --arg n "$assignmentName" --arg d "$displayName" \
      --arg id "/providers/Microsoft.Management/managementGroups/${definitionMg}/providers/Microsoft.Authorization/policyDefinitions/${definitionName}" \
      --argjson p "$policyParameters" '. + [{name: $n, displayName: $d, definitionId: $id, parameters: $p}]' <<< "$assignments")"
    roleAssignments="$(jq -c --argjson i "$index" --argjson r "$roleIds" \
      '. + [$r[] | {assignmentIndex: $i, roleDefinitionId: .}]' <<< "$roleAssignments")"
    templateFiles+=("$file")
    firstDefinition="${firstDefinition:-$definitionName}"
  done

  if [[ ${#templateFiles[@]} -eq 0 ]]; then
    echo "No alerts selected for '$svcPath' (check include / exclude)."
    continue
  fi
  echo "Alerts: ${#templateFiles[@]} -> $(jq -r 'map(.displayName | sub("^Deploy "; "")) | join("; ")' <<< "$assignments")"

  # 1. Policy definitions - management group scope
  for file in "${templateFiles[@]}"; do
    _az_deployment mg "amba-def-$(basename "${file%%_*}")" "$file" \
      --management-group-id "$definitionMg" \
      --location "$location" || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "! Policy definition step failed for $(basename "$file") (exit code $rc)" >&2
      exit $rc
    fi
  done

  # 2. Policy assignments and role assignments - management group scope
  if [[ "$deployMode" == "whatif" ]] && ! az policy definition show --name "$firstDefinition" \
       --management-group "$definitionMg" --query name -o tsv >/dev/null 2>&1; then
    echo "Policy assignments: the policy definitions do not exist yet - what-if for the assignments is skipped."
    echo "  After 'deploy' these policies are assigned at MG '$assignmentMg': $(jq -r 'map(.name) | join(", ")' <<< "$assignments")"
    continue
  fi

  paramsFile="$workDir/params-${svcSlug}.json"
  jq -n --arg l "$location" --argjson a "$assignments" --argjson r "$roleAssignments" \
    '{"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      contentVersion: "1.0.0.0",
      parameters: {param_location: {value: $l}, param_assignments: {value: $a}, param_roleAssignments: {value: $r}}}' > "$paramsFile"

  _az_deployment mg "amba-services-${svcSlug}" "$assignmentsBicep" \
    --management-group-id "$assignmentMg" \
    --location "$location" \
    --parameters "@$paramsFile" || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "! Policy assignment step failed for '$svcPath' (exit code $rc)" >&2
    exit $rc
  fi
done

##################################################
### SUMMARY
##################################################
echo ""
echo "AMBA services finished (deployMode=$deployMode)."
if [[ "$deployMode" == "deploy" ]]; then
  echo "Next: run the remediation step so the new policies create alerts on existing resources."
fi
