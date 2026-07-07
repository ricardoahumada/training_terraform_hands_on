# Lab 1 — Arquitectura 3-tier de AppLocker

> **Duración estimada**: 165 minutos.
> **Caso AppLocker**: desplegar VPC segmentada, MIG con autohealing y Cloud SQL privado con HA, consumiendo el módulo `cloudsql` publicado en el M2.

---

## 0. Objetivo general

Al terminar este lab, se habrá desplegado la arquitectura 3-tier de AppLocker bajo Terraform, con:

- VPC en modo custom con 4 subnets segmentadas por tier (`app`, `middleware`, `lock`, `data`).
- Cloud Router + Cloud NAT para egress sin IP pública.
- 3 reglas de firewall segmentadas por tags (zero-trust a nivel red).
- 1 instance template + 1 Managed Instance Group (MIG) para el tier `app` con health check y autohealing.
- 1 instancia Cloud SQL for PostgreSQL privada con HA regional, consumida desde el módulo `cloudsql@1.0.0` publicado en el M2.
- Labels obligatorios aplicados a todos los recursos vía `default_labels` del provider.
- `terraform plan` limpio y validación end-to-end con `nc` desde una VM del MIG hacia Cloud SQL.

> **Nota técnica importante**: el caso AppLocker original menciona "MongoDB" como datastore. **Cloud SQL no soporta MongoDB**. En este curso el datastore es **Cloud SQL for PostgreSQL**. Si el cliente necesita Mongo real, se usaría MongoDB Atlas o Firestore (fuera del alcance del curso).

---

## 1. Prerrequisitos

Haber completado M1 (state remoto) y M2 (módulo `cloudsql` publicado en el registry GCS).

Verificar con:

```bash
# Estado remoto
gcloud storage ls gs://${TF_STATE_BUCKET}/terraform/state/
# Módulo publicado
gcloud storage ls gs://${TF_STATE_BUCKET}/modules/cloudsql/1.0.0/
```

```powershell
# Estado remoto
gcloud storage ls gs://$env:TF_STATE_BUCKET/terraform/state/
# Módulo publicado
gcloud storage ls gs://$env:TF_STATE_BUCKET/modules/cloudsql/1.0.0/
```

APIs habilitadas:

```bash
gcloud services enable \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com
```

```powershell
gcloud services enable `
  compute.googleapis.com `
  sqladmin.googleapis.com `
  servicenetworking.googleapis.com `
  cloudresourcemanager.googleapis.com
```

Permisos necesarios en el proyecto:

- `compute.admin`
- `cloudsql.admin`
- `iam.serviceAccountUser`
- `servicenetworking.networksAdmin`

---

## 1.1 Cargar variables de entorno (obligatorio antes de cualquier comando)

> ⚠️ **Trampa común de PowerShell**: si `$env:TF_VAR_*` no existe, PowerShell deja el token literal y `gcloud` recibe `--region=` vacío, fallando con `HTTPError 400`.

```bash
export TF_STATE_BUCKET="applocker-tf-state-<sufijo>"
export TF_VAR_project_id="$(gcloud config get-value project)"
export TF_VAR_region="us-central1"
export TF_VAR_env="dev"
```

```powershell
$env:TF_STATE_BUCKET = "applocker-tf-state-<sufijo>"
$env:TF_VAR_project_id = (gcloud config get-value project)
$env:TF_VAR_region     = "us-central1"
$env:TF_VAR_env        = "dev"

# Opcional: Persistir para futuras sesiones de PowerShell
foreach ($k in "TF_STATE_BUCKET","TF_VAR_project_id","TF_VAR_region","TF_VAR_env") {
  [Environment]::SetEnvironmentVariable($k,(Get-Item "Env:$k").Value,"User")
}
```

Verificar antes de seguir:

```bash
echo "$TF_STATE_BUCKET | $TF_VAR_project_id | $TF_VAR_region | $TF_VAR_env"
```

```powershell
Write-Host "$($env:TF_STATE_BUCKET) | $($env:TF_VAR_project_id) | $($env:TF_VAR_region) | $($env:TF_VAR_env)"
```

---

