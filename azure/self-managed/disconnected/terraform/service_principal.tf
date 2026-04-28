# ── Service Principal for openshift-install ──────────────────────────────────
# openshift-install requires a service principal with a client secret
# stored in ~/.azure/osServicePrincipal.json. Managed identities are not
# supported by the installer binary.

resource "azuread_application" "ocp_installer" {
  display_name = "${local.openshift_cluster_name}-installer"
}

resource "azuread_service_principal" "ocp_installer" {
  client_id = azuread_application.ocp_installer.client_id
}

resource "azuread_service_principal_password" "ocp_installer" {
  service_principal_id = azuread_service_principal.ocp_installer.id
  end_date_relative    = "8760h" # 1 year
}

resource "azurerm_role_assignment" "sp_contributor" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.ocp_installer.object_id
}

resource "azurerm_role_assignment" "sp_user_access_admin" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.ocp_installer.object_id
}
