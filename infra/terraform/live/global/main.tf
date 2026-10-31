# Account-wide resources shared by every environment: container registries
# and the GitHub Actions OIDC roles.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  backend "s3" {
    bucket       = "eks-gitops-tfstate-123456789012" # from bootstrap output
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "eks-gitops-platform", managed-by = "terraform" }
  }
}

module "ecr" {
  source       = "../../modules/ecr"
  repositories = ["orders/api", "orders/worker", "orders/web"]
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  github_org           = var.github_org
  github_repo          = var.github_repo
  create_oidc_provider = var.create_oidc_provider
  ecr_repository_arns  = module.ecr.repository_arns
  state_bucket         = var.state_bucket
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type    = string
  default = "eks-gitops-platform"
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}

variable "state_bucket" {
  type = string
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "github_actions_role_arns" {
  value = {
    ecr_push        = module.github_oidc.ecr_push_role_arn
    terraform_plan  = module.github_oidc.terraform_plan_role_arn
    terraform_apply = module.github_oidc.terraform_apply_role_arn
  }
}
