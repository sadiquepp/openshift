# ── RHEL 9 AMI Lookup ─────────────────────────────────────────────────────────

data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat's official AWS account

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ── SSH Key Pair ──────────────────────────────────────────────────────────────

resource "aws_key_pair" "installer" {
  key_name   = "${var.prefix_for_name}_ansible"
  public_key = var.ssh_public_key
}

# ── Security Group for Installer EC2 ─────────────────────────────────────────

resource "aws_security_group" "installer" {
  name        = "ping_ssh_8443"
  description = "Security group for Mirror Registry to use 22, 8443 and ICMP"
  vpc_id      = aws_vpc.egress.id

  ingress {
    description = "Mirror registry and proxy from disconnected + egress VPCs"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr, var.egress_vpc_cidr]
  }

  ingress {
    description = "Squid proxy from disconnected + egress VPCs"
    from_port   = 3128
    to_port     = 3128
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr, var.egress_vpc_cidr]
  }

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "VNC / auxiliary access"
    from_port   = 5999
    to_port     = 5999
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ping_ssh_8443"
  }
}

# ── Installer EC2 Instance ───────────────────────────────────────────────────

resource "aws_instance" "installer" {
  ami                         = var.installer_ami != "" ? var.installer_ami : data.aws_ami.rhel9.id
  instance_type               = var.installer_instance_type
  subnet_id                   = aws_subnet.egress_public[0].id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.installer.key_name
  vpc_security_group_ids      = [aws_security_group.installer.id]
  iam_instance_profile        = aws_iam_instance_profile.ocp_install_ec2.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.installer_disk_size
    delete_on_termination = true
  }

  tags = {
    Name       = "${local.openshift_cluster_name}-installer"
    Automation = "ocp_installer"
  }
}
