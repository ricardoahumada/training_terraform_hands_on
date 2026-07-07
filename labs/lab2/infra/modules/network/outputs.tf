output "network_self_link" {
  value       = google_compute_network.this.self_link
  description = "Self-link de la VPC (úsalo desde otros módulos que necesiten referenciarla)."
}

output "network_id" {
  value       = google_compute_network.this.id
  description = "ID de la VPC."
}

output "public_subnet_self_link" {
  value       = google_compute_subnetwork.public.self_link
  description = "Self-link de la subred pública."
}

output "public_subnet_name" {
  value       = google_compute_subnetwork.public.name
  description = "Nombre de la subred pública."
}

output "private_subnet_self_link" {
  value       = google_compute_subnetwork.private.self_link
  description = "Self-link de la subred privada."
}

output "private_subnet_name" {
  value       = google_compute_subnetwork.private.name
  description = "Nombre de la subred privada."
}