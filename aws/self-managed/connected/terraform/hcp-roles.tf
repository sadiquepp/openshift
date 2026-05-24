# ── Self-Managed HCP Operator Roles ──────────────────────────────────────────
# Creates the OIDC S3 bucket, OIDC providers, and the 7 OIDC-based IAM
# roles required by each self-managed HCP HostedCluster's rolesRef, using
# ROSA managed policies.
#
# Supply one or more cluster suffixes (e.g. ["hcp1", "hcp2"]) to create a
# full set of OIDC provider + 7 roles per cluster. An empty list (default)
# creates nothing.
#
# OIDC issuer URL pattern (from hosted-cluster-hcp.yaml.j2 line 65):
#   https://self-managed-hcp-oidc-<prefix>.s3.<region>.amazonaws.com/<prefix>-<suffix>

variable "hcp_cluster_suffixes" {
  description = "List of HCP cluster suffixes to create operator roles for (e.g. [\"hcp1\", \"hcp2\"]). Empty list disables role creation."
  type        = list(string)
  default     = []
}

locals {
  hcp_enabled     = length(var.hcp_cluster_suffixes) > 0
  hcp_bucket_name = "self-managed-hcp-oidc-${var.openshift_cluster_name_suffix}"

  # Role definitions shared across all clusters
  hcp_operator_role_defs = {
    control-plane-operator = {
      role_suffix = "control-plane-operator"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSAControlPlaneOperatorPolicy"
      service_accounts = [
        "system:serviceaccount:kube-system:control-plane-operator",
      ]
    }
    openshift-image-registry = {
      role_suffix = "openshift-image-registry"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSAImageRegistryOperatorPolicy"
      service_accounts = [
        "system:serviceaccount:openshift-image-registry:cluster-image-registry-operator",
        "system:serviceaccount:openshift-image-registry:registry",
      ]
    }
    openshift-ingress = {
      role_suffix = "openshift-ingress"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSAIngressOperatorPolicy"
      service_accounts = [
        "system:serviceaccount:openshift-ingress-operator:ingress-operator",
      ]
    }
    cloud-controller = {
      role_suffix = "cloud-controller"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSAKubeControllerPolicy"
      service_accounts = [
        "system:serviceaccount:kube-system:kube-controller-manager",
      ]
    }
    cloud-network-config-controller = {
      role_suffix = "cloud-network-config-controller"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSACloudNetworkConfigOperatorPolicy"
      service_accounts = [
        "system:serviceaccount:openshift-cloud-network-config-controller:cloud-network-config-controller",
      ]
    }
    node-pool = {
      role_suffix = "node-pool"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSANodePoolManagementPolicy"
      service_accounts = [
        "system:serviceaccount:kube-system:capa-controller-manager",
      ]
    }
    aws-ebs-csi-driver-controller = {
      role_suffix = "aws-ebs-csi-driver-controller"
      policy_arn  = "arn:aws:iam::aws:policy/service-role/ROSAAmazonEBSCSIDriverOperatorPolicy"
      service_accounts = [
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-operator",
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-controller-sa",
      ]
    }
  }

  # Per-cluster metadata: OIDC issuer host, cluster name
  hcp_clusters = {
    for suffix in var.hcp_cluster_suffixes : suffix => {
      cluster_name = "${var.openshift_cluster_name_suffix}-${suffix}"
      issuer_host  = "self-managed-hcp-oidc-${var.openshift_cluster_name_suffix}.s3.${var.aws_region}.amazonaws.com/${var.openshift_cluster_name_suffix}-${suffix}"
      issuer_url   = "https://self-managed-hcp-oidc-${var.openshift_cluster_name_suffix}.s3.${var.aws_region}.amazonaws.com/${var.openshift_cluster_name_suffix}-${suffix}"
    }
  }

  # Flatten: one entry per (cluster-suffix, role) combination
  hcp_role_instances = merge([
    for suffix, cluster in local.hcp_clusters : {
      for role_key, role_def in local.hcp_operator_role_defs :
      "${suffix}/${role_key}" => {
        suffix           = suffix
        cluster_name     = cluster.cluster_name
        issuer_host      = cluster.issuer_host
        role_name        = "${cluster.cluster_name}-${role_def.role_suffix}"
        policy_arn       = role_def.policy_arn
        service_accounts = role_def.service_accounts
      }
    }
  ]...)
}

