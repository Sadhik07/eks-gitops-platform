output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${data.aws_region.current.name}"
}

output "orders_queue_url" {
  description = "Set as QUEUE_URL in deploy/overlays/<env>/{api,worker}"
  value       = aws_sqs_queue.orders.url
}

output "orders_dlq_url" {
  value = aws_sqs_queue.orders_dlq.url
}

output "karpenter_node_role_name" {
  value = module.eks.karpenter_node_role_name
}

output "karpenter_interruption_queue" {
  value = module.eks.karpenter_interruption_queue
}

output "velero_bucket" {
  value = aws_s3_bucket.velero.bucket
}

output "workload_role_arns" {
  value = module.workload_identity.role_arns
}
