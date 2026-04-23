# ── Cross-region endpoints (us-east-1) ────────────────────────────────────────
#
# Global AWS services (IAM, Route53, Tagging) only support VPC interface
# endpoints in us-east-1. To reach them from the disconnected VPC without
# internet access we:
#
#   1. Create a small VPC + subnet in us-east-1
#   2. Create interface endpoints for each service there
#   3. Peer the disconnected VPC with the us-east-1 VPC
#   4. For each service, create a Route53 private zone override
#      (<service>.us-east-1.amazonaws.com) in the disconnected VPC
#      pointing to the endpoint ENI IP
#
# All resources are gated on var.create_cross_region_endpoints.

# ── 1. VPC and subnet in us-east-1 ──────────────────────────────────────────

resource "aws_vpc" "cross_region" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  cidr_block           = var.cross_region_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix_for_name}-cross-region-us-east-1"
  }
}

data "aws_availability_zones" "us_east_1" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1
  state    = "available"
}

resource "aws_subnet" "cross_region" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  vpc_id            = aws_vpc.cross_region[0].id
  cidr_block        = var.cross_region_subnet_cidr
  availability_zone = data.aws_availability_zones.us_east_1[0].names[0]

  tags = {
    Name = "${var.prefix_for_name}-cross-region-subnet"
  }
}

# ── 2. Interface endpoints in us-east-1 ─────────────────────────────────────

resource "aws_security_group" "cross_region_endpoint" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  name        = "${var.prefix_for_name}-cross-region-endpoint"
  description = "Allow HTTPS from disconnected VPC via peering"
  vpc_id      = aws_vpc.cross_region[0].id

  ingress {
    description = "HTTPS from disconnected VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.disconnected_vpc_cidr]
  }

  tags = {
    Name = "${var.prefix_for_name}-cross-region-endpoint"
  }
}

locals {
  cross_region_services = var.create_cross_region_endpoints ? toset(var.cross_region_endpoint_services) : toset([])
}

resource "aws_vpc_endpoint" "cross_region" {
  for_each = local.cross_region_services
  provider = aws.us_east_1

  vpc_id              = aws_vpc.cross_region[0].id
  service_name        = "com.amazonaws.us-east-1.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.cross_region[0].id]
  security_group_ids  = [aws_security_group.cross_region_endpoint[0].id]
  private_dns_enabled = false

  tags = {
    Name = "${var.prefix_for_name}-${each.key}-us-east-1"
  }
}

data "aws_network_interface" "cross_region_endpoint" {
  for_each = local.cross_region_services
  provider = aws.us_east_1

  id = aws_vpc_endpoint.cross_region[each.key].network_interface_ids[0]
}

# ── 3. VPC peering: disconnected (ap-southeast-1) ↔ cross-region (us-east-1)

resource "aws_vpc_peering_connection" "disconnected_to_cross_region" {
  count = var.create_cross_region_endpoints ? 1 : 0

  vpc_id      = aws_vpc.disconnected.id
  peer_vpc_id = aws_vpc.cross_region[0].id
  peer_region = "us-east-1"
  auto_accept = false

  tags = {
    Name = "${var.prefix_for_name}-disconnected-to-us-east-1"
  }
}

resource "aws_vpc_peering_connection_accepter" "cross_region" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  vpc_peering_connection_id = aws_vpc_peering_connection.disconnected_to_cross_region[0].id
  auto_accept               = true

  tags = {
    Name = "${var.prefix_for_name}-us-east-1-accept"
  }
}

# Route: disconnected VPC → us-east-1 VPC
resource "aws_route" "disconnected_to_cross_region" {
  count = var.create_cross_region_endpoints ? 1 : 0

  route_table_id            = aws_route_table.disconnected.id
  destination_cidr_block    = var.cross_region_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.disconnected_to_cross_region[0].id

  depends_on = [aws_vpc_peering_connection_accepter.cross_region]
}

# Route: us-east-1 VPC → disconnected VPC (return path)
resource "aws_route_table" "cross_region" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  vpc_id = aws_vpc.cross_region[0].id

  tags = {
    Name = "${var.prefix_for_name}-cross-region-rt"
  }
}

resource "aws_route" "cross_region_to_disconnected" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  route_table_id            = aws_route_table.cross_region[0].id
  destination_cidr_block    = var.disconnected_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.disconnected_to_cross_region[0].id

  depends_on = [aws_vpc_peering_connection_accepter.cross_region]
}

resource "aws_route_table_association" "cross_region" {
  count    = var.create_cross_region_endpoints ? 1 : 0
  provider = aws.us_east_1

  subnet_id      = aws_subnet.cross_region[0].id
  route_table_id = aws_route_table.cross_region[0].id
}

# ── 4. Route53 private zone overrides ───────────────────────────────────────
# Each zone makes the disconnected VPC resolve <service>.us-east-1.amazonaws.com
# to the endpoint ENI IP reachable over the peering connection.

resource "aws_route53_zone" "cross_region" {
  for_each = local.cross_region_services

  name = "${each.key}.us-east-1.amazonaws.com"

  vpc {
    vpc_id     = aws_vpc.disconnected.id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name = "${var.prefix_for_name}-${each.key}-override"
  }
}

resource "aws_route53_record" "cross_region" {
  for_each = local.cross_region_services

  zone_id = aws_route53_zone.cross_region[each.key].zone_id
  name    = "${each.key}.us-east-1.amazonaws.com"
  type    = "A"
  ttl     = 300
  records = [data.aws_network_interface.cross_region_endpoint[each.key].private_ip]
}
