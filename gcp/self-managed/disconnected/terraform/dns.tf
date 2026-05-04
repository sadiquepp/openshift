# ── googleapis.com → PSC endpoint ─────────────────────────────────────────────

resource "google_dns_managed_zone" "googleapis" {
  name        = "${var.prefix_for_name}-googleapis"
  dns_name    = "googleapis.com."
  description = "Route googleapis.com to PSC endpoint"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.disconnected.id
    }
  }
}

resource "google_dns_record_set" "googleapis_wildcard" {
  name         = "*.googleapis.com."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.googleapis.name
  rrdatas      = [google_compute_global_address.psc_apis.address]
}

# ── gcr.io → PSC endpoint ────────────────────────────────────────────────────

resource "google_dns_managed_zone" "gcr" {
  name        = "${var.prefix_for_name}-gcr-io"
  dns_name    = "gcr.io."
  description = "Route gcr.io to PSC endpoint"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.disconnected.id
    }
  }
}

resource "google_dns_record_set" "gcr_wildcard" {
  name         = "*.gcr.io."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.gcr.name
  rrdatas      = [google_compute_global_address.psc_apis.address]
}

# ── pkg.dev → PSC endpoint (Artifact Registry) ──────────────────────────────

resource "google_dns_managed_zone" "pkg_dev" {
  name        = "${var.prefix_for_name}-pkg-dev"
  dns_name    = "pkg.dev."
  description = "Route pkg.dev to PSC endpoint"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.disconnected.id
    }
  }
}

resource "google_dns_record_set" "pkg_dev_wildcard" {
  name         = "*.pkg.dev."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.pkg_dev.name
  rrdatas      = [google_compute_global_address.psc_apis.address]
}

# ── accounts.google.com → PSC endpoint ───────────────────────────────────────

resource "google_dns_managed_zone" "accounts_google" {
  name        = "${var.prefix_for_name}-accounts-google"
  dns_name    = "accounts.google.com."
  description = "Route accounts.google.com to PSC endpoint for OAuth"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.disconnected.id
    }
  }
}

resource "google_dns_record_set" "accounts_google_a" {
  name         = "accounts.google.com."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.accounts_google.name
  rrdatas      = [google_compute_global_address.psc_apis.address]
}

# ── Mirror Registry DNS (mirror.internal) ────────────────────────────────────
# Ensures the bastion mirror registry hostname is resolvable from both VPCs.

resource "google_dns_managed_zone" "mirror" {
  name        = "${var.prefix_for_name}-mirror-internal"
  dns_name    = "mirror.internal."
  description = "Internal DNS for mirror registry on bastion"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.disconnected.id
    }
    networks {
      network_url = google_compute_network.egress.id
    }
  }
}

resource "google_dns_record_set" "bastion_mirror" {
  name         = "${google_compute_instance.bastion.name}.mirror.internal."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.mirror.name
  rrdatas      = [google_compute_instance.bastion.network_interface[0].network_ip]
}
