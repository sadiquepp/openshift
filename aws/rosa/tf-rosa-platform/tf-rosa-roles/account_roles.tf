# ─────────────────────────────────────────────────────────────────────────────
# Account roles (Installer / Support / Worker)
#
# The Ansible playbook read three static JSON files:
#   rosa-installer-policy.json
#   rosa-support-policy.json
#   rosa-worker-policy.json
#
# These are the standard Red Hat trust policies for ROSA HCP. They allow the
# Red Hat service principal to assume these roles. The documents below match
# the published ROSA HCP account-role trust policies. If your files differed,
# replace the jsonencode blocks with file("path/to/policy.json") calls.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Red Hat's AWS account that is allowed to assume ROSA account roles
  redhat_aws_account = "710019948333"
}

data "aws_iam_policy_document" "installer_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.redhat_aws_account}:role/RH-Managed-OpenShift-Installer"]
    }
  }
}

data "aws_iam_policy_document" "support_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.redhat_aws_account}:role/RH-Technical-Support-Access"]
    }
  }
}

data "aws_iam_policy_document" "worker_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ── Installer role ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "installer" {
  name               = "${local.cluster_name}-HCP-ROSA-Installer-Role"
  assume_role_policy = data.aws_iam_policy_document.installer_trust.json

  tags = merge(local.common_tags, {
    rosa_role_type        = "installer"
    rosa_openshift_version = var.openshift_major_version
  })
}

resource "aws_iam_role_policy_attachment" "installer_rosa_policy" {
  role       = aws_iam_role.installer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ROSAInstallerPolicy"
}

resource "aws_iam_role_policy_attachment" "installer_route53_assume" {
  role       = aws_iam_role.installer.name
  policy_arn = aws_iam_policy.route53_assume.arn
}

resource "aws_iam_role_policy_attachment" "installer_endpoint_assume" {
  role       = aws_iam_role.installer.name
  policy_arn = aws_iam_policy.endpoint_assume.arn
}

# ── Support role ───────────────────────────────────────────────────────────────

resource "aws_iam_role" "support" {
  name               = "${local.cluster_name}-HCP-ROSA-Support-Role"
  assume_role_policy = data.aws_iam_policy_document.support_trust.json

  tags = merge(local.common_tags, {
    rosa_role_type        = "support"
    rosa_openshift_version = var.openshift_major_version
  })
}

resource "aws_iam_role_policy_attachment" "support_rosa_policy" {
  role       = aws_iam_role.support.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ROSASRESupportPolicy"
}

# ── Worker role ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "worker" {
  name               = "${local.cluster_name}-HCP-ROSA-Worker-Role"
  assume_role_policy = data.aws_iam_policy_document.worker_trust.json

  tags = merge(local.common_tags, {
    rosa_role_type     = "instance_worker"
    operator_namespace = var.openshift_major_version
  })
}

resource "aws_iam_role_policy_attachment" "worker_rosa_policy" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ROSAWorkerInstancePolicy"
}

resource "aws_iam_role_policy_attachment" "worker_ecr_policy" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "worker" {
  name = "${local.cluster_name}-HCP-ROSA-Worker-Role"
  role = aws_iam_role.worker.name
}
