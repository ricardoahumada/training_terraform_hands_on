# Reutilizamos el bucket de state del M1.
# El prefijo `modular/dev` separa este estado del de M1.
terraform {
  backend "gcs" {
    bucket = "applocker-tf-state-ricenmotion" # <-- CAMBIAR por el sufijo del alumno
    prefix = "modular/dev"
  }
}