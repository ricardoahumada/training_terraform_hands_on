resource "google_compute_instance" "web" {
  name         = "applocker-web-${var.vm_suffix}"
  machine_type = "e2-micro"
  zone         = var.zone

  # Imagen mínima de Debian 12 (soportada y barata)
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Bloque vacío = Terraform pide una IP pública efímera a GCP
    }
  }

  metadata_startup_script = <<-BASH
    #!/usr/bin/env bash
    cat > /srv/www/index.html <<HTML
    <!doctype html>
    <html><head><title>Lab 1.2</title></head>
    <body><h1>Hola desde ${var.vm_suffix}</h1>
    <p>Levantado con Terraform en el lab 1.2.</p>
    </body></html>
    HTML
    nohup python3 -m http.server 80 --directory /srv/www >/var/www.log 2>&1 &
  BASH

  labels = {
    entorno = "lab"
    curso   = "terraform-hands-on"
    owner   = var.vm_suffix
    modulo  = "m1"
  }
}
