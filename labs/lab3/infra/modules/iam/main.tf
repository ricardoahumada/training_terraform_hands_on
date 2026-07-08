terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# Única SA del M3: el MIG `applocker-app-mig` del lab-3 ya está en producción.
# Los tiers `mw`, `lock` y `data` solo existen como subnets vacías hoy;
# cuando se desplieguen sus VMs (futuros labs) se les creará su propia SA
# con `terraform apply -target=module.iam` extendido.
locals {
  app_tier = "app"
}

# --- Service account dedicada para el MIG `app` ---

resource "google_service_account" "app" {
  account_id   = "sa-app-${var.env}-${var.sufijo}"
  display_name = "AppLocker App (${var.env}-${var.sufijo})"
  description  = "SA dedicada al tier app del entorno ${var.env} (MIG del lab-3)."
  project      = var.project_id
}

# --- Roles para la SA del tier app (privilegio mínimo) ---

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_project_iam_member" "app_logging" {
  project = data.google_project.project.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.app.member
}

resource "google_project_iam_member" "app_monitoring" {
  project = data.google_project.project.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.app.member
}

# El tier app abre conexiones a Cloud SQL y lee el secreto de password.
resource "google_project_iam_member" "app_sql_client" {
  project = data.google_project.project.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.app.member
}

resource "google_project_iam_member" "app_secret_accessor" {
  project = data.google_project.project.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = google_service_account.app.member
}