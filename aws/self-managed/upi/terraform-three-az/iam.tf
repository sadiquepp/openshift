data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ── Master IAM role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "master" {
  name               = "${local.infra_id}-master-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.infra_id}-master-role" }
}

resource "aws_iam_role_policy" "master" {
  name = "${local.infra_id}-master-policy"
  role = aws_iam_role.master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:AttachVolume", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateSecurityGroup", "ec2:CreateTags", "ec2:CreateVolume",
        "ec2:DeleteSecurityGroup", "ec2:DeleteVolume", "ec2:Describe*",
        "ec2:DetachVolume", "ec2:ModifyInstanceAttribute", "ec2:ModifyVolume",
        "ec2:RevokeSecurityGroupIngress",
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:AttachLoadBalancerToSubnets",
        "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancerPolicy",
        "elasticloadbalancing:CreateLoadBalancerListeners",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:ConfigureHealthCheck",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancerListeners",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:DetachLoadBalancerFromSubnets",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
        "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
        "kms:DescribeKey"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "master" {
  name = local.master_instance_profile
  role = aws_iam_role.master.name
}

# ── Worker IAM role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "worker" {
  name               = "${local.infra_id}-worker-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.infra_id}-worker-role" }
}

resource "aws_iam_role_policy" "worker" {
  name = "${local.infra_id}-worker-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeRegions"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "worker" {
  name = local.worker_instance_profile
  role = aws_iam_role.worker.name
}

# ── Bootstrap IAM role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "bootstrap" {
  name               = "${local.infra_id}-bootstrap-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.infra_id}-bootstrap-role" }
}

resource "aws_iam_role_policy" "bootstrap" {
  name = "${local.infra_id}-bootstrap-policy"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ec2:Describe*",   Resource = "*" },
      { Effect = "Allow", Action = "ec2:AttachVolume", Resource = "*" },
      { Effect = "Allow", Action = "ec2:DetachVolume", Resource = "*" },
      { Effect = "Allow", Action = "s3:GetObject",    Resource = "*" }
    ]
  })
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "${local.infra_id}-bootstrap-profile"
  role = aws_iam_role.bootstrap.name
}
