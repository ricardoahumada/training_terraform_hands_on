terraform {
  backend "gcs" {
    bucket = "applocker-tf-state-ricenmotion"
    prefix = "modules/network"
  }
}