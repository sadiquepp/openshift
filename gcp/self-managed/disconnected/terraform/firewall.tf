# ── Disconnected VPC Firewall Rules ───────────────────────────────────────────

resource "google_compute_firewall" "disconnected_allow_internal" {
  name    = "${var.prefix_for_name}-disconnected-allow-internal"
  network = google_compute_network.disconnected.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.control_plane_subnet_cidr, var.compute_subnet_cidr]
}

resource "google_compute_firewall" "disconnected_allow_from_egress" {
  name    = "${var.prefix_for_name}-disconnected-allow-from-egress"
  network = google_compute_network.disconnected.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.egress_subnet_cidr]
}

resource "google_compute_firewall" "disconnected_deny_egress_internet" {
  name      = "${var.prefix_for_name}-disconnected-deny-egress-internet"
  network   = google_compute_network.disconnected.id
  direction = "EGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "disconnected_allow_egress_internal" {
  name      = "${var.prefix_for_name}-disconnected-allow-egress-internal"
  network   = google_compute_network.disconnected.id
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  destination_ranges = [
    var.control_plane_subnet_cidr,
    var.compute_subnet_cidr,
    var.egress_subnet_cidr,
  ]
}

resource "google_compute_firewall" "disconnected_allow_egress_psc" {
  name      = "${var.prefix_for_name}-disconnected-allow-egress-psc"
  network   = google_compute_network.disconnected.id
  direction = "EGRESS"
  priority  = 900

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  destination_ranges = ["${var.psc_endpoint_ip}/32"]
}

resource "google_compute_firewall" "disconnected_allow_egress_google_hc" {
  name        = "${var.prefix_for_name}-disconnected-allow-egress-google-hc"
  network     = google_compute_network.disconnected.id
  description = "Allow health-check probes and metadata server from GCP infra ranges"
  direction   = "EGRESS"
  priority    = 800

  allow {
    protocol = "tcp"
  }

  destination_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
    "169.254.169.254/32",
  ]
}

resource "google_compute_firewall" "disconnected_allow_ingress_google_hc" {
  name        = "${var.prefix_for_name}-disconnected-allow-ingress-google-hc"
  network     = google_compute_network.disconnected.id
  description = "Allow inbound health-check probes from GCP load balancer ranges"
  direction   = "INGRESS"
  priority    = 800

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}

# ── Egress VPC Firewall Rules ─────────────────────────────────────────────────

resource "google_compute_firewall" "egress_allow_ssh" {
  name    = "${var.prefix_for_name}-egress-allow-ssh"
  network = google_compute_network.egress.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["bastion"]
}

resource "google_compute_firewall" "egress_allow_mirror" {
  name    = "${var.prefix_for_name}-egress-allow-mirror"
  network = google_compute_network.egress.id

  allow {
    protocol = "tcp"
    ports    = ["8444"]
  }

  source_ranges = [var.control_plane_subnet_cidr, var.compute_subnet_cidr, var.egress_subnet_cidr]
  target_tags   = ["bastion"]
}

resource "google_compute_firewall" "egress_allow_squid" {
  name    = "${var.prefix_for_name}-egress-allow-squid"
  network = google_compute_network.egress.id

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }

  source_ranges = [var.control_plane_subnet_cidr, var.compute_subnet_cidr, var.egress_subnet_cidr]
  target_tags   = ["bastion"]
}

resource "google_compute_firewall" "egress_allow_vnc" {
  name    = "${var.prefix_for_name}-egress-allow-vnc"
  network = google_compute_network.egress.id

  allow {
    protocol = "tcp"
    ports    = ["5999"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["bastion"]
}

resource "google_compute_firewall" "egress_allow_internal" {
  name    = "${var.prefix_for_name}-egress-allow-internal"
  network = google_compute_network.egress.id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.egress_subnet_cidr, var.control_plane_subnet_cidr, var.compute_subnet_cidr]
}
