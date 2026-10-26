# ==============================================================================
# FILE: outputs.tf -- read by validate.sh
# ==============================================================================

output "guacamole_url" {
  value = "https://${azurerm_public_ip.app_gateway_pip.fqdn}/"
}

output "app_gateway_name" { value = azurerm_application_gateway.guacamole.name }
output "resource_group_name" { value = data.azurerm_resource_group.servers.name }
output "vault_name" { value = data.azurerm_key_vault.ad_key_vault.name }
output "guacamole_vm_name" { value = azurerm_linux_virtual_machine.guacamole.name }
output "lubuntu_vm_name" { value = azurerm_linux_virtual_machine.lubuntu_instance.name }
output "windows_vm_name" { value = azurerm_windows_virtual_machine.windows_ad_instance.name }
output "guacamole_private_ip" { value = azurerm_network_interface.guacamole_nic.private_ip_address }
output "lubuntu_private_ip" { value = azurerm_network_interface.lubuntu_nic.private_ip_address }
output "windows_private_ip" { value = azurerm_network_interface.windows_vm_nic.private_ip_address }
