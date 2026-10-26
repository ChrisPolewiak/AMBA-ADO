#!/usr/bin/env bash
# Author: Chris Polewiak
# Date: 2026-10-12
# Description: Common argument parsing, configuration helpers and pipeline tags for AMBA bin scripts.
# This file is intended to be sourced by scripts in bin/ (same pattern as the ALZ repository).
set -euo pipefail

# Repository root = parent folder of bin/ (scripts can be started from any directory)
repoRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parse arguments: -deployMode [whatif|lint|deploy]  (and -cleanItems <items>, used by amba_cleanup.sh only)
DEPLOY_MODE=""
CLEAN_ITEMS=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -deployMode) DEPLOY_MODE="${2:-}"; shift ;;
    -cleanItems) CLEAN_ITEMS="${2:-}"; shift ;;
    *) echo "Error: unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done

# Normalize deployMode to lower-case and default to 'whatif' when unset (safe default)
deployMode="$(echo "${DEPLOY_MODE:-whatif}" | tr '[:upper:]' '[:lower:]')"
case "$deployMode" in
  whatif|lint|deploy) ;;
  *) echo "Error: unknown deployMode '$deployMode'. Expected one of: whatif, lint, deploy" >&2; exit 1 ;;
esac

# Required tools
for tool in az jq yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' is required but was not found in PATH." >&2
    exit 1
  fi
done

# Input files (can be overridden with environment variables when running outside Azure DevOps)
#  - AMBA parameter file: the same file that is passed to the AMBA deployment (single source of truth)
#  - AMBA config file:    settings used only by the pipelines/scripts of this repository
ambaParamFile="${AMBA_PARAM_FILE:-$repoRoot/configuration/alzArm.param.json}"
ambaConfigFile="${AMBA_CONFIG_FILE:-$repoRoot/configuration/amba.yaml}"
for f in "$ambaParamFile" "$ambaConfigFile"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: required file not found: $f" >&2
    exit 1
  fi
done

# The config file is YAML (comments allowed); it is converted to JSON once so that jq filters can be used.
# Supports mikefarah/yq v4 (preinstalled on Microsoft-hosted Ubuntu agents).
if ! ambaConfigJson="$(yq -o=json '.' "$ambaConfigFile")"; then
  echo "Error: cannot parse $ambaConfigFile as YAML" >&2
  exit 1
fi

# Read a value from the AMBA parameter file (parameters.<name>.value); empty when not set
_param() { jq -r --arg k "$1" '.parameters[$k].value // empty' "$ambaParamFile"; }

# Read a value from the config file using a jq filter; empty when not set
_config() { jq -r "$1 // empty" <<< "$ambaConfigJson"; }

# Read a JSON fragment (compact) from the config file using a jq filter
_configJson() { jq -c "$1" <<< "$ambaConfigJson"; }

# Stop with a clear message when a required value is empty
_require() {
  if [[ -z "$2" ]]; then
    echo "Error: $1 is not set." >&2
    exit 1
  fi
}

# Print a warning (shown as a warning in the Azure DevOps run summary as well)
_warn() {
  echo "WARNING: $*" >&2
  if [[ -n "${TF_BUILD:-}" ]]; then
    echo "##vso[task.logissue type=warning]$*"
  fi
  return 0
}

# Optional pipeline tags for resource tagging (filled by the pipeline environment variables)
pipelineTags="{}"
pipelineName="${PIPELINE_NAME:-}"
if [[ -n "$pipelineName" ]]; then
  pipelineTags=$(echo "$pipelineTags" | jq -c --arg pt "$pipelineName" '. + { "pipelineName": $pt }')
fi
pipelineId="${PIPELINE_ID:-}"
if [[ -n "$pipelineId" ]]; then
  pipelineTags=$(echo "$pipelineTags" | jq -c --arg pt "$pipelineId" '. + { "pipelineId": $pt }')
fi
pipelineBuild="${PIPELINE_BUILDNUMBER:-}"
if [[ -n "$pipelineBuild" ]]; then
  pipelineTags=$(echo "$pipelineTags" | jq -c --arg pt "$pipelineBuild" '. + { "pipelineBuild": $pt }')
fi

export repoRoot deployMode ambaParamFile ambaConfigFile pipelineTags
