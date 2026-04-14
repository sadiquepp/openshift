# ─────────────────────────────────────────
# The Ansible playbook rendered two Jinja2
# templates (route53-policy.json.j2 and
# endpoint-policy.json.j2) that are not
# included in the repo. The assume-role
# policies below follow the standard ROSA
# shared-VPC pattern: the ROSA service
# account in the *installer* account is
# allowed to assume these roles.
# Adjust the Principal if your templates
# differed.
# ─────────────────────────────────────────

data "aws_iam_policy_document" "route53_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      # Allow the target account (ROSA installer account) to assume this role
      identifiers = ["arn:aws:iam::${var.aws_account_number_to_share_with}:root"]
    }
  }
}

data "aws_iam_policy_document" "endpoint_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_number_to_share_with}:root"]
    }
  }
}

resource "aws_iam_role" "route53" {
  name               = local.route53_role_name
  assume_role_policy = data.aws_iam_policy_document.route53_assume_role.json

  tags = {
    Name = local.route53_role_name
  }
}

resource "aws_iam_role_policy_attachment" "route53" {
  role       = aws_iam_role.route53.name
  policy_arn = "arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy"
}

resource "aws_iam_role" "endpoint" {
  name               = local.endpoint_role_name
  assume_role_policy = data.aws_iam_policy_document.endpoint_assume_role.json

  tags = {
    Name = local.endpoint_role_name
  }
}

resource "aws_iam_role_policy_attachment" "endpoint" {
  role       = aws_iam_role.endpoint.name
  policy_arn = "arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy"
}
