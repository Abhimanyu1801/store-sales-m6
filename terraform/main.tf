data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "random_password" "pg" {
  length  = 28
  special = false # keeps the value safe in connection strings
}

locals {
  suffix = random_string.suffix.result
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ---------------------------------------------------------------- network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-storesales"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.0.0/22"]
}

resource "azurerm_subnet" "db" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.8.0/24"]
  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "pg" {
  name                = "storesales.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  name                  = "pg-vnet-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.pg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# ---------------------------------------------------------------- database (private IP only)
resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "pg-storesales-${local.suffix}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16"
  sku_name                      = var.pg_sku
  storage_mb                    = 32768
  administrator_login           = var.pg_admin_user
  administrator_password        = random_password.pg.result
  delegated_subnet_id           = azurerm_subnet.db.id
  private_dns_zone_id           = azurerm_private_dns_zone.pg.id
  public_network_access_enabled = false
  backup_retention_days         = 7

  depends_on = [azurerm_private_dns_zone_virtual_network_link.pg]

  lifecycle {
    ignore_changes = [zone] # Azure picks the availability zone
  }
}

# ---------------------------------------------------------------- registry
resource "azurerm_container_registry" "acr" {
  name                = "acrstoresales${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false # no shared password; pulls use identities
}

# ---------------------------------------------------------------- logging
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-storesales"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ---------------------------------------------------------------- AKS
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "storesales-aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  dns_prefix          = "storesales-aks"
  sku_tier            = "Free"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Upgrades need surge nodes, which would exceed the 6-vCPU regional quota.
  node_os_upgrade_channel   = "None"

  default_node_pool {
    name           = "system"
    vm_size        = var.aks_vm_size
    node_count     = var.aks_node_count
    vnet_subnet_id = azurerm_subnet.aks.id
    os_disk_size_gb = 64
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.2.0.0/16"
    dns_service_ip      = "10.2.0.10"
  }

  # Container Insights: ships container stdout (our JSON logs) to Log Analytics.
  # The addon also creates its own data collection rule (not managed by Terraform).
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.law.id
    msi_auth_for_monitoring_enabled = true
  }
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

# ---------------------------------------------------------------- storage (identity-only)
resource "azurerm_storage_account" "st" {
  name                            = "stsales${local.suffix}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # no account keys, identity only
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "uploads" {
  name                  = "uploads"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}

# ---------------------------------------------------------------- workload identity
resource "azurerm_user_assigned_identity" "app" {
  name                = "store-app-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "app" {
  name                = "aks-store-app"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.app.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = "system:serviceaccount:${var.app_namespace}:${var.app_service_account}"
}

resource "azurerm_role_assignment" "app_blob" {
  scope                = azurerm_storage_account.st.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# ---------------------------------------------------------------- Key Vault
resource "azurerm_key_vault" "kv" {
  name                       = "kv-storesales-${local.suffix}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_app" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "time_sleep" "rbac" {
  create_duration = "90s" # role assignments take a moment to propagate
  depends_on      = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "pg_host" {
  name         = "pg-host"
  value        = azurerm_postgresql_flexible_server.pg.fqdn
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.rbac]
}

resource "azurerm_key_vault_secret" "pg_user" {
  name         = "pg-user"
  value        = var.pg_admin_user
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.rbac]
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "pg-password"
  value        = random_password.pg.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.rbac]
}
