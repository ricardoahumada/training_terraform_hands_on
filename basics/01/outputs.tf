output "secret_path" {
  description = "Ruta del fichero de contraseña"
  value = local_sensitive_file.contraseña1.filename
}