## 2. Arquitectura objetivo

```
Mobile App
    │
    ▼
Node.js Backend  (MIG — tier "app", 10.10.0.0/20)
    │
    ▼
Middleware       (Compute VM — tier "middleware", 10.10.16.0/20)
    │
    ▼
Locker Mgmt      (Compute VM — tier "lock", 10.10.32.0/20)
    │
    ▼
Cloud SQL        (PostgreSQL — tier "data", IP privada 10.10.48.0/20)
```

Reglas de firewall (por tags, no por IP):

| Source | Target | Puerto | Acción |
|---|---|---|---|
| `app` | `middleware` | 8080 | allow ingress |
| `middleware` | `lock` | 9000 | allow ingress |
| `lock` | `data` | 5432 | allow ingress |
| IAP (35.235.240.0/20) | `app`,`middleware`,`lock` | 22 | allow ingress (SSH admin) |

---

## 3. Recursos necesarios

- Proyecto GCP con billing activo.
- 1 VPC + 4 subnets + 1 Cloud Router + 1 Cloud NAT.
- 3 reglas de firewall.
- 1 instance template + 1 health check + 1 MIG (2 VMs).
- 1 instance Cloud SQL PostgreSQL.
- Tiempo total estimado: ~2h 45min.

---

## 4. Estructura de archivos del lab

```bash
mkdir -p infra/modules/{network,compute,cloudsql}
cd infra/modules
```

```powershell
New-Item -ItemType Directory -Force -Path "infra\modules\network","infra\modules\compute","infra\modules\cloudsql" | Out-Null
Set-Location infra\modules
```

Estructura esperada al final:

```
infra/
└── modules/
    ├── network/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── compute/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── cloudsql/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```


---

## 5. Parte 1 — VPC y subnets (~20 min)

### 5.1 Crear `infra/modules/network/variables.tf`

```hcl
variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "env" {
  type    = string
  default = "dev"
}
```

### 5.2 Crear `infra/modules/network/main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    environment = var.env
    managed-by  = "terraform"
    cost-center = "cc-1042"
    course      = "terraform-hands-on"
  }
}

# --- VPC ---

