terraform {
  required_providers {

    local = {
      source  = "hashicorp/local"
      version = "2.9.0"
    }

    google = {
      source  = "hashicorp/google"
      version = "7.39.0"
    }

  }
}

# provider "local" {
#   # Configuration options
# }

# provider "google" {
#   # Configuration options
# }