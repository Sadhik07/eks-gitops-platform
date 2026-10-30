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
    key          = "dev/terraform.tfstate"
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

  environment           = "dev"
  repository            = var.repository
  vpc_cidr              = "10.10.0.0/16"
  az_count              = 2    # cheapest footprint that still survives one AZ loss
  single_nat_gateway    = true # cost over resilience in dev
  public_endpoint_cidrs = var.public_endpoint_cidrs
  admin_role_arns       = var.admin_role_arns
  system_instance_types = ["t3.medium"]
  system_min_size       = 2
  system_max_size       = 3
  backup_retention_days = 7
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
