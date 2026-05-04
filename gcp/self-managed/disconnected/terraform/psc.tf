# ── Private Service Connect for Google APIs ───────────────────────────────────
# A single PSC endpoint gives the disconnected VPC private access to ALL
# Google APIs (Compute, Storage, IAM, DNS, etc.) without any internet path.
# This replaces Azure Firewall + Private Endpoints / AWS VPC Interface Endpoints.

resource "google_compute_global_address" "psc_apis" {
  name         = "${var.prefix_for_name}-psc-googleapis"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  network      = google_compute_network.disconnected.id
  address      = var.psc_endpoint_ip
}

resource "google_compute_global_forwarding_rule" "psc_apis" {
  name                  = "${replace(var.prefix_for_name, "-", "")}pscapis"
  target                = "all-apis"
  network               = google_compute_network.disconnected.id
  ip_address            = google_compute_global_address.psc_apis.id
  load_balancing_scheme = ""
}
