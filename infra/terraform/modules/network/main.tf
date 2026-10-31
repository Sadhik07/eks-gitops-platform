data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Only the first az_count zones are used, so new zones never change the subnet layout
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # exclude Local/Wavelength zones
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  # /20 private (nodes + pods), /24 public (load balancers), /24 intra (EKS control-plane ENIs)
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, i + 64)]
  intra_subnets   = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, i + 68)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }

  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 30

  tags = var.tags
}
