# ─────────────────────────────────────────
# Security Group for VPC Endpoints
# ─────────────────────────────────────────

resource "aws_security_group" "vpc_endpoints" {
  name        = "vpc-endpoint-allow"
  description = "Security group for VPC EndPoints"
  vpc_id      = aws_vpc.disconnected.id

  ingress {
    description = "allow all on port 443 on endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.aws_disconnected_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vpc-endpoint-allow"
  }
}

# ─────────────────────────────────────────
# S3 Gateway Endpoint (disconnected VPC)
# ─────────────────────────────────────────

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.disconnected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [aws_route_table.disconnected.id]

  tags = {
    Name = "${var.prefix_for_name}-s3-disconnected"
  }
}

# ─────────────────────────────────────────
# Interface Endpoints (disconnected VPC)
# ec2 | sts | elasticloadbalancing | ecr.api | ecr.dkr
# ─────────────────────────────────────────

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = aws_vpc.disconnected.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  # Ansible only puts the first disconnected subnet in the endpoint
  subnet_ids = [aws_subnet.disconnected_private[0].id]

  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name = "${var.prefix_for_name}-${each.key}-disconnected"
  }
}
