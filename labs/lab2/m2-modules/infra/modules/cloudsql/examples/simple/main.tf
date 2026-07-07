module "cloudsql" {
  source = "../.."

  project_id      = "my-project"
  name            = "applocker-db-dev"
  private_network = "projects/my-project/global/networks/applocker-vpc"
}