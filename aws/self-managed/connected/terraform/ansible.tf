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
      prefix_for_name                          = var.prefix_for_name
      aws_region                               = var.aws_region
      openshift_base_domain                    = var.openshift_base_domain
      openshift_cluster_name_suffix            = var.openshift_cluster_name_suffix
      ssh_public_key_for_ec2_and_openshit_node = var.ssh_public_key
      vpc_owner_aws_account_number             = data.aws_caller_identity.current.account_id
      aws_account_number                       = data.aws_caller_identity.current.account_id
      connected_vpc_id                         = aws_vpc.connected.id
      connected_vpc_cidr                       = aws_vpc.connected.cidr_block
      connected_subnet_id_a                    = aws_subnet.private[0].id
      connected_subnet_id_b                    = aws_subnet.private[1].id
      connected_subnet_id_c                    = aws_subnet.private[2].id
      connected_public_subnet_id_a             = aws_subnet.public[0].id
      connected_public_subnet_id_b             = aws_subnet.public[1].id
      connected_public_subnet_id_c             = aws_subnet.public[2].id
      compute_instance_type                    = var.compute_instance_type
      compute_replicas                         = var.compute_replicas
      control_plane_replicas                   = var.control_plane_replicas
      hcp_cluster_suffixes                     = var.hcp_cluster_suffixes
      hcp_xacct_cluster_suffixes               = var.hcp_xacct_cluster_suffixes
      hcp_separate_vpc                         = var.hcp_separate_vpc
      hcp_vpc_suffixes                         = local.hcp_vpc_suffixes
      letsencrypt_enabled                      = var.letsencrypt_enabled
      letsencrypt_cert_pem                     = var.letsencrypt_enabled ? acme_certificate.cluster[0].certificate_pem : ""
      letsencrypt_key_pem                      = var.letsencrypt_enabled ? acme_certificate.cluster[0].private_key_pem : ""
      letsencrypt_issuer_pem                   = var.letsencrypt_enabled ? acme_certificate.cluster[0].issuer_pem : ""
    },
    local.hcp_enabled ? {
      hcp_account_numbers        = local.hcp_account_numbers
      hcp_base_domains           = local.hcp_base_domains
      hcp_public_zone_ids        = local.hcp_public_zone_ids
      hcp_private_zone_ids       = local.hcp_private_zone_ids_merged
      hcp_pvt_private_zone_ids   = local.hcp_pvt_private_zone_ids_merged
      hcp_pvtpl_private_zone_ids = local.hcp_pvtpl_private_zone_ids_merged
      hcp_sa_signing_keys = {
        for suffix in local.hcp_all_suffixes : suffix => tls_private_key.hcp_sa[suffix].private_key_pem
      }
      hcp_issuer_urls = {
        for suffix, cluster in local.hcp_all_cluster_issuer : suffix => cluster.issuer_url
      }
      hcp_pl_access_key_id     = aws_iam_access_key.hcp_privatelink[0].id
      hcp_pl_secret_access_key = aws_iam_access_key.hcp_privatelink[0].secret
      hcp_oidc_bucket_name     = aws_s3_bucket.hcp_oidc[0].id
      hcp_vpc_ids              = local.hcp_vpc_ids
      hcp_vpc_cidrs            = local.hcp_vpc_cidrs
      hcp_subnet_ids_a         = local.hcp_subnet_ids_a
      hcp_subnet_ids_b         = local.hcp_subnet_ids_b
      hcp_subnet_ids_c         = local.hcp_subnet_ids_c
    } : {
      hcp_account_numbers        = {}
      hcp_base_domains           = {}
      hcp_public_zone_ids        = {}
      hcp_private_zone_ids       = {}
      hcp_pvt_private_zone_ids   = {}
      hcp_pvtpl_private_zone_ids = {}
      hcp_sa_signing_keys        = {}
      hcp_issuer_urls            = {}
      hcp_pl_access_key_id       = ""
      hcp_pl_secret_access_key   = ""
      hcp_oidc_bucket_name       = ""
      hcp_vpc_ids                = {}
      hcp_vpc_cidrs              = {}
      hcp_subnet_ids_a           = {}
      hcp_subnet_ids_b           = {}
      hcp_subnet_ids_c           = {}
    }
  ))
}
