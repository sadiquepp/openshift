resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"

  content = <<-INI
    [bastion]
    ${azurerm_public_ip.bastion.ip_address}

    [bastion:vars]
    ansible_user=${var.admin_username}
    ansible_ssh_private_key_file=${var.ssh_private_key_path}
    ansible_ssh_common_args=-o StrictHostKeyChecking=no
  INI
}

resource "local_file" "ansible_vars" {
  filename        = "${path.module}/ansible-vars.json"
  file_permission = "0644"

  content = jsonencode({
    prefix_for_name                            = var.prefix_for_name
    azure_region                               = var.azure_region
    azure_subscription_id                      = data.azurerm_client_config.current.subscription_id
    azure_tenant_id                            = data.azurerm_client_config.current.tenant_id
    openshift_base_domain                      = var.openshift_base_domain
    openshift_cluster_name_suffix              = var.openshift_cluster_name_suffix
    ssh_public_key_for_vm_and_openshift_node   = var.ssh_public_key
    resource_group_name                        = azurerm_resource_group.main.name
    cluster_resource_group_name                = azurerm_resource_group.cluster.name
    disconnected_vnet_name                     = azurerm_virtual_network.disconnected.name
    disconnected_vnet_id                       = azurerm_virtual_network.disconnected.id
    disconnected_vnet_cidr                     = var.disconnected_vnet_cidr
    disconnected_subnet_name_a                 = azurerm_subnet.disconnected[0].name
    disconnected_subnet_name_b                 = azurerm_subnet.disconnected[1].name
    disconnected_subnet_name_c                 = azurerm_subnet.disconnected[2].name
    disconnected_subnet_id_a                   = azurerm_subnet.disconnected[0].id
    disconnected_subnet_id_b                   = azurerm_subnet.disconnected[1].id
    disconnected_subnet_id_c                   = azurerm_subnet.disconnected[2].id
    egress_vnet_id                             = azurerm_virtual_network.egress.id
    aro_subnet_name_a                          = azurerm_subnet.aro[0].name
    aro_subnet_name_b                          = azurerm_subnet.aro[1].name
    aro_subnet_id_a                            = azurerm_subnet.aro[0].id
    aro_subnet_id_b                            = azurerm_subnet.aro[1].id
    storage_account_name                       = azurerm_storage_account.mirror.name
    managed_identity_client_id                 = azurerm_user_assigned_identity.ocp_install.client_id
    network_resource_group_name                = azurerm_resource_group.main.name
    bastion_private_ip                         = azurerm_network_interface.bastion.private_ip_address
    mirror_registry_fqdn                       = "${azurerm_private_dns_a_record.bastion.name}.${azurerm_private_dns_zone.mirror.name}"
    use_service_principal                      = local.use_service_principal
    installer_sp_client_id                     = local.sp_client_id
    installer_sp_client_secret                 = local.sp_client_secret
  })
}

resource "local_file" "install_cluster_script" {
  filename        = "${path.module}/install-cluster.sh"
  file_permission = "0755"

  content = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail

    CLUSTER_DOMAIN="${local.openshift_cluster_name}.${var.openshift_base_domain}"
    CLUSTER_RG="${azurerm_resource_group.cluster.name}"
    EGRESS_VNET_ID="${azurerm_virtual_network.egress.id}"

    az login --identity

    # Background: link cluster private DNS zone to egress VNet mid-install
    (
      while ! az network private-dns zone show \
        -g "$CLUSTER_RG" -n "$CLUSTER_DOMAIN" &>/dev/null; do sleep 10; done
      az network private-dns link vnet create \
        --resource-group "$CLUSTER_RG" \
        --zone-name "$CLUSTER_DOMAIN" \
        --name egress-vnet-link \
        --virtual-network "$EGRESS_VNET_ID" \
        --registration-enabled false
      echo '[dns-linker] Done.'
    ) &

    # Foreground: run the installer
    ~/openshift-install create cluster --dir ~/install-dir --log-level=debug
  SCRIPT
}

