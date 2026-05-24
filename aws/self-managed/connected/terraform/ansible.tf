# Generate an Ansible inventory targeting the installer EC2 instance.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i terraform/inventory.ini setup-bastion-ec2-connected.yaml

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [bastion]
    ${aws_instance.installer.public_ip}

    [bastion:vars]
    ansible_user=ec2-user
    ansible_ssh_private_key_file=${var.ssh_private_key_path}
    ansible_ssh_common_args=-o StrictHostKeyChecking=no
  INI
}

# Generate an Ansible extra-vars file that passes Terraform-managed values
# (VPC IDs, subnet IDs, hosted zone, account number) into the playbook.
# Usage:  ansible-playbook ... -e @terraform/ansible-vars.json

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode(merge(
    {
      prefix_for_name                            = var.prefix_for_name
      aws_region                                 = var.aws_region
      openshift_base_domain                      = var.openshift_base_domain
      openshift_cluster_name_suffix              = var.openshift_cluster_name_suffix
      ssh_public_key_for_ec2_and_openshit_node   = var.ssh_public_key
      vpc_owner_aws_account_number               = data.aws_caller_identity.current.account_id
      aws_account_number                         = data.aws_caller_identity.current.account_id
      connected_vpc_id                           = aws_vpc.connected.id
      connected_vpc_cidr                         = aws_vpc.connected.cidr_block
      connected_subnet_id_a                      = aws_subnet.private[0].id
      connected_subnet_id_b                      = aws_subnet.private[1].id
      connected_subnet_id_c                      = aws_subnet.private[2].id
      connected_public_subnet_id_a               = aws_subnet.public[0].id
      connected_public_subnet_id_b               = aws_subnet.public[1].id
      connected_public_subnet_id_c               = aws_subnet.public[2].id
      compute_instance_type                      = var.compute_instance_type
      compute_replicas                           = var.compute_replicas
      control_plane_replicas                     = var.control_plane_replicas
      hcp_cluster_suffixes                       = var.hcp_cluster_suffixes
    },
    local.hcp_enabled ? {
      hcp_public_zone_id = data.aws_route53_zone.public[0].zone_id
      hcp_private_zone_ids = {
        for suffix in var.hcp_cluster_suffixes : suffix => aws_route53_zone.hcp_private[suffix].zone_id
      }
      hcp_sa_signing_keys = {
        for suffix in var.hcp_cluster_suffixes : suffix => tls_private_key.hcp_sa[suffix].private_key_pem
      }
      hcp_issuer_urls = {
        for suffix, cluster in local.hcp_cluster_issuer : suffix => cluster.issuer_url
      }
    } : {
      hcp_public_zone_id   = ""
      hcp_private_zone_ids = {}
      hcp_sa_signing_keys  = {}
      hcp_issuer_urls      = {}
    }
  ))
}
