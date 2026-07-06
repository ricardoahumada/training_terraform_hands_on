terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    bucket = "applocker-tf-state-ricenmotion"
    prefix = "terraform/state"
  }
}