# ── SSH Key ───────────────────────────────────────────────────────────────────

resource "ibm_is_ssh_key" "bastion" {
  name           = "${local.openshift_cluster_name}-bastion-key"
  public_key     = var.ssh_public_key
  resource_group = local.resource_group_id
}

# ── Bastion Image ────────────────────────────────────────────────────────────

data "ibm_is_image" "bastion" {
  name = var.bastion_image_name
}

# ── Floating IP (external access) ───────────────────────────────────────────

resource "ibm_is_floating_ip" "bastion" {
  name           = "${local.openshift_cluster_name}-bastion-fip"
  target         = ibm_is_instance.bastion.primary_network_interface[0].id
  resource_group = local.resource_group_id
}

# ── Bastion Virtual Server Instance ──────────────────────────────────────────

resource "ibm_is_instance" "bastion" {
  name           = "${local.openshift_cluster_name}-bastion"
  vpc            = ibm_is_vpc.connected.id
  zone           = var.zones[0]
  profile        = var.bastion_profile
  image          = data.ibm_is_image.bastion.id
  keys           = [ibm_is_ssh_key.bastion.id]
  resource_group = local.resource_group_id

  primary_network_interface {
    name            = "eth0"
    subnet          = ibm_is_subnet.bastion.id
    security_groups = [ibm_is_security_group.bastion.id]
  }

  boot_volume {
    name = "${local.openshift_cluster_name}-bastion-boot"
    size = var.bastion_boot_volume_size
  }
}
