output "installer_role_arn" {
  description = "ARN of the ROSA HCP Installer account role"
  value       = aws_iam_role.installer.arn
}

output "support_role_arn" {
  description = "ARN of the ROSA HCP Support account role"
  value       = aws_iam_role.support.arn
}

output "worker_role_arn" {
  description = "ARN of the ROSA HCP Worker account role"
  value       = aws_iam_role.worker.arn
}

output "worker_instance_profile_name" {
  description = "Instance profile name for ROSA worker nodes"
  value       = aws_iam_instance_profile.worker.name
}

output "operator_role_arns" {
  description = "Map of operator role key → ARN for all eight ROSA HCP operator roles"
  value       = { for k, v in aws_iam_role.operator : k => v.arn }
}

output "route53_assume_policy_arn" {
  description = "ARN of the shared-VPC Route53 assume-role managed policy"
  value       = aws_iam_policy.route53_assume.arn
}

output "endpoint_assume_policy_arn" {
  description = "ARN of the shared-VPC Endpoint assume-role managed policy"
  value       = aws_iam_policy.endpoint_assume.arn
}

output "rosa_create_cluster_hint" {
  description = "Key ARN values to pass to 'rosa create cluster --hosted-cp'"
  value = {
    installer_role_arn = aws_iam_role.installer.arn
    support_role_arn   = aws_iam_role.support.arn
    worker_role_arn    = aws_iam_role.worker.arn
    operator_roles     = { for k, v in aws_iam_role.operator : k => v.arn }
  }
}
