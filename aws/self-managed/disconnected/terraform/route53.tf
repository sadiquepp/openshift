resource "aws_route53_zone" "cluster" {
  name = "${local.openshift_cluster_name}.${var.openshift_base_domain}"

  vpc {
    vpc_id     = aws_vpc.disconnected.id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_zone_association" "egress" {
  zone_id    = aws_route53_zone.cluster.zone_id
  vpc_id     = aws_vpc.egress.id
  vpc_region = var.aws_region
}
