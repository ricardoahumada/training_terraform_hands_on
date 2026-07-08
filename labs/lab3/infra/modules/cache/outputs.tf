output "hosts" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => r.host
  }
  description = "Mapa de hosts de Redis por entorno."
}

output "ports" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => r.port
  }
  description = "Mapa de puertos de Redis por entorno."
}

output "instance_addresses" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => {
      name = r.name
      host   = r.host
      port   = r.port
      region = r.region
    }
  }
  description = "Mapa completo de direcciones (host:port y región) por entorno."
}
