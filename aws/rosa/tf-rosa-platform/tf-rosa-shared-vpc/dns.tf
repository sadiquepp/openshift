# ─────────────────────────────────────────
# Private hosted zone: <cluster>.<base_domain>
# Primary VPC: disconnected
# ─────────────────────────────────────────

resource "aws_route53_zone" "cluster" {
  name    = "${local.cluster_name}.${var.openshift_base_domain}"
  comment = "Private zone for OpenShift cluster ${local.cluster_name}"

  vpc {
    vpc_id     = data.aws_vpc.disconnected.id
    vpc_region = var.aws_region
  }

  # Prevent Terraform from destroying the zone if the VPC association
  # block is changed (e.g. when adding the egress VPC below)
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name = "${local.cluster_name}.${var.openshift_base_domain}"
  }
}

# The Ansible playbook uses `aws route53 associate-vpc-with-hosted-zone`
# via shell to attach the egress VPC. Terraform models this as a
# separate aws_route53_zone_association resource.

resource "aws_route53_zone_association" "cluster_egress" {
  zone_id    = aws_route53_zone.cluster.zone_id
  vpc_id     = data.aws_vpc.egress.id
  vpc_region = var.aws_region
}

# ─────────────────────────────────────────
# Private hosted zone: rosa.<cluster>.<rosa_shared_vpc_cluster_domain>
# ─────────────────────────────────────────

resource "aws_route53_zone" "rosa" {
  name    = "rosa.${local.cluster_name}.${var.rosa_shared_vpc_cluster_domain}"
  comment = "ROSA shared-VPC private zone"

  vpc {
    vpc_id     = data.aws_vpc.disconnected.id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name = "rosa.${local.cluster_name}.${var.rosa_shared_vpc_cluster_domain}"
  }
}

# ─────────────────────────────────────────
# Private hosted zone: <cluster>.hypershift.local
# ─────────────────────────────────────────

resource "aws_route53_zone" "hypershift_local" {
  name    = "${local.cluster_name}.hypershift.local"
  comment = "Hypershift local private zone for ${local.cluster_name}"

  vpc {
    vpc_id     = data.aws_vpc.disconnected.id
    vpc_region = var.aws_region
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name = "${local.cluster_name}.hypershift.local"
  }
}
