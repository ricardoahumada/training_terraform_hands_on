output "public_vm_name" {
  value       = google_compute_instance.public.name
  description = "Nombre de la VM pública."
}

output "public_vm_internal_ip" {
  value       = google_compute_instance.public.network_interface[0].network_ip
  description = "IP interna de la VM pública."
}

output "public_vm_external_ip" {
  value       = google_compute_instance.public.network_interface[0].access_config[0].nat_ip
  description = "IP externa (efímera) de la VM pública — necesaria para SSH desde el formador."
}

output "private_vm_name" {
  value       = google_compute_instance.private.name
  description = "Nombre de la VM privada."
}

output "private_vm_internal_ip" {
  value       = google_compute_instance.private.network_interface[0].network_ip
  description = "IP interna de la VM privada — la que usaremos para el ping."
}