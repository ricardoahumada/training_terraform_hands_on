variable "project_id" { type = string }
variable "region"     { type = string }
variable "env"        { type = string }

# subnet_app_self_link se obtiene desde el remote state del módulo network.
# Si el formador decide pasarlo explícito, se puede sobreescribir con -var.
variable "subnet_app_self_link" {
  type    = string
  default = null
}

variable "sufijo" {
  type    = string
}