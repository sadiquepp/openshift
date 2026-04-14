data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ocp_install" {
  name               = "${var.prefix_for_name}-ocp-install-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.prefix_for_name}-ocp-install-ec2"
  }
}

locals {
  ocp_install_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
    "arn:aws:iam::aws:policy/AutoScalingFullAccess",
    "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/ResourceGroupsandTagEditorFullAccess",
    "arn:aws:iam::aws:policy/AmazonRoute53FullAccess",
    "arn:aws:iam::aws:policy/ServiceQuotasFullAccess",
    "arn:aws:iam::aws:policy/CloudFrontFullAccess",
  ]
}

resource "aws_iam_role_policy_attachment" "ocp_install" {
  for_each = toset(local.ocp_install_managed_policies)

  role       = aws_iam_role.ocp_install.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ocp_install" {
  name = "${var.prefix_for_name}-ocp-install-ec2"
  role = aws_iam_role.ocp_install.name
}
