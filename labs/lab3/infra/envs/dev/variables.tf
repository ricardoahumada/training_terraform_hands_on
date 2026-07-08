variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Región GCP por defecto para los recursos del entorno."
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Nombre del entorno (dev, staging, prod)."
}

variable "tf_state_bucket" {
  type        = string
  default     = "applocker-tf-state-ricenmotion"
  description = "Bucket GCS donde se persiste el state. Sustituir <sufijo> por el valor real creado en M1."
}

variable "sufijo" {
  type        = string
  default     = "ricenmotion"
}