resource "local_file" "reinstall_cluster_script" {
  filename        = "${path.module}/reinstall-cluster.sh"
  file_permission = "0755"

  content = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail

    CLUSTER_DOMAIN="${local.openshift_cluster_name}.${var.openshift_base_domain}"
    CLUSTER_RG="${azurerm_resource_group.cluster.name}"
    EGRESS_VNET_ID="${azurerm_virtual_network.egress.id}"
    AZURE_REGION="${var.azure_region}"
    AZURE_SUB="${data.azurerm_client_config.current.subscription_id}"
    AZURE_TENANT="${data.azurerm_client_config.current.tenant_id}"
    NETWORK_RG="${azurerm_resource_group.main.name}"
    CCO_SUFFIX="${local.openshift_cluster_name}-cco"
    CCO_SA="$(echo "$CCO_SUFFIX" | tr -dc 'a-z0-9' | cut -c1-24)"
    HOME_DIR="$HOME"

    echo "================================================================"
    echo "  Step 1/7 — Destroy the cluster"
    echo "================================================================"
    ~/openshift-install destroy cluster --dir ~/install-dir --log-level=debug || true

    echo ""
    echo "================================================================"
    echo "  Step 2/7 — Recreate the cluster resource group"
    echo "================================================================"
    az login --identity
    az group create --name "$CLUSTER_RG" --location "$AZURE_REGION"

    echo ""
    echo "================================================================"
    echo "  Step 3/7 — Delete old CCO resources"
    echo "================================================================"
    cd ~/cco
    ~/cco/ccoctl azure delete \
      --name "$CCO_SUFFIX" \
      --region "$AZURE_REGION" \
      --subscription-id "$AZURE_SUB" \
      --storage-account-name "$CCO_SA" || true

    echo ""
    echo "================================================================"
    echo "  Step 4/7 — Clean up old CCO artifacts"
    echo "================================================================"
    rm -rf ~/cco/manifests ~/cco/tls ~/cco/jwks ~/cco/openid-configuration \
           ~/cco/serviceaccount-signer.private ~/cco/serviceaccount-signer.public

    echo ""
    echo "================================================================"
    echo "  Step 5/7 — Recreate CCO resources"
    echo "================================================================"
    ~/cco/ccoctl azure create-all \
      --credentials-requests-dir ~/cco/credrequests \
      --name "$CCO_SUFFIX" \
      --region "$AZURE_REGION" \
      --subscription-id "$AZURE_SUB" \
      --tenant-id "$AZURE_TENANT" \
      --storage-account-name "$CCO_SA" \
      --installation-resource-group-name "$CLUSTER_RG" \
      --network-resource-group-name "$NETWORK_RG" \
      --output-dir ~/cco

    echo ""
    echo "================================================================"
    echo "  Step 6/7 — Rebuild install-dir with fresh manifests"
    echo "================================================================"
    rm -rf ~/install-dir
    mkdir ~/install-dir
    cp ~/install-config.yaml ~/install-dir/
    ~/openshift-install create manifests --dir ~/install-dir
    cp ~/cco/manifests/* ~/install-dir/manifests/
    cp -r ~/cco/tls ~/install-dir/

    echo ""
    echo "================================================================"
    echo "  Step 7/7 — Install the cluster"
    echo "================================================================"

    # Background: link cluster DNS to egress VNet mid-install
    (
      while ! az network private-dns zone show \
        -g "$CLUSTER_RG" -n "$CLUSTER_DOMAIN" &>/dev/null; do sleep 10; done
      az network private-dns link vnet create \
        --resource-group "$CLUSTER_RG" \
        --zone-name "$CLUSTER_DOMAIN" \
        --name egress-vnet-link \
        --virtual-network "$EGRESS_VNET_ID" \
        --registration-enabled false
      echo '[dns-linker] Done.'
    ) &

    # Foreground: run the installer
    ~/openshift-install create cluster --dir ~/install-dir --log-level=debug
  SCRIPT
}
