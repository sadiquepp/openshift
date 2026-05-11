# Generate an Ansible inventory targeting the bastion VM.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i terraform/inventory.ini setup-bastion-vm-connected.yaml

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [bastion]
    ${google_compute_address.bastion.address}

    [bastion:vars]
    ansible_user=${var.admin_username}
    ansible_ssh_private_key_file=${var.ssh_private_key_path}
    ansible_ssh_common_args=-o StrictHostKeyChecking=no
  INI
}

# Generate an Ansible extra-vars file that passes Terraform-managed values
# (project, VPC, subnets, SA) into the playbook.
# Usage:  ansible-playbook ... -e @terraform/ansible-vars.json

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode({
    prefix_for_name                          = var.prefix_for_name
    gcp_project_id                           = var.gcp_project_id
    gcp_region                               = var.gcp_region
    openshift_base_domain                    = var.openshift_base_domain
    openshift_cluster_name_suffix            = var.openshift_cluster_name_suffix
    ssh_public_key_for_vm_and_openshift_node = var.ssh_public_key
    connected_vpc_name                       = google_compute_network.connected.name
    connected_vpc_cidr                       = var.connected_vpc_cidr
    control_plane_subnet_name                = google_compute_subnetwork.control_plane.name
    compute_subnet_name                      = google_compute_subnetwork.compute.name
    bastion_service_account_email            = google_service_account.bastion.email
    installer_sa_key_file                    = var.installer_sa_key_file
    use_service_account_key                  = var.use_service_account_key
  })
}
