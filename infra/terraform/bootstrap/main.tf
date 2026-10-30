# Run once per AWS account with local state:
#   terraform -chdir=infra/terraform/bootstrap init && terraform -chdir=infra/terraform/bootstrap apply
# Creates the S3 bucket that holds remote state for every other root module.
# Locking uses S3-native lock files (Terraform >= 1.10), so no DynamoDB table.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Access logs need a dedicated log bucket; enable with an org-wide logging account
  #checkov:skip=CKV_AWS_144:Versioning protects state; cross-region replication is optional for a single-region lab
  #checkov:skip=CKV2_AWS_62:No consumer for bucket event notifications
  bucket = "${var.prefix}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  description = "Bucket name prefix"
  type        = string
  default     = "eks-gitops"
}

output "state_bucket" {
  description = "Put this in every live/*/backend.tf"
  value       = aws_s3_bucket.state.bucket
}
