# Subscription-wide resources: the container registry and the GitHub Actions
# identities. Equivalent of infra/terraform/live/global on AWS.

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-sadhik07-tfstate" # from bootstrap output
    storage_account_name = "sadhik07tfstate"
    container_name       = "tfstate"
    key                  = "global.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

data "azurerm_subscription" "current" {}

data "azurerm_storage_account" "state" {
  name                = "${var.name_prefix}tfstate"
  resource_group_name = "rg-${var.name_prefix}-tfstate"
}

locals {
  tags = { project = "eks-gitops-platform", cloud = "azure", managed-by = "terraform" }
}

resource "azurerm_resource_group" "global" {
  name     = "rg-orders-global"
  location = var.location
  tags     = local.tags
}

resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_139:Private endpoints need the Premium SKU; access is Entra ID only (admin user disabled)
  #checkov:skip=CKV_AZURE_164:Content trust is replaced by cosign keyless signatures enforced at admission
  #checkov:skip=CKV_AZURE_165:Geo-replication needs Premium; single region for the lab
  #checkov:skip=CKV_AZURE_166:Quarantine needs Premium; the Trivy gate blocks vulnerable images before push
  #checkov:skip=CKV_AZURE_167:Retention policy needs Premium; tags are immutable SHAs
  #checkov:skip=CKV_AZURE_233:Zone redundancy needs Premium
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints need Premium
  name                          = "${var.name_prefix}orders"
  resource_group_name           = azurerm_resource_group.global.name
  location                      = azurerm_resource_group.global.location
  sku                           = "Standard"
  admin_enabled                 = false # Entra ID tokens only, no shared password
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  tags                          = local.tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_org               = var.github_org
  github_repo              = var.github_repo
  location                 = azurerm_resource_group.global.location
  resource_group_name      = azurerm_resource_group.global.name
  subscription_scope       = data.azurerm_subscription.current.id
  acr_id                   = azurerm_container_registry.this.id
  state_storage_account_id = data.azurerm_storage_account.state.id
  tags                     = local.tags
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "name_prefix" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "github_actions_client_ids" {
  value = module.github_oidc.client_ids
}

output "tenant_id" {
  value = data.azurerm_subscription.current.tenant_id
}

output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}
