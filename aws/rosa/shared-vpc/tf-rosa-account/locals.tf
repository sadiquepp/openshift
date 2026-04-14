locals {
  cluster_name        = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  openshift_version   = "${var.openshift_major_version}.${var.openshift_minor_version}"
  sts_suffix          = "${local.cluster_name}-sts"
  iam_role_name       = "${var.prefix_for_name}-ocp-install-ec2"
  key_name            = "${var.prefix_for_name}_ansible"
  instance_name       = "${local.cluster_name}-installer"
  sg_name             = "ping_ssh_8443"
}
