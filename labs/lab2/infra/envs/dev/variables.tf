variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  default     = "europe-west1"
  description = "Región GCP."
}

variable "zone" {
  type        = string
  default     = "europe-west1-b"
  description = "Zona GCP para las VMs."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "Tipo de máquina para ambas VMs."
}

variable "network_name" {
  type        = string
  default     = "applocker-vpc-ric"
  description = "Nombre de la VPC."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.10.1.0/24"
  description = "CIDR de la subred pública."
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.10.2.0/24"
  description = "CIDR de la subred privada."
}