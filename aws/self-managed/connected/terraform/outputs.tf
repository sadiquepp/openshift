output "vpc_owner_aws_account_number" {
  description = "AWS account number that owns the VPC"
  value       = data.aws_caller_identity.current.account_id
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

output "connected_vpc_id" {
  description = "ID of the connected VPC"
  value       = aws_vpc.connected.id
}

output "connected_private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "connected_public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "iam_role_arn" {
  description = "ARN of the IAM role for OCP installer EC2 instances"
  value       = aws_iam_role.ocp_install_ec2.arn
}

output "iam_role_name" {
  description = "Name of the IAM role for OCP installer EC2 instances"
  value       = aws_iam_role.ocp_install_ec2.name
}

# ── Route53 ───────────────────────────────────────────────────────────────────

output "public_hosted_zone_id" {
  description = "Public Route53 hosted zone ID (update your registrar NS records to delegate to this zone)"
  value       = var.create_public_hosted_zone ? aws_route53_zone.public[0].zone_id : null
}

output "public_hosted_zone_name_servers" {
  description = "NS records to configure at your domain registrar for the public hosted zone"
  value       = var.create_public_hosted_zone ? aws_route53_zone.public[0].name_servers : []
}

output "openshift_base_domain" {
  description = "Base domain for the OpenShift cluster"
  value       = var.openshift_base_domain
}

# ── Installer EC2 ────────────────────────────────────────────────────────────

output "installer_instance_id" {
  description = "Instance ID of the installer EC2"
  value       = aws_instance.installer.id
}

output "installer_public_ip" {
  description = "Public IP of the installer EC2 instance"
  value       = aws_instance.installer.public_ip
}

output "installer_private_ip" {
  description = "Private IP of the installer EC2 instance"
  value       = aws_instance.installer.private_ip
}
