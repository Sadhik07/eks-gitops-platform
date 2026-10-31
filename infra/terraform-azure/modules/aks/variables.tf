variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "kubernetes_version" {
  description = "AKS version; null picks the region's default. Check `az aks get-versions` before pinning."
  type        = string
  default     = null
}

variable "node_subnet_id" {
  type = string
}

variable "api_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the API server (your IP, VPN). Never 0.0.0.0/0."
  type        = list(string)
}

variable "admin_group_object_ids" {
  description = "Entra ID groups granted cluster-admin"
  type        = list(string)
  default     = []
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "system_node_count" {
  type    = number
  default = 2
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
