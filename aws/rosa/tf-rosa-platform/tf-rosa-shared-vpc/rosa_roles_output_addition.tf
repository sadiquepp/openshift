# Add this output to tf-rosa-roles/outputs.tf
# It exposes the ROSA account ID so the root module can wire it into
# module.share_subnets.rosa_account_id without hardcoding it.

output "rosa_account_id" {
  description = "AWS account ID of the ROSA/installer account (from data.aws_caller_identity)"
  value       = data.aws_caller_identity.current.account_id
}
