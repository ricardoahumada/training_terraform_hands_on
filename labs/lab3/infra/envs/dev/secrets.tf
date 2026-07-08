resource "google_secret_manager_secret" "db_password" {
  secret_id = "applocker-db-password"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = merge(local.common_labels, { tier = "data" })
}