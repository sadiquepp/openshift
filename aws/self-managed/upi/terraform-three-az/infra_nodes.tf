locals {
  infra_nodes = var.create_infra_nodes ? {
    "1" = { subnet = var.subnet_id_az1, ip = var.infra1_private_ip }
    "2" = { subnet = var.subnet_id_az2, ip = var.infra2_private_ip }
    "3" = { subnet = var.subnet_id_az3, ip = var.infra3_private_ip }
  } : {}
}

resource "aws_instance" "infra" {
  for_each = local.infra_nodes

  ami                  = var.rhcos_ami_id
  instance_type        = var.infra_instance_type
  iam_instance_profile = aws_iam_instance_profile.worker.name

  network_interface {
    network_interface_id = aws_network_interface.infra[each.key].id
    device_index         = 0
  }

  root_block_device {
    volume_size = 120
    volume_type = "gp3"
  }

  # Infra nodes boot as workers — they are re-labelled after the cluster is up
  user_data = local.worker_ignition_userdata

  tags = merge(local.common_tags, {
    Name = "${local.infra_id}-infra-${each.key}"
  })

  depends_on = [aws_iam_instance_profile.worker]
}

resource "aws_network_interface" "infra" {
  for_each = local.infra_nodes

  subnet_id       = each.value.subnet
  private_ips     = [each.value.ip]
  security_groups = [aws_security_group.worker.id]
  tags            = { Name = "${local.infra_id}-infra-${each.key}-eni" }
}
