variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "name_prefix" {
  description = "Globally unique lowercase prefix for storage, Key Vault and Service Bus names"
  type        = string
}

variable "location" {
  type = string
}

variable "repository" {
  type = string
}

variable "vnet_cidr" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = null
}

variable "api_authorized_ip_ranges" {
  type = list(string)
}

variable "admin_group_object_ids" {
  type    = list(string)
  default = []
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "system_node_count" {
  type    = number
  default = 2
}

variable "acr_id" {
  description = "Shared registry from live/global"
  type        = string
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
