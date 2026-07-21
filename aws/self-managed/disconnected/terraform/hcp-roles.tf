# ── Self-Managed HCP Operator Roles (Disconnected) ───────────────────────────
# Creates the OIDC S3 bucket, OIDC providers, and the 7 OIDC-based IAM
# roles required by each self-managed HCP HostedCluster's rolesRef, using
# ROSA managed policies.
#
# Simplified for disconnected: same-account only, pvt endpoint only,
# uses the existing disconnected VPC (no separate VPC).
#
# OIDC issuer URL pattern (served via CloudFront):
#   https://<cloudfront-domain>/<prefix>-<suffix>

variable "hcp_cluster_suffixes" {
  description = "List of HCP cluster suffixes to deploy (e.g. [\"hcp1\"]). Empty list disables role creation."
  type        = list(string)
  default     = []
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOCALS
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  hcp_enabled     = length(var.hcp_cluster_suffixes) > 0
  hcp_bucket_name = "self-managed-hcp-oidc-${var.openshift_cluster_name_suffix}"

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

  hcp_clusters = {
    for suffix in var.hcp_cluster_suffixes : suffix => {
      cluster_name = "${var.openshift_cluster_name_suffix}-${suffix}"
    }
  }

  hcp_pvt_clusters = {
    for suffix in var.hcp_cluster_suffixes : suffix => {
      cluster_name = "${var.openshift_cluster_name_suffix}-${suffix}-pvt"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SHARED RESOURCES — S3, CloudFront, SA keys
# ═══════════════════════════════════════════════════════════════════════════════

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

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "hcp_oidc" {
  count = local.hcp_enabled ? 1 : 0

  name                              = "${local.hcp_bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "hcp_oidc" {
  count   = local.hcp_enabled ? 1 : 0
  enabled = true
  comment = "OIDC endpoint for self-managed HCP clusters (disconnected)"

  origin {
    domain_name              = aws_s3_bucket.hcp_oidc[0].bucket_regional_domain_name
    origin_id                = "s3-${local.hcp_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.hcp_oidc[0].id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${local.hcp_bucket_name}"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name            = "${local.hcp_bucket_name}-cf"
    red-hat-managed = "true"
  }
}

resource "aws_s3_bucket_policy" "hcp_oidc" {
  count  = local.hcp_enabled ? 1 : 0
  bucket = aws_s3_bucket.hcp_oidc[0].id

  depends_on = [aws_s3_bucket_public_access_block.hcp_oidc]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.hcp_oidc[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.hcp_oidc[0].arn
        }
      }
    }]
  })
}

# ── CloudFront-derived locals ──

locals {
  hcp_cf_domain = local.hcp_enabled ? aws_cloudfront_distribution.hcp_oidc[0].domain_name : ""

  hcp_cluster_issuer = {
    for suffix, cluster in local.hcp_clusters : suffix => {
      cluster_name = cluster.cluster_name
      issuer_host  = "${local.hcp_cf_domain}/${cluster.cluster_name}"
      issuer_url   = "https://${local.hcp_cf_domain}/${cluster.cluster_name}"
    }
  }

  hcp_role_instances = merge([
    for suffix, issuer in local.hcp_cluster_issuer : {
      for role_key, role_def in local.hcp_operator_role_defs :
      "${suffix}/${role_key}" => {
        suffix           = suffix
        cluster_name     = issuer.cluster_name
        issuer_host      = issuer.issuer_host
        role_name        = "${issuer.cluster_name}-${role_def.role_suffix}"
        policy_arn       = role_def.policy_arn
        service_accounts = role_def.service_accounts
      }
    }
  ]...)
}

# ── SA Signing Keys ──

resource "tls_private_key" "hcp_sa" {
  for_each  = local.hcp_clusters
  algorithm = "RSA"
  rsa_bits  = 4096
}

data "external" "hcp_jwk" {
  for_each = local.hcp_clusters
  program  = ["python3", "${path.module}/scripts/pem-to-jwk.py"]
  query = {
    public_key_pem = tls_private_key.hcp_sa[each.key].public_key_pem
  }
}

# ── OIDC Discovery Documents ──