resource "google_compute_network" "applocker" {
  name                    = "applocker-vpc-${var.env}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# --- Subnets por tier ---

resource "google_compute_subnetwork" "app" {
  name          = "applocker-app-sn-${var.env}"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "middleware" {
  name          = "applocker-mw-sn-${var.env}"
  ip_cidr_range = "10.10.16.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "lock" {
  name          = "applocker-lock-sn-${var.env}"
  ip_cidr_range = "10.10.32.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  private_ip_google_access = true
}

# Subnet reservada para peering con services (Cloud SQL private IP)
resource "google_compute_subnetwork" "data" {
  name          = "applocker-data-sn-${var.env}"
  ip_cidr_range = "10.10.48.0/20"
  region        = var.region
  network       = google_compute_network.applocker.id

  purpose = "PRIVATE"
}
```

### 5.3 Crear `infra/modules/network/outputs.tf`

```hcl
output "vpc_self_link" {
  value = google_compute_network.applocker.self_link
}

output "vpc_id" {
  value = google_compute_network.applocker.id
}

output "subnet_self_links" {
  value = {
    app        = google_compute_subnetwork.app.self_link
    middleware = google_compute_subnetwork.middleware.self_link
    lock       = google_compute_subnetwork.lock.self_link
    data       = google_compute_subnetwork.data.self_link
  }
}
```

### 5.4 Crear el backend remoto

`backend.tf` en `infra/modules/network/`:

```hcl
terraform {
  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/network"
  }
}
```

### 5.5 Aplicar

```bash
cd infra/modules/network

terraform init
terraform plan
terraform apply
```

Verificar en consola: `VPC Network → VPC networks → applocker-vpc-dev`.

---

## 6. Parte 2 — Cloud Router + Cloud NAT (~15 min)

### 6.1 Añadir a `infra/modules/network/main.tf`

```hcl
# --- Cloud Router + Cloud NAT ---

resource "google_compute_router" "applocker" {
  name    = "applocker-router-${var.env}"
  region  = var.region
  network = google_compute_network.applocker.id
}

resource "google_compute_router_nat" "applocker" {
  name   = "applocker-nat-${var.env}"
  router = google_compute_router.applocker.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

### 6.2 Aplicar

```bash
terraform apply
```

Verificar:

```bash
gcloud compute routers nats list \
  --router=applocker-router-${TF_VAR_env} \
  --region=${TF_VAR_region}
```

```powershell
gcloud compute routers nats list `
  --router=applocker-router-$env:TF_VAR_env `
  --region=$env:TF_VAR_region
```

---

## 7. Parte 3 — Reglas de firewall segmentadas por tags (~15 min)

### 7.1 Añadir a `infra/modules/network/main.tf`

```hcl
# --- Reglas de firewall por tags (zero-trust) ---

resource "google_compute_firewall" "app_to_mw" {
  name      = "applocker-app-to-mw-${var.env}"
  network   = google_compute_network.applocker.id
  direction = "INGRESS"

  source_tags = ["app"]
  target_tags = ["middleware"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "mw_to_lock" {
  name    = "applocker-mw-to-lock-${var.env}"
  network = google_compute_network.applocker.id

  source_tags = ["middleware"]
  target_tags = ["lock"]

  allow {
    protocol = "tcp"
    ports    = ["9000"]
  }
}

resource "google_compute_firewall" "lock_to_data" {
  name    = "applocker-lock-to-data-${var.env}"
  network = google_compute_network.applocker.id

  source_tags = ["lock"]
  target_tags = ["data"]

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}

# SSH por IAP para los 3 tiers
resource "google_compute_firewall" "ssh_iap" {
  name    = "applocker-ssh-iap-${var.env}"
  network = google_compute_network.applocker.id

  source_ranges = ["35.235.240.0/20"]   # rango de IAP
  target_tags   = ["app", "middleware", "lock"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
```

### 7.2 Aplicar y verificar

```bash
terraform apply

gcloud compute firewall-rules list --filter="network=applocker-vpc-${TF_VAR_env}"
```

```powershell
terraform apply

gcloud compute firewall-rules list --filter="network=applocker-vpc-$env:TF_VAR_env"
```

---

## 8. Parte 4 — Instance template para el backend (~15 min)

### 8.1 Crear `infra/modules/compute/variables.tf`

```hcl
variable "project_id" { type = string }
variable "region"     { type = string }
variable "env"        { type = string }

# subnet_app_self_link se obtiene desde el remote state del módulo network
# (data.terraform_remote_state.network en main.tf). Si el formador decide
# pasarlo explícito, se puede sobreescribir con -var.
variable "subnet_app_self_link" {
  type    = string
  default = null
}
```

### 8.2 Crear `infra/modules/compute/main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/compute"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    environment = var.env
    managed-by  = "terraform"
    cost-center = "cc-1042"
    course      = "terraform-hands-on"
  }
}

# --- Remote state del módulo network ---

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/network"
  }
}

locals {
  subnet_app_self_link = coalesce(
    var.subnet_app_self_link,
    data.terraform_remote_state.network.outputs.subnet_self_links["app"],
  )
}

# --- Backend instance template ---

resource "google_compute_instance_template" "backend" {
  name_prefix  = "applocker-app-tmpl-${var.env}-"
  machine_type = "e2-standard-2"
  region       = var.region

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = local.subnet_app_self_link
  }

  tags = ["app"]

  metadata_startup_script = <<-EOT
    #!/bin/bash
    docker-credential-gcr configure-docker --quiet
  EOT

  labels = {
    tier = "app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Health check ---

resource "google_compute_health_check" "app" {
  name = "applocker-app-hc-${var.env}"

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/health"
  }
}

# --- Managed Instance Group ---

