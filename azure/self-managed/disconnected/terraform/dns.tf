# The OpenShift installer creates its own private DNS zone for the cluster
# (<cluster-name>.<base-domain>) in the installer-managed resource group and
# links it to the VNet.  Pre-creating the same zone here would cause an
# "overlapping namespaces" error, so we intentionally leave cluster DNS to
# the installer.

# ── Mirror Registry DNS ──────────────────────────────────────────────────────
# The bastion's short hostname (e.g. ijm-bg1-bastion) is used in the mirror
# registry TLS certificate and baked into install-config.yaml.  Azure DNS
# does not resolve short hostnames across VNet peering, so we create a
# private DNS zone to make the bastion reachable from the disconnected VNet.

resource "azurerm_private_dns_zone" "mirror" {
  name                = "mirror.internal"
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name = "${var.prefix_for_name}-mirror-dns"
  }

  lifecycle {
    ignore_changes = [tags["cost-center"]]
  }
}

resource "azurerm_private_dns_a_record" "bastion" {
  name                = azurerm_linux_virtual_machine.bastion.name
  zone_name           = azurerm_private_dns_zone.mirror.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_network_interface.bastion.private_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "mirror_disconnected" {
  name                  = "${var.prefix_for_name}-mirror-disconnected"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.mirror.name
  virtual_network_id    = azurerm_virtual_network.disconnected.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "mirror_egress" {
  name                  = "${var.prefix_for_name}-mirror-egress"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.mirror.name
  virtual_network_id    = azurerm_virtual_network.egress.id
}
