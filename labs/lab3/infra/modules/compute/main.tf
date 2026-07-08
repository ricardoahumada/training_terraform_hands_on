terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "applocker-tf-state-ricenmotion"
    prefix = "modules/compute"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    environment = var.env
    managed-by  = "terraform"
    cost-center = "cc-1042"
    course      = "terraform-hands-on"
  }
}

locals {
  subnet_app_self_link = coalesce(
    var.subnet_app_self_link,
    data.terraform_remote_state.network.outputs.subnet_self_links["app"],
  )

  tf_state_bucket = "applocker-tf-state-${var.sufijo}"

  common_labels = data.terraform_remote_state.root.outputs.common_labels

}

# --- Remote state del módulo network ---

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = local.tf_state_bucket
    prefix = "modules/network"
  }
}

data "terraform_remote_state" "root" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-ricenmotion"
    prefix = "envs/dev/root"
  }
}

# --- Backend instance template ---

resource "google_compute_instance_template" "backend" {
  name_prefix  = "applocker-app-tmpl-${var.env}-${var.sufijo}"
  machine_type = "e2-standard-2"
  region       = var.region

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = local.subnet_app_self_link
  }

  tags = ["app"]

  service_account {
    email  = data.terraform_remote_state.root.outputs.app_service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    docker-credential-gcr configure-docker --quiet
  EOT

  # labels = {
  #   tier = "app"
  # }

  labels = merge(local.common_labels, { tier = "app" }) # tier = "app" (no "backend"), alineado con M3

  lifecycle {
    create_before_destroy = true
  }
}

# --- Health check ---

resource "google_compute_health_check" "app" {
  name = "applocker-app-hc-${var.env}-${var.sufijo}"

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/health"
  }
}

# --- Managed Instance Group ---

resource "google_compute_instance_group_manager" "backend" {
  name               = "applocker-app-mig-${var.env}-${var.sufijo}"
  base_instance_name = "applocker-app-${var.env}-${var.sufijo}"
  zone               = "${var.region}-a"
  target_size        = 2

  version {
    instance_template = google_compute_instance_template.backend.self_link
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app.self_link
    initial_delay_sec = 60
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 2
    max_unavailable_fixed = 1
    replacement_method    = "SUBSTITUTE"
  }
}
