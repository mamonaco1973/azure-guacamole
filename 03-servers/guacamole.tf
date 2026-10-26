# ==============================================================================
# FILE: guacamole.tf
# ------------------------------------------------------------------------------
# The Apache Guacamole server: private, behind the App Gateway (appgateway.tf).
# It signs users in against the mini-AD and opens RDP to the Windows host, and
# RDP (XRDP) and SSH to the Lubuntu host, on their behalf. Setup is in
# scripts/custom_data_guacamole.sh.
# ==============================================================================

locals {
  # The DC's fully-qualified name: Guacamole's LDAPS target and the source of
  # the CA it trusts (http://<dc>/ca.pem). It must be this name, not an IP:
  # it is the name in the DC's certificate. Resolvable because the mini-AD
  # module points the VNet's DNS at the DC.
  dc_fqdn = "ad1.${var.dns_zone}"
}

# ------------------------------------------------------------------------------
# Private NIC (no public IP); the App Gateway reaches it on 8080
# ------------------------------------------------------------------------------
resource "azurerm_network_interface" "guacamole_nic" {
  name                = "guacamole-nic"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.vm_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# The VM-subnet NSG admits 8080 to this group from the App Gateway subnet, and
# lets this group (only) reach the Windows and Lubuntu hosts.
resource "azurerm_network_interface_application_security_group_association" "guacamole_asg" {
  network_interface_id          = azurerm_network_interface.guacamole_nic.id
  application_security_group_id = data.azurerm_application_security_group.guacamole_asg.id
}

# ------------------------------------------------------------------------------
# Local 'ubuntu' admin password (break-glass only; az vm run-command is the
# usual way in). Stored in Key Vault next to the others.
# ------------------------------------------------------------------------------
resource "random_password" "guacamole_password" {
  length           = 24
  special          = true
  override_special = "!@#$%"
}

resource "azurerm_key_vault_secret" "guacamole_secret" {
  name         = "guacamole-credentials"
  value        = jsonencode({
                  username = "ubuntu"
                  password = random_password.guacamole_password.result
                })
  key_vault_id = data.azurerm_key_vault.ad_key_vault.id
  content_type = "application/json"
}

# ------------------------------------------------------------------------------
# The Guacamole VM: Canonical Ubuntu 24.04 (not the Packer image), Docker
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "guacamole" {
  name                            = "guacamole"
  location                        = data.azurerm_resource_group.servers.location
  resource_group_name             = data.azurerm_resource_group.servers.name
  size                            = "Standard_B2ms" # guacd + Tomcat + PostgreSQL
  admin_username                  = "ubuntu"
  admin_password                  = random_password.guacamole_password.result
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.guacamole_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30 # three container images plus PostgreSQL
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = null
  }

  # Changing custom_data replaces the VM on azurerm, so the server is rebuilt
  # instead of left running with stale configuration.
  custom_data = base64encode(templatefile("./scripts/custom_data_guacamole.sh", {
    vault_name   = data.azurerm_key_vault.ad_key_vault.name
    guac_version = "1.6.0"
    dc_fqdn      = local.dc_fqdn
    base_dn      = local.base_dn
    netbios      = var.netbios
    windows_ip   = azurerm_network_interface.windows_vm_nic.private_ip_address
    lubuntu_ip   = azurerm_network_interface.lubuntu_nic.private_ip_address
  }))

  identity {
    type = "SystemAssigned"
  }
}

# ------------------------------------------------------------------------------
# Read access to Key Vault (the LDAP bind credential). The setup script
# retries until this assignment has propagated.
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "guacamole_key_vault_secrets_user" {
  scope                = data.azurerm_key_vault.ad_key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.guacamole.identity[0].principal_id
}
