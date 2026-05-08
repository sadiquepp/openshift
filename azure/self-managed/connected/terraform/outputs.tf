output "azure_subscription_id" {
  description = "Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

output "azure_tenant_id" {
  description = "Azure tenant ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_region" {
  description = "Azure region"
  value       = var.azure_region
}

# ── Resource Group ───────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the infra resource group"
  value       = azurerm_resource_group.main.name
}

output "cluster_resource_group_name" {
  description = "Name of the cluster resource group (used by openshift-install)"
  value       = azurerm_resource_group.cluster.name
}

# ── Connected VNet ────────────────────────────────────────────────────────────

output "connected_vnet_id" {
  description = "ID of the connected VNet"
  value       = azurerm_virtual_network.connected.id
}

output "connected_vnet_name" {
  description = "Name of the connected VNet"
  value       = azurerm_virtual_network.connected.name
}

output "connected_subnet_ids" {
  description = "IDs of the connected subnets"
  value       = azurerm_subnet.connected[*].id
}

output "connected_subnet_names" {
  description = "Names of the connected subnets"
  value       = azurerm_subnet.connected[*].name
}

# ── NAT Gateway ──────────────────────────────────────────────────────────────

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT Gateway (outbound IP for OpenShift nodes)"
  value       = azurerm_public_ip.nat.ip_address
}

# ── Service Principal ─────────────────────────────────────────────────────────

output "installer_sp_client_id" {
  description = "Service principal client ID (auto-created or user-provided; empty when using VM identity)"
  value       = local.use_service_principal ? local.sp_client_id : ""
}

# ── Identity ─────────────────────────────────────────────────────────────────

output "managed_identity_client_id" {
  description = "Client ID of the managed identity for OCP installer"
  value       = azurerm_user_assigned_identity.ocp_install.client_id
}

output "managed_identity_principal_id" {
  description = "Principal ID of the managed identity"
  value       = azurerm_user_assigned_identity.ocp_install.principal_id
}

# ── DNS ──────────────────────────────────────────────────────────────────────

output "cluster_domain" {
  description = "Fully qualified cluster domain"
  value       = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
}

# ── Bastion VM ───────────────────────────────────────────────────────────────

output "bastion_vm_id" {
  description = "Resource ID of the bastion VM"
  value       = azurerm_linux_virtual_machine.bastion.id
}

output "bastion_public_ip" {
  description = "Public IP of the bastion VM"
  value       = azurerm_public_ip.bastion.ip_address
}

output "bastion_private_ip" {
  description = "Private IP of the bastion VM"
  value       = azurerm_network_interface.bastion.private_ip_address
}
