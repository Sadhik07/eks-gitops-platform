# One IAM role per Kubernetes service account, bound with EKS Pod Identity.
# Each workload gets only the AWS permissions it needs (least privilege).

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = var.workloads

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "this" {
  for_each = var.workloads

  role   = aws_iam_role.this[each.key].id
  policy = each.value.policy_json
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = var.workloads

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.this[each.key].arn
  tags            = var.tags
}
