# ── HCP VPC (optional, separate VPC for hosting HCP clusters) ─────────────────
# When hcp_separate_vpc = true, creates a standalone VPC with private/public
# subnets, IGW, NAT gateway, and S3 endpoint -- mirroring the main connected
# VPC structure. HCP clusters deploy into this VPC instead of the main one.
#
# Set hcp_separate_vpc = false (default) to deploy HCP clusters in the main
# connected VPC.

variable "hcp_separate_vpc" {
  description = "When true, create a separate VPC for HCP clusters instead of using the main connected VPC."
  type        = bool
  default     = false
}

variable "hcp_vpc_cidr" {
  description = "CIDR block for the HCP VPC (only used when hcp_separate_vpc = true)"
  type        = string
  default     = "172.17.0.0/16"
}

variable "hcp_private_subnet_cidrs" {
  description = "CIDR blocks for HCP private subnets, one per AZ (only used when hcp_separate_vpc = true)"
  type        = list(string)
  default     = ["172.17.1.0/24", "172.17.2.0/24", "172.17.3.0/24"]
}

variable "hcp_public_subnet_cidrs" {
  description = "CIDR blocks for HCP public subnets, one per AZ (only used when hcp_separate_vpc = true)"
  type        = list(string)
  default     = ["172.17.4.0/24", "172.17.5.0/24", "172.17.6.0/24"]
}

locals {
  hcp_vpc_enabled = local.hcp_enabled && var.hcp_separate_vpc
  hcp_vpc_name    = "${var.prefix_for_name}-hcp"

  # Resolved values: point to HCP VPC when separate, otherwise main VPC
  resolved_hcp_vpc_id   = local.hcp_vpc_enabled ? aws_vpc.hcp[0].id : aws_vpc.connected.id
  resolved_hcp_vpc_cidr = local.hcp_vpc_enabled ? aws_vpc.hcp[0].cidr_block : aws_vpc.connected.cidr_block
  resolved_hcp_subnet_a = local.hcp_vpc_enabled ? aws_subnet.hcp_private[0].id : aws_subnet.private[0].id
  resolved_hcp_subnet_b = local.hcp_vpc_enabled ? aws_subnet.hcp_private[1].id : aws_subnet.private[1].id
  resolved_hcp_subnet_c = local.hcp_vpc_enabled ? aws_subnet.hcp_private[2].id : aws_subnet.private[2].id
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "hcp" {
  count = local.hcp_vpc_enabled ? 1 : 0

  cidr_block           = var.hcp_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.hcp_vpc_name
  }
}

# ── Private Subnets ──────────────────────────────────────────────────────────

resource "aws_subnet" "hcp_private" {
  count = local.hcp_vpc_enabled ? length(var.hcp_private_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp[0].id
  cidr_block        = var.hcp_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.hcp_vpc_name}-subnet-az${count.index + 1}"
  }
}

# ── Public Subnets ───────────────────────────────────────────────────────────

resource "aws_subnet" "hcp_public" {
  count = local.hcp_vpc_enabled ? length(var.hcp_public_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp[0].id
  cidr_block        = var.hcp_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name                          = "${local.hcp_vpc_name}-public-subnet-az${count.index + 1}"
      "kubernetes.io/cluster/dummy" = "shared"
    },
    {
      for suffix, cluster in local.hcp_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    },
    {
      for suffix, cluster in local.hcp_pvt_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    },
    {
      for suffix, cluster in local.hcp_pvtpl_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    }
  )
}

# ── Internet Gateway ─────────────────────────────────────────────────────────

resource "aws_internet_gateway" "hcp" {
  count = local.hcp_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  tags = {
    Name = "${local.hcp_vpc_name}-igw"
  }
}

# ── Public Route Table (IGW) ─────────────────────────────────────────────────

resource "aws_route_table" "hcp_public" {
  count = local.hcp_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hcp[0].id
  }

  tags = {
    Name = "${local.hcp_vpc_name}-rt-igw"
  }
}

resource "aws_route_table_association" "hcp_public" {
  count = local.hcp_vpc_enabled ? length(aws_subnet.hcp_public) : 0

  subnet_id      = aws_subnet.hcp_public[count.index].id
  route_table_id = aws_route_table.hcp_public[0].id
}

# ── NAT Gateway ──────────────────────────────────────────────────────────────

resource "aws_eip" "hcp_nat" {
  count  = local.hcp_vpc_enabled ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${local.hcp_vpc_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "hcp" {
  count = local.hcp_vpc_enabled ? 1 : 0

  allocation_id = aws_eip.hcp_nat[0].id
  subnet_id     = aws_subnet.hcp_public[0].id

  tags = {
    Name = "${local.hcp_vpc_name}-nat"
  }

  depends_on = [aws_internet_gateway.hcp]
}

# ── Private Route Table (NAT) ────────────────────────────────────────────────

resource "aws_route_table" "hcp_private" {
  count = local.hcp_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hcp[0].id
  }

  tags = {
    Name = "${local.hcp_vpc_name}-rt-nat"
  }
}

resource "aws_route_table_association" "hcp_private" {
  count = local.hcp_vpc_enabled ? length(aws_subnet.hcp_private) : 0

  subnet_id      = aws_subnet.hcp_private[count.index].id
  route_table_id = aws_route_table.hcp_private[0].id
}

# ── S3 Gateway Endpoint ─────────────────────────────────────────────────────

resource "aws_vpc_endpoint" "hcp_s3" {
  count = local.hcp_vpc_enabled ? 1 : 0

  vpc_id            = aws_vpc.hcp[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.hcp_public[0].id,
    aws_route_table.hcp_private[0].id,
  ]

  tags = {
    Name = "${local.hcp_vpc_name}-s3"
  }
}
