# ── AzureFirewallSubnet (required name) ──────────────────────────────────────

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.egress.name
  address_prefixes     = [var.firewall_subnet_cidr]
}

# Basic SKU requires a dedicated management subnet
resource "azurerm_subnet" "firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.egress.name
  address_prefixes     = [var.firewall_management_subnet_cidr]
}

# ── Public IPs for Firewall ──────────────────────────────────────────────────

resource "azurerm_public_ip" "firewall" {
  name                = "${var.prefix_for_name}-firewall-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Name = "${var.prefix_for_name}-firewall-pip"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

resource "azurerm_public_ip" "firewall_mgmt" {
  name                = "${var.prefix_for_name}-firewall-mgmt-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Name = "${var.prefix_for_name}-firewall-mgmt-pip"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

# ── Firewall Policy ─────────────────────────────────────────────────────────

resource "azurerm_firewall_policy" "main" {
  name                = "${var.prefix_for_name}-fw-policy"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.firewall_sku

  tags = {
    Name = "${var.prefix_for_name}-fw-policy"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

# ── Application Rules (3 FQDNs per Red Hat docs) ────────────────────────────

resource "azurerm_firewall_policy_rule_collection_group" "openshift" {
  name               = "${var.prefix_for_name}-ocp-rules"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 100

  application_rule_collection {
    name     = "azure-apis"
    priority = 100
    action   = "Allow"

    rule {
      name = "arm-api"
      source_addresses = [var.disconnected_vnet_cidr]
      destination_fqdns = ["management.azure.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name = "entra-id"
      source_addresses = [var.disconnected_vnet_cidr]
      destination_fqdns = ["login.microsoftonline.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name = "storage-blob"
      source_addresses = [var.disconnected_vnet_cidr]
      destination_fqdns = ["*.blob.core.windows.net"]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  network_rule_collection {
    name     = "dns"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "allow-dns"
      source_addresses      = [var.disconnected_vnet_cidr]
      destination_addresses = ["168.63.129.16"]
      destination_ports     = ["53"]
      protocols             = ["UDP", "TCP"]
    }
  }
}

# ── Azure Firewall ──────────────────────────────────────────────────────────

resource "azurerm_firewall" "main" {
  name                = "${var.prefix_for_name}-firewall"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku
  firewall_policy_id  = azurerm_firewall_policy.main.id

  ip_configuration {
    name                 = "fw-ip-config"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  management_ip_configuration {
    name                 = "fw-mgmt-ip-config"
    subnet_id            = azurerm_subnet.firewall_management.id
    public_ip_address_id = azurerm_public_ip.firewall_mgmt.id
  }

  tags = {
    Name = "${var.prefix_for_name}-firewall"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}
