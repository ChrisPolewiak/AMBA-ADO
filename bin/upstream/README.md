# Official AMBA scripts

| Source | Value |
|---|---|
| Repository | [Azure/azure-monitor-baseline-alerts](https://github.com/Azure/azure-monitor-baseline-alerts) |
| Directory | `patterns/alz/scripts` |
| Reference | `main`, snapshot retrieved 2026-10-23 |
| Commit | [ec5e5f3acfcdc52773110517b1f51bd06cf766de](https://github.com/Azure/azure-monitor-baseline-alerts/tree/ec5e5f3acfcdc52773110517b1f51bd06cf766de/patterns/alz/scripts) |
| License | [MIT](./LICENSE); scripts and original notices are unmodified |

- [Start-AMBA-ALZ-Remediation.ps1](./Start-AMBA-ALZ-Remediation.ps1): official policy remediation.
- [Start-AMBA-ALZ-Maintenance.ps1](./Start-AMBA-ALZ-Maintenance.ps1): official cleanup, including native `-WhatIf`.
- [LICENSE](./LICENSE): upstream MIT license. Original script notices are retained.
- [source.json](./source.json): source reference and exact commit.

Pipelines execute local copies without downloading scripts.
[Invoke-AMBAOperation.ps1](../Invoke-AMBAOperation.ps1) passes configuration and guards BYO cleanup.

## Updating

1. Select the AMBA version used by `deploy.releaseTag`.
2. Replace both scripts and the license with untouched files from that exact upstream commit.
3. Update `source.json` and this document, review upstream changes and test the adapter.
4. Preview before executing remediation or cleanup.

| Version rule | Requirement |
|---|---|
| `deploy.releaseTag` | Must match the reference or commit in `source.json` |
| Deployment repository | Must match the recorded official source |
| Reproducibility | Pin deploy to the recorded commit; `main` is moving while these scripts are a fixed snapshot |
