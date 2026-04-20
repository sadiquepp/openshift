# ── Master security group ──────────────────────────────────────────────────────

resource "aws_security_group" "master" {
  name        = "${local.infra_id}-master-sg"
  description = "Cluster Master Security Group"
  vpc_id      = var.vpc_id

  # Egress unrestricted — OVN/SDN handles internal routing
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.infra_id}-master-sg" })
}

# ── Worker security group ──────────────────────────────────────────────────────

resource "aws_security_group" "worker" {
  name        = "${local.infra_id}-worker-sg"
  description = "Cluster Worker Security Group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.infra_id}-worker-sg" })
}

# ── Master ingress — from VPC CIDR ────────────────────────────────────────────

resource "aws_security_group_rule" "master_icmp" {
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "ICMP"
  protocol          = "icmp"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "master_ssh" {
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "SSH"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "master_api_vpc" {
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "Kubernetes API from VPC"
  protocol          = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "master_api_lb" {
  count             = var.loadbalancer_cidr != var.vpc_cidr ? 1 : 0
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "Kubernetes API from LB"
  protocol          = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_blocks       = [var.loadbalancer_cidr]
}

resource "aws_security_group_rule" "master_mcs_vpc" {
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "MCS from VPC"
  protocol          = "tcp"
  from_port         = 22623
  to_port           = 22623
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "master_mcs_lb" {
  count             = var.loadbalancer_cidr != var.vpc_cidr ? 1 : 0
  security_group_id = aws_security_group.master.id
  type              = "ingress"
  description       = "MCS from LB"
  protocol          = "tcp"
  from_port         = 22623
  to_port           = 22623
  cidr_blocks       = [var.loadbalancer_cidr]
}

# ── Master ingress — self-referencing ─────────────────────────────────────────

resource "aws_security_group_rule" "master_etcd" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "etcd"
  protocol                 = "tcp"
  from_port                = 2379
  to_port                  = 2380
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_vxlan_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Vxlan packets"
  protocol                 = "udp"
  from_port                = 4789
  to_port                  = 4789
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_geneve_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Geneve packets"
  protocol                 = "udp"
  from_port                = 6081
  to_port                  = 6081
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_ipsec_ike_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec IKE packets"
  protocol                 = "udp"
  from_port                = 500
  to_port                  = 500
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_ipsec_nat_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec NAT-T packets"
  protocol                 = "udp"
  from_port                = 4500
  to_port                  = 4500
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_ipsec_esp_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec ESP packets"
  protocol                 = "50"
  from_port                = -1
  to_port                  = -1
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_internal_tcp_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Internal cluster communication"
  protocol                 = "tcp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_internal_udp_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Internal cluster communication"
  protocol                 = "udp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_kube_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Kubernetes kubelet, scheduler and controller manager"
  protocol                 = "tcp"
  from_port                = 10250
  to_port                  = 10259
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_services_tcp_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Kubernetes ingress services"
  protocol                 = "tcp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "master_services_udp_self" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Kubernetes ingress services"
  protocol                 = "udp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.master.id
}

# ── Master ingress — from worker ───────────────────────────────────────────────

resource "aws_security_group_rule" "master_vxlan_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Vxlan from worker"
  protocol                 = "udp"
  from_port                = 4789
  to_port                  = 4789
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_geneve_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Geneve from worker"
  protocol                 = "udp"
  from_port                = 6081
  to_port                  = 6081
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_ipsec_ike_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec IKE from worker"
  protocol                 = "udp"
  from_port                = 500
  to_port                  = 500
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_ipsec_nat_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec NAT-T from worker"
  protocol                 = "udp"
  from_port                = 4500
  to_port                  = 4500
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_ipsec_esp_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "IPsec ESP from worker"
  protocol                 = "50"
  from_port                = -1
  to_port                  = -1
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_internal_tcp_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Internal cluster communication from worker"
  protocol                 = "tcp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_internal_udp_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Internal cluster communication from worker"
  protocol                 = "udp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_kube_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Kubernetes kubelet from worker"
  protocol                 = "tcp"
  from_port                = 10250
  to_port                  = 10259
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_services_tcp_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Ingress services from worker"
  protocol                 = "tcp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "master_services_udp_worker" {
  security_group_id        = aws_security_group.master.id
  type                     = "ingress"
  description              = "Ingress services from worker"
  protocol                 = "udp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.worker.id
}

# ── Worker ingress — from VPC CIDR ────────────────────────────────────────────

resource "aws_security_group_rule" "worker_icmp" {
  security_group_id = aws_security_group.worker.id
  type              = "ingress"
  description       = "ICMP"
  protocol          = "icmp"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "worker_ssh" {
  security_group_id = aws_security_group.worker.id
  type              = "ingress"
  description       = "SSH"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.vpc_cidr]
}

# ── Worker ingress — from LB CIDR ─────────────────────────────────────────────

resource "aws_security_group_rule" "worker_https_lb" {
  count             = var.loadbalancer_cidr != var.vpc_cidr ? 1 : 0
  security_group_id = aws_security_group.worker.id
  type              = "ingress"
  description       = "HTTPS from LB"
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = [var.loadbalancer_cidr]
}

resource "aws_security_group_rule" "worker_http_lb" {
  count             = var.loadbalancer_cidr != var.vpc_cidr ? 1 : 0
  security_group_id = aws_security_group.worker.id
  type              = "ingress"
  description       = "HTTP from LB"
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = [var.loadbalancer_cidr]
}

resource "aws_security_group_rule" "worker_healthcheck_lb" {
  count             = var.loadbalancer_cidr != var.vpc_cidr ? 1 : 0
  security_group_id = aws_security_group.worker.id
  type              = "ingress"
  description       = "Healthcheck from LB"
  protocol          = "tcp"
  from_port         = 1936
  to_port           = 1936
  cidr_blocks       = [var.loadbalancer_cidr]
}

# ── Worker ingress — self-referencing ─────────────────────────────────────────

resource "aws_security_group_rule" "worker_vxlan_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Vxlan packets"
  protocol                 = "udp"
  from_port                = 4789
  to_port                  = 4789
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_geneve_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Geneve packets"
  protocol                 = "udp"
  from_port                = 6081
  to_port                  = 6081
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_ipsec_ike_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec IKE packets"
  protocol                 = "udp"
  from_port                = 500
  to_port                  = 500
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_ipsec_nat_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec NAT-T packets"
  protocol                 = "udp"
  from_port                = 4500
  to_port                  = 4500
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_ipsec_esp_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec ESP packets"
  protocol                 = "50"
  from_port                = -1
  to_port                  = -1
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_internal_tcp_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Internal cluster communication"
  protocol                 = "tcp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_internal_udp_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Internal cluster communication"
  protocol                 = "udp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_kube_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Kubernetes kubelet"
  protocol                 = "tcp"
  from_port                = 10250
  to_port                  = 10250
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_services_tcp_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Kubernetes ingress services"
  protocol                 = "tcp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_services_udp_self" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Kubernetes ingress services"
  protocol                 = "udp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.worker.id
}

# ── Worker ingress — from master ───────────────────────────────────────────────

resource "aws_security_group_rule" "worker_vxlan_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Vxlan from master"
  protocol                 = "udp"
  from_port                = 4789
  to_port                  = 4789
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_geneve_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Geneve from master"
  protocol                 = "udp"
  from_port                = 6081
  to_port                  = 6081
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_ipsec_ike_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec IKE from master"
  protocol                 = "udp"
  from_port                = 500
  to_port                  = 500
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_ipsec_nat_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec NAT-T from master"
  protocol                 = "udp"
  from_port                = 4500
  to_port                  = 4500
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_ipsec_esp_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "IPsec ESP from master"
  protocol                 = "50"
  from_port                = -1
  to_port                  = -1
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_internal_tcp_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Internal communication from master"
  protocol                 = "tcp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_internal_udp_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Internal communication from master"
  protocol                 = "udp"
  from_port                = 9000
  to_port                  = 9999
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_kube_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Kubernetes kubelet from master"
  protocol                 = "tcp"
  from_port                = 10250
  to_port                  = 10250
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_services_tcp_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Ingress services from master"
  protocol                 = "tcp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.master.id
}

resource "aws_security_group_rule" "worker_services_udp_master" {
  security_group_id        = aws_security_group.worker.id
  type                     = "ingress"
  description              = "Ingress services from master"
  protocol                 = "udp"
  from_port                = 30000
  to_port                  = 32767
  source_security_group_id = aws_security_group.master.id
}
