# ─────────────────────────────────────────
# SSH Key Pair
# ─────────────────────────────────────────

resource "aws_key_pair" "installer" {
  key_name   = local.key_name
  public_key = var.ssh_public_key

  tags = {
    Name = local.key_name
  }
}

# ─────────────────────────────────────────
# IAM Role
# The Ansible playbook re-creates the same
# role that tf-disconnected already created.
# We reference it here rather than recreate
# it to avoid a duplicate-resource conflict.
# ─────────────────────────────────────────

data "aws_iam_instance_profile" "ocp_install" {
  name = local.iam_role_name
}

# ─────────────────────────────────────────
# Security Group
# Placed in the egress VPC (the shared VPC
# visible to this installer account).
# ─────────────────────────────────────────

resource "aws_security_group" "installer" {
  name        = local.sg_name
  description = "Security group for Mirror Registry to use 22, 8443, 3128 and icmp"
  vpc_id      = var.egress_vpc_id

  # Mirror registry (8443) and squid proxy (3128) — from both VPC CIDRs only
  ingress {
    description = "Mirror registry and squid from disconnected VPC"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr, var.egress_vpc_cidr]
  }

  ingress {
    description = "Squid proxy from both VPCs"
    from_port   = 3128
    to_port     = 3128
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr, var.egress_vpc_cidr]
  }

  # SSH and VNC — open to the world (matches Ansible rule: cidr_ip: 0.0.0.0/0)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "VNC"
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
    Name = local.sg_name
  }
}

# ─────────────────────────────────────────
# EC2 Instance
# ─────────────────────────────────────────

resource "aws_instance" "installer" {
  ami                         = var.aws_ami
  instance_type               = var.aws_instance_type
  key_name                    = aws_key_pair.installer.key_name
  subnet_id                   = var.egress_subnet_id_a
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.installer.id]
  iam_instance_profile        = data.aws_iam_instance_profile.ocp_install.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ec2_disk_size
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region               = var.aws_region
    openshift_major_version  = var.openshift_major_version
    openshift_minor_version  = var.openshift_minor_version
    openshift_version        = local.openshift_version
    mirror_registry_password = var.mirror_registry_password
    pull_secret              = var.pull_secret
    quay_root_mount          = var.quay_root_mount
    openshift_local_repo     = var.openshift_local_repository
    cluster_name             = local.cluster_name
    sts_suffix               = local.sts_suffix
  })

  tags = {
    Name       = local.instance_name
    Automation = "ocp_installer"
  }
}
