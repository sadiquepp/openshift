locals {
  master_ignition_userdata = jsonencode({
    ignition = {
      version = "3.1.0"
      config = {
        merge = [{ source = local.master_ignition_location }]
      }
      security = {
        tls = {
          certificateAuthorities = [{ source = var.certificate_authority }]
        }
      }
    }
  })
}

resource "aws_instance" "master" {
  for_each = {
    "0" = { subnet = var.subnet_id_az1, ip = var.master0_private_ip }
    "1" = { subnet = var.subnet_id_az2, ip = var.master1_private_ip }
    "2" = { subnet = var.subnet_id_az3, ip = var.master2_private_ip }
  }

  ami                  = var.rhcos_ami_id
  instance_type        = var.master_instance_type
  iam_instance_profile = aws_iam_instance_profile.master.name

  network_interface {
    network_interface_id = aws_network_interface.master[each.key].id
    device_index         = 0
  }

  root_block_device {
    volume_size = 120
    volume_type = "gp3"
  }

  user_data = local.master_ignition_userdata

  tags = merge(local.common_tags, {
    Name = "${local.infra_id}-master-${each.key}"
  })

  depends_on = [aws_iam_instance_profile.master]
}

resource "aws_network_interface" "master" {
  for_each = {
    "0" = { subnet = var.subnet_id_az1, ip = var.master0_private_ip }
    "1" = { subnet = var.subnet_id_az2, ip = var.master1_private_ip }
    "2" = { subnet = var.subnet_id_az3, ip = var.master2_private_ip }
  }

  subnet_id       = each.value.subnet
  private_ips     = [each.value.ip]
  security_groups = [aws_security_group.master.id]
  tags            = { Name = "${local.infra_id}-master-${each.key}-eni" }
}
