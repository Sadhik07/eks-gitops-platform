terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-sadhik07-tfstate"
    storage_account_name = "sadhik07tfstate"
    container_name       = "tfstate"
    key                  = "dev.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true # dev only: lets `destroy` + re-create reuse the vault name
    }
  }
  storage_use_azuread = true
}

data "azurerm_container_registry" "shared" {
  name                = "${var.name_prefix}orders"
  resource_group_name = "rg-orders-global"
}

module "stack" {
  source = "../../stacks/environment"

  environment              = "dev"
  name_prefix              = var.name_prefix
  location                 = var.location
  repository               = var.repository
  vnet_cidr                = "10.40.0.0/16"
  api_authorized_ip_ranges = var.api_authorized_ip_ranges
  admin_group_object_ids   = var.admin_group_object_ids
  system_vm_size           = "Standard_D2s_v5"
  system_node_count        = 2
  acr_id                   = data.azurerm_container_registry.shared.id
  backup_retention_days    = 7
  tags                     = { project = "eks-gitops-platform", cloud = "azure" }
}

variable "name_prefix" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "repository" {
  type = string
}

variable "api_authorized_ip_ranges" {
  type = list(string)
}

variable "admin_group_object_ids" {
  type    = list(string)
  default = []
}

output "stack" {
  value = module.stack
}
