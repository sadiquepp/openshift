# ── Bootstrap security group ───────────────────────────────────────────────────

resource "aws_security_group" "bootstrap" {
  name        = "${local.infra_id}-bootstrap-sg"
  description = "Cluster Bootstrap Security Group"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.allowed_bootstrap_ssh_cidr]
  }

  ingress {
    description = "Journal log port"
    protocol    = "tcp"
    from_port   = 19531
    to_port     = 19531
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.infra_id}-bootstrap-sg" }
}

# ── Bootstrap EC2 instance ─────────────────────────────────────────────────────

resource "aws_instance" "bootstrap" {
  ami                  = var.rhcos_ami_id
  instance_type        = var.bootstrap_instance_type
  iam_instance_profile = aws_iam_instance_profile.bootstrap.name

  network_interface {
    network_interface_id = aws_network_interface.bootstrap.id
    device_index         = 0
  }

  user_data = jsonencode({
    ignition = {
      version = "3.1.0"
      config = {
        replace = {
          source = local.bootstrap_ignition_location
        }
      }
    }
  })

  tags = merge(local.common_tags, {
    Name = "${local.infra_id}-bootstrap"
  })

  depends_on = [aws_iam_instance_profile.bootstrap]
}

resource "aws_network_interface" "bootstrap" {
  subnet_id       = var.bootstrap_subnet_id
  private_ips     = [var.bootstrap_private_ip]
  security_groups = [aws_security_group.bootstrap.id, aws_security_group.master.id]
  tags            = { Name = "${local.infra_id}-bootstrap-eni" }
}
