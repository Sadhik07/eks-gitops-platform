# Run once per Azure subscription with local state:
#   az login && export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
#   terraform -chdir=infra/terraform-azure/bootstrap init && terraform -chdir=infra/terraform-azure/bootstrap apply
# Creates the storage account that holds remote state for every other Azure
# root module. Blob leases give state locking natively; access uses Entra ID
# (no storage account keys).

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.50"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "state" {
  name     = "rg-${var.name_prefix}-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV_AZURE_33:Queue service is unused on a state-only account
  #checkov:skip=CKV_AZURE_59:GitHub-hosted runners need public network access; access is Entra ID only (no keys)
  #checkov:skip=CKV_AZURE_206:ZRS survives a zone outage; geo-replication is optional for a lab
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for Terraform state in this lab
  #checkov:skip=CKV2_AZURE_33:Private endpoints would block GitHub-hosted runners
  name                              = "${var.name_prefix}tfstate"
  resource_group_name               = azurerm_resource_group.state.name
  location                          = azurerm_resource_group.state.location
  account_tier                      = "Standard"
  account_replication_type          = "ZRS"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false # Entra ID auth only
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs a Log Analytics workspace; versioning keeps every state revision
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# The person running bootstrap can read/write state with their Entra identity
resource "azurerm_role_assignment" "state_admin" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "name_prefix" {
  description = "Short, globally unique, lowercase alphanumeric prefix (storage and registry names are global)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 lowercase letters or digits."
  }
}

output "backend_config" {
  description = "Copy these values into every live/*/main.tf backend block"
  value = {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
  }
}
