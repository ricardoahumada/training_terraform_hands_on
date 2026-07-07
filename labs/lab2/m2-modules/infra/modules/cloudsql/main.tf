resource "google_sql_database_instance" "main" {
  project          = var.project_id
  name             = var.name
  region           = var.region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_size         = var.disk_size
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.private_network
      #   require_ssl     = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      location                       = "eu"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
      }
    }
  }
}

resource "google_sql_database" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  name     = "applocker"
}

resource "google_sql_user" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  name     = "applocker_app"
  password = data.google_secret_manager_secret_version.db_password.secret_data
}

data "google_secret_manager_secret_version" "db_password" {
  project = var.project_id
  secret  = "applocker-db-password"
}
