# ==============================================================================
# FILE: lubuntu.tf
# ------------------------------------------------------------------------------
# The Lubuntu desktop host: Ubuntu 26.04 with LXQt and XRDP, from the image
# 02-packer builds. Private (no public IP), joined to the mini-AD with SSSD at
# boot (scripts/custom_data_lubuntu.sh). Users reach it through Guacamole over
# RDP (a desktop) or SSH. Admin access is `az vm run-command`.
# ==============================================================================

# ------------------------------------------------------------------------------
# Generate a secure random password for the local 'ubuntu' account
# ------------------------------------------------------------------------------
resource "random_password" "ubuntu_password" {
  length           = 24
  special          = true
  override_special = "!@#$%"
}

# ------------------------------------------------------------------------------
# Store 'ubuntu' credentials in Azure Key Vault as a JSON object
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "ubuntu_secret" {
  name         = "ubuntu-credentials"
  value        = jsonencode({
                  username = "ubuntu"
                  password = random_password.ubuntu_password.result
                })
  key_vault_id = data.azurerm_key_vault.ad_key_vault.id
  content_type = "application/json"
}

# ------------------------------------------------------------------------------
# Private NIC for the Lubuntu VM (no public IP)
# ------------------------------------------------------------------------------
resource "azurerm_network_interface" "lubuntu_nic" {
  name                = "lubuntu-nic"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.vm_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# The VM-subnet NSG admits SSH and RDP to this group from Guacamole only.
resource "azurerm_network_interface_application_security_group_association" "lubuntu_asg" {
  network_interface_id          = azurerm_network_interface.lubuntu_nic.id
  application_security_group_id = data.azurerm_application_security_group.lubuntu_asg.id
}

# ------------------------------------------------------------------------------
# Provision the Lubuntu Linux virtual machine
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "lubuntu_instance" {
  # Also the hostname, and so the AD computer object name on join (<= 15 chars).
  name                = "lubuntu-${random_string.vm_suffix.result}"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name
  size                = "Standard_D2s_v3" # a desktop session per user
  admin_username      = "ubuntu"
  admin_password      = random_password.ubuntu_password.result
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.lubuntu_nic.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_id = data.azurerm_image.lubuntu_image.id

  boot_diagnostics {
    storage_account_uri = null
  }

  # Changing custom_data replaces the VM on azurerm, so a new script never runs
  # against a host that already joined with the old one.
  custom_data = base64encode(templatefile(
    "./scripts/custom_data_lubuntu.sh",
    {
      vault_name  = data.azurerm_key_vault.ad_key_vault.name
      domain_fqdn = var.dns_zone
    }
  ))

  identity {
    type = "SystemAssigned"
  }
}

# ------------------------------------------------------------------------------
# Grant the VM identity permission to read Key Vault secrets (the domain join
# credential). The boot script retries until this assignment has propagated.
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "vm_lnx_key_vault_secrets_user" {
  scope                = data.azurerm_key_vault.ad_key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.lubuntu_instance.identity[0].principal_id
}