resource "aws_s3_object" "hcp_oidc_discovery" {
  for_each = local.hcp_cluster_issuer

  bucket       = aws_s3_bucket.hcp_oidc[0].id
  key          = "${each.value.cluster_name}/.well-known/openid-configuration"
  content_type = "application/json"

  content = <<-JSON
{
  "issuer": "${each.value.issuer_url}",
  "jwks_uri": "${each.value.issuer_url}/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
JSON
}

resource "aws_s3_object" "hcp_oidc_jwks" {
  for_each = local.hcp_cluster_issuer

  bucket       = aws_s3_bucket.hcp_oidc[0].id
  key          = "${each.value.cluster_name}/openid/v1/jwks"
  content_type = "application/json"

  content = <<-JSON
{
  "keys": [
    {
      "use": "sig",
      "kty": "RSA",
      "kid": "${data.external.hcp_jwk[each.key].result.kid}",
      "alg": "RS256",
      "n": "${data.external.hcp_jwk[each.key].result.n}",
      "e": "${data.external.hcp_jwk[each.key].result.e}"
    }
  ]
}
JSON
}

# ── TLS Certificate (for OIDC provider thumbprint) ──

data "tls_certificate" "hcp_oidc" {
  for_each   = local.hcp_cluster_issuer
  url        = each.value.issuer_url
  depends_on = [aws_s3_object.hcp_oidc_discovery, aws_s3_object.hcp_oidc_jwks]
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM RESOURCES (same-account, same disconnected VPC)
# ═══════════════════════════════════════════════════════════════════════════════

# ── OIDC Providers ──

resource "aws_iam_openid_connect_provider" "hcp" {
  for_each = local.hcp_cluster_issuer

  url             = each.value.issuer_url
  client_id_list  = ["openshift", "sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.hcp_oidc[each.key].certificates[0].sha1_fingerprint]

  depends_on = [aws_s3_object.hcp_oidc_discovery, aws_s3_object.hcp_oidc_jwks]

  tags = {
    Name            = each.value.cluster_name
    red-hat-managed = "true"
  }
}

# ── Operator IAM Roles (7 per cluster) ──

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

# ── Worker Role + Instance Profile ──

resource "aws_iam_role" "hcp_worker" {
  for_each = local.hcp_clusters

  name = "${each.value.cluster_name}-ROSA-Worker-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name                  = "${each.value.cluster_name}-ROSA-Worker-Role"
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

  name = "${each.value.cluster_name}-ROSA-Worker-Role"
  role = aws_iam_role.hcp_worker[each.key].name

  tags = {
    Name            = "${each.value.cluster_name}-ROSA-Worker-Role"
    red-hat-managed = "true"
  }
}

# ── Ingress Route53 Policy ──

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
          aws_route53_zone.hcp_pvt_private[each.key].arn,
          aws_route53_zone.hcp_public_subdomain[0].arn,
        ]
      },
    ]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE53 ZONES
# ═══════════════════════════════════════════════════════════════════════════════

# Look up the parent base domain public zone for NS delegation
data "aws_route53_zone" "public" {
  count        = local.hcp_enabled ? 1 : 0
  name         = var.openshift_base_domain
  private_zone = false
}

# Public subdomain zone: hcp.<base_domain>
resource "aws_route53_zone" "hcp_public_subdomain" {
  count = local.hcp_enabled ? 1 : 0

  name = "hcp.${var.openshift_base_domain}"

  tags = {
    Name            = "hcp-public-subdomain"
    red-hat-managed = "true"
  }
}

resource "aws_route53_record" "hcp_public_subdomain_ns" {
  count   = local.hcp_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "hcp.${var.openshift_base_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.hcp_public_subdomain[0].name_servers
}

# ── Private Zone for pvt clusters ──

resource "aws_route53_zone" "hcp_pvt_private" {
  for_each = local.hcp_pvt_clusters

  name = "${each.value.cluster_name}.hcp.${var.openshift_base_domain}"

  vpc {
    vpc_id = aws_vpc.disconnected.id
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name            = "${each.value.cluster_name}-private-zone"
    red-hat-managed = "true"
  }
}