resource "google_compute_instance_group_manager" "backend" {
  name               = "applocker-app-mig-${var.env}"
  base_instance_name = "applocker-app-${var.env}"
  zone               = "${var.region}-a"
  target_size        = 2

  version {
    instance_template = google_compute_instance_template.backend.self_link
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app.self_link
    initial_delay_sec = 60
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 2
    max_unavailable_fixed = 1
    replacement_method    = "SUBSTITUTE"
  }
}
```

### 8.3 `outputs.tf`

> ℹ️ El backend GCS ya está declarado en `main.tf` (Terraform ≥ 1.6 lo soporta inline). Si trabajas con Terraform 1.5, declara el bloque `backend` en un `backend.tf` aparte.

`outputs.tf`:

```hcl
output "app_mig_self_link" {
  value = google_compute_instance_group_manager.backend.self_link
}

output "app_mig_instances" {
  value = google_compute_instance_group_manager.backend.instance_group
}
```

### 8.4 Aplicar

```bash
cd infra/modules/compute

terraform init
terraform plan
terraform apply
```

Verificar:

```bash
gcloud compute instance-templates list --filter="name~applocker-app-tmpl"

gcloud compute instance-groups list-instances applocker-app-mig-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a
```

```powershell
gcloud compute instance-templates list --filter="name~applocker-app-tmpl"

gcloud compute instance-groups list-instances applocker-app-mig-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a
```

Debe devolver 2 instancias en estado `RUNNING`.

---

## 9. Parte 5 — Probar el autohealing (~10 min)

### 9.1 Simular fallo

```bash
# Listar instancias del MIG
INSTANCES=$(gcloud compute instance-groups list-instances applocker-app-mig-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a --format="value(name)" | head -1)
echo "Matando VM: $INSTANCES"

gcloud compute instances stop $INSTANCES --zone=${TF_VAR_region}-a
```

```powershell
# Listar instancias del MIG
$INSTANCE = (& gcloud compute instance-groups list-instances applocker-app-mig-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a --format="value(NAME)").Trim() -split "`r?`n" | Select-Object -First 1

Write-Host "Matando VM: $INSTANCE"

gcloud compute instances stop $INSTANCE --zone=$env:TF_VAR_region-a
```

### 9.2 Esperar el autohealing (~90 segundos)

```bash
sleep 90

gcloud compute instance-groups list-instances applocker-app-mig-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a
```

```powershell
Start-Sleep -Seconds 90

gcloud compute instance-groups list-instances applocker-app-mig-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a
```

El MIG debe haber recreado la VM con un nombre distinto. La instancia vieja ya no aparece.

> **Nota**: *"Esto es lo que pasa cuando un health check falla N veces consecutivas: el MIG destruye la VM mala y arranca una nueva. Si tuviéramos un load balancer delante, los usuarios ni se enterarían."*

---

## 10. Parte 6 — Cloud SQL privado con HA (~30 min)

### 10.1 Crear el peering con services

Añadir a `infra/modules/network/main.tf`:

```hcl
# --- Peering con services (Cloud SQL private IP) ---

