# ─────────────────────────────────────────
# RAM Resource Share
# Shares the three disconnected subnets and
# the egress public AZ1 subnet with the
# ROSA installer account.
# ─────────────────────────────────────────

resource "aws_ram_resource_share" "subnets" {
  name                      = "${local.cluster_name}-${var.resource_share_name}"
  allow_external_principals = true

  tags = {
    Name = "${local.cluster_name}-${var.resource_share_name}"
  }
}

# Associate all four subnets with the share

resource "aws_ram_resource_association" "disconnected_az1" {
  resource_share_arn = aws_ram_resource_share.subnets.arn
  resource_arn       = data.aws_subnet.disconnected_az1.arn
}

resource "aws_ram_resource_association" "disconnected_az2" {
  resource_share_arn = aws_ram_resource_share.subnets.arn
  resource_arn       = data.aws_subnet.disconnected_az2.arn
}

resource "aws_ram_resource_association" "disconnected_az3" {
  resource_share_arn = aws_ram_resource_share.subnets.arn
  resource_arn       = data.aws_subnet.disconnected_az3.arn
}

resource "aws_ram_resource_association" "egress_public_az1" {
  resource_share_arn = aws_ram_resource_share.subnets.arn
  resource_arn       = data.aws_subnet.egress_public_az1.arn
}

# Grant access to the target AWS account

resource "aws_ram_principal_association" "rosa_account" {
  resource_share_arn = aws_ram_resource_share.subnets.arn
  principal          = var.aws_account_number_to_share_with
}
