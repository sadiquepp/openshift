# ── NSG for Disconnected Subnets ──────────────────────────────────────────────

resource "azurerm_network_security_group" "disconnected" {
  name                = "${var.prefix_for_name}-disconnected-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowVNetInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = {
    Name = "${var.prefix_for_name}-disconnected-nsg"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

resource "azurerm_subnet_network_security_group_association" "disconnected" {
  count = length(azurerm_subnet.disconnected)

  subnet_id                 = azurerm_subnet.disconnected[count.index].id
  network_security_group_id = azurerm_network_security_group.disconnected.id
}

# ── NSG for Bastion VM ───────────────────────────────────────────────────────

resource "azurerm_network_security_group" "bastion" {
  name                = "${var.prefix_for_name}-bastion-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowMirrorRegistry"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8444"
    source_address_prefixes    = [var.disconnected_vnet_cidr, var.egress_vnet_cidr]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSquidProxy"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3128"
    source_address_prefixes    = [var.disconnected_vnet_cidr, var.egress_vnet_cidr]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowVNC"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    Name = "${var.prefix_for_name}-bastion-nsg"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

resource "azurerm_subnet_network_security_group_association" "egress_public" {
  subnet_id                 = azurerm_subnet.egress_public.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}
