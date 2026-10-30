variable "cluster_name" {
  type = string
}

variable "workloads" {
  description = "name => { namespace, service_account, policy_json }"
  type = map(object({
    namespace       = string
    service_account = string
    policy_json     = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
