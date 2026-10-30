variable "environment" {
  description = "Environment name: dev, stage or prod"
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "repository" {
  description = "Source repository, recorded as a tag on every resource"
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "public_endpoint_cidrs" {
  description = "CIDRs allowed to reach the EKS public endpoint"
  type        = list(string)
}

variable "admin_role_arns" {
  type    = map(string)
  default = {}
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

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
