terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  backend "s3" {
    bucket       = "eks-gitops-tfstate-123456789012"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "eks-gitops-platform" }
  }
}

module "stack" {
  source = "../../stacks/environment"

  environment           = "prod"
  repository            = var.repository
  vpc_cidr              = "10.30.0.0/16"
  az_count              = 3
  single_nat_gateway    = false # one NAT per AZ so an AZ outage doesn't cut egress
  public_endpoint_cidrs = var.public_endpoint_cidrs
  admin_role_arns       = var.admin_role_arns
  system_instance_types = ["m6i.large"]
  system_min_size       = 3
  system_max_size       = 4
  backup_retention_days = 30
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "repository" {
  type = string
}

variable "public_endpoint_cidrs" {
  type = list(string)
}

variable "admin_role_arns" {
  type    = map(string)
  default = {}
}

output "stack" {
  value = module.stack
}
