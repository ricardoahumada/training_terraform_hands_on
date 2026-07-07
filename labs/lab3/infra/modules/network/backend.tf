terraform {
  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/network"
  }
}