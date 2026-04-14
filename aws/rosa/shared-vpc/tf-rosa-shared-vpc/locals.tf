locals {
  disconnected_vpc_name = "${var.prefix_for_name}-disconnected"
  egress_vpc_name       = "${var.prefix_for_name}-egress"
  cluster_name          = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"

  route53_role_name = "${local.cluster_name}-shared-vpc-route53"
  endpoint_role_name = "${local.cluster_name}-shared-vpc-endpoint"
}
