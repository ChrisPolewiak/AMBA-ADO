#!/usr/bin/env bash
set -euo pipefail
# Requires an authenticated Azure PowerShell context; pipelines use AzurePowerShell@5.
exec pwsh -NoProfile -File "$(dirname "$0")/Invoke-AMBAOperation.ps1" -Operation cleanup "$@"
