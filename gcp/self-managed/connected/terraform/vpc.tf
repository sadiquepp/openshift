locals {
  connected_vpc_name        = "${var.prefix_for_name}-connected"
  openshift_cluster_name    = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  control_plane_subnet_name = "${local.connected_vpc_name}-control-plane"
  compute_subnet_name       = "${local.connected_vpc_name}-compute"
  bastion_subnet_name       = "${local.connected_vpc_name}-bastion"
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

resource "google_compute_network" "connected" {
  name                    = local.connected_vpc_name
  auto_create_subnetworks = false
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "google_compute_subnetwork" "control_plane" {
  name                     = local.control_plane_subnet_name
  ip_cidr_range            = var.control_plane_subnet_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.connected.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "compute" {
  name                     = local.compute_subnet_name
  ip_cidr_range            = var.compute_subnet_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.connected.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "bastion" {
  name          = local.bastion_subnet_name
  ip_cidr_range = var.bastion_subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.connected.id
}

# ── Cloud Router + NAT (outbound internet for all subnets) ───────────────────

resource "google_compute_router" "connected" {
  name    = "${var.prefix_for_name}-connected-router"
  region  = var.gcp_region
  network = google_compute_network.connected.id
}

resource "google_compute_router_nat" "connected" {
  name                               = "${var.prefix_for_name}-connected-nat"
  router                             = google_compute_router.connected.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