resource "google_compute_global_address" "private_ip_range" {
  name          = "applocker-private-ip-range-${var.env}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.applocker.id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.applocker.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}
```

Aplicar:

```bash
terraform apply
```

### 10.1.1 Crear el secreto de password (precondición del módulo `cloudsql@1.0.0`)

```bash
# Habilitar la API (idempotente)
gcloud services enable secretmanager.googleapis.com

# Generar password aleatoria de 24 chars y crear la primera versión
PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"

echo -n "$PASSWORD" | gcloud secrets create applocker-db-password \
  --project="${TF_VAR_project_id}" \
  --replication-policy=automatic \
  --data-file=-

# Verificar
gcloud secrets versions access latest \
  --secret="applocker-db-password" \
  --project="${TF_VAR_project_id}" >/dev/null && \
  echo "✅ Secret listo"
```

```powershell
# Habilitar la API (idempotente)
gcloud services enable secretmanager.googleapis.com

# Generar password aleatoria de 24 chars y crear la primera versión
$PASSWORD = -join ((1..24) | ForEach-Object { Get-Random -InputObject ([char[]](65..90) + [char[]](97..122) + [char[]](48..57)) })

$PASSWORD | gcloud secrets create applocker-db-password `
  --project=$env:TF_VAR_project_id `
  --replication-policy=automatic `
  --data-file=-

# Verificar
$versionInfo = gcloud secrets versions list `
  "applocker-db-password" `
  --project=$env:TF_VAR_project_id `
  --format="value(name)" 2>$null
if ($LASTEXITCODE -eq 0 -and $versionInfo) {
  Write-Host "✅ Secret listo (versión: $versionInfo)"
} else {
  Write-Host "❌ El secret no existe o no tiene versiones todavía"
}
```

### 10.2 Crear `infra/modules/cloudsql/`

> 📌 **Contexto**: el `main.tf` de este subproyecto consume el módulo `cloudsql@1.0.0` publicado en M2. Ese módulo lee el password desde Secret Manager (precondición que acabas de resolver en 10.1.1). En M4 esto se automatiza con `v1.1.0`.

`variables.tf`:

```hcl
variable "project_id"    { type = string }
variable "region"        { type = string }
variable "env"           { type = string }

# vpc_self_link se obtiene desde el remote state del módulo network
# (data.terraform_remote_state.network en main.tf). Si el formador decide
# pasarlo explícito, se puede sobreescribir con -var.
variable "vpc_self_link" {
  type    = string
  default = null
}
```

> ℹ️ El backend GCS ya está declarado en `main.tf` (Terraform ≥ 1.6 lo soporta inline). Si trabajas con Terraform 1.5, declara el bloque `backend` en un `backend.tf` aparte.

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/cloudsql"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    environment = var.env
    managed-by  = "terraform"
    cost-center = "cc-1042"
    course      = "terraform-hands-on"
  }
}

# --- Remote state del módulo network ---

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/network"
  }
}

locals {
  vpc_self_link = coalesce(
    var.vpc_self_link,
    data.terraform_remote_state.network.outputs.vpc_self_link,
  )

  tf_state_bucket = "applocker-tf-state-<sufijo>"

}

module "cloudsql" {
  source = "gcs::https://www.googleapis.com/storage/v1/${local.tf_state_bucket}/modules/cloudsql/1.0.0/cloudsql.zip"

  project_id        = var.project_id
  name              = "applocker-db-${var.env}"
  region            = var.region
  tier              = "db-custom-2-7680"
  availability_type = "REGIONAL"
  database_version  = "POSTGRES_15"
  private_network   = var.vpc_self_link

  deletion_protection = true

  depends_on = [data.terraform_remote_state.network]
}
```

`outputs.tf`:

```hcl
output "cloudsql_connection_name" {
  value = module.cloudsql.connection_name
}

output "cloudsql_private_ip" {
  value = module.cloudsql.private_ip
}

output "cloudsql_self_link" {
  value = module.cloudsql.self_link
}
```

### 10.3 Aplicar

```bash
cd infra/modules/cloudsql
terraform init -upgrade
terraform plan
terraform apply
```

Verificar:

```bash
gcloud sql instances describe applocker-db-${TF_VAR_env} \
  --format="value(state,region,settings.availabilityType,ipAddresses[0].ipAddress)"
```

```powershell
gcloud sql instances describe applocker-db-$env:TF_VAR_env `
  --format="value(state,region,settings.availabilityType,ipAddresses[0].ipAddress)"
```

Debe devolver algo como:

```
RUNNABLE us-central1 REGIONAL 10.10.50.x
```

---

## 11. Parte 7 — Validación end-to-end (~15 min)

### 11.1 Confirmar que todo el plan está limpio

```bash
# En cada subproyecto
for d in infra/modules/network infra/modules/compute infra/modules/cloudsql; do
  echo "=== $d ==="
  (cd $d && terraform plan)
done
```

```powershell
# En cada subproyecto
$d = "infra\modules\network","infra\modules\compute","infra\modules\cloudsql"
foreach ($dir in $d) {
  Write-Host "=== $dir ==="
  Push-Location $dir
  terraform plan
  Pop-Location
}
```

Todos deben devolver: `No changes. Your infrastructure matches the configuration.`

### 11.2 Inspeccionar los outputs

```bash
cd infra/modules/network && terraform output -json | jq .
cd ../compute && terraform output -json | jq .
cd ../cloudsql && terraform output -json | jq .
```

```powershell
Set-Location infra\modules\network; terraform output -json | ConvertFrom-Json
Set-Location ..\compute; terraform output -json | ConvertFrom-Json
Set-Location ..\cloudsql; terraform output -json | ConvertFrom-Json
```

Deben aparecer al menos:

- `vpc_self_link`
- `app_mig_self_link`
- `cloudsql_connection_name`
- `cloudsql_private_ip`

### 11.3 Probar conectividad desde una VM del MIG a Cloud SQL

```bash
# Obtener la IP privada de Cloud SQL
CLOUDSQL_IP=$(cd infra/modules/cloudsql && terraform output -raw cloudsql_private_ip)

# Obtener el nombre de una VM del MIG
VM_NAME=$(gcloud compute instance-groups list-instances applocker-app-mig-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a --format="value(name)" | head -1)

# Probar conexión (puerto 5432 = PostgreSQL)
gcloud compute ssh $VM_NAME \
  --zone=${TF_VAR_region}-a \
  --command="nc -zv ${CLOUDSQL_IP} 5432"
```

```powershell
# Obtener la IP privada de Cloud SQL
Push-Location infra\modules\cloudsql
$CLOUDSQL_IP = terraform output -raw cloudsql_private_ip
Pop-Location

# Obtener el nombre de una VM del MIG
# Importante: `--format="value(name)"` devuelve strings, no objetos.
# Capturar entre paréntesis, Trim() y coger la primera línea con -split.
$VM_NAME = (& gcloud compute instance-groups list-instances applocker-app-mig-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a --format="value(NAME)").Trim() -split "`r?`n" | Select-Object -First 1

# Probar conexión (puerto 5432 = PostgreSQL)
gcloud compute ssh $VM_NAME `
  --zone=$env:TF_VAR_region-a `
  --command="nc -zv $CLOUDSQL_IP 5432"
```

Resultado esperado en **Linux/macOS** (nc de OpenBSD):

```
Connection to <ip> 5432 port [tcp/postgres] succeeded!
```

Resultado esperado en **Container-Optimized OS** (la imagen de las VMs del MIG en este lab):

```
External IP address was not found; defaulting to using IAP tunneling.
172.18.0.2: inverse host lookup failed:
(UNKNOWN) [172.18.0.2] 5432 (postgresql) open
```

> ⚠️ **Cómo leer el output de COS** (es éxito, no fallo):
> - `(UNKNOWN) [172.18.0.2] 5432 (postgresql) open` ⇒ puerto abierto. La versión de `nc` en COS usa el verbo `open` en lugar de `succeeded!`.
> - `inverse host lookup failed` ⇒ `nc -zv` intenta resolver el PTR inverso; las IPs privadas (10.x, 172.16/12) no tienen PTR y `nc` lo reporta. Ignorar.
> - `External IP address was not found; defaulting to using IAP tunneling` ⇒ la VM no tiene IP externa (correcto por diseño) y `gcloud` entra por IAP. **Valida la arquitectura zero-trust.**

**Gate binario**: la línea clave es `... 5432 (postgresql) open`. Si la ves → conectividad validada. Si dice `Connection refused` o `No route to host` → revisar firewall `applocker-lock-to-data-${env}` y peering con services.

> **Nota**: *"Si esto funciona, la arquitectura está completa: una VM del tier `app` puede hablar con Cloud SQL usando solo la red privada. Ni IPs públicas, ni firewall abierto al mundo."*

### 11.4 Validar labels

```bash
gcloud compute instances list \
  --project=${TF_VAR_project_id} \
  --filter="labels.app=applocker" \
  --format="table(name,zone,labels.environment,labels.tier,labels.managed-by,labels.cost-center)"
```

```powershell
gcloud compute instances list `
  --project="$env:TF_VAR_project_id" `
  --filter="labels.tier=app AND labels.environment=dev" `
  --format="table(name,zone,labels.environment,labels.tier,labels.managed-by,labels.cost-center)"
```


Debe devolver las 2 VMs del MIG con los 4 labels obligatorios.

---

## 12. Limpieza

> ⚠️ **NO destruir los recursos en este lab**. La arquitectura es la base para M4 (seguridad), M5 (GitOps) y M6 (migración zero-downtime). El formador confirmará si se conserva todo o si se destruye al final del curso.

Lo único que se elimina (si el formador lo pide) son los archivos locales `*.tfstate*` y `.terraform/`:

```bash
# Solo si el formador lo pide
for d in infra/modules/network infra/modules/compute infra/modules/cloudsql; do
  rm -rf $d/.terraform $d/*.tfstate*
done
```

```powershell
# Solo si el formador lo pide
$d = "infra\modules\network","infra\modules\compute","infra\modules\cloudsql"
foreach ($dir in $d) {
  Remove-Item -Recurse -Force "$dir\.terraform" -ErrorAction SilentlyContinue
  Get-ChildItem "$dir\*.tfstate*" -ErrorAction SilentlyContinue | Remove-Item -Force
}
```

Confirmar que la infraestructura sigue activa:

```bash
gcloud compute instances list \
  --filter="labels.tier=app AND labels.environment=dev" \
  --format="table(name,zone,labels.tier,labels.environment,status)"
gcloud sql instances list --filter="name:applocker-db-*"
```

```powershell
gcloud compute instances list `
  --filter="labels.tier=app AND labels.environment=dev" `
  --format="table(name,zone,labels.tier,labels.environment,status)"

gcloud sql instances list --filter="name:applocker-db-*"
```

Si se quiere destruir por completo:
1. Acceder a cada módulo y hacer `terrafprm destroy`
2. Eliminar el secreto: 

```bash
gcloud secrets delete applocker-db-password --project="${TF_VAR_project_id}" --quiet
```

### 12.1 Commit del lab en Git

```bash
cd infra
git add .
git commit -m "feat(M3): desplegar arquitectura 3-tier de AppLocker (VPC + MIG + Cloud SQL)"
git push origin main
```

---

## 13. Recursos desplegados (resumen)

| Recurso | Nombre | Propósito |
|---|---|---|
| VPC | `applocker-vpc-${env}` | Red privada del curso |
| Subnets | `applocker-{app,mw,lock,data}-sn-${env}` | Segmentación por tier |
| Cloud Router | `applocker-router-${env}` | Para Cloud NAT |
| Cloud NAT | `applocker-nat-${env}` | Egress sin IP pública |
| 4 reglas de firewall | `applocker-*-${env}` | Zero-trust por tags |
| Instance template | `applocker-app-tmpl-${env}-XXX` | Plano del MIG |
| Health check | `applocker-app-hc-${env}` | Autohealing |
| MIG | `applocker-app-mig-${env}` | 2 VMs backend |
| Cloud SQL | `applocker-db-${env}` | PostgreSQL HA privado |
| Global address | `applocker-private-ip-range-${env}` | Peering con services |

---

## 14. Validación final (gate del formador)

- [ ] `terraform plan` limpio en los 3 subproyectos.
- [ ] `nc -zv` desde una VM del MIG a Cloud SQL: succeeded.
- [ ] Las 2 VMs del MIG visibles con los 4 labels obligatorios.
- [ ] `gcloud sql instances describe` muestra `availabilityType=REGIONAL` y Private IP.
- [ ] Commit en Git con mensaje convencional.

---

## 15. Referencias oficiales

- Google Provider: <https://registry.terraform.io/providers/hashicorp/google/latest/docs>
- `google_compute_network`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network>
- `google_compute_subnetwork`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork>
- `google_compute_firewall`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall>
- `google_compute_instance_template`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance_template>
- `google_compute_instance_group_manager`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance_group_manager>
- `google_compute_health_check`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_health_check>
- `google_sql_database_instance`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance>
- Managed Instance Groups: <https://cloud.google.com/compute/docs/instance-groups>
- Cloud SQL for PostgreSQL best practices: <https://cloud.google.com/sql/docs/postgres/best-practices>
- VPC reference architectures: <https://cloud.google.com/vpc/docs/reference-architectures>
- Cloud NAT: <https://cloud.google.com/nat/docs/overview>
- Service Networking (peering): <https://cloud.google.com/vpc/docs/configure-private-services-access>
- Identity-Aware Proxy: <https://cloud.google.com/iap/docs/concepts-overview>