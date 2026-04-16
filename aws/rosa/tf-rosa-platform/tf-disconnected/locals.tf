locals {
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}c",
  ]

  disconnected_vpc_name = "${var.prefix_for_name}-disconnected"
  egress_vpc_name       = "${var.prefix_for_name}-egress"

  # Interface endpoint services to create in the disconnected VPC
  interface_endpoint_services = [
    "ec2",
    "sts",
    "elasticloadbalancing",
    "ecr.api",
    "ecr.dkr",
  ]
}
