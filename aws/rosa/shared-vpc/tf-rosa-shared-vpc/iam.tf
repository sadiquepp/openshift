# ─────────────────────────────────────────────────────────────────────────────
# Trust policies rendered from the actual Jinja2 templates:
#   route53-policy.json.j2  — trusts 3 specific roles in the ROSA account
#   endpoint-policy.json.j2 — trusts 2 specific roles in the ROSA account
#
# Note the cross-account dependency:
#   These roles live in the VPC owner account but trust roles that are
#   created in the ROSA account (Step 2 / tf-rosa-roles).
#   The ROSA account ID and cluster name must be passed in as variables.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  rosa_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  rosa_account_id   = var.rosa_account_id
}

# ── Route53 trust policy ───────────────────────────────────────────────────────
# Trusts: ingress-operator, HCP-ROSA-Installer-Role, control-plane-operator

data "aws_iam_policy_document" "route53_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.rosa_account_id}:role/${local.rosa_cluster_name}-openshift-ingress-operator-cloud-credentials",
        "arn:aws:iam::${local.rosa_account_id}:role/${local.rosa_cluster_name}-HCP-ROSA-Installer-Role",
        "arn:aws:iam::${local.rosa_account_id}:role/${local.rosa_cluster_name}-kube-system-control-plane-operator",
      ]
    }
  }
}

# ── Endpoint trust policy ──────────────────────────────────────────────────────
# Trusts: HCP-ROSA-Installer-Role, control-plane-operator

data "aws_iam_policy_document" "endpoint_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${local.rosa_account_id}:role/${local.rosa_cluster_name}-HCP-ROSA-Installer-Role",
        "arn:aws:iam::${local.rosa_account_id}:role/${local.rosa_cluster_name}-kube-system-control-plane-operator",
      ]
    }
  }
}

# ── IAM roles (in the VPC owner account) ──────────────────────────────────────

resource "aws_iam_role" "route53" {
  name               = "${local.rosa_cluster_name}-shared-vpc-route53"
  assume_role_policy = data.aws_iam_policy_document.route53_trust.json

  tags = {
    Name = "${local.rosa_cluster_name}-shared-vpc-route53"
  }
}

resource "aws_iam_role_policy_attachment" "route53" {
  role       = aws_iam_role.route53.name
  policy_arn = "arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy"
}

resource "aws_iam_role" "endpoint" {
  name               = "${local.rosa_cluster_name}-shared-vpc-endpoint"
  assume_role_policy = data.aws_iam_policy_document.endpoint_trust.json

  tags = {
    Name = "${local.rosa_cluster_name}-shared-vpc-endpoint"
  }
}

resource "aws_iam_role_policy_attachment" "endpoint" {
  role       = aws_iam_role.endpoint.name
  policy_arn = "arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy"
}
