variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se desplegará la red."
}

variable "network_name" {
  type        = string
  description = "Nombre de la VPC."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.network_name))
    error_message = "El nombre debe empezar por minúscula y contener solo minúsculas, dígitos o guiones."
  }
}

variable "region" {
  type        = string
  description = "Región GCP para las subredes (ambas en la misma región)."
}

variable "public_subnet_name" {
  type        = string
  description = "Nombre de la subred pública."
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR de la subred pública (formato a.b.c.d/n)."

  validation {
    condition     = can(cidrnetmask(var.public_subnet_cidr))
    error_message = "Debe ser un CIDR válido (ej: 10.10.1.0/24)."
  }
}

variable "private_subnet_name" {
  type        = string
  description = "Nombre de la subred privada."
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR de la subred privada (formato a.b.c.d/n)."

  validation {
    condition     = can(cidrnetmask(var.private_subnet_cidr))
    error_message = "Debe ser un CIDR válido (ej: 10.10.2.0/24)."
  }
}