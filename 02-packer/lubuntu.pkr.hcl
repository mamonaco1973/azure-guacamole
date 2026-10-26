# ==============================================================================
# lubuntu.pkr.hcl -- Ubuntu 26.04 + Lubuntu core (LXQt) + XRDP + SSSD packages
# ==============================================================================
# Builds the managed image for the private desktop host that Guacamole reaches
# over RDP and SSH. The image holds the slow, generic part (desktop, XRDP,
# Firefox, the SSSD/realmd packages). The domain join happens at boot in
# custom data (03-servers/scripts/custom_data_lubuntu.sh): a computer account
# and keytab are per machine and must never be baked into a shared image.
#
# Packer creates its own temporary VNet and public IP for the build VM, so the
# build does not depend on the phase-1 network.
# ==============================================================================

# ------------------------------------------------------------------------------
# Packer Plugin Configuration
# - Loads the Azure plugin used for building managed images
# ------------------------------------------------------------------------------
packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

# ------------------------------------------------------------------------------
# Locals: Timestamp Utility
# - Generates compact timestamp for image naming
# ------------------------------------------------------------------------------
locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

# ------------------------------------------------------------------------------
# Required Variables: Azure Credentials and Settings
# - Passed securely via env vars or CLI
# ------------------------------------------------------------------------------
variable "client_id" {
  description = "Azure Client ID"
  type        = string
}

variable "client_secret" {
  description = "Azure Client Secret"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "resource_group" {
  description = "Resource group for the image"
  type        = string
}

variable "location" {
  description = "Azure region to build in"
  type        = string
  default     = "Central US"
}

variable "vm_size" {
  description = "Builder VM size"
  type        = string
  default     = "Standard_D4s_v3"
}

# ------------------------------------------------------------------------------
# Source Block: Azure Image Builder
# - Defines base Ubuntu image and build parameters
# ------------------------------------------------------------------------------
source "azure-arm" "lubuntu_image" {
  client_id       = var.client_id
  client_secret   = var.client_secret
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  image_publisher = "Canonical"
  image_offer     = "ubuntu-26_04-lts"
  image_sku       = "server"
  image_version   = "latest"

  location        = var.location
  vm_size         = var.vm_size
  os_type         = "Linux"
  ssh_username    = "ubuntu"

  managed_image_name = "lubuntu_image_${local.timestamp}"
  managed_image_resource_group_name = var.resource_group
  managed_image_storage_account_type = "Premium_LRS"
  os_disk_size_gb                    = 30
}

# ------------------------------------------------------------------------------
# Build Block: Provisioning Scripts
# - Executes each setup script inside the build VM
# ------------------------------------------------------------------------------
build {
  sources = ["source.azure-arm.lubuntu_image"]

  provisioner "shell" {
    script          = "./scripts/01-packages.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  provisioner "shell" {
    script          = "./scripts/02-desktop.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }

  provisioner "shell" {
    script          = "./scripts/03-xrdp.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
  }
}
