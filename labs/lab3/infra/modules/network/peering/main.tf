
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  
}

# provider "google" {
#   project = var.project_id
#   region  = var.region

#   default_labels = {
#     environment = var.env
#     managed-by  = "terraform"
#     cost-center = "cc-1042"
#     course      = "terraform-hands-on"
#   }
# }

# --- Peering con services (Cloud SQL private IP) ---

resource "google_compute_global_address" "private_ip_range" {
  name          = var.name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.network
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = var.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}


# -- ouputs
output "private_ip_range_name" {
  value = google_compute_global_address.private_ip_range.name
}