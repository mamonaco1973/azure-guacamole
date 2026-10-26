# ==================================================================================================
# Virtual Network, Subnets, Network Security Groups and NAT Gateway
# - VNet with three subnets: servers (Guacamole, Windows, Lubuntu), mini-AD,
#   and a dedicated subnet for the Application Gateway
# - NSGs mirror the AWS security groups:
#     internet ─443/80─▶ App Gateway ─8080─▶ Guacamole ─3389─────▶ Windows
#                                                      └─22, 3389─▶ Lubuntu
# - NAT gateway gives the private VMs outbound internet; no VM has a public IP
# ==================================================================================================

# --------------------------------------------------------------------------------------------------
# Define the Virtual Network
# --------------------------------------------------------------------------------------------------
resource "azurerm_virtual_network" "ad_vnet" {
  name                = "ad-vnet"
  address_space       = ["10.0.0.0/23"]                     # Overall VNet range
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
}

# --------------------------------------------------------------------------------------------------
# Define VM Subnet (10.0.0.0/25)
# --------------------------------------------------------------------------------------------------
resource "azurerm_subnet" "vm_subnet" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.ad.name
  virtual_network_name = azurerm_virtual_network.ad_vnet.name
  address_prefixes     = ["10.0.0.0/25"]
  default_outbound_access_enabled = false
}

# --------------------------------------------------------------------------------------------------
# Define Mini-AD Subnet (10.0.0.128/25)
# --------------------------------------------------------------------------------------------------
resource "azurerm_subnet" "mini_ad_subnet" {
  name                 = "mini-ad-subnet"
  resource_group_name  = azurerm_resource_group.ad.name
  virtual_network_name = azurerm_virtual_network.ad_vnet.name
  address_prefixes     = ["10.0.0.128/25"]
  default_outbound_access_enabled = false
}

