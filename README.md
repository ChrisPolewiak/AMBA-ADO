# Azure Monitor Baseline Alerts (AMBA-ALZ)

**English** | [Polski](README.PL.md)

Deploys [AMBA-ALZ](https://azure.github.io/azure-monitor-baseline-alerts/) from Azure DevOps or the command line.
The AMBA template comes from the official release (no fork). This repo holds only configuration, pipelines and scripts.

Pipelines run the scripts from `bin/`. Preview modes do not change Azure resources:
ARM What-If for init/deploy/services, an execution plan for remediation, and native PowerShell WhatIf for cleanup.

## Steps

| Step | Purpose | Pipeline |
| --- | --- | --- |
| 0 | Pipeline identity and Service Connection | Manual setup below |
| 1 | **init**: RG, BYO identity and Monitoring Reader | [amba_init.yml](.pipelines/amba_init.yml) |
| 2 | **deploy**: official AMBA-ALZ and BYO operator permissions | [amba_deploy.yml](.pipelines/amba_deploy.yml) |
| 3 | **services**: selected service policies and assignments | [amba_services.yml](.pipelines/amba_services.yml) |
| 4 | **remediate**: create remediation tasks for existing resources | [amba_remediate.yml](.pipelines/amba_remediate.yml) |
| 5 | **cleanup**: remove selected AMBA resources | [amba_cleanup.yml](.pipelines/amba_cleanup.yml) |

## Requirements

- Init/deploy/services: Azure CLI with Bicep, `jq`, `yq` (mikefarah v4), Bash; services also needs Git.
- Remediate/cleanup: PowerShell 7, `yq`, `Az.Accounts`, `Az.Resources`; cleanup also needs `Az.ResourceGraph` and `Az.ManagedServiceIdentity` at the minimum versions required by the official scripts. Pipelines authenticate through `AzurePowerShell@5`; local use requires an Azure PowerShell login.
- The **Management** subscription and an existing management group (MG) hierarchy with a pseudo root MG.
- Resource providers in every monitored subscription: `Microsoft.AlertsManagement`, `Microsoft.Insights`.

## Configuration

| File | What you set |
| --- | --- |
| `configuration/ado-env.yml` | Agent pool (`devops_runner_pool_name`) and Service Connection (`devops_service_connection_name`). |
| `configuration/alzArm.param.json` | AMBA parameters. Init reads the Management subscription, region, UAMI name (`userAssignedManagedIdentityName`) and `enterpriseScaleCompanyPrefix` from it. |
| `configuration/amba.yaml` | `init`: identity resource group name, lock, tags and roles for the UAMI, optional `pseudoRootManagementGroupId`. `deploy`: AMBA release tag and deployment name. `services`: management groups for the service policies. `remediate`: optional settings. |
| `configuration/services.yaml` | The list of additional Azure services (`enabled: true/false`) for step 3, with optional per-service settings. |

The UAMI name is in `alzArm.param.json`; the RG it is created in is in `amba.yaml`.

Each file has an example with placeholder values: `ado-env.example.yml`, `alzArm.param.example.json`, `amba.example.yaml`, `services.example.yaml`. For a new environment, copy the examples over the real files (without `.example`) and replace the placeholders.

## Two identities: do not confuse them

| | Pipeline identity | AMBA identity |
| --- | --- | --- |
| Purpose | Deploys: runs init, deploy, remediate, cleanup | Used by AMBA log-search alert rules at runtime to read data (Azure Resource Graph: tags, threshold overrides) |
| Created by | You, manually (step 0) | The init step |
| Permissions | Write access: Contributor, Locks Contributor, RBAC Administrator (with condition), policy roles | Read only: **Monitoring Reader** on the pseudo root MG |
| Where it is used | Azure DevOps Service Connection | `bringYourOwnUserAssignedManagedIdentityResourceId` in `alzArm.param.json` |
| Cleanup | Keep outside the AMBA cleanup scope; do not tag `_deployed_by_amba` | Full cleanup can select marked UAMIs; the adapter blocks execution if the configured BYO identity is marked |

Keep them separate. The AMBA identity is attached to many alert rules in all subscriptions, so it must stay read-only. If it was the pipeline identity, every alert rule would run with rights to deploy resources and assign roles. The pipeline identity must also exist before init, and it must survive cleanup.

## Step 0: pipeline identity and Service Connection

This is the only manual step. The pipeline signs in to Azure as a **UAMI** with federation (Workload Identity Federation), with no secrets.
It is a different identity from the UAMI created by init (that one is used by the AMBA alerts). Create it outside the RG from `amba.yaml`.

### 0.1 Create the UAMI

```bash
az identity create -g <rg-platform> -n id-pipeline-amba-001 -l <region> --subscription <subscription>
az identity show   -g <rg-platform> -n id-pipeline-amba-001 --query "{principalId:principalId, clientId:clientId, tenantId:tenantId}" -o json
```

### 0.2 Grant permissions

Scope **MG** means the pseudo root MG (`enterpriseScaleCompanyPrefix`). Scope **Root MG** means the Tenant Root Group (its ID is the Tenant ID).

| Role | Scope | Purpose | Step |
| --- | --- | --- | --- |
| Contributor | Management subscription | RG, deployments, What-If | init |
| Locks Contributor | Management subscription | lock on the identity RG | init, cleanup |
| Role Based Access Control Administrator **with condition** | MG | assigning roles to AMBA identities | init, deploy, cleanup |
| Monitoring Policy Contributor | MG | AMBA policies | deploy, cleanup |
| Resource Policy Contributor | Root MG | AMBA policy definitions and assignments, remediation | deploy, remediate |

The condition on RBAC Administrator blocks assigning Owner, User Access Administrator and RBAC Administrator, so the pipeline cannot elevate itself.
The first three roles are enough for the init step alone.

```bash
PRINCIPAL_ID=<principalId from 0.1>
MG_ID=<pseudo root MG>
MG_SCOPE="/providers/Microsoft.Management/managementGroups/$MG_ID"
ROOT_MG_SCOPE="/providers/Microsoft.Management/managementGroups/<Tenant ID>"
SUB_SCOPE="/subscriptions/<managementSubscriptionId>"

az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope "$SUB_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Locks Contributor" --scope "$SUB_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Policy Contributor" --scope "$MG_SCOPE"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Resource Policy Contributor" --scope "$ROOT_MG_SCOPE"

# RBAC Administrator with condition (excludes Owner, User Access Administrator, RBAC Administrator)
CONDITION=$(cat <<'COND'
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168}))
COND
)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" --scope "$MG_SCOPE" \
  --condition "$CONDITION" --condition-version "2.0"
```

Someone with permission to assign roles at these scopes (e.g. Owner or User Access Administrator) must run these commands.

### 0.3 Service Connection in Azure DevOps

1. Project settings → Service connections → New service connection → **Azure Resource Manager**.
2. Choose **Workload Identity federation (manual)** with an existing identity.
3. Enter the Management subscription ID and name, the Tenant ID and **Service Principal Id = `clientId`** from 0.1.
4. The wizard shows an **Issuer** and a **Subject**. Add them as a federated credential:

```bash
az identity federated-credential create \
  --name ado-amba --identity-name id-pipeline-amba-001 --resource-group <rg-platform> \
  --issuer "<Issuer from the wizard>" --subject "<Subject from the wizard>" \
  --audiences api://AzureADTokenExchange
```

5. In the wizard choose **Verify and save**.
6. Put the Service Connection name and the agent pool name in `configuration/ado-env.yml`.

## Step 1: init

Init creates:

- the resource group from `configuration/amba.yaml`, with a `CanNotDelete` lock,
- the UAMI named in `alzArm.param.json`,
- the **Monitoring Reader** role for that UAMI on the pseudo root MG (log-search alerts use it to query Azure Resource Graph).

Init can be run repeatedly.

### In Azure DevOps

1. Pipelines → New pipeline → Azure Repos Git → Existing Azure Pipelines YAML file → `/.pipelines/amba_init.yml` (e.g. name it `AMBA-1-init`).
2. Run with `deployMode = whatif` (default). The preview is in the log and in the `WhatIfOutput.txt` attachment.
3. Run again with `deployMode = deploy`. The pipeline shows the preview first, then deploys. If the preview fails, the deployment does not start.

### Outside Azure DevOps

```bash
az login
./bin/amba_init.sh -deployMode lint     # validate the Bicep templates
./bin/amba_init.sh -deployMode whatif   # preview
./bin/amba_init.sh -deployMode deploy   # deploy
```

Use the `AMBA_PARAM_FILE` and `AMBA_CONFIG_FILE` variables to point to other parameter or config files.

### After init

The script prints the values to put in `configuration/alzArm.param.json`:

```bash
bringYourOwnUserAssignedManagedIdentity           = Yes
bringYourOwnUserAssignedManagedIdentityResourceId = /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>
```

If the file has different values, the script prints a warning.

## Step 2: deploy

| Deployment setting | Value |
| --- | --- |
| Template | Official remote `patterns/alz/alzArm.json` |
| Version | `deploy.releaseTag` in `configuration/amba.yaml`; use a fixed release/commit, not moving `main`, for reproducibility |
| Scope | Pseudo root MG |
| Parameters | `configuration/alzArm.param.json` |

Requirements:

- init has run and `alzArm.param.json` has `bringYourOwnUserAssignedManagedIdentity = Yes` and the Resource ID of the AMBA identity,
- `managementSubscriptionId` and the management group names are set in `alzArm.param.json`.

After the AMBA deployment the script gives the **Managed Identity Operator** role on the AMBA identity to the policy assignments `Deploy-AMBA-VM`, `Deploy-AMBA-HybridVM`, `Deploy-AMBA-VMSS`, `Deploy-AMBA-Management` and `Deploy-AMBA-Web` (list in `deploy.managedIdentityOperatorAssignments`).
AMBA does this only when it creates the identity itself, so with "bring your own" the pipeline has to do it.

Choose pipeline tags in `deploy.pipelineTags`. Changing tags such as `pipelineBuild` also changes policy parameters shown in What-If.

What-If shows the AMBA deployment. The operator role is previewed only when the policy assignments already exist (not on the first run).

### In Azure DevOps

Create the pipeline from `/.pipelines/amba_deploy.yml` (e.g. `AMBA-2-deploy`) and run it like init: first `whatif`, then `deploy`.

### Outside Azure DevOps

```bash
./bin/amba_deploy.sh -deployMode whatif
./bin/amba_deploy.sh -deployMode deploy
```

### Upgrading AMBA

Change `deploy.releaseTag` in `configuration/amba.yaml`, run `whatif` and review it, then run `deploy`. Releases: <https://github.com/Azure/azure-monitor-baseline-alerts/releases>

## Step 3: services (alerts for additional Azure services)

AMBA-ALZ covers a fixed set of services. The AMBA repository (folder `services`) has alert policies for many more, for example Application Gateway with WAF. The services step deploys them from the same release as `deploy`.

1. Open `configuration/services.yaml`. It lists all available services (copy `configuration/services.example.yaml` first if the file does not exist). Every service has `enabled: false`.
2. Set `enabled: true` for the services you want to monitor:

```yaml
services:
  - path: Network/applicationGateways
    enabled: true
```

3. Run `/.pipelines/amba_services.yml` (e.g. `AMBA-3-services`) with `whatif`, then `deploy`. Or from the command line: `./bin/amba_services.sh -deployMode whatif`.

The step uses official AMBA definitions. Automatic assignments, identities and RBAC are this repository's integration. Check scope and alert coverage against AMBA-ALZ before enabling a service.
Assignment display names use `AMBA-Services | <official display name>`; technical names and official definitions are unchanged.

| Service setting | Purpose |
| --- | --- |
| `path`, `enabled` | AMBA service folder and deployment selection |
| `include`, `exclude` | Alert names to select or skip; omitted/empty `include` selects all |
| `assignmentManagementGroupId` | Override the assignment MG |
| `parameters`, `overrides` | Policy parameters for the service or a named alert; overrides take precedence |

Examples and parameter details: [services.example.yaml](configuration/services.example.yaml). Default definition and assignment MGs are configured in `services` in [amba.yaml](configuration/amba.yaml).

The policies create alerts on existing resources only after remediation (step 4) and on new resources automatically.
The policy definitions request the **Contributor** role for the identity of each assignment; the script grants it at the assignment MG.

Assignment names are stable and limited to 24 characters; the readable display names come from AMBA.

### Maintaining services

| Task | Steps | Note |
| --- | --- | --- |
| Add a service | 1. Set `enabled: true` for it in `services.yaml`.<br>2. Run **services** (`whatif`, then `deploy`).<br>3. Run **remediate** (step 4) for existing resources. | All alerts of the service are added. |
| Add or skip a single alert | 1. Add the alert name to `include` or `exclude` of the service.<br>2. Run **services**.<br>3. Run **remediate** (step 4) when adding. | Alert name as on the service page, e.g. `AzwafSecRule`. |
| Change severity, window, threshold | 1. Change `parameters` (all alerts of the service) or `overrides` (one alert).<br>2. Run **services**.<br>3. Run **remediate** (step 4). | The assignment is updated, then the existing alert rules. |
| Move to a newer AMBA release | 1. Change `deploy.releaseTag`.<br>2. Run **deploy**, then **services**, then **remediate**. | Services use the same release tag as deploy. Check the list in `services.yaml` against the `services` folder of the release. |
| Stop deploying an alert or service | Set `enabled: false` or add an alert to `exclude`. | Nothing is deleted or disabled in Azure. Existing assignments remain active; removing them and their alert rules is a separate operation. |

Always run `whatif` first. Policy assignment names are in the `whatif` output.

## Step 4: remediate

Policies create alert rules on **new** resources automatically. For resources that **already exist**, and after changes of tags or parameters, run remediation.

1. Run `/.pipelines/amba_remediate.yml` (e.g. `AMBA-4-remediate`) with `whatif`: it lists the management groups and policy/initiative names to pass to the official script. Nothing is created; this is an execution plan, not an upstream WhatIf.
2. Run it with `deploy`. Or from the command line: `./bin/amba_remediate.sh -deployMode deploy`.

| Setting / behavior | Value |
| --- | --- |
| Execution | Official [Start-AMBA-ALZ-Remediation.ps1](bin/upstream/Start-AMBA-ALZ-Remediation.ps1); notification assets and health initiatives submitted first |
| Selection | `remediate.assignmentNamePattern` (default `^(Deploy-AMBA-\|amba-x-)`), `include`, `exclude`, additional `managementGroups` |
| Scope | Upstream selects by definition/initiative name; multiple assignments of it at that scope may be remediated |
| Completion | Tasks continue in Azure; check **Azure Policy > Remediation** |
| Compliance | No forced `ReEvaluateCompliance`; task behavior follows the official script |

Remediation and cleanup use local official scripts. Source, version requirements and update instructions: [bin/upstream](bin/upstream/README.md).

## Step 5: cleanup

Runs the unmodified official `patterns/alz/scripts/Start-AMBA-ALZ-Maintenance.ps1`. Resource selection and deletion order are owned by upstream. Do not mark the pipeline identity with `_deployed_by_amba`.

The `_deployed_by_amba` marker does not distinguish individual AMBA deployments or repositories. Resources from another deployment using the same marker may also be selected if they are visible to the cleanup identity. Before deleting, review the `whatif` list, especially when multiple AMBA deployments share the environment.

1. Run `/.pipelines/amba_cleanup.yml` (e.g. `AMBA-5-cleanup`) with `whatif` and the desired official `cleanItems` operation. This passes native `-WhatIf` to upstream.
2. Run it with `deploy` and the item you want to remove. Or from the command line: `./bin/amba_cleanup.sh -deployMode deploy -cleanItems Alerts`.

| `cleanItems` | Removes |
| --- | --- |
| `Alerts` | alert rules (metric, log-search, activity log) |
| `OrphanedAlerts` | only alert rules whose target resource no longer exists |
| `NotificationAssets` | alert processing rules and action groups |
| `PolicyAssignments` | assignments of the AMBA-ALZ initiatives and of services |
| `RoleAssignments` | role assignments of those assignments |
| `PolicyDefinitions` | initiatives and policy definitions |
| `Deployments` | `amba-*` ARM deployments at the pseudo root management group |
| `OldNotificationAssets` | legacy notification assets selected by upstream |
| `LegacySH` | legacy Service Health resources selected by upstream |
| `Amba-Alz` | full upstream cleanup, including marked UAMIs and resource groups |

| Safety check | Rule |
| --- | --- |
| Defaults | `Alerts`, `whatif`; review the preview before execution |
| Full cleanup | `Amba-Alz` can delete marked UAMIs and RGs; execution is blocked if the configured BYO identity has `_deployed_by_amba=True` |
| Locks / unmarked resources | May require separate handling |
| Verification | Repeat WhatIf after Resource Graph propagation |

The identity running cleanup needs more than the other steps: **Contributor** on the management groups or subscriptions that hold AMBA resources (to delete alert rules, action groups and resource groups). Contributor already includes read access, which the lookup needs. Remove it again after cleanup.

### Cleanup errors

Review task failures, permissions and locks before retrying. The Service Connection and pipeline definitions are outside the upstream cleanup.

## Managing monitoring with tags

The deployment contains no exceptions. You set exceptions with tags on resources:

- **Disable monitoring** for a resource or subscription: tag `MonitorDisable` with the value `true`, `Test`, `Dev` or `Sandbox`. Change the name and values in `alzArm.param.json` (`ALZMonitorDisableTagName`, `ALZMonitorDisableTagValues`).
- **Different alert threshold**: tag `_amba-<metricName>-threshold-Override_` with a numeric value, e.g. `_amba-CpuPercentage-threshold-Override_ = 95`. It applies to metric and log-search alerts. Log-search alerts pick up the new value immediately; metric alerts need a remediation.
- Full list: <https://azure.github.io/azure-monitor-baseline-alerts/patterns/alz/HowTo/Threshold-Override/>

### Changing the configuration later (tuning)

Changing a tag or parameter does not change alert rules that already exist. Alert rules are created by `DeployIfNotExists` policies, so the change reaches them only through the steps below.

| Scenario | Steps | Result |
| --- | --- | --- |
| Different threshold, **log-search** alert (tag override) | 1. Set the tag on the resource. | Applied immediately. The query reads the tag at run time. |
| Different threshold, **metric** alert (tag override) | 1. Set the tag on the resource.<br>2. Run **remediate** (step 4) for the policy of that service. | The existing alert rule is reconfigured. |
| Disable an alert everywhere (`<Type><Metric>AlertState = "false"`) | 1. Change the parameter in `alzArm.param.json`.<br>2. Run **deploy** (step 2).<br>3. Run **remediate** (step 4). | Alert rules stay, but are disabled. Set back to `"true"` and repeat to enable them. |
| Stop creating a given alert (`PolicyEffect = disabled`) | 1. Change the parameter in `alzArm.param.json`.<br>2. Run **deploy** (step 2). | No new alert rules. Existing ones stay. |
| Exclude a resource or subscription (`MonitorDisable` tag) | Set the tag; review and remove existing alert rules separately if needed. | The official cleanup has no `ExcludedAlerts` operation. Remediation does not delete existing alert rules. |
| Change a policy parameter of a pattern (e.g. severity, window, evaluation frequency, scope) | 1. Change `alzArm.param.json`.<br>2. Run **deploy** (step 2).<br>3. Run **remediate** (step 4). | Policies are updated, then existing alert rules. |
| Start over | 1. Preview **cleanup** (step 5), item `Alerts` or `Amba-Alz` (full upstream cleanup).<br>2. After approved cleanup, run **deploy** (step 2), then **remediate** (step 4). | Last resort. Review identity handling first. Alerts are recreated and history of the old rules is lost. |

Notifications are not part of this process. AMBA alert rules are deployed without notifications; Action Groups and Alert Processing Rules are created and changed separately in Azure.

Always run `whatif` before `deploy` and `cleanup`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `'yq' is required but was not found` | Install `yq` (mikefarah v4) on the agent. |
| `... is not set` | Fill in the missing parameter in `configuration/alzArm.param.json` or `configuration/amba.yaml`. |
| What-If fails with an authorization error | Check the roles from step 0.2 (e.g. Contributor on the Management subscription). |
| Error when creating the lock | The Locks Contributor role is missing on the Management subscription. |
| The identity RG cannot be deleted | It has a `CanNotDelete` lock. The cleanup step removes it, or remove it manually. |
| The UAMI's roles disappeared after recreating it | The new UAMI has a new `principalId`. Run init again to reassign the roles. |
| Pipeline stops at CheckVariables | `configuration/ado-env.yml` still contains `CHANGE-ME` values. |
