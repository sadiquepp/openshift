output "aws_account_id" {
  description = "AWS account ID (equivalent to Ansible set_stats vpc_owner_aws_account_number)"
  value       = data.aws_caller_identity.current.account_id
}

output "disconnected_vpc_id" {
  description = "ID of the disconnected VPC"
  value       = aws_vpc.disconnected.id
}

output "disconnected_private_subnet_ids" {
  description = "IDs of the three disconnected private subnets"
  value       = aws_subnet.disconnected_private[*].id
}

output "egress_vpc_id" {
  description = "ID of the egress VPC"
  value       = aws_vpc.egress.id
}

output "egress_public_subnet_ids" {
  description = "IDs of the egress public subnets"
  value       = aws_subnet.egress_public[*].id
}

output "egress_private_subnet_ids" {
  description = "IDs of the egress private subnets"
  value       = aws_subnet.egress_private[*].id
}

output "transit_gateway_id" {
  description = "ID of the Transit Gateway"
  value       = aws_ec2_transit_gateway.this.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway on the egress VPC"
  value       = aws_internet_gateway.egress.id
}

output "ocp_install_role_arn" {
  description = "ARN of the IAM role for the OCP install EC2 instance"
  value       = aws_iam_role.ocp_install.arn
}

output "ocp_install_instance_profile_name" {
  description = "Name of the IAM instance profile for the OCP install EC2 instance"
  value       = aws_iam_instance_profile.ocp_install.name
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "IDs of the interface VPC endpoints keyed by service name"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
