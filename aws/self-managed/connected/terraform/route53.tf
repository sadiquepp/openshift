resource "aws_route53_zone" "cluster" {
  name = "${local.openshift_cluster_name}.${var.openshift_base_domain}"

  vpc {
    vpc_id     = aws_vpc.connected.id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }
}
