#!/bin/bash
# ==============================================================================
# check_env.sh - Environment validation
# ------------------------------------------------------------------------------
#   - Required CLI tools are on PATH (az, terraform, packer, jq, curl).
#   - ARM_* service principal variables are set (Terraform and Packer use them).
#   - Logs the Azure CLI in as that service principal.
# ==============================================================================

set -euo pipefail

echo "NOTE: Validating that required commands are found in your PATH."

# List of required commands
commands=("az" "terraform" "packer" "jq" "curl")

# Flag to track if all commands are found
all_found=true

# Iterate through each command and check if it's available
for cmd in "${commands[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd is not found in the current PATH."
    all_found=false
  else
    echo "NOTE: $cmd is found in the current PATH."
  fi
done

# Final status
if [ "$all_found" = true ]; then
  echo "NOTE: All required commands are available."
else
  echo "ERROR: One or more commands are missing."
  exit 1
fi

echo "NOTE: Validating that required environment variables are set."
# Array of required environment variables
required_vars=("ARM_CLIENT_ID" "ARM_CLIENT_SECRET" "ARM_SUBSCRIPTION_ID" "ARM_TENANT_ID")

# Flag to check if all variables are set
all_set=true

# Loop through the required variables and check if they are set
for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set or is empty."
    all_set=false
  else
    echo "NOTE: $var is set."
  fi
done

# Final status
if [ "$all_set" = true ]; then
  echo "NOTE: All required environment variables are set."
else
  echo "ERROR: One or more required environment variables are missing or empty."
  exit 1
fi

echo "NOTE: Logging in to Azure using Service Principal..."
if ! az login --service-principal --username "$ARM_CLIENT_ID" \
    --password "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" > /dev/null 2>&1; then
  echo "ERROR: Failed to log into Azure. Please check your credentials and environment variables."
  exit 1
else
  echo "NOTE: Successfully logged into Azure."
fi