# ── OIDC S3 Bucket (shared by all clusters) ──────────────────────────────────
# One bucket hosts OIDC discovery docs for all HCP clusters under separate
# path prefixes (e.g. /<prefix>-hcp1, /<prefix>-hcp2).

resource "aws_s3_bucket" "hcp_oidc" {
  count  = local.hcp_enabled ? 1 : 0
  bucket = local.hcp_bucket_name

  tags = {
    Name            = local.hcp_bucket_name
    red-hat-managed = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "hcp_oidc" {
  count  = local.hcp_enabled ? 1 : 0
  bucket = aws_s3_bucket.hcp_oidc[0].id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "hcp_oidc" {
  count  = local.hcp_enabled ? 1 : 0
  bucket = aws_s3_bucket.hcp_oidc[0].id

  depends_on = [aws_s3_bucket_public_access_block.hcp_oidc]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:PutObject", "s3:GetObject"]
      Resource  = "${aws_s3_bucket.hcp_oidc[0].arn}/*"
    }]
  })
}

# ── OIDC Providers (one per cluster) ─────────────────────────────────────────

data "tls_certificate" "hcp_oidc" {
  for_each   = local.hcp_clusters
  url        = each.value.issuer_url
  depends_on = [aws_s3_bucket_policy.hcp_oidc]
}

resource "aws_iam_openid_connect_provider" "hcp" {
  for_each = local.hcp_clusters

  url             = each.value.issuer_url
  client_id_list  = ["openshift", "sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.hcp_oidc[each.key].certificates[0].sha1_fingerprint]

  depends_on = [aws_s3_bucket_policy.hcp_oidc]

  tags = {
    Name            = each.value.cluster_name
    red-hat-managed = "true"
  }
}

# ── Operator IAM Roles (7 per cluster) ───────────────────────────────────────

resource "aws_iam_role" "hcp_operator" {
  for_each = local.hcp_role_instances

  name = each.value.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.hcp[each.value.suffix].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${each.value.issuer_host}:sub" = each.value.service_accounts
        }
      }
    }]
  })

  tags = {
    Name                  = each.value.role_name
    red-hat-managed       = "true"
    rosa_hcp_policies     = "true"
    rosa_managed_policies = "true"
  }
}

resource "aws_iam_role_policy_attachment" "hcp_operator" {
  for_each = local.hcp_role_instances

  role       = aws_iam_role.hcp_operator[each.key].name
  policy_arn = each.value.policy_arn
}

# ── Worker Role + Instance Profile (one per cluster) ─────────────────────────
# Referenced by NodePool as instanceProfile: <prefix>-<suffix>-worker

resource "aws_iam_role" "hcp_worker" {
  for_each = local.hcp_clusters

  name = "${each.value.cluster_name}-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name                  = "${each.value.cluster_name}-worker"
    red-hat-managed       = "true"
    rosa_hcp_policies     = "true"
    rosa_managed_policies = "true"
  }
}

