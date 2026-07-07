variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = "Región por defecto para el provider"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona para la VM (debe pertenecer a la región)"
  type        = string
  default     = "us-central1-a"
}

variable "vm_suffix" {
  description = "Sufijo personal del alumno (ej. ricar0107)"
  type        = string
}