output "vpc_owner_aws_account_number" {
  description = "AWS account number that owns the VPCs"
  value       = data.aws_caller_identity.current.account_id
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

output "disconnected_vpc_id" {
  description = "ID of the disconnected VPC"
  value       = aws_vpc.disconnected.id
}

output "disconnected_subnet_ids" {
  description = "IDs of the disconnected private subnets"
  value       = aws_subnet.disconnected[*].id
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

output "egress_vpc_id" {
  description = "ID of the egress VPC"
  value       = aws_vpc.egress.id
}

output "egress_public_subnet_ids" {
  description = "IDs of the egress public subnets"
  value       = aws_subnet.egress_public[*].id
}

# ── Transit Gateway ──────────────────────────────────────────────────────────

output "transit_gateway_id" {
  description = "ID of the transit gateway"
  value       = aws_ec2_transit_gateway.main.id
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

output "hosted_zone_id" {
  description = "Route53 private hosted zone ID for the cluster domain"
  value       = aws_route53_zone.cluster.zone_id
}

output "cluster_domain" {
  description = "Fully qualified cluster domain"
  value       = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
}

# ── Installer EC2 ────────────────────────────────────────────────────────────

output "installer_ami_id" {
  description = "AMI ID used for the installer EC2 (resolved from RHEL 9 lookup or override)"
  value       = aws_instance.installer.ami
}

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
