# ── Storage Account (used for private endpoint + UPI bootstrap.ign) ──────────

resource "azurerm_storage_account" "mirror" {
  name                     = replace("${var.prefix_for_name}mirror", "-", "")
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = false

  tags = {
    Name = "${var.prefix_for_name}-mirror-storage"
  }
}

resource "azurerm_storage_container" "bootstrap" {
  name                  = "bootstrap"
  storage_account_id    = azurerm_storage_account.mirror.id
  container_access_type = "private"
}

# ── Private Endpoint for Storage (blob) ──────────────────────────────────────
# Allows the disconnected VNet to reach Azure Storage without internet

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "${var.prefix_for_name}-storage-blob-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.prefix_for_name}-storage-blob-psc"
    private_connection_resource_id = azurerm_storage_account.mirror.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "storage-blob-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_blob.id]
  }

  tags = {
    Name = "${var.prefix_for_name}-storage-blob-pe"
  }
}

resource "azurerm_private_dns_zone" "storage_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob_disconnected" {
  name                  = "${var.prefix_for_name}-storage-blob-disconnected"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob.name
  virtual_network_id    = azurerm_virtual_network.disconnected.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob_egress" {
  name                  = "${var.prefix_for_name}-storage-blob-egress"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob.name
  virtual_network_id    = azurerm_virtual_network.egress.id
}
