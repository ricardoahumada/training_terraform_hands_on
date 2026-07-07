variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se crearán los recursos"
}

variable "region" {
  type        = string
  description = "Región GCP por defecto para los recursos del provider"
  default     = "us-central1"
}

variable "suffix" {
  type        = string
  description = "Identificador personal (ej. iniciales+DDMM). Evita colisiones de nombres de bucket."
}