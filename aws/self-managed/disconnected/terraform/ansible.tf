# Generate an Ansible inventory targeting the installer EC2 instance.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i ../terraform/inventory.ini ../setup-bastion-ec2.yaml

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
# (VPC IDs, hosted zone, account number) into the setup-bastion playbook.
# Usage:  ansible-playbook ... -e @../terraform/ansible-vars.json

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode(merge(
    {
      prefix_for_name                 = var.prefix_for_name
      aws_region                      = var.aws_region
      aws_account_number              = data.aws_caller_identity.current.account_id
      openshift_base_domain           = var.openshift_base_domain
      openshift_cluster_name_suffix   = var.openshift_cluster_name_suffix
      compute_replicas                = var.compute_replicas
      ssh_public_key_for_ec2_and_openshit_node  = var.ssh_public_key
      vpc_owner_aws_account_number    = data.aws_caller_identity.current.account_id
      hosted_zone_id_for_domain       = aws_route53_zone.cluster.zone_id
      disconnected_vpc_id             = aws_vpc.disconnected.id
      disconnected_vpc_cidr           = aws_vpc.disconnected.cidr_block
      disconnected_subnet_id_a        = aws_subnet.disconnected[0].id
      disconnected_subnet_id_b        = aws_subnet.disconnected[1].id
      disconnected_subnet_id_c        = aws_subnet.disconnected[2].id
      disconnected_subnet_id_a_cidr   = aws_subnet.disconnected[0].cidr_block
      disconnected_subnet_id_b_cidr   = aws_subnet.disconnected[1].cidr_block
      disconnected_subnet_id_c_cidr   = aws_subnet.disconnected[2].cidr_block
      egress_vpc_id                   = aws_vpc.egress.id
      hcp_cluster_suffixes            = var.hcp_cluster_suffixes
      hcp_workaround_enabled          = var.hcp_workaround_enabled
      upi_bootstrap_ip = cidrhost(var.disconnected_subnet_cidrs[0], var.upi_node_host_numbers.bootstrap)
      upi_master0_ip   = cidrhost(var.disconnected_subnet_cidrs[0], var.upi_node_host_numbers.master0)
      upi_master1_ip   = cidrhost(var.disconnected_subnet_cidrs[1], var.upi_node_host_numbers.master1)
      upi_master2_ip   = cidrhost(var.disconnected_subnet_cidrs[2], var.upi_node_host_numbers.master2)
      upi_worker1_ip   = cidrhost(var.disconnected_subnet_cidrs[0], var.upi_node_host_numbers.worker1)
      upi_worker2_ip   = cidrhost(var.disconnected_subnet_cidrs[1], var.upi_node_host_numbers.worker2)
      upi_worker3_ip   = cidrhost(var.disconnected_subnet_cidrs[2], var.upi_node_host_numbers.worker3)
      upi_infra1_ip    = cidrhost(var.disconnected_subnet_cidrs[0], var.upi_node_host_numbers.infra1)
      upi_infra2_ip    = cidrhost(var.disconnected_subnet_cidrs[1], var.upi_node_host_numbers.infra2)
      upi_infra3_ip    = cidrhost(var.disconnected_subnet_cidrs[2], var.upi_node_host_numbers.infra3)
    },
    local.hcp_enabled ? {
      hcp_account_numbers      = local.hcp_account_numbers
      hcp_base_domains         = local.hcp_base_domains
      hcp_public_zone_ids      = local.hcp_public_zone_ids
      hcp_pvt_private_zone_ids = local.hcp_pvt_private_zone_ids
      hcp_sa_signing_keys = {
        for suffix in var.hcp_cluster_suffixes : suffix => tls_private_key.hcp_sa[suffix].private_key_pem
      }
      hcp_issuer_urls = {
        for suffix, cluster in local.hcp_cluster_issuer : suffix => cluster.issuer_url
      }
      hcp_pl_access_key_id       = aws_iam_access_key.hcp_privatelink[0].id
      hcp_pl_secret_access_key   = aws_iam_access_key.hcp_privatelink[0].secret
      hcp_ext_dns_access_key_id  = aws_iam_access_key.hcp_external_dns[0].id
      hcp_ext_dns_secret_access_key = aws_iam_access_key.hcp_external_dns[0].secret
      hcp_oidc_bucket_name       = aws_s3_bucket.hcp_oidc[0].id
    } : {
      hcp_account_numbers           = {}
      hcp_base_domains              = {}
      hcp_public_zone_ids           = {}
      hcp_pvt_private_zone_ids      = {}
      hcp_sa_signing_keys           = {}
      hcp_issuer_urls               = {}
      hcp_pl_access_key_id          = ""
      hcp_pl_secret_access_key      = ""
      hcp_ext_dns_access_key_id     = ""
      hcp_ext_dns_secret_access_key = ""
      hcp_oidc_bucket_name          = ""
    }
  ))
}
