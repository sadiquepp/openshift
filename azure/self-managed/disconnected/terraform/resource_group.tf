resource "azurerm_resource_group" "main" {
  name     = "${var.prefix_for_name}-disconnected-rg"
  location = var.azure_region

  tags = {
    Environment = "disconnected"
    ManagedBy   = "terraform"
  }
}

resource "azurerm_resource_group" "cluster" {
  name     = "${local.openshift_cluster_name}-rg"
  location = var.azure_region

  tags = {
    Environment = "disconnected"
    ManagedBy   = "terraform"
  }
}
