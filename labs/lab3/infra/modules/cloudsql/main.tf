terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/cloudsql"
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

# --- Remote state del módulo network ---

locals {
  vpc_self_link = coalesce(
    var.vpc_self_link,
    data.terraform_remote_state.network.outputs.vpc_self_link,
  )

  tf_state_bucket = var.tf_state_bucket
}

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = local.tf_state_bucket
    prefix = "modules/network"
  }
}

module "cloudsql" {
  source = "gcs::https://www.googleapis.com/storage/v1/${local.tf_state_bucket}/modules/cloudsql/1.0.0/cloudsql.zip"

  project_id        = var.project_id
  name              = "applocker-db-${var.env}-${var.sufijo}"
  region            = var.region
  tier              = "db-custom-2-7680"
  availability_type = "REGIONAL"
  database_version  = "POSTGRES_15"
  private_network   = local.vpc_self_link

  deletion_protection = true

  depends_on = [data.terraform_remote_state.network]
}