# Generate an Ansible inventory targeting the bastion VM.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i terraform/inventory.ini setup-bastion-vm-connected.yaml

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [ibmcloud_vm]
    ${ibm_is_floating_ip.bastion.address}

    [ibmcloud_vm:vars]
    ansible_user=root
    ansible_ssh_private_key_file=${var.ssh_private_key_path}
    ansible_ssh_common_args=-o StrictHostKeyChecking=no
  INI
}

# Generate an Ansible extra-vars file that passes Terraform-managed values
# (VPC, subnets, API key) into the playbook.
# Usage:  ansible-playbook ... -e @terraform/ansible-vars.json

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0600"

  content = jsonencode({
    prefix_for_name                          = var.prefix_for_name
    ibmcloud_region                          = var.ibmcloud_region
    ibmcloud_api_key                         = var.ibmcloud_api_key
    resource_group_name                      = var.resource_group_name
    openshift_base_domain                    = var.openshift_base_domain
    openshift_cluster_name_suffix            = var.openshift_cluster_name_suffix
    ssh_public_key_for_vm_and_openshift_node = var.ssh_public_key
    connected_vpc_name                       = ibm_is_vpc.connected.name
    connected_vpc_cidr                       = var.connected_vpc_cidr
    control_plane_subnet_names               = ibm_is_subnet.control_plane[*].name
    compute_subnet_names                     = ibm_is_subnet.compute[*].name
  })
}
