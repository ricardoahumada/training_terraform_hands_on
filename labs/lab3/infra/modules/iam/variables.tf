variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "env" {
  type        = string
  description = "Entorno (dev, staging, prod)."
}

variable "sufijo" {
  type        = string
}