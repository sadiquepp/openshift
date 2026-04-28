# ── Public IP for Bastion ─────────────────────────────────────────────────────

resource "azurerm_public_ip" "bastion" {
  name                = "${local.openshift_cluster_name}-bastion-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Name = "${local.openshift_cluster_name}-bastion-pip"
  }
}

# ── NIC for Bastion ──────────────────────────────────────────────────────────

resource "azurerm_network_interface" "bastion" {
  name                = "${local.openshift_cluster_name}-bastion-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.egress_public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }

  tags = {
    Name = "${local.openshift_cluster_name}-bastion-nic"
  }
}

# ── Bastion VM ───────────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "bastion" {
  name                            = "${local.openshift_cluster_name}-bastion"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.installer_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.bastion.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ocp_install.id]
  }

  os_disk {
    name                 = "${local.openshift_cluster_name}-bastion-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.installer_disk_size
  }

  source_image_reference {
    publisher = var.installer_image.publisher
    offer     = var.installer_image.offer
    sku       = var.installer_image.sku
    version   = var.installer_image.version
  }

  tags = {
    Name       = "${local.openshift_cluster_name}-installer"
    Automation = "ocp_installer"
  }
}
