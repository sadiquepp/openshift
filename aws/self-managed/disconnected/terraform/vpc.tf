locals {
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}c",
  ]
  disconnected_vpc_name  = "${var.prefix_for_name}-disconnected"
  egress_vpc_name        = "${var.prefix_for_name}-egress"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
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

resource "aws_subnet" "egress_public" {
  count = length(var.egress_public_subnet_cidrs)

  vpc_id            = aws_vpc.egress.id
  cidr_block        = var.egress_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.egress_vpc_name}-public-az${count.index + 1}"
  }
}
