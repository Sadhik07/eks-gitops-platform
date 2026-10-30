variable "name" {
  description = "VPC name"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for Karpenter subnet discovery tags"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block (/16 recommended)"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "Number of availability zones to span"
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper, not AZ-resilient). Use false in prod."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
