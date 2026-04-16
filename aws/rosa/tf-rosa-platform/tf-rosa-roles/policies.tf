# ─────────────────────────────────────────────────────────────────────────────
# These two policies allow roles in this (installer) account to assume the
# Route53 and Endpoint roles that live in the VPC owner account.
# The Ansible playbook rendered rosa-shared-vpc-route53.json.j2 and
# rosa-shared-vpc-endpoint.json.j2 — those templates were not uploaded, so the
# policy documents below follow the standard ROSA shared-VPC pattern.
# Adjust the Resource ARN if your templates targeted a specific role rather than
# the account root.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "route53_assume" {
  statement {
    sid     = "AllowAssumeRoute53Role"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    resources = [
      "arn:aws:iam::${var.vpc_owner_account_id}:role/${local.cluster_name}-shared-vpc-route53",
    ]
  }
}

data "aws_iam_policy_document" "endpoint_assume" {
  statement {
    sid     = "AllowAssumeEndpointRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    resources = [
      "arn:aws:iam::${var.vpc_owner_account_id}:role/${local.cluster_name}-shared-vpc-endpoint",
    ]
  }
}

resource "aws_iam_policy" "route53_assume" {
  name   = "${local.cluster_name}-shared-vpc-route53-assume-role"
  policy = data.aws_iam_policy_document.route53_assume.json

  tags = merge(local.common_tags, {
    hcp-shared-vpc = "true"
  })
}

resource "aws_iam_policy" "endpoint_assume" {
  name   = "${local.cluster_name}-shared-vpc-endpoint-assume-role"
  policy = data.aws_iam_policy_document.endpoint_assume.json

  tags = merge(local.common_tags, {
    hcp-shared-vpc = "true"
  })
}
