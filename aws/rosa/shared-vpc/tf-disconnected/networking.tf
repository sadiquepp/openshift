# ─────────────────────────────────────────
# Disconnected VPC
# ─────────────────────────────────────────

resource "aws_vpc" "disconnected" {
  cidr_block           = var.aws_disconnected_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.disconnected_vpc_name
  }
}

resource "aws_subnet" "disconnected_private" {
  count = 3

  vpc_id            = aws_vpc.disconnected.id
  cidr_block        = var.aws_disconnected_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.disconnected_vpc_name}-subnet-az${count.index + 1}"
  }
}

# ─────────────────────────────────────────
# Egress VPC
# ─────────────────────────────────────────

resource "aws_vpc" "egress" {
  cidr_block           = var.aws_egress_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.egress_vpc_name
  }
}

resource "aws_subnet" "egress_public" {
  count = 3

  vpc_id                  = aws_vpc.egress.id
  cidr_block              = var.aws_egress_subnet_public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.egress_vpc_name}-public-az${count.index + 1}"
  }
}

resource "aws_subnet" "egress_private" {
  count = 3

  vpc_id            = aws_vpc.egress.id
  cidr_block        = var.aws_egress_subnet_private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.egress_vpc_name}-private-az${count.index + 1}"
  }
}

# ─────────────────────────────────────────
# Internet Gateway (Egress VPC)
# ─────────────────────────────────────────

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id

  tags = {
    Name = "${local.egress_vpc_name}-igw"
  }
}

# ─────────────────────────────────────────
# Transit Gateway
# ─────────────────────────────────────────

resource "aws_ec2_transit_gateway" "this" {
  description = "Transit Gateway for Disconnected"

  tags = {
    Name = "${var.prefix_for_name}-transitgw"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "disconnected" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.disconnected.id

  subnet_ids = aws_subnet.disconnected_private[*].id

  tags = {
    Name = "${var.prefix_for_name}-Disconnected-Attach"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.egress.id

  # The Ansible playbook only attaches the first public subnet to the TGW
  subnet_ids = [aws_subnet.egress_public[0].id]

  tags = {
    Name = "${var.prefix_for_name}-Egress-Attach"
  }
}

# ─────────────────────────────────────────
# Route Tables
# ─────────────────────────────────────────

# Disconnected VPC: route to egress VPC via TGW
resource "aws_route_table" "disconnected" {
  vpc_id = aws_vpc.disconnected.id

  route {
    cidr_block         = var.aws_egress_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags = {
    Name = "${var.prefix_for_name}-disconnected-subnet-rt"
  }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.disconnected]
}

resource "aws_route_table_association" "disconnected_private" {
  count = 3

  subnet_id      = aws_subnet.disconnected_private[count.index].id
  route_table_id = aws_route_table.disconnected.id
}

# Egress VPC public: default via IGW + return route to disconnected via TGW
resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.egress.id
  }

  route {
    cidr_block         = var.aws_disconnected_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.this.id
  }

  tags = {
    Name = "${var.prefix_for_name}-egress-rt-igw"
  }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.egress]
}

resource "aws_route_table_association" "egress_public" {
  count = 3

  subnet_id      = aws_subnet.egress_public[count.index].id
  route_table_id = aws_route_table.egress_public.id
}
