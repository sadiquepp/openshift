output "bastion_public_ip" {
  description = "SSH target for the Ansible bastion setup playbook"
  value       = module.installer_ec2.installer_public_ip
}

output "ansible_run_command" {
  description = "Command to run the remaining Ansible setup against the bastion"
  value       = module.installer_ec2.ansible_inventory_hint
}

output "disconnected_subnet_ids" {
  value = {
    az1 = module.share_subnets.disconnected_subnet_id_a
    az2 = module.share_subnets.disconnected_subnet_id_b
    az3 = module.share_subnets.disconnected_subnet_id_c
  }
}

output "hosted_zone_ids" {
  value = {
    cluster          = module.share_subnets.hosted_zone_id_for_domain
    rosa_shared_vpc  = module.share_subnets.rosa_shared_vpc_hosted_zone_id
    hypershift_local = module.share_subnets.hypershift_local_hosted_zone_id
  }
}

output "installer_role_arn"  { value = module.rosa_roles.installer_role_arn }
output "worker_role_arn"     { value = module.rosa_roles.worker_role_arn }
output "operator_role_arns"  { value = module.rosa_roles.operator_role_arns }
