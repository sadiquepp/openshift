# ─────────────────────────────────────────────────────────────────────────────
# ROSA HCP operator roles
#
# All eight roles share the same assume-role structure from the Jinja2 templates:
#   sts:AssumeRoleWithWebIdentity from the ROSA OIDC provider,
#   conditioned on a specific service account sub claim.
#
# The local.operator_roles map in locals.tf drives all eight roles from a single
# pair of resources, eliminating eight near-identical resource blocks.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "operator_trust" {
  for_each = local.operator_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = each.value.service_accounts
    }
  }
}

resource "aws_iam_role" "operator" {
  for_each = local.operator_roles

  name               = "${local.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.operator_trust[each.key].json

  tags = merge(local.common_tags, {
    operator_name      = each.value.operator_name
    operator_namespace = each.value.operator_namespace
  })
}

# AWS-managed policy attachments — one attachment resource per (role, policy) pair
resource "aws_iam_role_policy_attachment" "operator_managed" {
  for_each = {
    for pair in flatten([
      for role_key, role_cfg in local.operator_roles : [
        for policy_arn in role_cfg.managed_policies : {
          key        = "${role_key}__${policy_arn}"
          role_key   = role_key
          policy_arn = policy_arn
        }
      ]
    ]) : pair.key => pair
  }

  role       = aws_iam_role.operator[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

# Customer-managed (extra) policy attachments — route53/endpoint assume-role policies
resource "aws_iam_role_policy_attachment" "operator_extra" {
  for_each = {
    for pair in flatten([
      for role_key, role_cfg in local.operator_roles : [
        for policy_arn in role_cfg.extra_policies : {
          key        = "${role_key}__${policy_arn}"
          role_key   = role_key
          policy_arn = policy_arn
        }
      ]
    ]) : pair.key => pair
  }

  role       = aws_iam_role.operator[each.value.role_key].name
  policy_arn = each.value.policy_arn

  depends_on = [
    aws_iam_policy.route53_assume,
    aws_iam_policy.endpoint_assume,
  ]
}
