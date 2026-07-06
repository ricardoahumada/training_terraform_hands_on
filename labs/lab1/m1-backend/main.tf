resource "google_storage_bucket" "tf_state" {
  name          = "applocker-tf-state-ricenmotion"
  location      = "us-central1"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  
}