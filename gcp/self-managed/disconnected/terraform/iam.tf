# ── Bastion Service Account ───────────────────────────────────────────────────
# Attached to the bastion VM. Provides the VM identity for gcloud operations,
# ccoctl, and general automation. Equivalent to the Azure Managed Identity /
# AWS Instance Profile.

resource "google_service_account" "bastion" {
  account_id   = "${var.prefix_for_name}-bastion-sa"
  display_name = "${var.prefix_for_name} bastion VM"
}

locals {
  bastion_roles = [
    "roles/compute.admin",
    "roles/dns.admin",
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountKeyAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/storage.admin",
  ]
}

resource "google_project_iam_member" "bastion" {
  for_each = toset(local.bastion_roles)

  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.bastion.email}"
}
