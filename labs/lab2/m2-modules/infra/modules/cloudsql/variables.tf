variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se desplegará la instancia."
}

variable "name" {
  type        = string
  description = "Nombre de la instancia Cloud SQL (sin prefijo de proyecto)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.name))
    error_message = "El nombre debe empezar por minúscula y contener solo minúsculas, dígitos o guiones."
  }
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Región GCP donde se desplegará la instancia."
}

variable "tier" {
  type        = string
  default     = "db-custom-2-7680"
  description = "Tier de máquina dedicado a Cloud SQL (ej: db-custom-2-7680, db-f1-micro)."

  validation {
    condition     = can(regex("^db-", var.tier))
    error_message = "El tier debe empezar por 'db-' (ej: db-custom-2-7680)."
  }
}

variable "availability_type" {
  type        = string
  default     = "REGIONAL"
  description = "ZONAL o REGIONAL. REGIONAL ofrece HA con failover automático (recomendado para prod)."

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type debe ser ZONAL o REGIONAL."
  }
}

variable "database_version" {
  type        = string
  default     = "POSTGRES_15"
  description = "Versión del motor de base de datos."
}

variable "disk_size" {
  type        = number
  default     = 50
  description = "Tamaño del disco en GB. Mínimo 10, máximo 65536."

  validation {
    condition     = var.disk_size >= 10 && var.disk_size <= 65536
    error_message = "disk_size debe estar entre 10 y 65536 GB."
  }
}

variable "private_network" {
  type        = string
  description = "Self-link de la red VPC donde se conectará la instancia (IP privada)."
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Si es true, protege la instancia contra borrados accidentales."
}