# ==============================================================================
# FILE: appgateway.tf
# ------------------------------------------------------------------------------
# The one internet-facing piece: an Application Gateway (Standard_v2) in its
# own subnet, terminating HTTPS with a self-signed certificate and forwarding
# to Guacamole on :8080. HTTP redirects to HTTPS.
#
# Notes:
#   - The certificate is self-signed (issued by Key Vault itself), so browsers
#     warn on first visit. Use a CA-issued certificate and a DNS name for
#     anything beyond a demo.
#   - Guacamole's remote-desktop traffic is one long-lived WebSocket per
#     session. The v2 SKU carries WebSockets with no extra setting, but applies
#     the backend request timeout to them as an idle timeout, and the public
#     IP has a TCP idle timeout: both are raised below so sessions aren't cut.
#   - Unlike an ALB, App Gateway v2 bills a fixed hourly charge while it
#     exists, busy or idle. Destroy the lab when you are done.
# ==============================================================================

# ------------------------------------------------------------------------------
# Random DNS suffix: guacamole-<suffix>.<region>.cloudapp.azure.com
# ------------------------------------------------------------------------------
resource "random_string" "gateway_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# Public IP (Static Standard SKU, required by v2)
# ------------------------------------------------------------------------------
resource "azurerm_public_ip" "app_gateway_pip" {
  name                = "guacamole-app-gateway-pip"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "guacamole-${random_string.gateway_suffix.result}"

  # Front-end TCP idle timeout (default 4 minutes, max 30). A desktop left
  # idle with no screen updates must not lose its tunnel.
  idle_timeout_in_minutes = 30
}

# ------------------------------------------------------------------------------
# Self-signed certificate, generated and held by the phase-1 Key Vault
# (Terraform's identity has Key Vault Certificates Officer there)
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_certificate" "guacamole" {
  name         = "guacamole-app-gateway-cert"
  key_vault_id = data.azurerm_key_vault.ad_key_vault.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true # App Gateway reads the PFX (key included) as a secret
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${azurerm_public_ip.app_gateway_pip.fqdn}"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"] # server authentication

      subject_alternative_names {
        dns_names = [azurerm_public_ip.app_gateway_pip.fqdn]
      }
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Identity the gateway uses to read the certificate from Key Vault
# ------------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "app_gateway" {
  name                = "guacamole-app-gateway-identity"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name
}

resource "azurerm_role_assignment" "app_gateway_key_vault_secrets_user" {
  scope                = data.azurerm_key_vault.ad_key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app_gateway.principal_id
}

# The gateway fetches the certificate as soon as it is created and fails the
# deployment if access is denied, so give the new role assignment time to
# propagate first.
resource "time_sleep" "app_gateway_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.app_gateway_key_vault_secrets_user]
  create_duration = "90s"
}

# ------------------------------------------------------------------------------
# Application Gateway
# ------------------------------------------------------------------------------
locals {
  frontend_name     = "app-gateway-frontend"
  backend_pool_name = "guacamole-backend-pool"
  backend_settings  = "guacamole-http-settings"
  https_listener    = "https-listener"
  http_listener     = "http-listener"
  ssl_cert_name     = "guacamole-self-signed"
}

resource "azurerm_application_gateway" "guacamole" {
  name                = "guacamole-app-gateway"
  location            = data.azurerm_resource_group.servers.location
  resource_group_name = data.azurerm_resource_group.servers.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1 # one instance is plenty for a lab
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app_gateway.id]
  }

  gateway_ip_configuration {
    name      = "app-gateway-ip-config"
    subnet_id = data.azurerm_subnet.app_gateway_subnet.id
  }

  frontend_ip_configuration {
    name                 = local.frontend_name
    public_ip_address_id = azurerm_public_ip.app_gateway_pip.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # Older predefined TLS policies are deprecated; pin a current one.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  ssl_certificate {
    name                = local.ssl_cert_name
    key_vault_secret_id = azurerm_key_vault_certificate.guacamole.versionless_secret_id
  }

  # --------------------------------------------------------------------------
  # Backend: the Guacamole VM's private IP, Tomcat on 8080
  # --------------------------------------------------------------------------
  backend_address_pool {
    name         = local.backend_pool_name
    ip_addresses = [azurerm_network_interface.guacamole_nic.private_ip_address]
  }

  backend_http_settings {
    name     = local.backend_settings
    port     = 8080
    protocol = "Http"
    path     = "/"

    # One backend, but keep a user's tunnel on it if more are ever added.
    cookie_based_affinity = "Enabled"

    # v2 applies this to WebSocket sessions too, as an idle timer rather than
    # a cap on session length: a Guacamole session (keep-alives every few
    # seconds) outlived a 60-second setting by minutes. The generous value
    # also covers the HTTP-tunnel fallback, whose long-poll reads stay open.
    request_timeout = 3600

    probe_name = "guacamole-probe"
  }

  # Guacamole's ROOT context (WEBAPP_CONTEXT: ROOT) answers 200 at "/".
  probe {
    name                = "guacamole-probe"
    protocol            = "Http"
    host                = "127.0.0.1"
    path                = "/"
    port                = 8080
    interval            = 15
    timeout             = 10
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  # --------------------------------------------------------------------------
  # Listeners: HTTPS forwards to Guacamole; HTTP redirects to HTTPS
  # --------------------------------------------------------------------------
  http_listener {
    name                           = local.https_listener
    frontend_ip_configuration_name = local.frontend_name
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = local.ssl_cert_name
  }

  http_listener {
    name                           = local.http_listener
    frontend_ip_configuration_name = local.frontend_name
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = local.https_listener
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https-to-guacamole"
    rule_type                  = "Basic"
    http_listener_name         = local.https_listener
    backend_address_pool_name  = local.backend_pool_name
    backend_http_settings_name = local.backend_settings
    priority                   = 100
  }

  request_routing_rule {
    name                        = "http-redirect"
    rule_type                   = "Basic"
    http_listener_name          = local.http_listener
    redirect_configuration_name = "http-to-https"
    priority                    = 200
  }

  # Created after the Windows domain-join extension finishes: in every build
  # where the two overlapped, Azure failed the gateway with a bare
  # InternalServerError, and the same gateway created on its own succeeded.
  depends_on = [
    time_sleep.app_gateway_rbac_propagation,
    azurerm_virtual_machine_extension.join_script,
  ]
}
