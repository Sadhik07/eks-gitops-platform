variable "cluster_name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "oidc_issuer_url" {
  type = string
}

variable "workloads" {
  description = "name => { namespace, service_account, roles = [{ scope, role }] }"
  type = map(object({
    namespace       = string
    service_account = string
    roles = list(object({
      scope = string
      role  = string
    }))
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
