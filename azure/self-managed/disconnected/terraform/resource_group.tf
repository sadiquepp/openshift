resource "azurerm_resource_group" "main" {
  name     = "${local.openshift_cluster_name}-network-rg"
  location = var.azure_region

  tags = {
    Environment = "disconnected"
    ManagedBy   = "terraform"
  }
}

resource "azurerm_resource_group" "cluster" {
  name     = "${local.openshift_cluster_name}-cluster-rg"
  location = var.azure_region

  tags = {
    Environment = "disconnected"
    ManagedBy   = "terraform"
  }
}
