#!/bin/bash
# ==============================================================================
# destroy.sh - Guacamole + Active Directory on Azure: teardown
# ------------------------------------------------------------------------------
#   1. 03-servers: App Gateway, Guacamole, Windows and Lubuntu VMs.
#   2. Every Lubuntu managed image in the project resource group.
#   3. 01-directory: mini-AD, Key Vault (purged), network, resource groups.
#
# Notes:
#   - Idempotent: each phase is skipped when there is nothing left to
#     destroy, so a re-run after a partial failure picks up where it stopped.
#   - Key Vault has purge protection off and the provider purges it (and the
#     App Gateway certificate) on destroy, so a rebuild can reuse the names.
#   - This permanently deletes everything the lab created.
# ==============================================================================

set -euo pipefail
cd "$(dirname "$0")"

NETWORK_RG="guacamole-network-rg"
PROJECT_RG="guacamole-project-rg"

./check_env.sh

# Resources a Terraform directory still tracks (0 when none or no state).
# A failed init (e.g. the provider registry unreachable) stops the script:
# counting it as 0 would skip a phase that still has resources.
tracked() {
  (cd "$1" && terraform init -input=false >/dev/null) ||
    { echo "ERROR: terraform init failed in $1; stopping rather than skipping it. Re-run ./destroy.sh." >&2; return 1; }
  (cd "$1" && terraform state list 2>/dev/null | wc -l)
}

# ------------------------------------------------------------------------------
# Phase 1: destroy the server layer
# ------------------------------------------------------------------------------
# Its data sources need the vault and image names, so look them up while
# they still exist.
# ------------------------------------------------------------------------------
# Assigned first: set -e ignores a failure inside "[ $(...) ]", but not here.
count=$(tracked 03-servers)
if [ "${count}" -gt 0 ]; then
  echo "NOTE: Destroying the App Gateway, Guacamole and servers..."
  lubuntu_image_name=$(az image list --resource-group "${PROJECT_RG}" \
    --query "[?starts_with(name, 'lubuntu_image')]|sort_by(@, &name)[-1].name" \
    --output tsv 2>/dev/null || true)
  vault=$(az keyvault list --resource-group "${NETWORK_RG}" \
    --query "[?starts_with(name, 'ad-key-vault')].name | [0]" \
    --output tsv 2>/dev/null || true)
  echo "NOTE: Using Key Vault: ${vault}, image: ${lubuntu_image_name}"

  cd 03-servers
  terraform destroy \
    -var="vault_name=${vault}" \
    -var="lubuntu_image_name=${lubuntu_image_name}" \
    -auto-approve
  cd ..
else
  echo "NOTE: 03-servers has nothing to destroy; skipping."
fi

# ------------------------------------------------------------------------------
# Phase 2: delete every Lubuntu image (Packer creates them outside Terraform)
# ------------------------------------------------------------------------------
if az group show --name "${PROJECT_RG}" >/dev/null 2>&1; then
  az image list --resource-group "${PROJECT_RG}" \
    --query "[?starts_with(name, 'lubuntu_image')].name" -o tsv |
  while read -r image; do
    echo "NOTE: Deleting image: ${image}"
    az image delete --name "${image}" --resource-group "${PROJECT_RG}"
  done
fi

# ------------------------------------------------------------------------------
# Phase 3: destroy the directory layer (mini-AD, Key Vault, network)
# ------------------------------------------------------------------------------
count=$(tracked 01-directory)
if [ "${count}" -gt 0 ]; then
  echo "NOTE: Destroying the mini-AD, Key Vault and network..."
  cd 01-directory
  terraform destroy -auto-approve
  cd ..
else
  echo "NOTE: 01-directory has nothing to destroy; skipping."
fi

echo "NOTE: Guacamole lab resources have been destroyed."
