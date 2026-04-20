locals {
  worker_ignition_userdata = jsonencode({
    ignition = {
      version = "3.1.0"
      config = {
        merge = [{ source = local.worker_ignition_location }]
      }
      security = {
        tls = {
          certificateAuthorities = [{ source = var.certificate_authority }]
        }
      }
    }
  })
}

resource "aws_instance" "worker" {
  for_each = {
    "1" = { subnet = var.subnet_id_az1, ip = var.worker1_private_ip }
    "2" = { subnet = var.subnet_id_az2, ip = var.worker2_private_ip }
    "3" = { subnet = var.subnet_id_az3, ip = var.worker3_private_ip }
  }

  ami                  = var.rhcos_ami_id
  instance_type        = var.worker_instance_type
  iam_instance_profile = aws_iam_instance_profile.worker.name

  network_interface {
    network_interface_id = aws_network_interface.worker[each.key].id
    device_index         = 0
  }

  root_block_device {
    volume_size = 120
    volume_type = "gp3"
  }

  user_data = local.worker_ignition_userdata

  tags = merge(local.common_tags, {
    Name = "${local.infra_id}-worker-${each.key}"
  })

  depends_on = [aws_iam_instance_profile.worker]
}

resource "aws_network_interface" "worker" {
  for_each = {
    "1" = { subnet = var.subnet_id_az1, ip = var.worker1_private_ip }
    "2" = { subnet = var.subnet_id_az2, ip = var.worker2_private_ip }
    "3" = { subnet = var.subnet_id_az3, ip = var.worker3_private_ip }
  }

  subnet_id       = each.value.subnet
  private_ips     = [each.value.ip]
  security_groups = [aws_security_group.worker.id]
  tags            = { Name = "${local.infra_id}-worker-${each.key}-eni" }
}
