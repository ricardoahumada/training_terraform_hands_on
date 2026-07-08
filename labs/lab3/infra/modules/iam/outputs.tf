# Map original — útil si en el futuro se exponen más tiers.
output "service_accounts" {
  value = {
    app = {
      email  = google_service_account.app.email
      member = google_service_account.app.member
    }
  }
  description = "SA del tier app, lista para adjuntar al instance template."
}
