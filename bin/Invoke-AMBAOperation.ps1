[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('remediate', 'cleanup')][string]$Operation,
    [ValidateSet('whatif', 'deploy')][string]$DeployMode = 'whatif',
    [ValidateSet('Alerts', 'OrphanedAlerts', 'NotificationAssets', 'PolicyAssignments', 'PolicyDefinitions', 'RoleAssignments', 'Deployments', 'OldNotificationAssets', 'LegacySH', 'Amba-Alz')]
    [string]$CleanItems = 'Alerts'
)

$ErrorActionPreference = 'Stop'
foreach ($module in @('Az.Accounts', 'Az.Resources') + $(if ($Operation -eq 'cleanup') { @('Az.ResourceGraph', 'Az.ManagedServiceIdentity') } else { @() })) {
    if (!(Get-Module -ListAvailable -Name $module)) { throw "Required module is not installed: $module. Provision it on the pipeline agent before running." }
}
$root = Split-Path $PSScriptRoot -Parent
$configText = & yq -o=json '.' (Join-Path $root 'configuration/amba.yaml')
if ($LASTEXITCODE -ne 0) { throw 'Cannot read configuration/amba.yaml using yq.' }
$config = ($configText -join "`n") | ConvertFrom-Json
$parameters = (Get-Content (Join-Path $root 'configuration/alzArm.param.json') -Raw | ConvertFrom-Json).parameters
$release = $config.deploy.releaseTag
if ([string]::IsNullOrWhiteSpace($release)) { throw 'deploy.releaseTag is required.' }
$mg = $config.init.pseudoRootManagementGroupId
if (!$mg) { $mg = $parameters.enterpriseScaleCompanyPrefix.value }
if (!$mg) { throw 'Pseudo root management group is required.' }

$scriptName = if ($Operation -eq 'cleanup') { 'Start-AMBA-ALZ-Maintenance.ps1' } else { 'Start-AMBA-ALZ-Remediation.ps1' }
$officialDirectory = Join-Path $PSScriptRoot 'upstream'
$source = Get-Content (Join-Path $officialDirectory 'source.json') -Raw | ConvertFrom-Json
if ($release -notin @($source.ref, $source.commit)) {
    throw "deploy.releaseTag '$release' does not match the bundled AMBA scripts ($($source.ref), $($source.commit)). Update bin/upstream with that version first."
}
if ($config.deploy.templateBaseUri -and $config.deploy.templateBaseUri.TrimEnd('/') -ne 'https://raw.githubusercontent.com/Azure/azure-monitor-baseline-alerts') {
    throw 'Bundled scripts are from Azure/azure-monitor-baseline-alerts; review and update provenance before using a different deployment source.'
}
$script = Join-Path $officialDirectory $scriptName
Write-Host "Official AMBA script: $script (upstream commit $($source.commit))"
& {

    if ($Operation -eq 'cleanup') {
        # Upstream full cleanup deletes any UAMI carrying its ownership tag, including BYO identities.
        $identityId = $parameters.bringYourOwnUserAssignedManagedIdentityResourceId.value
        if ($CleanItems -eq 'Amba-Alz' -and $identityId -and $DeployMode -eq 'deploy') {
            $identity = Get-AzResource -ResourceId $identityId
            if ([string]$identity.Tags['_deployed_by_amba'] -ieq 'true') {
                throw 'Full upstream cleanup would select the BYO identity. Use selective cleanup operations instead.'
            }
        }
        & $script -pseudoRootManagementGroup $mg -cleanItems $CleanItems -WhatIf:($DeployMode -eq 'whatif') -Confirm:$false
    }
    else {
        $groups = @(
            $parameters.enterpriseScaleCompanyPrefix.value
            $parameters.platformManagementGroup.value
            $parameters.IdentityManagementGroup.value
            $parameters.managementManagementGroup.value
            $parameters.connectivityManagementGroup.value
            $parameters.LandingZoneManagementGroup.value
            $config.services.assignmentManagementGroupId
            $config.remediate.managementGroups
        )
        $servicesPath = Join-Path $root 'configuration/services.yaml'
        if (Test-Path $servicesPath) {
            $servicesText = & yq -o=json '.' $servicesPath
            if ($LASTEXITCODE -ne 0) { throw 'Cannot read configuration/services.yaml using yq.' }
            $services = ($servicesText -join "`n") | ConvertFrom-Json
            $groups += @($services.services | Where-Object enabled -EQ $true | ForEach-Object assignmentManagementGroupId)
        }
        $pattern = $config.remediate.assignmentNamePattern
        if (!$pattern) { $pattern = '^(Deploy-AMBA-|amba-x-)' }
        $plan = foreach ($group in ($groups | Where-Object { $_ } | Sort-Object -Unique)) {
            $scope = "/providers/Microsoft.Management/managementGroups/$group"
            foreach ($assignment in (Get-AzPolicyAssignment -Scope $scope)) {
                if ($assignment.Scope -ine $scope) { continue }
                if ($config.remediate.include.Count -gt 0 -and $assignment.Name -notin $config.remediate.include) { continue }
                if ($assignment.Name -in $config.remediate.exclude) { continue }
                if ($assignment.Name -notmatch $pattern) { continue }
                [pscustomobject]@{
                    Group = $group
                    Policy = ($assignment.PolicyDefinitionId -split '/')[-1]
                }
            }
        }
        $plan = @($plan | Sort-Object Group, Policy -Unique | Sort-Object { if ($_.Policy -match 'Notification|ServiceHealth|ResourceAndServiceHealth') { 0 } else { 1 } })
        if (!$plan.Count) { throw 'No matching AMBA assignments found. Check deployment, scopes and remediation filters.' }
        foreach ($item in $plan) {
            Write-Host "AMBA remediation: MG=$($item.Group); policy/initiative=$($item.Policy)"
            if ($DeployMode -eq 'deploy') {
                & $script -managementGroupName $item.Group -policyName $item.Policy | ForEach-Object {
                    if ($_.PSObject.Properties['StatusCode'] -and [int]$_.StatusCode -ge 400) {
                        throw "Official remediation request failed (HTTP $($_.StatusCode)): $($_.Content)"
                    }
                    $_
                }
            }
        }
        if ($DeployMode -eq 'whatif') {
            Write-Host 'Plan only: the official remediation script has no WhatIf mode and was not executed.'
        }
    }
}
