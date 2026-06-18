# ── Let's Encrypt Certificates ────────────────────────────────────────────────
# Generates a single TLS certificate via Let's Encrypt (ACME) with SANs for
# both the API server and wildcard Ingress of the public connected OCP cluster.
# DNS-01 challenge is validated against the Route53 public hosted zone.

variable "letsencrypt_enabled" {
  description = "Generate Let's Encrypt TLS certificates for API and Ingress (public cluster only)"
  type        = bool
  default     = false
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt ACME registration. Required when letsencrypt_enabled is true."
  type        = string
  default     = ""
}

check "letsencrypt_requires_email" {
  assert {
    condition     = !var.letsencrypt_enabled || var.letsencrypt_email != ""
    error_message = "letsencrypt_email must be set when letsencrypt_enabled is true."
  }
}

locals {
  cluster_fqdn = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}.${var.openshift_base_domain}"
}

# ── Route53 Public Zone Lookup ────────────────────────────────────────────────

data "aws_route53_zone" "letsencrypt_public" {
  count        = var.letsencrypt_enabled ? 1 : 0
  name         = var.openshift_base_domain
  private_zone = false
}

# ── ACME Account ──────────────────────────────────────────────────────────────

resource "tls_private_key" "letsencrypt_account" {
  count     = var.letsencrypt_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "reg" {
  count           = var.letsencrypt_enabled ? 1 : 0
  account_key_pem = tls_private_key.letsencrypt_account[0].private_key_pem
  email_address   = var.letsencrypt_email
}

# ── Certificate (API + Ingress wildcard) ──────────────────────────────────────

resource "acme_certificate" "cluster" {
  count                     = var.letsencrypt_enabled ? 1 : 0
  account_key_pem           = acme_registration.reg[0].account_key_pem
  common_name               = "api.${local.cluster_fqdn}"
  subject_alternative_names = ["*.apps.${local.cluster_fqdn}"]
  min_days_remaining        = 30

  dns_challenge {
    provider = "route53"
    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.letsencrypt_public[0].zone_id
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "letsencrypt_certificate_domains" {
  description = "Domains covered by the Let's Encrypt certificate"
  value       = var.letsencrypt_enabled ? ["api.${local.cluster_fqdn}", "*.apps.${local.cluster_fqdn}"] : []
}
