variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "zone" {
  type        = string
  description = "Zona donde se crearán las VMs."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "Tipo de máquina para ambas VMs."
}

variable "image" {
  type        = string
  default     = "debian-cloud/debian-12"
  description = "Imagen base (project/family)."
}

variable "network_self_link" {
  type        = string
  description = "Self-link de la VPC donde se conectarán las VMs."
}

variable "public_subnet_self_link" {
  type        = string
  description = "Self-link de la subred pública."
}

variable "private_subnet_self_link" {
  type        = string
  description = "Self-link de la subred privada."
}

variable "public_vm_name" {
  type        = string
  description = "Nombre de la VM pública."
}

variable "private_vm_name" {
  type        = string
  description = "Nombre de la VM privada."
}

variable "course_label" {
  type        = string
  description = "Nombre label curso"
}