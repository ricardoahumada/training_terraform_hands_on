

resource "local_file" "fichero1" {
  content  = "Este es un fichero gestionado por terraform. Es un ejemplo básico!!. Más detalles"
  filename = "${local.base_path}/${var.filename-1}-${count.index}.md"
  count    = var.count_num
}

resource "local_sensitive_file" "contraseña1" {
  content  = "xyz1223445"
  filename = "${local.base_path}/pass1.md"
}
