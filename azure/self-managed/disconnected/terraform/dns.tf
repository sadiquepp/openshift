# ── Private DNS Zone for OpenShift Cluster ────────────────────────────────────
# Equivalent to Route53 private hosted zone in AWS

resource "azurerm_private_dns_zone" "cluster" {
  name                = "${local.openshift_cluster_name}.${var.openshift_base_domain}"
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name = "${local.openshift_cluster_name}-dns"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "cluster_disconnected" {
  name                  = "${var.prefix_for_name}-cluster-disconnected"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = azurerm_virtual_network.disconnected.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "cluster_egress" {
  name                  = "${var.prefix_for_name}-cluster-egress"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = azurerm_virtual_network.egress.id
  registration_enabled  = false
}
