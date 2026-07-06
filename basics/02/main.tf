module "creador_ficheros" {
    source = "./file_creator"

    extension = "md"
    ruta_base = "./ficheros"
    prefijo_nombre = "datos"
}

output "file_path" {
  value = module.creador_ficheros.file_path
}
