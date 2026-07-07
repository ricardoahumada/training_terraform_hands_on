resource "google_storage_bucket" "tf_state" {
  name          = "applocker-tf-state-ricenmotion"
  location      = "us-central1"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  labels = {
    managed_by = "terraform"
    module     = "training"
  }
}

resource "google_storage_bucket" "artifacts" {
  name          = "applocker-artifacts-${terraform.workspace}-${var.suffix}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  labels = {
    environment = terraform.workspace
    managed_by  = "terraform"
  }
}