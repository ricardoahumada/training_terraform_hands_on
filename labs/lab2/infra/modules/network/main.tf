resource "google_compute_network" "this" {
  project                         = var.project_id
  name                            = var.network_name
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "public" {
  project       = var.project_id
  name          = var.public_subnet_name
  ip_cidr_range = var.public_subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id
  

  # Sin private_ip_google_access: la subred pública sí tiene salida directa a Internet
  # (las VMs con access_config pueden hablar hacia fuera).
}

resource "google_compute_subnetwork" "private" {
  project       = var.project_id
  name          = var.private_subnet_name
  ip_cidr_range = var.private_subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id

  # Activamos private_ip_google_access para que las VMs privadas puedan
  # hablar con APIs de GCP (GCS, Secret Manager...) sin Cloud NAT.
  # Para Internet genérico necesitaríamos Cloud NAT — fuera de scope de este lab.
  private_ip_google_access = true
}

# Firewall que permite tráfico interno entre las dos subredes de esta VPC.
# Es la pieza que hace que las VMs "se vean entre sí".
resource "google_compute_firewall" "allow_internal" {
  project = var.project_id
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.this.name

  source_ranges = [var.public_subnet_cidr, var.private_subnet_cidr]

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  description = "Permite tráfico interno entre las subredes de la VPC ${var.network_name}."
}