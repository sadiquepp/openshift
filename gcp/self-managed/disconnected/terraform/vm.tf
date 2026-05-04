# ── Bastion Compute Instance ───────────────────────────────────────────────────

resource "google_compute_address" "bastion" {
  name   = "${local.openshift_cluster_name}-bastion-ip"
  region = var.gcp_region
}

resource "google_compute_instance" "bastion" {
  name         = "${local.openshift_cluster_name}-bastion"
  machine_type = var.bastion_machine_type
  zone         = "${var.gcp_region}-a"
  tags         = ["bastion"]

  boot_disk {
    initialize_params {
      image = "${var.bastion_image_project}/${var.bastion_image_family}"
      size  = var.bastion_disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.egress.id

    access_config {
      nat_ip = google_compute_address.bastion.address
    }
  }

  service_account {
    email  = google_service_account.bastion.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "${var.admin_username}:${var.ssh_public_key}"
  }

  labels = {
    purpose    = "ocp-installer"
    managed-by = "terraform"
  }
}
