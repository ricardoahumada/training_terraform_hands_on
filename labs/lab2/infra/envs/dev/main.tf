# ─────────────────────────────────────────────────────────────────────────────
# ROOT MODULE
# Compone los módulos network + compute para el entorno `dev`.
# Toda la gestión (init/plan/apply/destroy) se ejecuta desde aquí.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  common_labels = {
    course = "terraform-m2"
  }
}

module "network" {
  source = "../../modules/network"

  project_id = var.project_id
  region     = var.region

  network_name        = var.network_name
  public_subnet_name  = "${var.network_name}-pub"
  private_subnet_name = "${var.network_name}-priv"

  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "compute" {
  source = "../../modules/compute"

  project_id   = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  course_label = local.common_labels.course

  # Cableamos los outputs del módulo network hacia los inputs del módulo compute.
  network_self_link        = module.network.network_self_link
  public_subnet_self_link  = module.network.public_subnet_self_link
  private_subnet_self_link = module.network.private_subnet_self_link

  public_vm_name  = "${var.network_name}-pub-vm"
  private_vm_name = "${var.network_name}-priv-vm"
}
