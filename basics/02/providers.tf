terraform {

  backend "local" {
    path = "D:/Shared/MyTrainingRepos/training_terraform_hands_on/basics/estado_tf/terraform.tfstate"  
  }

  # backend "gcs" {
    
  # }

  required_providers {

    local = {
      source  = "hashicorp/local"
      version = "2.9.0"
    }

  }
}