resource "aws_route53_zone_association" "hcp_pvt_private_egress" {
  for_each = local.hcp_pvt_clusters

  zone_id = aws_route53_zone.hcp_pvt_private[each.key].zone_id
  vpc_id  = aws_vpc.egress.id
}

resource "aws_route53_zone" "hcp_pvt_hypershift_local" {
  for_each = local.hcp_pvt_clusters

  name = "${each.value.cluster_name}.hypershift.local"

  vpc {
    vpc_id = aws_vpc.disconnected.id
  }

  lifecycle {
    ignore_changes = [vpc]
  }

  tags = {
    Name            = "${each.value.cluster_name}-hypershift-local"
    red-hat-managed = "true"
  }
}

resource "aws_route53_zone_association" "hcp_pvt_hypershift_local_egress" {
  for_each = local.hcp_pvt_clusters

  zone_id = aws_route53_zone.hcp_pvt_hypershift_local[each.key].zone_id
  vpc_id  = aws_vpc.egress.id
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRIVATELINK — IAM User + Access Key
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_user" "hcp_privatelink" {
  count = local.hcp_enabled ? 1 : 0
  name  = "hypershift-operator-pl"

  tags = {
    Name            = "hypershift-operator-pl"
    red-hat-managed = "true"
  }
}

resource "aws_iam_user_policy" "hcp_privatelink" {
  count = local.hcp_enabled ? 1 : 0
  name  = "hypershift-operator-privatelink"
  user  = aws_iam_user.hcp_privatelink[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:CreateVpcEndpointServiceConfiguration",
        "ec2:DescribeVpcEndpointServiceConfigurations",
        "ec2:DeleteVpcEndpointServiceConfigurations",
        "ec2:DescribeVpcEndpointServicePermissions",
        "ec2:ModifyVpcEndpointServicePermissions",
        "ec2:RejectVpcEndpointConnections",
        "ec2:DescribeVpcEndpointConnections",
        "ec2:DescribeInstanceTypes",
        "ec2:CreateTags",
        "elasticloadbalancing:DescribeLoadBalancers",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "hcp_privatelink" {
  count = local.hcp_enabled ? 1 : 0
  user  = aws_iam_user.hcp_privatelink[0].name
}

# ═══════════════════════════════════════════════════════════════════════════════
# MERGED PER-SUFFIX LOCALS (for Ansible / outputs)
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  hcp_account_numbers = {
    for suffix in var.hcp_cluster_suffixes : suffix => data.aws_caller_identity.current.account_id
  }

  hcp_base_domains = {
    for suffix in var.hcp_cluster_suffixes : suffix => "hcp.${var.openshift_base_domain}"
  }

  hcp_public_zone_ids = local.hcp_enabled ? {
    for suffix in var.hcp_cluster_suffixes : suffix => aws_route53_zone.hcp_public_subdomain[0].zone_id
  } : {}

  hcp_pvt_private_zone_ids = {
    for suffix in var.hcp_cluster_suffixes : suffix => aws_route53_zone.hcp_pvt_private[suffix].zone_id
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUTS
# ═══════════════════════════════════════════════════════════════════════════════

output "hcp_oidc_bucket_name" {
  description = "Name of the OIDC S3 bucket shared by all HCP clusters"
  value       = local.hcp_enabled ? aws_s3_bucket.hcp_oidc[0].id : null
}

output "hcp_cloudfront_domain" {
  description = "CloudFront distribution domain serving the OIDC S3 bucket"
  value       = local.hcp_enabled ? aws_cloudfront_distribution.hcp_oidc[0].domain_name : null
}

output "hcp_account_numbers" {
  description = "Per-cluster AWS account IDs"
  value       = local.hcp_account_numbers
}

output "hcp_base_domains" {
  description = "Per-cluster base domains"
  value       = local.hcp_base_domains
}

output "hcp_public_zone_ids" {
  description = "Per-cluster public hosted zone IDs"
  value       = local.hcp_public_zone_ids
}

output "hcp_pvt_private_zone_ids" {
  description = "Per-cluster private hosted zone IDs (pvt)"
  value       = local.hcp_pvt_private_zone_ids
}

output "hcp_operator_role_arns" {
  description = "Per-cluster map of rolesRef ARNs."
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
