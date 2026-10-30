variable "github_org" {
  description = "GitHub user or organization that owns the repository"
  type        = string
}

variable "github_repo" {
  description = "Repository name"
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider (only one per AWS account; set false if it already exists)"
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "ECR repositories CI may push to"
  type        = list(string)
}

variable "state_bucket" {
  description = "Terraform state bucket name"
  type        = string
}

variable "apply_environments" {
  description = "GitHub environments (with required reviewers) allowed to run terraform apply"
  type        = list(string)
  default     = ["dev", "stage", "prod"]
}

variable "apply_policy_arn" {
  description = <<-EOT
    Policy for the apply role. AdministratorAccess keeps the lab simple; in a real
    account replace it with a scoped policy plus a permissions boundary.
  EOT
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

variable "tags" {
  type    = map(string)
  default = {}
}
