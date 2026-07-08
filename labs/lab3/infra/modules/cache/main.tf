terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

resource "google_redis_instance" "applocker_cache" {
  for_each = var.environments

  project        = var.project_id
  name           = "applocker-cache-${each.key}-${var.sufijo}"
  tier           = each.value.tier
  memory_size_gb = each.value.memory_gb
  region         = each.value.region
  redis_version  = "REDIS_7_2"

  authorized_network = var.network_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  labels = var.labels

  lifecycle {
    create_before_destroy = true
  }
}