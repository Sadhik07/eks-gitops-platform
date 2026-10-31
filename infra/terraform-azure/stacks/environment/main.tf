# One complete Azure environment: network, AKS, app dependencies and workload
# identities. Mirrors infra/terraform/stacks/environment on AWS:
#   SQS + DLQ        -> Service Bus queue (built-in dead-letter sub-queue)
#   Secrets Manager  -> Key Vault (RBAC mode)
#   S3 (Velero)      -> Blob storage
#   Pod Identity     -> Entra Workload ID

locals {
  name   = "orders-${var.environment}"
  app_ns = "orders"
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    repository  = var.repository
  })
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "../../modules/network"

  name                = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  cidr                = var.vnet_cidr
  tags                = local.tags
}

module "aks" {
  source = "../../modules/aks"

  name                     = "aks-${local.name}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.this.name
  kubernetes_version       = var.kubernetes_version
  node_subnet_id           = module.network.node_subnet_id
  api_authorized_ip_ranges = var.api_authorized_ip_ranges
  admin_group_object_ids   = var.admin_group_object_ids
  system_vm_size           = var.system_vm_size
  system_node_count        = var.system_node_count
  tags                     = local.tags
}

# Nodes pull images from the shared registry (created in live/global)
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = module.aks.kubelet_object_id
  principal_type       = "ServicePrincipal"
}

# --- Order queue -------------------------------------------------------------
# tflint-ignore: azurerm_resources_missing_prevent_destroy # environments are torn down after demos; prod data protection would come from backups + soft delete
resource "azurerm_servicebus_namespace" "this" {
  #checkov:skip=CKV_AZURE_199:Microsoft-managed keys are sufficient; customer-managed keys need Premium
  #checkov:skip=CKV_AZURE_201:Customer-managed keys need Premium
  #checkov:skip=CKV_AZURE_204:Private endpoints need Premium; local (SAS) auth is disabled, so only Entra identities connect
  name                          = "sb-${var.name_prefix}-${local.name}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  sku                           = "Standard"
  local_auth_enabled            = false # no connection strings: Entra ID only
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # environments are torn down after demos; prod data protection would come from backups + soft delete
resource "azurerm_servicebus_queue" "orders" {
  name                                 = "orders"
  namespace_id                         = azurerm_servicebus_namespace.this.id
  lock_duration                        = "PT1M"
  max_delivery_count                   = 5 # then the message moves to orders/$DeadLetterQueue
  dead_lettering_on_message_expiration = true
  default_message_ttl                  = "P14D"
}

# --- Application secrets: values are set out of band, never in Terraform state ---
# tflint-ignore: azurerm_resources_missing_prevent_destroy # environments are torn down after demos; prod data protection would come from backups + soft delete
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_109:Public access is needed from GitHub-hosted runners; RBAC limits who can read secrets
  #checkov:skip=CKV_AZURE_189:Same as above
  #checkov:skip=CKV2_AZURE_32:Private endpoints are out of scope for the lab
  name                          = "kv-${var.name_prefix}-${var.environment}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = var.environment == "prod"
  public_network_access_enabled = true
  tags                          = local.tags

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# Whoever runs Terraform can set secret values (az keyvault secret set ...)
resource "azurerm_role_assignment" "deployer_kv_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Velero backups ----------------------------------------------------------
# tflint-ignore: azurerm_resources_missing_prevent_destroy # environments are torn down after demos; prod data protection would come from backups + soft delete
resource "azurerm_storage_account" "velero" {
  #checkov:skip=CKV_AZURE_33:Queue service is unused
  #checkov:skip=CKV_AZURE_59:Velero runs in the cluster and reaches storage over its public endpoint with Entra ID auth
  #checkov:skip=CKV_AZURE_206:LRS keeps backup cost low in dev; use GRS/GZRS for prod DR
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for the lab
  #checkov:skip=CKV2_AZURE_33:Private endpoints are out of scope for the lab
  name                              = "${var.name_prefix}velero${var.environment}"
  resource_group_name               = azurerm_resource_group.this.name
  location                          = var.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  infrastructure_encryption_enabled = true
  tags                              = local.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # environments are torn down after demos; prod data protection would come from backups + soft delete
resource "azurerm_storage_container" "velero" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace
  name                  = "velero"
  storage_account_id    = azurerm_storage_account.velero.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "velero" {
  storage_account_id = azurerm_storage_account.velero.id
  rule {
    name    = "expire-old-backups"
    enabled = true
    filters {
      blob_types = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.backup_retention_days
      }
    }
  }
}

# --- Least-privilege workload identities -------------------------------------
module "workload_identity" {
  source = "../../modules/workload-identity"

  cluster_name        = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  oidc_issuer_url     = module.aks.oidc_issuer_url
  tags                = local.tags

  workloads = {
    api = {
      namespace = local.app_ns, service_account = "api"
      roles     = [{ scope = azurerm_servicebus_queue.orders.id, role = "Azure Service Bus Data Sender" }]
    }
    worker = {
      namespace = local.app_ns, service_account = "worker"
      roles     = [{ scope = azurerm_servicebus_queue.orders.id, role = "Azure Service Bus Data Receiver" }]
    }
    external-secrets = {
      namespace = "external-secrets", service_account = "external-secrets"
      roles     = [{ scope = azurerm_key_vault.this.id, role = "Key Vault Secrets User" }]
    }
    velero = {
      namespace = "velero", service_account = "velero-server"
      roles = [
        { scope = azurerm_storage_account.velero.id, role = "Storage Blob Data Contributor" },
        # Disk snapshots of persistent volumes live in the AKS node resource group
        { scope = module.aks.node_resource_group_id, role = "Disk Snapshot Contributor" },
        { scope = module.aks.node_resource_group_id, role = "Reader" },
      ]
    }
    kyverno = {
      namespace = "kyverno", service_account = "kyverno-admission-controller"
      roles     = [{ scope = var.acr_id, role = "AcrPull" }] # read image signatures
    }
  }
}
