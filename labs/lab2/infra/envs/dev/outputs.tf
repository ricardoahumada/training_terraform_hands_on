output "network_name" {
  value       = module.network.network_self_link
  description = "Self-link de la VPC creada."
}

output "public_subnet_name" {
  value       = module.network.public_subnet_name
  description = "Nombre de la subred pública."
}

output "private_subnet_name" {
  value       = module.network.private_subnet_name
  description = "Nombre de la subred privada."
}

output "public_vm_name" {
  value       = module.compute.public_vm_name
  description = "Nombre de la VM pública."
}

output "public_vm_external_ip" {
  value       = module.compute.public_vm_external_ip
  description = "IP externa de la VM pública (para SSH)."
}

output "private_vm_name" {
  value       = module.compute.private_vm_name
  description = "Nombre de la VM privada."
}

output "private_vm_internal_ip" {
  value       = module.compute.private_vm_internal_ip
  description = "IP interna de la VM privada — el target del ping."
}
