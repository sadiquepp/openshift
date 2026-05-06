locals {
  connected_vnet_name    = "${var.prefix_for_name}-connected"
  openshift_cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
}

# ── Connected VNet ────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "connected" {
  name                = local.connected_vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.connected_vnet_cidr]

  tags = {
    Name = local.connected_vnet_name
  }
}

# ── OpenShift Subnets (private, one per AZ) ───────────────────────────────────

resource "azurerm_subnet" "connected" {
  count = length(var.connected_subnet_cidrs)

  name                 = "${local.connected_vnet_name}-subnet-az${count.index + 1}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.connected.name
  address_prefixes     = [var.connected_subnet_cidrs[count.index]]
}

# ── Bastion Subnet ────────────────────────────────────────────────────────────

resource "azurerm_subnet" "bastion" {
  name                 = "${local.connected_vnet_name}-bastion"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.connected.name
  address_prefixes     = [var.bastion_subnet_cidr]
}

# ── NAT Gateway (outbound internet for OpenShift node subnets) ───────────────

resource "azurerm_public_ip" "nat" {
  name                = "${local.connected_vnet_name}-nat-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Name = "${local.connected_vnet_name}-nat-pip"
  }
}

resource "azurerm_nat_gateway" "main" {
  name                = "${local.connected_vnet_name}-nat"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name = "${local.connected_vnet_name}-nat"
  }
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "connected" {
  count = length(azurerm_subnet.connected)

  subnet_id      = azurerm_subnet.connected[count.index].id
  nat_gateway_id = azurerm_nat_gateway.main.id
}