resource "aws_iam_role_policy_attachment" "hcp_worker" {
  for_each = local.hcp_clusters

  role       = aws_iam_role.hcp_worker[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ROSAWorkerInstancePolicy"
}

resource "aws_iam_instance_profile" "hcp_worker" {
  for_each = local.hcp_clusters

  name = "${each.value.cluster_name}-worker"
  role = aws_iam_role.hcp_worker[each.key].name

  tags = {
    Name            = "${each.value.cluster_name}-worker"
    red-hat-managed = "true"
  }
}

# ── Ingress Operator: self-managed Route53 policy ────────────────────────────
# ROSAIngressOperatorPolicy only allows ChangeResourceRecordSets for
# *.openshiftapps.com. For self-managed HCP we need the ingress operator
# to manage records in our own hosted zones.

resource "aws_iam_role_policy" "hcp_ingress_route53" {
  for_each = local.hcp_clusters

  name = "self-managed-ingress-route53"
  role = aws_iam_role.hcp_operator["${each.key}/openshift-ingress"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowChangeRecordsInClusterZones"
        Effect = "Allow"
        Action = ["route53:ChangeResourceRecordSets"]
        Resource = [
          aws_route53_zone.hcp_private[each.key].arn,
          data.aws_route53_zone.public[0].arn,
        ]
      },
    ]
  })
}

# ── Route53 Hosted Zones ─────────────────────────────────────────────────────

# 1. Per-cluster private hosted zone: <cluster_name>.<base_domain>
#    Zone ID is fed into the HostedCluster manifest as privateZoneID.
resource "aws_route53_zone" "hcp_private" {
  for_each = local.hcp_clusters

  name = "${each.value.cluster_name}.${var.openshift_base_domain}"

  vpc {
    vpc_id = aws_vpc.connected.id
  }

  tags = {
    Name            = "${each.value.cluster_name}-private-zone"
    red-hat-managed = "true"
  }
}

# 2. Look up the existing public hosted zone for openshift_base_domain.
#    Zone ID is fed into the HostedCluster manifest as publicZoneID.
data "aws_route53_zone" "public" {
  count        = local.hcp_enabled ? 1 : 0
  name         = var.openshift_base_domain
  private_zone = false
}

# 3. Per-cluster hypershift.local private zone (used internally by HyperShift).
resource "aws_route53_zone" "hcp_hypershift_local" {
  for_each = local.hcp_clusters

  name = "${each.value.cluster_name}.hypershift.local"

  vpc {
    vpc_id = aws_vpc.connected.id
  }

  tags = {
    Name            = "${each.value.cluster_name}-hypershift-local"
    red-hat-managed = "true"
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────────

output "hcp_oidc_bucket_name" {
  description = "Name of the OIDC S3 bucket shared by all HCP clusters"
  value       = local.hcp_enabled ? aws_s3_bucket.hcp_oidc[0].id : null
}

output "hcp_public_zone_id" {
  description = "Zone ID of the public hosted zone for openshift_base_domain"
  value       = local.hcp_enabled ? data.aws_route53_zone.public[0].zone_id : null
}

output "hcp_private_zone_ids" {
  description = "Per-cluster private hosted zone IDs (maps to HostedCluster privateZoneID)"
  value = {
    for suffix, cluster in local.hcp_clusters : suffix => aws_route53_zone.hcp_private[suffix].zone_id
  }
}

output "hcp_operator_role_arns" {
  description = "Per-cluster map of rolesRef ARNs. Key = cluster suffix, value = rolesRef fields."
  value = {
    for suffix, cluster in local.hcp_clusters : suffix => {
      controlPlaneOperatorARN = aws_iam_role.hcp_operator["${suffix}/control-plane-operator"].arn
      imageRegistryARN        = aws_iam_role.hcp_operator["${suffix}/openshift-image-registry"].arn
      ingressARN              = aws_iam_role.hcp_operator["${suffix}/openshift-ingress"].arn
      kubeCloudControllerARN  = aws_iam_role.hcp_operator["${suffix}/cloud-controller"].arn
      networkARN              = aws_iam_role.hcp_operator["${suffix}/cloud-network-config-controller"].arn
      nodePoolManagementARN   = aws_iam_role.hcp_operator["${suffix}/node-pool"].arn
      storageARN              = aws_iam_role.hcp_operator["${suffix}/aws-ebs-csi-driver-controller"].arn
    }
  }
}
