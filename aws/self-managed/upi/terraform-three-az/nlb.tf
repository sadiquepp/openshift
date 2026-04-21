# ── Network Load Balancer ─────────────────────────────────────────────────────
# All resources in this file are created only when create_nlb_and_dns = true.
# When false the user is expected to bring their own load balancer and DNS.

resource "aws_lb" "cluster" {
  count = var.create_nlb_and_dns ? 1 : 0

  name               = "${local.infra_id}-nlb"
  internal           = true
  load_balancer_type = "network"

  subnets = [
    var.subnet_id_az1,
    var.subnet_id_az2,
    var.subnet_id_az3,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.infra_id}-nlb"
  })
}

# ── Target Groups ────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "api" {
  count = var.create_nlb_and_dns ? 1 : 0

  name        = "${local.infra_id}-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = 6443
  }

  tags = { Name = "${local.infra_id}-api" }
}

resource "aws_lb_target_group" "mcs" {
  count = var.create_nlb_and_dns ? 1 : 0

  name        = "${local.infra_id}-mcs"
  port        = 22623
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = 22623
  }

  tags = { Name = "${local.infra_id}-mcs" }
}

resource "aws_lb_target_group" "https" {
  count = var.create_nlb_and_dns ? 1 : 0

  name        = "${local.infra_id}-https"
  port        = 443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTP"
    port     = 1936
    path     = "/healthz"
  }

  tags = { Name = "${local.infra_id}-https" }
}

resource "aws_lb_target_group" "http" {
  count = var.create_nlb_and_dns ? 1 : 0

  name        = "${local.infra_id}-http"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTP"
    port     = 1936
    path     = "/healthz"
  }

  tags = { Name = "${local.infra_id}-http" }
}

# ── Listeners ────────────────────────────────────────────────────────────────

resource "aws_lb_listener" "api" {
  count = var.create_nlb_and_dns ? 1 : 0

  load_balancer_arn = aws_lb.cluster[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}

resource "aws_lb_listener" "mcs" {
  count = var.create_nlb_and_dns ? 1 : 0

  load_balancer_arn = aws_lb.cluster[0].arn
  port              = 22623
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcs[0].arn
  }
}

resource "aws_lb_listener" "https" {
  count = var.create_nlb_and_dns ? 1 : 0

  load_balancer_arn = aws_lb.cluster[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https[0].arn
  }
}

resource "aws_lb_listener" "http" {
  count = var.create_nlb_and_dns ? 1 : 0

  load_balancer_arn = aws_lb.cluster[0].arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http[0].arn
  }
}

# ── API / MCS Target Group Attachments ───────────────────────────────────────
# Bootstrap + 3 masters for both API (6443) and MCS (22623).

locals {
  api_mcs_targets = var.create_nlb_and_dns ? {
    bootstrap = var.bootstrap_private_ip
    master0   = var.master0_private_ip
    master1   = var.master1_private_ip
    master2   = var.master2_private_ip
  } : {}

  ingress_targets = var.create_nlb_and_dns ? merge(
    {
      worker1 = var.worker1_private_ip
      worker2 = var.worker2_private_ip
      worker3 = var.worker3_private_ip
    },
    var.create_infra_nodes ? {
      infra1 = var.infra1_private_ip
      infra2 = var.infra2_private_ip
      infra3 = var.infra3_private_ip
    } : {}
  ) : {}
}

resource "aws_lb_target_group_attachment" "api" {
  for_each = local.api_mcs_targets

  target_group_arn = aws_lb_target_group.api[0].arn
  target_id        = each.value
  port             = 6443
}

resource "aws_lb_target_group_attachment" "mcs" {
  for_each = local.api_mcs_targets

  target_group_arn = aws_lb_target_group.mcs[0].arn
  target_id        = each.value
  port             = 22623
}

# ── Ingress Target Group Attachments ─────────────────────────────────────────
# Workers + infra nodes (if enabled) for HTTPS (443) and HTTP (80).

resource "aws_lb_target_group_attachment" "https" {
  for_each = local.ingress_targets

  target_group_arn = aws_lb_target_group.https[0].arn
  target_id        = each.value
  port             = 443
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = local.ingress_targets

  target_group_arn = aws_lb_target_group.http[0].arn
  target_id        = each.value
  port             = 80
}

# ── Route53 DNS Records ─────────────────────────────────────────────────────

resource "aws_route53_record" "api" {
  count = var.create_nlb_and_dns ? 1 : 0

  zone_id = aws_route53_zone.cluster.zone_id
  name    = "api.${var.cluster_name}.${var.cluster_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.cluster[0].dns_name
    zone_id                = aws_lb.cluster[0].zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_int" {
  count = var.create_nlb_and_dns ? 1 : 0

  zone_id = aws_route53_zone.cluster.zone_id
  name    = "api-int.${var.cluster_name}.${var.cluster_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.cluster[0].dns_name
    zone_id                = aws_lb.cluster[0].zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apps" {
  count = var.create_nlb_and_dns ? 1 : 0

  zone_id = aws_route53_zone.cluster.zone_id
  name    = "*.apps.${var.cluster_name}.${var.cluster_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.cluster[0].dns_name
    zone_id                = aws_lb.cluster[0].zone_id
    evaluate_target_health = false
  }
}
