#!/bin/bash
# ==============================================================================
# apply.sh - Guacamole + Active Directory on Azure: build
# ------------------------------------------------------------------------------
# Three phases:
#   1. 01-directory: VNet, NSGs, NAT gateway, Key Vault, mini-AD (Samba DC).
#   2. 02-packer:    the Lubuntu + XRDP managed image.
#   3. 03-servers:   the App Gateway, Guacamole, and the Windows and Lubuntu
#                    servers.
# Then validate.sh checks the result.
#
# Notes:
#   - Each run builds a fresh image; phase 3 uses the newest one, and
#     destroy.sh deletes them all.
#   - The Key Vault name (random suffix) is discovered after phase 1.
#   - Phase 3 retries (up to 3 attempts) if Azure fails the App Gateway.
# ==============================================================================

set -euo pipefail
cd "$(dirname "$0")"

NETWORK_RG="guacamole-network-rg"
PROJECT_RG="guacamole-project-rg"
APP_GATEWAY="guacamole-app-gateway"

# ------------------------------------------------------------------------------
# Pre-flight check: tools, ARM_* variables, Azure login
# ------------------------------------------------------------------------------
./check_env.sh

# ------------------------------------------------------------------------------
# Phase 1: directory layer (network, Key Vault, mini-AD)
# ------------------------------------------------------------------------------
echo "NOTE: Building the network, Key Vault and mini-AD..."
cd 01-directory
terraform init
terraform apply -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Phase 2: Lubuntu image (Packer builds in its own temporary VNet)
# ------------------------------------------------------------------------------
echo "NOTE: Building the Lubuntu + XRDP image with Packer..."
cd 02-packer
packer init .
packer build \
  -var="client_id=$ARM_CLIENT_ID" \
  -var="client_secret=$ARM_CLIENT_SECRET" \
  -var="subscription_id=$ARM_SUBSCRIPTION_ID" \
  -var="tenant_id=$ARM_TENANT_ID" \
  -var="resource_group=${PROJECT_RG}" \
  lubuntu.pkr.hcl
cd ..

# ------------------------------------------------------------------------------
# Phase 3: App Gateway, Guacamole and the servers
# ------------------------------------------------------------------------------
lubuntu_image_name=$(az image list \
  --resource-group "${PROJECT_RG}" \
  --query "[?starts_with(name, 'lubuntu_image')]|sort_by(@, &name)[-1].name" \
  --output tsv)
if [ -z "${lubuntu_image_name}" ]; then
  echo "ERROR: No Lubuntu image found in ${PROJECT_RG}."
  exit 1
fi
echo "NOTE: Using latest Lubuntu image: ${lubuntu_image_name}"

vault=$(az keyvault list \
  --resource-group "${NETWORK_RG}" \
  --query "[?starts_with(name, 'ad-key-vault')].name | [0]" \
  --output tsv)
echo "NOTE: Using Key Vault: ${vault}"

# Azure occasionally fails an App Gateway create with a bare
# InternalServerError after several minutes, leaving a "Failed" gateway that
# Terraform doesn't track (a rerun then stops at "already exists"). When that
# is why phase 3 failed, delete the gateway and try again; any other failure
# stops the build as usual.
echo "NOTE: Building the App Gateway, Guacamole and servers..."
cd 03-servers
terraform init
for attempt in 1 2 3; do
  if terraform apply \
    -var="vault_name=${vault}" \
    -var="lubuntu_image_name=${lubuntu_image_name}" \
    -auto-approve; then
    break
  fi

  gateway_state=$(az network application-gateway show \
    --resource-group "${PROJECT_RG}" --name "${APP_GATEWAY}" \
    --query provisioningState --output tsv 2>/dev/null || true)
  if [ "${gateway_state}" != "Failed" ] || [ "${attempt}" -eq 3 ]; then
    echo "ERROR: Phase 3 failed (attempt ${attempt}, App Gateway: ${gateway_state:-not created})."
    exit 1
  fi

  echo "WARNING: Azure failed the App Gateway (attempt ${attempt}); deleting it and retrying..."
  az network application-gateway delete \
    --resource-group "${PROJECT_RG}" --name "${APP_GATEWAY}"
done
cd ..

# ------------------------------------------------------------------------------
# Build validation
# ------------------------------------------------------------------------------
echo "NOTE: Running build validation..."
./validate.sh

echo "NOTE: Infrastructure build complete."
