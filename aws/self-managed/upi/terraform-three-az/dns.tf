# ── Route53 Private Hosted Zone ───────────────────────────────────────────────
# UPI clusters use a separate DNS namespace (e.g. cluster.upi.example.com)
# so IPI and UPI clusters can coexist in the same environment.

resource "aws_route53_zone" "cluster" {
  name = "${var.cluster_name}.${var.cluster_domain}"

  vpc {
    vpc_id     = var.vpc_id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}.${var.cluster_domain}"
  })
}

resource "aws_route53_zone_association" "egress" {
  zone_id    = aws_route53_zone.cluster.zone_id
  vpc_id     = var.egress_vpc_id
  vpc_region = var.aws_region
}
