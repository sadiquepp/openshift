locals {
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}c",
  ]
  disconnected_vpc_name  = "${var.prefix_for_name}-disconnected"
  egress_vpc_name        = "${var.prefix_for_name}-egress"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"

  upi_ip_reservations = {
    bootstrap = { subnet_index = 0, host_num = var.upi_node_host_numbers.bootstrap }
    master0   = { subnet_index = 0, host_num = var.upi_node_host_numbers.master0 }
    master1   = { subnet_index = 1, host_num = var.upi_node_host_numbers.master1 }
    master2   = { subnet_index = 2, host_num = var.upi_node_host_numbers.master2 }
    worker1   = { subnet_index = 0, host_num = var.upi_node_host_numbers.worker1 }
    worker2   = { subnet_index = 1, host_num = var.upi_node_host_numbers.worker2 }
    worker3   = { subnet_index = 2, host_num = var.upi_node_host_numbers.worker3 }
    infra1    = { subnet_index = 0, host_num = var.upi_node_host_numbers.infra1 }
    infra2    = { subnet_index = 1, host_num = var.upi_node_host_numbers.infra2 }
    infra3    = { subnet_index = 2, host_num = var.upi_node_host_numbers.infra3 }
  }
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

resource "aws_vpc" "disconnected" {
  cidr_block           = var.disconnected_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.disconnected_vpc_name
  }
}

resource "aws_subnet" "disconnected" {
  count = length(var.disconnected_subnet_cidrs)

  vpc_id            = aws_vpc.disconnected.id
  cidr_block        = var.disconnected_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.disconnected_vpc_name}-subnet-az${count.index + 1}"
  }
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

resource "aws_vpc" "egress" {
  cidr_block           = var.egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.egress_vpc_name
  }
}

# ── UPI IP Reservations ──────────────────────────────────────────────────────

resource "aws_ec2_subnet_cidr_reservation" "upi" {
  for_each = local.upi_ip_reservations

  subnet_id        = aws_subnet.disconnected[each.value.subnet_index].id
  cidr_block       = "${cidrhost(var.disconnected_subnet_cidrs[each.value.subnet_index], each.value.host_num)}/32"
  reservation_type = "explicit"
  description      = "UPI ${each.key}"
}

resource "aws_subnet" "egress_public" {
  count = length(var.egress_public_subnet_cidrs)

  vpc_id            = aws_vpc.egress.id
  cidr_block        = var.egress_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.egress_vpc_name}-public-az${count.index + 1}"
  }
}
