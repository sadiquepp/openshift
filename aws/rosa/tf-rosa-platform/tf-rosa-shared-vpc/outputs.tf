# These outputs mirror the Ansible set_stats block at the end of the playbook.
# Pass them into your ROSA cluster installation config.

output "vpc_owner_aws_account_number" {
  description = "AWS account ID of the VPC owner"
  value       = data.aws_caller_identity.current.account_id
}

output "disconnected_vpc_id" {
  description = "ID of the disconnected VPC"
  value       = data.aws_vpc.disconnected.id
}

output "disconnected_vpc_cidr" {
  description = "CIDR block of the disconnected VPC"
  value       = data.aws_vpc.disconnected.cidr_block
}

output "disconnected_subnet_id_a" {
  description = "Disconnected subnet ID in AZ1"
  value       = data.aws_subnet.disconnected_az1.id
}

output "disconnected_subnet_id_b" {
  description = "Disconnected subnet ID in AZ2"
  value       = data.aws_subnet.disconnected_az2.id
}

output "disconnected_subnet_id_c" {
  description = "Disconnected subnet ID in AZ3"
  value       = data.aws_subnet.disconnected_az3.id
}

output "egress_vpc_id" {
  description = "ID of the egress VPC"
  value       = data.aws_vpc.egress.id
}

output "egress_vpc_cidr" {
  description = "CIDR block of the egress VPC"
  value       = data.aws_vpc.egress.cidr_block
}

output "egress_subnet_id_a" {
  description = "Egress public subnet ID in AZ1 (the one shared via RAM)"
  value       = data.aws_subnet.egress_public_az1.id
}

output "hosted_zone_id_for_domain" {
  description = "Route53 private hosted zone ID for <cluster>.<base_domain>"
  value       = aws_route53_zone.cluster.zone_id
}

output "rosa_shared_vpc_hosted_zone_id" {
  description = "Route53 private hosted zone ID for the ROSA shared-VPC domain"
  value       = aws_route53_zone.rosa.zone_id
}

output "hypershift_local_hosted_zone_id" {
  description = "Route53 private hosted zone ID for <cluster>.hypershift.local"
  value       = aws_route53_zone.hypershift_local.zone_id
}

output "route53_role_arn" {
  description = "ARN of the IAM role for ROSA shared-VPC Route53 management"
  value       = aws_iam_role.route53.arn
}

output "endpoint_role_arn" {
  description = "ARN of the IAM role for ROSA shared-VPC endpoint management"
  value       = aws_iam_role.endpoint.arn
}

output "ram_resource_share_arn" {
  description = "ARN of the RAM resource share"
  value       = aws_ram_resource_share.subnets.arn
}