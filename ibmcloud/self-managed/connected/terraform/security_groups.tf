# ── Bastion Security Group ────────────────────────────────────────────────────

resource "ibm_is_security_group" "bastion" {
  name           = "${local.openshift_cluster_name}-bastion-sg"
  vpc            = ibm_is_vpc.connected.id
  resource_group = local.resource_group_id
}

# SSH from anywhere
resource "ibm_is_security_group_rule" "bastion_ssh_in" {
  group     = ibm_is_security_group.bastion.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  tcp {
    port_min = 22
    port_max = 22
  }
}

# VNC from anywhere
resource "ibm_is_security_group_rule" "bastion_vnc_in" {
  group     = ibm_is_security_group.bastion.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  tcp {
    port_min = 5999
    port_max = 5999
  }
}

# Internal VPC traffic (all subnets)
resource "ibm_is_security_group_rule" "bastion_internal_in" {
  group     = ibm_is_security_group.bastion.id
  direction = "inbound"
  remote    = var.connected_vpc_cidr
}

# All outbound
resource "ibm_is_security_group_rule" "bastion_all_out" {
  group     = ibm_is_security_group.bastion.id
  direction = "outbound"
  remote    = "0.0.0.0/0"
}
