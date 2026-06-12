# ── HCP VPC (optional, for hosting HCP clusters in a separate VPC) ────────────
#
# Two independent VPCs may be created:
#
# 1. Same-account separate VPC (hcp_separate_vpc = true):
#    Created in the management account for hcp_cluster_suffixes clusters.
#    Uses provider = aws.hcp (which equals the default provider).
#
# 2. Cross-account VPC (hcp_xacct_cluster_suffixes non-empty):
#    Created in the HCP account via provider = aws.xacct.
#    Both may coexist simultaneously.
#
# Set hcp_separate_vpc = false (default) and leave hcp_xacct_cluster_suffixes
# empty to deploy all HCP clusters into the main connected VPC.

variable "hcp_separate_vpc" {
  description = "When true, create a separate VPC for HCP clusters instead of using the main connected VPC."
  type        = bool
  default     = false
}

variable "hcp_vpc_cidr" {
  description = "CIDR block for the same-account HCP VPC (only used when hcp_separate_vpc = true)"
  type        = string
  default     = "172.17.0.0/16"
}

variable "hcp_private_subnet_cidrs" {
  description = "CIDR blocks for same-account HCP private subnets, one per AZ (only used when hcp_separate_vpc = true)"
  type        = list(string)
  default     = ["172.17.1.0/24", "172.17.2.0/24", "172.17.3.0/24"]
}

variable "hcp_public_subnet_cidrs" {
  description = "CIDR blocks for same-account HCP public subnets, one per AZ (only used when hcp_separate_vpc = true)"
  type        = list(string)
  default     = ["172.17.4.0/24", "172.17.5.0/24", "172.17.6.0/24"]
}

variable "hcp_xacct_vpc_cidr" {
  description = "CIDR block for the cross-account HCP VPC"
  type        = string
  default     = "172.18.0.0/16"
}

variable "hcp_xacct_private_subnet_cidrs" {
  description = "CIDR blocks for cross-account HCP private subnets, one per AZ"
  type        = list(string)
  default     = ["172.18.1.0/24", "172.18.2.0/24", "172.18.3.0/24"]
}

variable "hcp_xacct_public_subnet_cidrs" {
  description = "CIDR blocks for cross-account HCP public subnets, one per AZ"
  type        = list(string)
  default     = ["172.18.4.0/24", "172.18.5.0/24", "172.18.6.0/24"]
}

locals {
  hcp_sep_vpc_enabled   = length(var.hcp_cluster_suffixes) > 0 && var.hcp_separate_vpc
  hcp_xacct_vpc_enabled = length(var.hcp_xacct_cluster_suffixes) > 0

  hcp_sep_vpc_name   = "${var.prefix_for_name}-hcp"
  hcp_xacct_vpc_name = "${var.prefix_for_name}-hcp-xacct"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SAME-ACCOUNT SEPARATE VPC  (provider = aws.hcp = default provider)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_vpc" "hcp" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  cidr_block           = var.hcp_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.hcp_sep_vpc_name
  }
}

resource "aws_subnet" "hcp_private" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? length(var.hcp_private_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp[0].id
  cidr_block        = var.hcp_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.hcp_sep_vpc_name}-subnet-az${count.index + 1}"
  }
}

resource "aws_subnet" "hcp_public" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? length(var.hcp_public_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp[0].id
  cidr_block        = var.hcp_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name                          = "${local.hcp_sep_vpc_name}-public-subnet-az${count.index + 1}"
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

resource "aws_internet_gateway" "hcp" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  tags = {
    Name = "${local.hcp_sep_vpc_name}-igw"
  }
}

resource "aws_route_table" "hcp_public" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hcp[0].id
  }

  tags = {
    Name = "${local.hcp_sep_vpc_name}-rt-igw"
  }
}

resource "aws_route_table_association" "hcp_public" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? length(aws_subnet.hcp_public) : 0

  subnet_id      = aws_subnet.hcp_public[count.index].id
  route_table_id = aws_route_table.hcp_public[0].id
}

