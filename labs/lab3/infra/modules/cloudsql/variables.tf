variable "project_id"    { type = string }
variable "region"        { type = string }
variable "env"           { type = string }

# vpc_self_link se obtiene desde el remote state del módulo network.
# Si el formador decide pasarlo explícito, se puede sobreescribir con -var.
variable "vpc_self_link" {
  type    = string
  default = null
}

variable "sufijo" {
  type    = string
}

variable "tf_state_bucket" {
  type = string
  const = true
}

