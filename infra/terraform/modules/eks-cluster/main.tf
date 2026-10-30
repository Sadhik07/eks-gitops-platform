module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # Public endpoint restricted to allowed CIDRs; private endpoint always on
  cluster_endpoint_public_access       = var.public_endpoint
  cluster_endpoint_public_access_cidrs = var.public_endpoint_cidrs
  cluster_endpoint_private_access      = true

  # Access entries (not aws-auth ConfigMap): the identity running terraform
  # becomes cluster admin, plus any admin roles passed in.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  access_entries = {
    for name, arn in var.admin_role_arns : name => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator"]
  # Secrets are envelope-encrypted with a module-managed KMS key (module default)

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true, before_compute = true }
    eks-pod-identity-agent = { most_recent = true, before_compute = true }
  }

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.intra_subnet_ids

  # Small, stable node group for cluster-critical add-ons (CoreDNS, Karpenter, ArgoCD).
  # Application capacity is provisioned just-in-time by Karpenter.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      min_size       = var.system_min_size
      max_size       = var.system_max_size
      desired_size   = var.system_min_size

      labels = { "node-role" = "system" }
      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      metadata_options = {
        http_tokens                 = "required" # IMDSv2 only
        http_put_response_hop_limit = 1
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}

# Karpenter controller IAM, interruption SQS queue and node role
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.37"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true

  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # Spot-interruption / rebalance events land here; name referenced by the Helm values
  queue_name = "karpenter-${var.cluster_name}"

  # Deterministic name so the EC2NodeClass in platform/clusters/<env>/karpenter can reference it
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "KarpenterNode-${var.cluster_name}"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# EBS CSI driver with pod identity, for stateful add-ons (Prometheus, Loki)
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-ebs-csi-driver"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [module.eks]
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}
