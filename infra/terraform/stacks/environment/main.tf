# One complete environment: network, EKS, app dependencies and workload IAM.
# live/dev, live/stage and live/prod call this stack with different sizing.

locals {
  cluster_name = "orders-${var.environment}"
  app_ns       = "orders"
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    repository  = var.repository
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "network" {
  source = "../../modules/network"

  name               = local.cluster_name
  cluster_name       = local.cluster_name
  cidr               = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}

module "eks" {
  source = "../../modules/eks-cluster"

  cluster_name          = local.cluster_name
  kubernetes_version    = var.kubernetes_version
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  intra_subnet_ids      = module.network.intra_subnet_ids
  public_endpoint_cidrs = var.public_endpoint_cidrs
  admin_role_arns       = var.admin_role_arns
  system_instance_types = var.system_instance_types
  system_min_size       = var.system_min_size
  system_max_size       = var.system_max_size
  tags                  = local.tags
}

# --- Order queue with dead-letter queue -----------------------------------
resource "aws_sqs_queue" "orders_dlq" {
  name                      = "${local.cluster_name}-orders-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate poison messages
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_sqs_queue" "orders" {
  name                       = "${local.cluster_name}-orders"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 5
  })
  tags = local.tags
}

# --- Application secret: value is set out of band, never in Terraform state ---
resource "aws_secretsmanager_secret" "api" {
  #checkov:skip=CKV2_AWS_57:Holds third-party API keys rotated by their issuer; no rotation Lambda to run
  #checkov:skip=CKV_AWS_149:AWS-managed key is sufficient for the lab; use a CMK where key policy separation is required
  name                    = "orders/${var.environment}/api"
  description             = "Orders API runtime secrets, synced by External Secrets Operator"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = local.tags
}

# --- Velero backup bucket ---------------------------------------------------
resource "aws_s3_bucket" "velero" {
  #checkov:skip=CKV_AWS_18:Access logs need a dedicated log bucket; enable with an org-wide logging account
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles backup cost; enable for prod DR requirements
  #checkov:skip=CKV2_AWS_62:No consumer for bucket event notifications
  bucket        = "${local.cluster_name}-velero-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment != "prod"
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Least-privilege workload roles (EKS Pod Identity) ----------------------
data "aws_iam_policy_document" "api" {
  statement {
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.orders.arn]
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.orders.arn]
  }
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:orders/${var.environment}/*"
    ]
  }
}

data "aws_iam_policy_document" "velero" {
  #checkov:skip=CKV_AWS_111:EBS snapshot APIs do not support resource-level scoping for create/describe (matches Velero's documented policy)
  #checkov:skip=CKV_AWS_356:Same as above; S3 access is scoped to the backup bucket
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.velero.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.velero.arn]
  }
  statement {
    actions = [
      "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags",
      "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot",
    ]
    resources = ["*"]
  }
}

# Kyverno pulls image signatures from ECR to verify them at admission
data "aws_iam_policy_document" "kyverno" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"]
    resources = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/orders/*"]
  }
}

module "workload_identity" {
  source       = "../../modules/workload-identity"
  cluster_name = module.eks.cluster_name
  tags         = local.tags

  workloads = {
    api              = { namespace = local.app_ns, service_account = "api", policy_json = data.aws_iam_policy_document.api.json }
    worker           = { namespace = local.app_ns, service_account = "worker", policy_json = data.aws_iam_policy_document.worker.json }
    external-secrets = { namespace = "external-secrets", service_account = "external-secrets", policy_json = data.aws_iam_policy_document.external_secrets.json }
    velero           = { namespace = "velero", service_account = "velero-server", policy_json = data.aws_iam_policy_document.velero.json }
    kyverno          = { namespace = "kyverno", service_account = "kyverno-admission-controller", policy_json = data.aws_iam_policy_document.kyverno.json }
  }
}
