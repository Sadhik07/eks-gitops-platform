variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subscription_scope" {
  description = "Subscription resource id, e.g. /subscriptions/<id>"
  type        = string
}

variable "acr_id" {
  type = string
}

variable "state_storage_account_id" {
  type = string
}

variable "apply_environments" {
  description = "GitHub environments (with required reviewers) allowed to run terraform apply"
  type        = list(string)
  default     = ["azure-dev"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
