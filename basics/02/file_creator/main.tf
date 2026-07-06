resource "local_file" "fichero" {
  content  = ""
  filename = "${var.ruta_base}/${var.prefijo_nombre}.${var.extension}"
}
