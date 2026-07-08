# Outputs planos — necesarios para que los sub-stacks de lab-3
# (compute/, cloudsql/, network/) puedan leer la SA vía
# `data "terraform_remote_state" "root"`. Los outputs de remote_state
# tienen que ser valores escalares o mapas simples, no anidados
# profundamente como el map `service_accounts` de arriba.
# output "app_service_account_email" {
#   value       = module.iam.service_accounts.app.email
#   description = "Email de la SA `app` (para `data.terraform_remote_state.root.outputs.*`)."
# }

# output "app_service_account_member" {
#   value       = module.iam.service_accounts.app.member
#   description = "Member IAM de la SA `app` (formato `serviceAccount:email`)."
# }

# output "common_labels" {
#   value       = local.common_labels
#   description = "Labels comunes aplicados a todos los recursos del entorno."
# }

# output "redis_endpoint" {
#   value       = local.redis_endpoint
#   description = "Mapa host:port de Redis por entorno (dev, prod)."
#   sensitive   = false   # no contiene secretos
# }

# output "redis_hosts" {
#   value = {
#     for k, r in data.google_redis_instance.applocker_cache : k => r.host
#   }
#   description = "Hosts de Redis por entorno."
# }

# output "redis_ports" {
#   value = {
#     for k, r in data.google_redis_instance.applocker_cache : k => r.port
#   }
#   description = "Puertos de Redis por entorno."
# }