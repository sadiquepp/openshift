# Generate an Ansible inventory targeting the installer EC2 instance.
# After `terraform apply`, the setup-bastion playbook can be run with:
#   ansible-playbook -i ../terraform/inventory.ini ../setup-bastion-ec2.yaml

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [aws_ec2]
    ${aws_instance.installer.public_ip}

    [aws_ec2:vars]
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

  content = jsonencode({
    prefix_for_name                 = var.prefix_for_name
    aws_region                      = var.aws_region
    openshift_base_domain           = var.openshift_base_domain
    openshift_cluster_name_suffix   = var.openshift_cluster_name_suffix
    vpc_owner_aws_account_number    = data.aws_caller_identity.current.account_id
    hosted_zone_id_for_domain       = aws_route53_zone.cluster.zone_id
    disconnected_vpc_id             = aws_vpc.disconnected.id
    disconnected_vpc_cidr           = aws_vpc.disconnected.cidr_block
    disconnected_subnet_id_a        = aws_subnet.disconnected[0].id
    disconnected_subnet_id_b        = aws_subnet.disconnected[1].id
    disconnected_subnet_id_c        = aws_subnet.disconnected[2].id
    egress_vpc_id                   = aws_vpc.egress.id
  })
}
