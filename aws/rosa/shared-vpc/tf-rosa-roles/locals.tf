locals {
  cluster_name = "${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"
  oidc_issuer  = "oidc.op1.openshiftapps.com/${var.oidc_config_id}"
  oidc_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.op1.openshiftapps.com/${var.oidc_config_id}"

  common_tags = {
    red-hat-managed   = "true"
    rosa_hcp_policies = "true"
    rosa_managed_policies = "true"
    rosa_role_prefix  = local.cluster_name
  }

  # ── Operator roles ────────────────────────────────────────────────────────────
  # Each entry drives one aws_iam_role + assume-role policy + policy attachments.
  # Keys become the role name suffix (after <cluster_name>-).
  # service_accounts: the OIDC sub values from the Jinja2 templates.
  # managed_policies: AWS-managed ARNs to attach.
  # extra_policies: customer-managed policy ARNs to attach (empty list = none).

  operator_roles = {

    "kube-system-kms-provider" = {
      operator_name      = "kms-provider"
      operator_namespace = "kube-system"
      service_accounts   = ["system:serviceaccount:kube-system:kms-provider"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSAKMSProviderPolicy"]
      extra_policies     = []
    }

    "kube-system-kube-controller-manager" = {
      operator_name      = "kube-controller-manager"
      operator_namespace = "kube-system"
      service_accounts   = ["system:serviceaccount:kube-system:kube-controller-manager"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSAKubeControllerPolicy"]
      extra_policies     = []
    }

    "kube-system-capa-controller-manager" = {
      operator_name      = "capa-controller-manager"
      operator_namespace = "kube-system"
      service_accounts   = ["system:serviceaccount:kube-system:capa-controller-manager"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSANodePoolManagementPolicy"]
      extra_policies     = []
    }

    "kube-system-control-plane-operator" = {
      operator_name      = "control-plane-operator"
      operator_namespace = "kube-system"
      service_accounts   = ["system:serviceaccount:kube-system:control-plane-operator"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSAControlPlaneOperatorPolicy"]
      extra_policies = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.cluster_name}-shared-vpc-route53-assume-role",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.cluster_name}-shared-vpc-endpoint-assume-role",
      ]
    }

    "openshift-image-registry-installer-cloud-credentials" = {
      operator_name      = "installer-cloud-credentials"
      operator_namespace = "openshift-image-registry"
      service_accounts = [
        "system:serviceaccount:openshift-image-registry:cluster-image-registry-operator",
        "system:serviceaccount:openshift-image-registry:registry",
      ]
      managed_policies = ["arn:aws:iam::aws:policy/service-role/ROSAImageRegistryOperatorPolicy"]
      extra_policies   = []
    }

    "openshift-ingress-operator-cloud-credentials" = {
      operator_name      = "cloud-credentials"
      operator_namespace = "openshift-ingress-operator"
      service_accounts   = ["system:serviceaccount:openshift-ingress-operator:ingress-operator"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSAIngressOperatorPolicy"]
      extra_policies = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.cluster_name}-shared-vpc-route53-assume-role",
      ]
    }

    "openshift-cluster-csi-drivers-ebs-cloud-credentials" = {
      operator_name      = "ebs-cloud-credentials"
      operator_namespace = "openshift-cluster-csi-driver"
      service_accounts = [
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-operator",
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-controller-sa",
      ]
      managed_policies = ["arn:aws:iam::aws:policy/service-role/ROSAAmazonEBSCSIDriverOperatorPolicy"]
      extra_policies   = []
    }

    "openshift-cloud-network-config-controller-cloud-creden" = {
      operator_name      = "cloud-credentials"
      operator_namespace = "openshift-cloud-network-config-controller"
      service_accounts   = ["system:serviceaccount:openshift-cloud-network-config-controller:cloud-network-config-controller"]
      managed_policies   = ["arn:aws:iam::aws:policy/service-role/ROSACloudNetworkConfigOperatorPolicy"]
      extra_policies     = []
    }
  }
}
