# --- Composición del environment root ---

# module "iam" {
#   source = "../../modules/iam"

#   project_id = var.project_id
#   env        = var.env
#   sufijo = "ricenmotion"
# }

# Los siguientes módulos se referencian desde sus propios archivos
# del lab-3 (infra/envs/dev/network, compute, cloudsql) y se aplican
# con `terraform apply` desde cada sub-stack, NO desde aquí.
# El root NO los re-llama para evitar doble aplicación y drift.


# --- M6: Memorystore Redis (tier de cache) ---
# Versión 1: declarado directamente en el root. En la Parte 4 lo
# moveremos a modules/cache/ usando `terraform state mv` + bloque moved.

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-ricenmotion"
    prefix = "modules/network"
  }
}

# resource "google_redis_instance" "applocker_cache" {
#   for_each = {
#     dev  = { tier = "BASIC",       memory_gb = 1, region = "us-central1" }
#     prod = { tier = "BASIC", memory_gb = 3, region = "us-central1" }
#   }

#   project        = var.project_id
#   name           = "applocker-cache-${each.key}-ricenmotion"
#   tier           = each.value.tier
#   memory_size_gb = each.value.memory_gb
#   region         = each.value.region
#   redis_version  = "REDIS_7_2"

#   authorized_network = data.terraform_remote_state.network.outputs.vpc_self_link
#   connect_mode       = "PRIVATE_SERVICE_ACCESS"

#   labels = merge(local.common_labels, {
#     tier = "cache"
#     env  = each.key
#   })

#   lifecycle {
#     create_before_destroy = true
#   }
# }




# module "cache" {
#   source = "../../modules/cache"

#   project_id        = var.project_id
#   sufijo            = var.sufijo
#   network_self_link = data.terraform_remote_state.network.outputs.vpc_self_link
#   labels            = local.common_labels

#   environments = {
#     dev  = { tier = "BASIC",       memory_gb = 1, region = "us-central1" }
#     prod = { tier = "STANDARD_HA", memory_gb = 5, region = "us-central1" }
#   }
# }

# data "google_redis_instance" "applocker_cache" {
#   for_each = module.cache.instance_addresses
#   # google_redis_instance.applocker_cache

#   name   = each.value.name
#   region = each.value.region
# }

# locals {
#   redis_endpoint = {
#     for k, r in data.google_redis_instance.applocker_cache : k => "${r.host}:${r.port}"
#   }
# }

# # Moved
# moved {
#   from = google_redis_instance.applocker_cache["dev"]
#   to   = module.cache.google_redis_instance.applocker_cache["dev"]
# }

# moved {
#   from = google_redis_instance.applocker_cache["prod"]
#   to   = module.cache.google_redis_instance.applocker_cache["prod"]
# }