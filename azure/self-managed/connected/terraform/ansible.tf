# Generate an Ansible inventory targeting the bastion VM.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i terraform/inventory.ini setup-bastion-vm-connected.yaml

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

# Generate an Ansible extra-vars file that passes Terraform-managed values
# (RG names, VNet, subnets, SP credentials) into the playbook.
# Usage:  ansible-playbook ... -e @terraform/ansible-vars.json

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode({
    prefix_for_name                          = var.prefix_for_name
    azure_region                             = var.azure_region
    azure_subscription_id                    = data.azurerm_client_config.current.subscription_id
    azure_tenant_id                          = data.azurerm_client_config.current.tenant_id
    openshift_base_domain                    = var.openshift_base_domain
    openshift_cluster_name_suffix            = var.openshift_cluster_name_suffix
    ssh_public_key_for_vm_and_openshift_node = var.ssh_public_key
    resource_group_name                      = azurerm_resource_group.main.name
    cluster_resource_group_name              = azurerm_resource_group.cluster.name
    connected_vnet_name                      = azurerm_virtual_network.connected.name
    connected_vnet_cidr                      = var.connected_vnet_cidr
    connected_subnet_name_a                  = azurerm_subnet.connected[0].name
    connected_subnet_name_b                  = azurerm_subnet.connected[1].name
    connected_subnet_name_c                  = azurerm_subnet.connected[2].name
    network_resource_group_name              = azurerm_resource_group.main.name
    use_service_principal                    = local.use_service_principal
    installer_sp_client_id                   = local.sp_client_id
    installer_sp_client_secret               = local.sp_client_secret
  })
}
