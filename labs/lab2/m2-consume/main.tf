terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
}

variable "project_id" { type = string }
variable "vpc_self_link" { type = string }

locals {
  tf_state_bucket = "applocker-tf-state-ricenmotion"
}

module "cloudsql" {
  source = "gcs::https://www.googleapis.com/storage/v1/${local.tf_state_bucket}/modules/cloudsql/1.0.0/cloudsql.zip"

  project_id       = var.project_id
  name             = "applocker-db-dev"
  private_network  = var.vpc_self_link
}

output "cloudsql_connection_name" {
  value = module.cloudsql.connection_name
}