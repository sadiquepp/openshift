# ── Internet Gateway (Egress VPC) ─────────────────────────────────────────────

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.egress.id

  tags = {
    Name = "${local.egress_vpc_name}-igw"
  }
}

# ── Transit Gateway ──────────────────────────────────────────────────────────

resource "aws_ec2_transit_gateway" "main" {
  description = "Transit Gateway for Disconnected"

  tags = {
    Name = "${var.prefix_for_name}-transitgw"
  }
}

# ── Transit Gateway Attachments ──────────────────────────────────────────────

resource "aws_ec2_transit_gateway_vpc_attachment" "disconnected" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.disconnected.id
  subnet_ids         = aws_subnet.disconnected[*].id

  tags = {
    Name = "${var.prefix_for_name}-Disconnected-Attach"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.egress.id
  subnet_ids         = [aws_subnet.egress_public[0].id]

  tags = {
    Name = "${var.prefix_for_name}-Egress-Attach"
  }
}

# ── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "disconnected" {
  vpc_id = aws_vpc.disconnected.id

  route {
    cidr_block         = var.egress_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = {
    Name = "${var.prefix_for_name}-disconnected-subnet-rt"
  }
}

resource "aws_route_table_association" "disconnected" {
  count = length(aws_subnet.disconnected)

  subnet_id      = aws_subnet.disconnected[count.index].id
  route_table_id = aws_route_table.disconnected.id
}

resource "aws_route_table" "egress_public" {
  vpc_id = aws_vpc.egress.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.egress.id
  }

  route {
    cidr_block         = var.disconnected_vpc_cidr
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = {
    Name = "${var.prefix_for_name}-egress-rt-igw"
  }
}

resource "aws_route_table_association" "egress_public" {
  subnet_id      = aws_subnet.egress_public[0].id
  route_table_id = aws_route_table.egress_public.id
}
