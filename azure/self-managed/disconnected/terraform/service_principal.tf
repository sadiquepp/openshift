# ── Auto-created Service Principal for openshift-install ─────────────────────
# Gated behind var.create_service_principal (default: false).
# Recommended: pre-create the SP manually and pass the credentials instead.

locals {
  create_sp            = var.create_service_principal
  use_service_principal = local.create_sp || var.installer_sp_client_id != ""

  sp_client_id     = local.create_sp ? azuread_application.ocp_installer[0].client_id : var.installer_sp_client_id
  sp_client_secret = local.create_sp ? azuread_service_principal_password.ocp_installer[0].value : var.installer_sp_client_secret
}

resource "azuread_application" "ocp_installer" {
  count        = local.create_sp ? 1 : 0
  display_name = "${var.prefix_for_name}-ocp-installer"
}

resource "azuread_service_principal" "ocp_installer" {
  count     = local.create_sp ? 1 : 0
  client_id = azuread_application.ocp_installer[0].client_id
}

resource "azuread_service_principal_password" "ocp_installer" {
  count                = local.create_sp ? 1 : 0
  service_principal_id = azuread_service_principal.ocp_installer[0].id
}

resource "azurerm_role_assignment" "sp_contributor" {
  count                = local.create_sp ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.ocp_installer[0].object_id
}

resource "azurerm_role_assignment" "sp_user_access_admin" {
  count                = local.create_sp ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.ocp_installer[0].object_id
}
