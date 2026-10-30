output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "karpenter_node_role_name" {
  description = "Referenced by the Karpenter EC2NodeClass"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue" {
  description = "Passed to the Karpenter Helm chart (settings.interruptionQueue)"
  value       = module.karpenter.queue_name
}

output "pod_identity_trust_policy_json" {
  description = "Trust policy for roles assumed through EKS Pod Identity"
  value       = data.aws_iam_policy_document.pod_identity_trust.json
}
