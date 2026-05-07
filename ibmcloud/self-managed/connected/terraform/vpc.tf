locals {
  connected_vpc_name     = "${var.prefix_for_name}-connected"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "ibm_is_vpc" "connected" {
  name                      = local.connected_vpc_name
  resource_group            = local.resource_group_id
  address_prefix_management = "manual"
}

# ── Address Prefixes (required for custom 172.16.x CIDRs) ────────────────────

resource "ibm_is_vpc_address_prefix" "control_plane" {
  count = length(var.zones)

  name = "${local.connected_vpc_name}-cp-prefix-${count.index + 1}"
  vpc  = ibm_is_vpc.connected.id
  zone = var.zones[count.index]
  cidr = var.control_plane_subnet_cidrs[count.index]
}

resource "ibm_is_vpc_address_prefix" "compute" {
  count = length(var.zones)

  name = "${local.connected_vpc_name}-compute-prefix-${count.index + 1}"
  vpc  = ibm_is_vpc.connected.id
  zone = var.zones[count.index]
  cidr = var.compute_subnet_cidrs[count.index]
}

resource "ibm_is_vpc_address_prefix" "bastion" {
  name = "${local.connected_vpc_name}-bastion-prefix"
  vpc  = ibm_is_vpc.connected.id
  zone = var.zones[0]
  cidr = var.bastion_subnet_cidr
}

# ── Public Gateways (outbound internet for all subnets) ──────────────────────

resource "ibm_is_public_gateway" "zones" {
  count = length(var.zones)

  name           = "${local.connected_vpc_name}-pgw-${count.index + 1}"
  vpc            = ibm_is_vpc.connected.id
  zone           = var.zones[count.index]
  resource_group = local.resource_group_id
}

# ── Control-Plane Subnets (one per zone) ─────────────────────────────────────

resource "ibm_is_subnet" "control_plane" {
  count = length(var.zones)

  name            = "${local.connected_vpc_name}-cp-${count.index + 1}"
  vpc             = ibm_is_vpc.connected.id
  zone            = var.zones[count.index]
  ipv4_cidr_block = var.control_plane_subnet_cidrs[count.index]
  resource_group  = local.resource_group_id
  public_gateway  = ibm_is_public_gateway.zones[count.index].id

  depends_on = [ibm_is_vpc_address_prefix.control_plane]
}

# ── Compute Subnets (one per zone) ───────────────────────────────────────────

resource "ibm_is_subnet" "compute" {
  count = length(var.zones)

  name            = "${local.connected_vpc_name}-compute-${count.index + 1}"
  vpc             = ibm_is_vpc.connected.id
  zone            = var.zones[count.index]
  ipv4_cidr_block = var.compute_subnet_cidrs[count.index]
  resource_group  = local.resource_group_id
  public_gateway  = ibm_is_public_gateway.zones[count.index].id

  depends_on = [ibm_is_vpc_address_prefix.compute]
}

# ── Bastion Subnet (zone 1) ─────────────────────────────────────────────────

resource "ibm_is_subnet" "bastion" {
  name            = "${local.connected_vpc_name}-bastion"
  vpc             = ibm_is_vpc.connected.id
  zone            = var.zones[0]
  ipv4_cidr_block = var.bastion_subnet_cidr
  resource_group  = local.resource_group_id
  public_gateway  = ibm_is_public_gateway.zones[0].id

  depends_on = [ibm_is_vpc_address_prefix.bastion]
}
