#!/usr/bin/env bash
# Author: Chris Polewiak
# Date: 2026-10-12
# Description: Helper functions for Azure deployments in Azure DevOps Pipelines (and locally).
#
# helper: _az_deployment <scope> <deploymentName> <templateFile> [az arguments...]
#   scope            sub | mg | group
#   deploymentName   name of the ARM deployment
#   templateFile     full path to the Bicep template, or an https:// URL of a template (passed as --template-uri;
#                    needed for templates that reference linked templates relative to their own URI, e.g. AMBA)
#   az arguments     scope specific flags and parameters, e.g.
#                      --location <loc> --parameters "key=value" ...                  (sub)
#                      --management-group-id <id> --location <loc> --parameters ...   (mg)
#                      --resource-group <rg> --parameters ...                         (group)
# expects the caller to set:
#   deployMode       "whatif", "lint" or "deploy" (set by _common_args.sh)
#
# Behaviour depends on deployMode:
#   whatif  runs 'az deployment <scope> what-if', writes the result to whatif_outputs/ and to the log
#   lint    runs 'az bicep lint', writes the result to lint_outputs/ and to the log
#   deploy  runs 'az deployment <scope> create'
# Returns the exit code of the az command (non-zero when the what-if/lint/deployment failed).
_az_deployment() {
  local scope="$1" deploymentName="$2" templateFile="$3"
  shift 3

  case "$scope" in
    sub|mg|group) ;;
    *) echo "! Unknown scope: ${scope}. Expected one of: sub, mg, group" >&2; return 2 ;;
  esac

  local templateArgs
  if [[ "$templateFile" == https://* ]]; then
    templateArgs=(--template-uri "$templateFile")
  else
    if [[ ! -f "$templateFile" ]]; then
      echo "! Template not found: $templateFile" >&2
      return 3
    fi
    templateArgs=(--template-file "$templateFile")
  fi

  local outDir outFile rc=0
  case "${deployMode}" in
    whatif)
      outDir="${WHATIF_OUTPUT_DIR:-$(pwd)/whatif_outputs}"
      mkdir -p "$outDir"
      outFile="$outDir/WhatIfOutput-${scope}-$(basename "$templateFile" | sed -E 's/\.(bicep|json)$//').txt"

      echo "What-If: ${deploymentName} (${scope}) ${templateFile}"
      az deployment "$scope" what-if \
        --name "$deploymentName" \
        "${templateArgs[@]}" \
        "$@" > "$outFile" 2>&1 || rc=$?
      cat "$outFile"
      echo "  What-If output saved to: $outFile"
      ;;

    lint)
      outDir="${LINT_OUTPUT_DIR:-$(pwd)/lint_outputs}"
      mkdir -p "$outDir"
      outFile="$outDir/LintOutput-${scope}-$(basename "$templateFile" | sed -E 's/\.(bicep|json)$//').txt"

      if [[ "$templateFile" == https://* ]]; then
        echo "Lint: skipped for remote template ${templateFile}"
        return 0
      fi
      echo "Lint: ${templateFile}"
      az bicep lint --file "$templateFile" > "$outFile" 2>&1 || rc=$?
      cat "$outFile"
      echo "  Lint output saved to: $outFile"
      ;;

    deploy)
      echo "Deploying: ${deploymentName} (${scope}) ${templateFile}"
      az deployment "$scope" create \
        --name "$deploymentName" \
        "${templateArgs[@]}" \
        --only-show-errors \
        "$@" || rc=$?
      ;;

    *)
      echo "! Unknown deployMode: ${deployMode}. Expected one of: whatif, lint, deploy" >&2
      rc=2
      ;;
  esac

  return $rc
}
