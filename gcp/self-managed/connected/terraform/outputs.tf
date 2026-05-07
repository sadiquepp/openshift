output "gcp_project_id" {
  description = "GCP project ID"
  value       = var.gcp_project_id
}

output "gcp_region" {
  description = "GCP region"
  value       = var.gcp_region
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

output "connected_vpc_name" {
  description = "Name of the connected VPC"
  value       = google_compute_network.connected.name
}

output "connected_vpc_id" {
  description = "Self-link of the connected VPC"
  value       = google_compute_network.connected.id
}

output "control_plane_subnet_name" {
  description = "Name of the control-plane subnet"
  value       = google_compute_subnetwork.control_plane.name
}

output "compute_subnet_name" {
  description = "Name of the compute subnet"
  value       = google_compute_subnetwork.compute.name
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "bastion_service_account_email" {
  description = "Email of the bastion VM service account"
  value       = google_service_account.bastion.email
}

# ── DNS ───────────────────────────────────────────────────────────────────────

output "cluster_domain" {
  description = "Fully qualified cluster domain"
  value       = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
}

# ── Bastion VM ────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "External IP of the bastion VM"
  value       = google_compute_address.bastion.address
}

output "bastion_private_ip" {
  description = "Internal IP of the bastion VM"
  value       = google_compute_instance.bastion.network_interface[0].network_ip
}

output "bastion_name" {
  description = "Name of the bastion VM"
  value       = google_compute_instance.bastion.name
}

output "admin_username" {
  description = "SSH user for the bastion VM"
  value       = var.admin_username
}

output "ssh_private_key_path" {
  description = "SSH private key path"
  value       = var.ssh_private_key_path
}
