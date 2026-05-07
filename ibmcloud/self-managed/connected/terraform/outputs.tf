output "ibmcloud_region" {
  description = "IBM Cloud region"
  value       = var.ibmcloud_region
}

output "resource_group_name" {
  description = "Resource group name"
  value       = var.resource_group_name
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

output "connected_vpc_name" {
  description = "Name of the connected VPC"
  value       = ibm_is_vpc.connected.name
}

output "connected_vpc_id" {
  description = "ID of the connected VPC"
  value       = ibm_is_vpc.connected.id
}

output "control_plane_subnet_names" {
  description = "Names of the control-plane subnets"
  value       = ibm_is_subnet.control_plane[*].name
}

output "compute_subnet_names" {
  description = "Names of the compute subnets"
  value       = ibm_is_subnet.compute[*].name
}

# ── DNS ───────────────────────────────────────────────────────────────────────

output "cluster_domain" {
  description = "Fully qualified cluster domain"
  value       = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
}

# ── Bastion VM ────────────────────────────────────────────────────────────────

output "bastion_floating_ip" {
  description = "Floating IP of the bastion VM"
  value       = ibm_is_floating_ip.bastion.address
}

output "bastion_private_ip" {
  description = "Private IP of the bastion VM"
  value       = ibm_is_instance.bastion.primary_network_interface[0].primary_ip[0].address
}

output "bastion_name" {
  description = "Name of the bastion VM"
  value       = ibm_is_instance.bastion.name
}

output "ssh_private_key_path" {
  description = "SSH private key path"
  value       = var.ssh_private_key_path
}
