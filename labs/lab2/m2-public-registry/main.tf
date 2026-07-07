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

variable "project_id" {
  type = string
}

module "cloudsql" {
  source  = "terraform-google-modules/sql-db/google//modules/postgresql"
  version = "~> 22.0"

  project_id        = var.project_id
  region            = "us-central1"
  name              = "applocker-db-dev"
  database_version  = "POSTGRES_15"
  tier              = "db-f1-micro"   # pequeño para el lab

  ip_configuration = {
    ipv4_enabled    = false
    private_network = null   # para el lab: el módulo requiere private_network o null
  }

  deletion_protection = false   # para el lab
}