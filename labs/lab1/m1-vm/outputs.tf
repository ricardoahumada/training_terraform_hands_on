output "vm_name" {
  value       = google_compute_instance.web.name
  description = "Nombre de la VM"
}

output "vm_external_ip" {
  value       = google_compute_instance.web.network_interface[0].access_config[0].nat_ip
  description = "IP pública efímera de la VM"
}

output "vm_zone" {
  value       = google_compute_instance.web.zone
  description = "Zona donde se ha creado la VM"
}