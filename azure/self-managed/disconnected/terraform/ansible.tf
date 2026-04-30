resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [azure_vm]
    ${azurerm_public_ip.bastion.ip_address}

    [azure_vm:vars]
    ansible_user=${var.admin_username}
    ansible_ssh_private_key_file=${var.ssh_private_key_path}
    ansible_ssh_common_args=-o StrictHostKeyChecking=no
  INI
}

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode({
    prefix_for_name                            = var.prefix_for_name
    azure_region                               = var.azure_region
    azure_subscription_id                      = data.azurerm_client_config.current.subscription_id
    azure_tenant_id                            = data.azurerm_client_config.current.tenant_id
    openshift_base_domain                      = var.openshift_base_domain
    openshift_cluster_name_suffix              = var.openshift_cluster_name_suffix
    ssh_public_key_for_vm_and_openshift_node   = var.ssh_public_key
    resource_group_name                        = azurerm_resource_group.main.name
    disconnected_vnet_name                     = azurerm_virtual_network.disconnected.name
    disconnected_vnet_id                       = azurerm_virtual_network.disconnected.id
    disconnected_vnet_cidr                     = var.disconnected_vnet_cidr
    disconnected_subnet_name_a                 = azurerm_subnet.disconnected[0].name
    disconnected_subnet_name_b                 = azurerm_subnet.disconnected[1].name
    disconnected_subnet_name_c                 = azurerm_subnet.disconnected[2].name
    disconnected_subnet_id_a                   = azurerm_subnet.disconnected[0].id
    disconnected_subnet_id_b                   = azurerm_subnet.disconnected[1].id
    disconnected_subnet_id_c                   = azurerm_subnet.disconnected[2].id
    egress_vnet_id                             = azurerm_virtual_network.egress.id
    storage_account_name                       = azurerm_storage_account.mirror.name
    managed_identity_client_id                 = azurerm_user_assigned_identity.ocp_install.client_id
    network_resource_group_name                = azurerm_resource_group.main.name
    bastion_private_ip                         = azurerm_network_interface.bastion.private_ip_address
    installer_sp_client_id                     = local.sp_client_id
    installer_sp_client_secret                 = local.sp_client_secret
  })
}
