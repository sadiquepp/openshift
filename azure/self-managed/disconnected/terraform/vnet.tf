locals {
  disconnected_vnet_name = "${var.prefix_for_name}-disconnected"
  egress_vnet_name       = "${var.prefix_for_name}-egress"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  azs                    = ["1", "2", "3"]
}

# ── Disconnected VNet ────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "disconnected" {
  name                = local.disconnected_vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.disconnected_vnet_cidr]

  tags = {
    Name = local.disconnected_vnet_name
  }
}

resource "azurerm_subnet" "disconnected" {
  count = length(var.disconnected_subnet_cidrs)

  name                 = "${local.disconnected_vnet_name}-subnet-az${count.index + 1}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.disconnected.name
  address_prefixes     = [var.disconnected_subnet_cidrs[count.index]]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "${local.disconnected_vnet_name}-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.disconnected.name
  address_prefixes     = [var.private_endpoint_subnet_cidr]
}

# ── Egress VNet ──────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "egress" {
  name                = local.egress_vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.egress_vnet_cidr]

  tags = {
    Name = local.egress_vnet_name
  }
}

resource "azurerm_subnet" "egress_public" {
  name                 = "${local.egress_vnet_name}-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.egress.name
  address_prefixes     = [var.egress_public_subnet_cidr]
}

# ── VNet Peering (replaces AWS Transit Gateway) ──────────────────────────────

resource "azurerm_virtual_network_peering" "disconnected_to_egress" {
  name                      = "${var.prefix_for_name}-disconnected-to-egress"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.disconnected.name
  remote_virtual_network_id = azurerm_virtual_network.egress.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false

  depends_on = [
    azurerm_subnet.disconnected,
    azurerm_subnet.private_endpoints,
    azurerm_subnet.egress_public,
    azurerm_subnet.firewall,
    azurerm_subnet.firewall_management,
  ]
}

resource "azurerm_virtual_network_peering" "egress_to_disconnected" {
  name                      = "${var.prefix_for_name}-egress-to-disconnected"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.egress.name
  remote_virtual_network_id = azurerm_virtual_network.disconnected.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false

  depends_on = [
    azurerm_subnet.disconnected,
    azurerm_subnet.private_endpoints,
    azurerm_subnet.egress_public,
    azurerm_subnet.firewall,
    azurerm_subnet.firewall_management,
  ]
}

# ── Route Table for Disconnected Subnets ─────────────────────────────────────

resource "azurerm_route_table" "disconnected" {
  name                          = "${var.prefix_for_name}-disconnected-rt"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.main.ip_configuration[0].private_ip_address
  }

  tags = {
    Name = "${var.prefix_for_name}-disconnected-rt"
  }
}

resource "azurerm_subnet_route_table_association" "disconnected" {
  count = length(azurerm_subnet.disconnected)

  subnet_id      = azurerm_subnet.disconnected[count.index].id
  route_table_id = azurerm_route_table.disconnected.id
}
