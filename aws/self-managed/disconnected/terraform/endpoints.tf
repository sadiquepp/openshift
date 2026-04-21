# ── Security Group for VPC Endpoints ──────────────────────────────────────────

resource "aws_security_group" "vpc_endpoint" {
  name        = "vpc-endpoint-allow"
  description = "Security group for VPC EndPoints"
  vpc_id      = aws_vpc.disconnected.id

  ingress {
    description = "Allow HTTPS from disconnected VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr]
  }

  tags = {
    Name = "vpc-endpoint-allow"
  }
}

# ── S3 Gateway Endpoint ──────────────────────────────────────────────────────

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.disconnected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.disconnected.id]

  tags = {
    Name = "${var.prefix_for_name}-s3-disconnected"
  }
}

# ── Interface Endpoints (ec2, sts, elb, ecr.api, ecr.dkr) ────────────────────

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoint_services)

  vpc_id              = aws_vpc.disconnected.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.disconnected[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.prefix_for_name}-${each.key}-disconnected"
  }
}
