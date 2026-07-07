# VM PÚBLICA — tiene IP externa efímera, sirve como "puerta de entrada".
# Solo esta VM es accesible desde Internet.
resource "google_compute_instance" "public" {
  project      = var.project_id
  zone         = var.zone
  name         = var.public_vm_name
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = var.network_self_link
    subnetwork = var.public_subnet_self_link

    # access_config con bloque vacío = IP externa efímera (la asigna GCP).
    access_config {}
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  labels = {
    role    = "public"
    lab     = "m2-modular"
    managed = "terraform"
    course = var.course_label
  }
}

# VM PRIVADA — sin IP externa, solo accesible desde dentro de la VPC.
# Para llegar a ella hay que pasar por la VM pública (SSH bastion).
resource "google_compute_instance" "private" {
  project      = var.project_id
  zone         = var.zone
  name         = var.private_vm_name
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = var.network_self_link
    subnetwork = var.private_subnet_self_link

    # Sin access_config = sin IP externa. Solo IP interna (10.10.2.x).
  }

  # Permite IAP (Identity-Aware Proxy) para SSH sin IP externa.
  # Útil más adelante en M4 cuando veamos patrones de bastión seguro.
  metadata = {
    enable-oslogin = "TRUE"
  }

  labels = {
    role    = "private"
    lab     = "m2-modular"
    managed = "terraform"
    course = var.course_label
  }
}