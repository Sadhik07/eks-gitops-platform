output "ecr_push_role_arn" {
  description = "Set as the AWS_ECR_PUSH_ROLE_ARN repository variable"
  value       = aws_iam_role.ecr_push.arn
}

output "terraform_plan_role_arn" {
  description = "Set as the AWS_TF_PLAN_ROLE_ARN repository variable"
  value       = aws_iam_role.terraform_plan.arn
}

output "terraform_apply_role_arn" {
  description = "Set as the AWS_TF_APPLY_ROLE_ARN repository variable"
  value       = try(aws_iam_role.terraform_apply[0].arn, null)
}
