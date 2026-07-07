output "app_mig_self_link" {
  value = google_compute_instance_group_manager.backend.self_link
}

output "app_mig_instances" {
  value = google_compute_instance_group_manager.backend.instance_group
}

output "app_mig_name" {
  value = google_compute_instance_group_manager.backend.name
}

output "health_check_self_link" {
  value = google_compute_health_check.app.self_link
}