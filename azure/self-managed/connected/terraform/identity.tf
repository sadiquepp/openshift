# ── User-Assigned Managed Identity ────────────────────────────────────────────
# Equivalent to the IAM Role + Instance Profile in AWS.
# Assigned to the bastion VM so it can manage Azure resources for OpenShift.

resource "azurerm_user_assigned_identity" "ocp_install" {
  name                = "${var.prefix_for_name}-ocp-install"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_role_assignment" "ocp_install_contributor" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ocp_install.principal_id
}

resource "azurerm_role_assignment" "ocp_install_user_access_admin" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.ocp_install.principal_id
}
