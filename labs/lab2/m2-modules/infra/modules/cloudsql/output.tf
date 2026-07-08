output "instance_name" {
  value       = google_sql_database_instance.main.name
  description = "Nombre de la instancia Cloud SQL."
}

output "connection_name" {
  value       = google_sql_database_instance.main.connection_name
  description = "Connection name en formato project:region:name. Usar desde Cloud SQL Proxy o clientes GCP."
}

output "self_link" {
  value       = google_sql_database_instance.main.self_link
  description = "URI self-link del recurso."
}

output "private_ip" {
  value       = google_sql_database_instance.main.private_ip_address
  description = "IP privada de la instancia (solo accesible desde la VPC)."
}

output "database_name" {
  value       = google_sql_database.app.name
  description = "Nombre de la base de datos creada."
}