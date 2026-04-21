output "master_security_group_id" {
  description = "Master security group ID — add to external LB backend on 6443 and 22623"
  value       = aws_security_group.master.id
}

output "worker_security_group_id" {
  description = "Worker security group ID — add to external LB backend on 443, 80, 1936"
  value       = aws_security_group.worker.id
}

output "master_instance_profile" {
  description = "Master IAM instance profile name"
  value       = aws_iam_instance_profile.master.name
}

output "worker_instance_profile" {
  description = "Worker IAM instance profile name"
  value       = aws_iam_instance_profile.worker.name
}

output "bootstrap_instance_id" {
  description = "Bootstrap EC2 instance ID — terminate after cluster install completes"
  value       = aws_instance.bootstrap.id
}

output "bootstrap_private_ip" {
  description = "Bootstrap node private IP address"
  value       = var.bootstrap_private_ip
}

output "master_private_ips" {
  description = "Control plane node private IP addresses"
  value = {
    master0 = var.master0_private_ip
    master1 = var.master1_private_ip
    master2 = var.master2_private_ip
  }
}

output "worker_private_ips" {
  description = "Worker node private IP addresses"
  value = {
    worker1 = var.worker1_private_ip
    worker2 = var.worker2_private_ip
    worker3 = var.worker3_private_ip
  }
}

output "infra_private_ips" {
  description = "Infra node private IP addresses (empty if create_infra_nodes = false)"
  value = {
    for k, v in local.infra_nodes : "infra${k}" => v.ip
  }
}

# ── DNS ───────────────────────────────────────────────────────────────────────

output "hosted_zone_id" {
  description = "Route53 private hosted zone ID created for the UPI cluster"
  value       = aws_route53_zone.cluster.zone_id
}

output "hosted_zone_name" {
  description = "Route53 private hosted zone name (cluster_name.cluster_domain)"
  value       = aws_route53_zone.cluster.name
}

# ── NLB (only when create_nlb_and_dns = true) ─────────────────────────────────

output "nlb_dns_name" {
  description = "NLB DNS name — api/api-int/apps records point here (empty when create_nlb_and_dns = false)"
  value       = var.create_nlb_and_dns ? aws_lb.cluster[0].dns_name : ""
}

output "nlb_arn" {
  description = "NLB ARN (empty when create_nlb_and_dns = false)"
  value       = var.create_nlb_and_dns ? aws_lb.cluster[0].arn : ""
}

# ── Post-install commands ─────────────────────────────────────────────────────

output "bootstrap_terminate_command" {
  description = "Command to destroy bootstrap resources once the cluster is healthy"
  value = join(" ", concat(
    [
      "terraform destroy",
      "-target=aws_instance.bootstrap",
      "-target=aws_network_interface.bootstrap",
      "-target=aws_security_group.bootstrap",
    ],
    var.create_nlb_and_dns ? [
      "-target=aws_lb_target_group_attachment.api[\\\"bootstrap\\\"]",
      "-target=aws_lb_target_group_attachment.mcs[\\\"bootstrap\\\"]",
    ] : []
  ))
}
