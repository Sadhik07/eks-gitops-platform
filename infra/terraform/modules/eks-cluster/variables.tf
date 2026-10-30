variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Check supported versions before changing."
  type        = string
  default     = "1.33"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Subnets for worker nodes"
  type        = list(string)
}

variable "intra_subnet_ids" {
  description = "Subnets for control-plane ENIs"
  type        = list(string)
}

variable "public_endpoint" {
  description = "Expose the API server publicly (restricted by public_endpoint_cidrs)"
  type        = bool
  default     = true
}

variable "public_endpoint_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Set to your IP/VPN, never 0.0.0.0/0 in prod."
  type        = list(string)
}

variable "admin_role_arns" {
  description = "Map of name => IAM role ARN granted cluster-admin via EKS access entries"
  type        = map(string)
  default     = {}
}

variable "system_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "system_min_size" {
  type    = number
  default = 2
}

variable "system_max_size" {
  type    = number
  default = 3
}

variable "tags" {
  type    = map(string)
  default = {}
}
