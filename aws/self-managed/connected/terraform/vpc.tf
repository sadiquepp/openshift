locals {
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}c",
  ]
  connected_vpc_name     = "${var.prefix_for_name}-connected"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

resource "aws_vpc" "connected" {
  cidr_block           = var.connected_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.connected_vpc_name
  }
}

# ── Private Subnets ───────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = length(var.connected_private_subnet_cidrs)

  vpc_id            = aws_vpc.connected.id
  cidr_block        = var.connected_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  lifecycle {
    ignore_changes = [
      tags,
      tags_all,
    ]
  }
}

# ── Private Subnet Tags ───────────────────────────────────────────────────────

resource "aws_ec2_tag" "private_subnet_name" {
  count       = length(var.connected_private_subnet_cidrs)
  resource_id = aws_subnet.private[count.index].id
  key         = "Name"
  value       = "${local.connected_vpc_name}-subnet-az${count.index + 1}"
}

resource "aws_ec2_tag" "private_subnet_internal_elb" {
  count       = length(var.connected_private_subnet_cidrs)
  resource_id = aws_subnet.private[count.index].id
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet_hcp_pvt_shared" {
  for_each = {
    for pair in setproduct(range(length(var.connected_private_subnet_cidrs)), keys(local.hcp_pvt_clusters)) :
    "${pair[0]}-${pair[1]}" => {
      subnet_index = pair[0]
      suffix       = pair[1]
    }
  }

  resource_id = aws_subnet.private[each.value.subnet_index].id
  key         = "kubernetes.io/cluster/${local.hcp_pvt_clusters[each.value.suffix].cluster_name}"
  value       = "shared"
}

# ── Public Subnets ────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(var.connected_public_subnet_cidrs)

  vpc_id            = aws_vpc.connected.id
  cidr_block        = var.connected_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  lifecycle {
    ignore_changes = [
      tags,
      tags_all,
    ]
  }
}

# ── Public Subnet Tags ────────────────────────────────────────────────────────

resource "aws_ec2_tag" "public_subnet_name" {
  count       = length(var.connected_public_subnet_cidrs)
  resource_id = aws_subnet.public[count.index].id
  key         = "Name"
  value       = "${local.connected_vpc_name}-public-subnet-az${count.index + 1}"
}

resource "aws_ec2_tag" "public_subnet_dummy_cluster" {
  count       = length(var.connected_public_subnet_cidrs)
  resource_id = aws_subnet.public[count.index].id
  key         = "kubernetes.io/cluster/dummy"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet_hcp_shared" {
  for_each = {
    for pair in setproduct(range(length(var.connected_public_subnet_cidrs)), keys(local.hcp_clusters)) :
    "${pair[0]}-${pair[1]}" => {
      subnet_index = pair[0]
      suffix       = pair[1]
    }
  }

  resource_id = aws_subnet.public[each.value.subnet_index].id
  key         = "kubernetes.io/cluster/${local.hcp_clusters[each.value.suffix].cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet_hcp_pvt_shared" {
  for_each = {
    for pair in setproduct(range(length(var.connected_public_subnet_cidrs)), keys(local.hcp_pvt_clusters)) :
    "${pair[0]}-${pair[1]}" => {
      subnet_index = pair[0]
      suffix       = pair[1]
    }
  }

  resource_id = aws_subnet.public[each.value.subnet_index].id
  key         = "kubernetes.io/cluster/${local.hcp_pvt_clusters[each.value.suffix].cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_subnet_hcp_pvtpl_shared" {
  for_each = {
    for pair in setproduct(range(length(var.connected_public_subnet_cidrs)), keys(local.hcp_pvtpl_clusters)) :
    "${pair[0]}-${pair[1]}" => {
      subnet_index = pair[0]
      suffix       = pair[1]
    }
  }

  resource_id = aws_subnet.public[each.value.subnet_index].id
  key         = "kubernetes.io/cluster/${local.hcp_pvtpl_clusters[each.value.suffix].cluster_name}"
  value       = "shared"
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.connected.id

  tags = {
    Name = "${local.connected_vpc_name}-igw"
  }
}

# ── Public Route Table (IGW) ──────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.connected.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.prefix_for_name}-connected-rt-igw"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.connected_vpc_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.connected_vpc_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# ── Private Route Table (NAT) ─────────────────────────────────────────────────

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.connected.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.prefix_for_name}-rt-nat"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── S3 Gateway Endpoint ──────────────────────────────────────────────────────

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.connected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  tags = {
    Name = "${var.prefix_for_name}-s3-connected"
  }
}