resource "aws_eip" "hcp_nat" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0
  domain   = "vpc"

  tags = {
    Name = "${local.hcp_sep_vpc_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "hcp" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  allocation_id = aws_eip.hcp_nat[0].id
  subnet_id     = aws_subnet.hcp_public[0].id

  tags = {
    Name = "${local.hcp_sep_vpc_name}-nat"
  }

  depends_on = [aws_internet_gateway.hcp]
}

resource "aws_route_table" "hcp_private" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hcp[0].id
  }

  tags = {
    Name = "${local.hcp_sep_vpc_name}-rt-nat"
  }
}

resource "aws_route_table_association" "hcp_private" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? length(aws_subnet.hcp_private) : 0

  subnet_id      = aws_subnet.hcp_private[count.index].id
  route_table_id = aws_route_table.hcp_private[0].id
}

resource "aws_vpc_endpoint" "hcp_s3" {
  provider = aws.hcp
  count    = local.hcp_sep_vpc_enabled ? 1 : 0

  vpc_id            = aws_vpc.hcp[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.hcp_public[0].id,
    aws_route_table.hcp_private[0].id,
  ]

  tags = {
    Name = "${local.hcp_sep_vpc_name}-s3"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CROSS-ACCOUNT VPC  (provider = aws.xacct — created in the HCP account)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_vpc" "hcp_xacct" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  cidr_block           = var.hcp_xacct_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.hcp_xacct_vpc_name
  }
}

resource "aws_subnet" "hcp_xacct_private" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? length(var.hcp_xacct_private_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp_xacct[0].id
  cidr_block        = var.hcp_xacct_private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-subnet-az${count.index + 1}"
  }
}

resource "aws_subnet" "hcp_xacct_public" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? length(var.hcp_xacct_public_subnet_cidrs) : 0

  vpc_id            = aws_vpc.hcp_xacct[0].id
  cidr_block        = var.hcp_xacct_public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name                          = "${local.hcp_xacct_vpc_name}-public-subnet-az${count.index + 1}"
      "kubernetes.io/cluster/dummy" = "shared"
    },
    {
      for suffix, cluster in local.hcp_xacct_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    },
    {
      for suffix, cluster in local.hcp_xacct_pvt_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    },
    {
      for suffix, cluster in local.hcp_xacct_pvtpl_clusters :
      "kubernetes.io/cluster/${cluster.cluster_name}" => "shared"
    }
  )
}

resource "aws_internet_gateway" "hcp_xacct" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp_xacct[0].id

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-igw"
  }
}

resource "aws_route_table" "hcp_xacct_public" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp_xacct[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hcp_xacct[0].id
  }

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-rt-igw"
  }
}

resource "aws_route_table_association" "hcp_xacct_public" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? length(aws_subnet.hcp_xacct_public) : 0

  subnet_id      = aws_subnet.hcp_xacct_public[count.index].id
  route_table_id = aws_route_table.hcp_xacct_public[0].id
}

resource "aws_eip" "hcp_xacct_nat" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0
  domain   = "vpc"

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "hcp_xacct" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  allocation_id = aws_eip.hcp_xacct_nat[0].id
  subnet_id     = aws_subnet.hcp_xacct_public[0].id

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-nat"
  }

  depends_on = [aws_internet_gateway.hcp_xacct]
}

resource "aws_route_table" "hcp_xacct_private" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  vpc_id = aws_vpc.hcp_xacct[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hcp_xacct[0].id
  }

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-rt-nat"
  }
}

resource "aws_route_table_association" "hcp_xacct_private" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? length(aws_subnet.hcp_xacct_private) : 0

  subnet_id      = aws_subnet.hcp_xacct_private[count.index].id
  route_table_id = aws_route_table.hcp_xacct_private[0].id
}

resource "aws_vpc_endpoint" "hcp_xacct_s3" {
  provider = aws.xacct
  count    = local.hcp_xacct_vpc_enabled ? 1 : 0

  vpc_id            = aws_vpc.hcp_xacct[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.hcp_xacct_public[0].id,
    aws_route_table.hcp_xacct_private[0].id,
  ]

  tags = {
    Name = "${local.hcp_xacct_vpc_name}-s3"
  }
}
