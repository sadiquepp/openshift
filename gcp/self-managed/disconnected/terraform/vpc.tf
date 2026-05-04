locals {
  disconnected_vpc_name      = "${var.prefix_for_name}-disconnected"
  egress_vpc_name            = "${var.prefix_for_name}-egress"
  openshift_cluster_name     = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  control_plane_subnet_name  = "${local.disconnected_vpc_name}-control-plane"
  compute_subnet_name        = "${local.disconnected_vpc_name}-compute"
  egress_subnet_name         = "${local.egress_vpc_name}-public"
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

resource "google_compute_network" "disconnected" {
  name                    = local.disconnected_vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "control_plane" {
  name                     = local.control_plane_subnet_name
  ip_cidr_range            = var.control_plane_subnet_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.disconnected.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "compute" {
  name                     = local.compute_subnet_name
  ip_cidr_range            = var.compute_subnet_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.disconnected.id
  private_ip_google_access = true
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

resource "google_compute_network" "egress" {
  name                    = local.egress_vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "egress" {
  name          = local.egress_subnet_name
  ip_cidr_range = var.egress_subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.egress.id
}

# ── VPC Peering ───────────────────────────────────────────────────────────────

resource "google_compute_network_peering" "disconnected_to_egress" {
  name                 = "${var.prefix_for_name}-disconnected-to-egress"
  network              = google_compute_network.disconnected.id
  peer_network         = google_compute_network.egress.id
  export_custom_routes = true
  import_custom_routes = true
}

resource "google_compute_network_peering" "egress_to_disconnected" {
  name                 = "${var.prefix_for_name}-egress-to-disconnected"
  network              = google_compute_network.egress.id
  peer_network         = google_compute_network.disconnected.id
  export_custom_routes = true
  import_custom_routes = true

  depends_on = [google_compute_network_peering.disconnected_to_egress]
}

# ── Cloud Router + NAT (egress VPC, for bastion outbound) ─────────────────────

resource "google_compute_router" "egress" {
  name    = "${var.prefix_for_name}-egress-router"
  region  = var.gcp_region
  network = google_compute_network.egress.id
}

resource "google_compute_router_nat" "egress" {
  name                               = "${var.prefix_for_name}-egress-nat"
  router                             = google_compute_router.egress.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
