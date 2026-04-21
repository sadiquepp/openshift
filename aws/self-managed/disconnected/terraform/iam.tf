resource "aws_iam_role" "ocp_install_ec2" {
  name = "${var.prefix_for_name}-ocp-install-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  managed_policy_arns = [
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

resource "aws_iam_instance_profile" "ocp_install_ec2" {
  name = "${var.prefix_for_name}-ocp-install-ec2"
  role = aws_iam_role.ocp_install_ec2.name
}