# --------------------------------------------------------------------------------------------------
# Define App Gateway Subnet (10.0.1.0/24)
# Application Gateway v2 needs a subnet of its own: nothing else may be placed in it.
# --------------------------------------------------------------------------------------------------
resource "azurerm_subnet" "app_gateway_subnet" {
  name                 = "app-gateway-subnet"
  resource_group_name  = azurerm_resource_group.ad.name
  virtual_network_name = azurerm_virtual_network.ad_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# --------------------------------------------------------------------------------------------------
# Application Security Groups: one per server role, so the VM-subnet rules read
# "Guacamole -> Windows" instead of IP addresses. The NICs join them in 03-servers.
# --------------------------------------------------------------------------------------------------
resource "azurerm_application_security_group" "guacamole_asg" {
  name                = "guacamole-asg"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
}

resource "azurerm_application_security_group" "windows_asg" {
  name                = "windows-asg"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
}

resource "azurerm_application_security_group" "lubuntu_asg" {
  name                = "lubuntu-asg"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
}

# --------------------------------------------------------------------------------------------------
# NSG for the VM subnet
# Azure's default rules allow everything inside the VNet, so an explicit deny at
# the end makes the allow rules above it the only way in, as AWS security groups do.
# --------------------------------------------------------------------------------------------------
resource "azurerm_network_security_group" "vm_nsg" {
  name                = "vm-nsg"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name

  # App Gateway -> Guacamole web app (Tomcat)
  security_rule {
    name                                       = "AppGateway-to-Guacamole"
    priority                                   = 1001
    direction                                  = "Inbound"
    access                                     = "Allow"
    protocol                                   = "Tcp"
    source_port_range                          = "*"
    destination_port_range                     = "8080"
    source_address_prefix                      = azurerm_subnet.app_gateway_subnet.address_prefixes[0]
    destination_application_security_group_ids = [azurerm_application_security_group.guacamole_asg.id]
  }

  # Guacamole -> Windows RDP
  security_rule {
    name                                       = "Guacamole-to-Windows-RDP"
    priority                                   = 1002
    direction                                  = "Inbound"
    access                                     = "Allow"
    protocol                                   = "Tcp"
    source_port_range                          = "*"
    destination_port_range                     = "3389"
    source_application_security_group_ids      = [azurerm_application_security_group.guacamole_asg.id]
    destination_application_security_group_ids = [azurerm_application_security_group.windows_asg.id]
  }

  # Guacamole -> Lubuntu SSH and XRDP
  security_rule {
    name                                       = "Guacamole-to-Lubuntu"
    priority                                   = 1003
    direction                                  = "Inbound"
    access                                     = "Allow"
    protocol                                   = "Tcp"
    source_port_range                          = "*"
    destination_port_ranges                    = ["22", "3389"]
    source_application_security_group_ids      = [azurerm_application_security_group.guacamole_asg.id]
    destination_application_security_group_ids = [azurerm_application_security_group.lubuntu_asg.id]
  }

  # Everything else from inside the VNet (overrides the default AllowVnetInBound).
  # Replies to the servers' own outbound traffic (AD, NAT) are stateful and unaffected.
  security_rule {
    name                       = "Deny-VNet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# --------------------------------------------------------------------------------------------------
# Associate NSG with VM subnet
# --------------------------------------------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "vm_nsg_assoc" {
  subnet_id                 = azurerm_subnet.vm_subnet.id
  network_security_group_id = azurerm_network_security_group.vm_nsg.id
}

# --------------------------------------------------------------------------------------------------
# NSG for the App Gateway subnet
# The v2 SKU refuses to deploy unless GatewayManager can reach 65200-65535
# (its control plane) and the AzureLoadBalancer probe is allowed.
# --------------------------------------------------------------------------------------------------
resource "azurerm_network_security_group" "app_gateway_nsg" {
  name                = "app-gateway-nsg"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name

  # Users -> HTTPS (and HTTP, which redirects to HTTPS)
  security_rule {
    name                       = "Allow-Web"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefixes    = var.allowed_cidrs
    destination_address_prefix = "*"
  }

  # Azure infrastructure -> App Gateway v2 control plane (required)
  security_rule {
    name                       = "Allow-GatewayManager"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  # Azure load balancer health probe (required)
  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

# --------------------------------------------------------------------------------------------------
# Associate NSG with App Gateway subnet
# --------------------------------------------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "app_gateway_nsg_assoc" {
  subnet_id                 = azurerm_subnet.app_gateway_subnet.id
  network_security_group_id = azurerm_network_security_group.app_gateway_nsg.id
}

# --------------------------------------------------------------------------------------------------
# NAT Gateway: Public IP, Gateway, and Associations
# --------------------------------------------------------------------------------------------------

# Public IP for NAT Gateway
resource "azurerm_public_ip" "nat_gateway_pip" {
  name                = "nat-gateway-pip"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NAT Gateway Resource
resource "azurerm_nat_gateway" "vm_nat_gateway" {
  name                = "vm-nat-gateway"
  location            = azurerm_resource_group.ad.location
  resource_group_name = azurerm_resource_group.ad.name
  sku_name            = "Standard"
  idle_timeout_in_minutes = 10
}

# Associate Public IP with NAT Gateway
resource "azurerm_nat_gateway_public_ip_association" "nat_gw_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.vm_nat_gateway.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_pip.id
}

# Associate NAT Gateway with VM Subnet
resource "azurerm_subnet_nat_gateway_association" "vm_nat_assoc" {
  subnet_id      = azurerm_subnet.vm_subnet.id
  nat_gateway_id = azurerm_nat_gateway.vm_nat_gateway.id
}

# Associate NAT Gateway with Mini-AD Subnet
resource "azurerm_subnet_nat_gateway_association" "mini_ad_nat_assoc" {
  subnet_id      = azurerm_subnet.mini_ad_subnet.id
  nat_gateway_id = azurerm_nat_gateway.vm_nat_gateway.id
}
