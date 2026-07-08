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
    prefix = "envs/dev/root"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(local.common_labels, {
    managed-by = "terraform"
  })
}