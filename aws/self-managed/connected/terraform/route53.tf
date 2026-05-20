# ── Public Hosted Zone ────────────────────────────────────────────────────────
# Required for public clusters. The installer expects a public Route53 zone
# matching openshift_base_domain to already exist.
#
# Set create_public_hosted_zone = false if you already have a public zone
# for this domain. AWS allows duplicate zone names, so leaving it true
# when one exists will create a second zone (not overwrite).
#
# After creation, update your domain registrar's NS records with the name
# servers from: terraform output public_hosted_zone_name_servers

resource "aws_route53_zone" "public" {
  count = var.create_public_hosted_zone ? 1 : 0

  name = var.openshift_base_domain

  lifecycle {
    prevent_destroy = true
  }
}
