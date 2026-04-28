resource "azurerm_resource_group" "main" {
  name     = "${var.prefix_for_name}-disconnected-rg"
  location = var.azure_region

  tags = {
    Environment = "disconnected"
    ManagedBy   = "terraform"
  }
}
