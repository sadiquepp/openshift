output "gcp_project_id" {
  description = "GCP project ID"
  value       = var.gcp_project_id
}

output "gcp_region" {
  description = "GCP region"
  value       = var.gcp_region
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

output "disconnected_vpc_name" {
  description = "Name of the disconnected VPC"
  value       = google_compute_network.disconnected.name
}

output "disconnected_vpc_id" {
  description = "Self-link of the disconnected VPC"
  value       = google_compute_network.disconnected.id
}

output "control_plane_subnet_name" {
  description = "Name of the control-plane subnet"
  value       = google_compute_subnetwork.control_plane.name
}

output "compute_subnet_name" {
  description = "Name of the compute subnet"
  value       = google_compute_subnetwork.compute.name
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

output "egress_vpc_name" {
  description = "Name of the egress VPC"
  value       = google_compute_network.egress.name
}

# ── PSC ───────────────────────────────────────────────────────────────────────

output "psc_endpoint_ip" {
  description = "Private IP of the PSC endpoint for Google APIs"
  value       = google_compute_global_address.psc_apis.address
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
