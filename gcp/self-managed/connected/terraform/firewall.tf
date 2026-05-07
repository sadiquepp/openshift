# ── SSH access to bastion ─────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.prefix_for_name}-connected-allow-ssh"
  network = google_compute_network.connected.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["bastion"]
}

# ── VNC access to bastion ────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_vnc" {
  name    = "${var.prefix_for_name}-connected-allow-vnc"
  network = google_compute_network.connected.id

  allow {
    protocol = "tcp"
    ports    = ["5999"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["bastion"]
}

# ── Internal VPC traffic ─────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.prefix_for_name}-connected-allow-internal"
  network = google_compute_network.connected.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    var.control_plane_subnet_cidr,
    var.compute_subnet_cidr,
    var.bastion_subnet_cidr,
  ]
}

# ── GCP health-check probes (required for IPI load balancers) ────────────────

resource "google_compute_firewall" "allow_health_checks" {
  name        = "${var.prefix_for_name}-connected-allow-health-checks"
  network     = google_compute_network.connected.id
  description = "Allow inbound health-check probes from GCP load balancer ranges"

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}
