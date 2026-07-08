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
  region  = var.region

  default_labels = {
    environment = var.env
    managed-by  = "terraform"
    cost-center = "cc-1042"
    course      = "terraform-hands-on"
  }
}

# --- VPC ---

resource "google_compute_network" "applocker" {
  name                    = "applocker-vpc-${var.env}-${var.sufijo}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# --- Subnets por tier ---

resource "google_compute_subnetwork" "app" {
  name          = "applocker-app-sn-${var.env}-${var.sufijo}"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "middleware" {
  name          = "applocker-mw-sn-${var.env}-${var.sufijo}"
  ip_cidr_range = "10.10.16.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "lock" {
  name          = "applocker-lock-sn-${var.env}-${var.sufijo}"
  ip_cidr_range = "10.10.32.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

# Subnet reservada para peering con services (Cloud SQL private IP)
resource "google_compute_subnetwork" "data" {
  name          = "applocker-data-sn-${var.env}-${var.sufijo}"
  ip_cidr_range = "10.10.48.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  purpose = "PRIVATE"
}

# --- Cloud Router + Cloud NAT ---

resource "google_compute_router" "applocker" {
  name    = "applocker-router-${var.env}-${var.sufijo}"
  region  = var.region
  network = google_compute_network.applocker.id
}

resource "google_compute_router_nat" "applocker" {
  name   = "applocker-nat-${var.env}-${var.sufijo}"
  router = google_compute_router.applocker.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Reglas de firewall por tags (zero-trust) ---

# resource "google_compute_firewall" "app_to_mw" {
#   name      = "applocker-app-to-mw-${var.env}-${var.sufijo}"
#   network   = google_compute_network.applocker.id
#   direction = "INGRESS"

#   source_tags = ["app"]
#   target_tags = ["middleware"]

#   allow {
#     protocol = "tcp"
#     ports    = ["8080"]
#   }

#   log_config {
#     metadata = "INCLUDE_ALL_METADATA"
#   }
# }

# resource "google_compute_firewall" "mw_to_lock" {
#   name    = "applocker-mw-to-lock-${var.env}-${var.sufijo}"
#   network = google_compute_network.applocker.id

#   source_tags = ["middleware"]
#   target_tags = ["lock"]

#   allow {
#     protocol = "tcp"
#     ports    = ["9000"]
#   }
# }

# resource "google_compute_firewall" "lock_to_data" {
#   name    = "applocker-lock-to-data-${var.env}-${var.sufijo}"
#   network = google_compute_network.applocker.id

#   source_tags = ["lock"]
#   target_tags = ["data"]

#   allow {
#     protocol = "tcp"
#     ports    = ["5432"]
#   }
# }

locals {
  firewall_rules = {
    allow_app_to_mw = {
      description = "App tier to Middleware (8080)"
      source_tags = ["app"]
      target_tags = ["middleware"]
      ports       = ["8080"]
    }
    allow_mw_to_lock = {
      description = "Middleware to Locker Mgmt (9000)"
      source_tags = ["middleware"]
      target_tags = ["lock"]
      ports       = ["9000"]
    }
    allow_lock_to_data = {
      description = "Locker Mgmt to Cloud SQL (5432)"
      source_tags = ["lock"]
      target_tags = ["data"]
      ports       = ["5432"]
    }
    # NUEVO en M6: regla hacia Redis
    allow_middleware_to_redis = {
      description = "Middleware to Redis cache (6379)"
      source_tags = ["middleware"]
      target_tags = ["data"]   # las instancias Redis están en la subnet data
      ports       = ["6379"]
    }
  }
}

resource "google_compute_firewall" "applocker" {
  for_each = local.firewall_rules

  project     = var.project_id
  name        = "applocker-${replace(each.key, "_", "-")}-${var.env}-${var.sufijo}"
  network     = google_compute_network.applocker.id
  description = each.value.description
  direction   = "INGRESS"

  source_tags = each.value.source_tags
  target_tags = each.value.target_tags

  dynamic "allow" {
    for_each = each.value.ports
    content {
      protocol = "tcp"
      ports    = [allow.value]
    }
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}


# SSH por IAP para los 3 tiers
resource "google_compute_firewall" "ssh_iap" {
  name    = "applocker-ssh-iap-${var.env}-${var.sufijo}"
  network = google_compute_network.applocker.id

  source_ranges = ["35.235.240.0/20"] # rango de IAP
  target_tags   = ["app", "middleware", "lock"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}



# # --- Peering con services (Cloud SQL private IP) ---

# resource "google_compute_global_address" "private_ip_range" {
#   name          = "applocker-private-ip-range-${var.env}-${var.sufijo}"
#   purpose       = "VPC_PEERING"
#   address_type  = "INTERNAL"
#   prefix_length = 16
#   network       = google_compute_network.applocker.id
# }

# resource "google_service_networking_connection" "private_vpc" {
#   network                 = google_compute_network.applocker.id
#   service                 = "servicenetworking.googleapis.com"
#   reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
# }

module "peering" {
  source     = "./peering"
  project_id = var.project_id
  region     = var.region
  env        = var.env
  name       = "applocker-private-ip-range-${var.env}-${var.sufijo}"
  network    = google_compute_network.applocker.id
}
