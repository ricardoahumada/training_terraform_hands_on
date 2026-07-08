variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "sufijo" {
  type        = string
  description = "Sufijo único del alumno (mismo que en el resto del curso)."
}

variable "network_self_link" {
  type        = string
  description = "Self-link de la VPC donde se conectará Redis."
}

variable "environments" {
  type = map(object({
    tier      = string
    memory_gb = number
    region    = string
  }))
  description = "Mapa de entornos con su tier, memoria y región."

  validation {
    condition     = alltrue([for e in var.environments : contains(["BASIC", "STANDARD_HA"], e.tier)])
    error_message = "El tier debe ser BASIC o STANDARD_HA."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels comunes a aplicar a las instancias."
  default     = {}
}