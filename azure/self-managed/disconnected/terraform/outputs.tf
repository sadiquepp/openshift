output "azure_subscription_id" {
  description = "Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

output "azure_tenant_id" {
  description = "Azure tenant ID"
  value       = data.azurerm_client_config.current.tenant_id
}

# ── Resource Group ───────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

# ── Disconnected VNet ────────────────────────────────────────────────────────

output "disconnected_vnet_id" {
  description = "ID of the disconnected VNet"
  value       = azurerm_virtual_network.disconnected.id
}

output "disconnected_vnet_name" {
  description = "Name of the disconnected VNet"
  value       = azurerm_virtual_network.disconnected.name
}

output "disconnected_subnet_ids" {
  description = "IDs of the disconnected private subnets"
  value       = azurerm_subnet.disconnected[*].id
}

output "disconnected_subnet_names" {
  description = "Names of the disconnected private subnets"
  value       = azurerm_subnet.disconnected[*].name
}

# ── Egress VNet ──────────────────────────────────────────────────────────────

output "egress_vnet_id" {
  description = "ID of the egress VNet"
  value       = azurerm_virtual_network.egress.id
}

# ── Firewall ─────────────────────────────────────────────────────────────────

output "firewall_private_ip" {
  description = "Private IP of the Azure Firewall (used as UDR next hop)"
  value       = azurerm_firewall.main.ip_configuration[0].private_ip_address
}

output "firewall_public_ip" {
  description = "Public IP of the Azure Firewall"
  value       = azurerm_public_ip.firewall.ip_address
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

output "private_dns_zone_id" {
  description = "Azure Private DNS zone ID for the cluster domain"
  value       = azurerm_private_dns_zone.cluster.id
}

output "private_dns_zone_name" {
  description = "Private DNS zone name"
  value       = azurerm_private_dns_zone.cluster.name
}

output "cluster_domain" {
  description = "Fully qualified cluster domain"
  value       = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
}

# ── Storage ──────────────────────────────────────────────────────────────────

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.mirror.name
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
