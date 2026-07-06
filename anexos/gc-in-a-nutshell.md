# Google Cloud en pocas palabras — Guía resumida (2026)

> Resumen de referencia para el curso *Terraform Hands-on* (MediaMarkt, GCP).
> Cubre **solo los servicios de Google Cloud que aparecen en el outline**:
> GCS (state + Private Registry), Compute Engine, Managed Instance Groups, Cloud SQL,
> VPC + subnets + firewall, IAM + Service Accounts, Secret Manager, Labels, y las piezas
> satélites necesarias (proyectos, billing, gcloud, APIs).
>
> No reemplaza la documentación oficial; sirve como mapa mental rápido.

---

## 0. Modelo mental de Google Cloud

### 0.1 Jerarquía de recursos

```
Organización (folder raíz)
  └── Carpetas (Folders) — agrupación lógica por entorno/equipo
        └── Proyectos (Projects) — unidad de aislamiento, billing y quota
              └── Recursos (Compute, SQL, VPC, GCS, IAM...)
```

- **Proyecto** = unidad mínima de trabajo. Aísla red, IAM y facturación.
- **Facturación** se asocia al proyecto (cuenta de billing).
- **APIs** se habilitan por proyecto (no por organización).
- **Service Account** puede ser de proyecto, de carpeta o de organización.

### 0.2 Identificadores clave

| Recurso | Formato | Ejemplo |
|---|---|---|
| **Project ID** | string global único, inmutable | `mediamarkt-tf-prod` |
| **Project Number** | numérico autogenerado | `823746192837` |
| **Region** | zona geográfica amplia | `us-central1` |
| **Zone** | region + letra | `us-central1-a` |
| **Resource ID** | generado por GCP | `projects/.../zones/.../instances/vm-1` |

> ⚠️ El curso trabaja en `us-central1` por defecto. **Region ≠ Zone**: una región tiene 3+ zones.

### 0.3 IAM en 30 segundos

- **Who** (identity): `user`, `group`, `serviceAccount`, `allUsers`, `allAuthenticatedUsers`.
- **Can do what** (role): colección de permisos (`compute.instances.list`, ...).
- **On which resource** (scope): organización, folder, proyecto o recurso concreto.

Tipos de roles:
- **Basic roles** (`roles/owner`, `editor`, `viewer`) — *anti-patrón* en producción.
- **Predefined roles** (`roles/compute.admin`, `roles/cloudsql.client`) — granular, recomendado.
- **Custom roles** — combinación de permisos definidos por ti.

---

## 1. gcloud CLI — la navaja suiza

### 1.1 Instalación y configuración

```bash
# Linux (Debian/Ubuntu)
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# macOS
brew install --cask google-cloud-sdk

# Windows (PowerShell)
winget install Google.CloudSDK

# Inicializar (orden recomendado)
export PROJECT_ID=mediamarkt-tf-prod   # o tu project ID real
gcloud init                              # login + región/zone (solo la primera vez)
gcloud auth login                        # credenciales de usuario (navegador)

gcloud auth application-default login    # ADC para Terraform local (M3+)
gcloud auth application-default login --scopes="https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email"

gcloud config set project $PROJECT_ID    # fija el proyecto activo
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a
```

#### Usuario para CLI

- Opción A: usuario humano nuevo en Cloud Identity / Workspace
  + lo hace el admin desde la consola, no por gcloud

- Opción B: usar tu misma cuenta y limitar roles:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:tu-usuario@dominio.com" \
  --role="roles/owner"
```

### 1.2 Comandos esenciales para el curso

| Comando | Uso |
|---|---|
| `gcloud config set project <id>` | Cambia el proyecto activo. |
| `gcloud auth application-default login` | ADC para Terraform local. |
| `gcloud services enable <api>` | Habilita una API en el proyecto. |
| `gcloud compute instances list` | Lista VMs. |
| `gcloud compute ssh <vm>` | SSH a una VM. |
| `gcloud sql instances describe <name>` | Detalle de Cloud SQL. |
| `gcloud iam service-accounts list` | Lista service accounts. |
| `gcloud projects get-iam-policy <id>` | IAM policy efectiva. |
| `gcloud secrets versions access latest --secret=<name>` | Lee un secreto. |
| `gcloud billing projects link <id> --billing-account=<id>` | Asocia billing. |

### 1.3 Configuración multi-proyecto

```bash
gcloud config configurations create prod
gcloud config set project mediamarkt-tf-prod
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

gcloud config configurations list
gcloud config configurations activate prod
```

> **Convención de project ID del curso**: `<empresa>-tf-<env>` → `mediamarkt-tf-prod`, `mediamarkt-tf-staging`, `mediamarkt-tf-dev`. Mantener el sufijo `-tf-` para distinguir proyectos gestionados por Terraform de los manuales.

---

## 2. Google Cloud Storage (GCS) — el Remote Backend del curso

### 2.1 Modelo

- **Bucket** = contenedor global con nombre único (`gs://<name>`).
- **Objeto** = archivo dentro del bucket (sin jerarquía real, solo prefijos).
- **Clases de almacenamiento**: `Standard`, `Nearline`, `Coldline`, `Archive`.
- **Location**: `EU`, `US`, `US-CENTRAL1`, o una región específica.
- **Versionado**: mantiene historial de objetos (clave para Terraform state).
- **Uniform bucket-level access**: desactiva ACLs heredadas — recomendado.

### 2.2 Comandos gcloud/gsutil

```bash
gsutil mb -l EU -b on gs://tfstate-eu-prod-1234      # crear bucket
gsutil versioning set on gs://tfstate-eu-prod-1234   # versionado ON
gsutil ls -L -b gs://tfstate-eu-prod-1234             # ver config
gsutil rm -r gs://bucket/prefix                      # borrar (con cuidado)
```

### 2.3 Terraform: backend GCS

```hcl
terraform {
  backend "gcs" {
    bucket                      = "tfstate-eu-prod-1234"
    prefix                      = "env/prod/network"
    location                    = "EU"
    uniform_bucket_level_access = true
  }
}
```

- **Locking**: GCS crea `default.tflock` automáticamente (sin DynamoDB como AWS).
- **Versionado**: cada `apply` deja una versión nueva del `tfstate`.
- **Recuperación**: `gsutil cp gs://bucket/tfstate.tfstate#<generation> ./restore.tfstate`.
- **Force unlock**: `terraform force-unlock <LOCK_ID>` (cuidado: confirma que nadie está aplicando).

### 2.4 GCS como Private Module Registry

Además de state, GCS sirve como **registry privado de módulos** (Módulo 2):

```hcl
module "cloud_sql" {
  source  = "gcs::https://www.googleapis.com/storage/v1/<bucket>/modules/cloud-sql.zip"
  version = "1.2.0"

  project_id = var.project_id
  region     = "us-central1"
}
```

Convenciones:
- Un zip por versión en el path `modules/<name>/<version>/<module>.zip`.
- Tag Git = versión (SemVer).
- IAM granular: solo el equipo de plataforma puede escribir; todos pueden leer.

---

## 3. Compute Engine y Managed Instance Groups

### 3.1 Compute Engine — VMs

- **Tipos de máquinas**: predefinidas (`e2-standard-2`) o custom (CPU+RAM a medida).
- **Imágenes**: pública (`debian-12`, `ubuntu-2204-lts`), familia propia, o custom importada.
- **Discos persistentes**: SSD (`pd-ssd`), balanceado (`pd-balanced`), estándar (`pd-standard`).
- **Metadata**: arranque vía `startup-script` (clave para VMs de AppLocker).
- **Preemptible / Spot**: hasta 80% descuento, se apagan a los 24h (no para backend estable).
- **SSH**: `gcloud compute ssh` genera claves efímeras vía OS Login.

```bash
gcloud compute instances create vm-app \
  --zone=us-central1-a \
  --machine-type=e2-standard-2 \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --service-account=app-runtime@PROJECT.iam.gserviceaccount.com \
  --scopes=cloud-platform
```

### 3.2 Terraform: instancia base

```hcl
resource "google_compute_instance" "backend" {
  name         = "applocker-backend"
  zone         = "us-central1-a"
  machine_type = "e2-standard-2"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
    access_config {}   # IP pública efímera (evitar en prod)
  }

  service_account {
    email  = google_service_account.app.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = file("./scripts/startup.sh")

  labels = {
    env     = "prod"
    app     = "applocker"
    managed = "terraform"
  }
}
```

### 3.3 Managed Instance Groups (MIG)

- **Stateless MIG**: instancias idénticas, reemplazables (ideal para backend/middleware).
- **Stateful MIG**: preserva discos en recreación (bases de datos, caches).
- **Autohealing**: health check HTTP/HTTPS que recrea VMs fallidas.
- **Autoscaler**: escala por CPU, LB capacity o métricas custom.
- **Rolling update**: despliega versión nueva gradualmente (`maxSurge`, `maxUnavailable`).

```hcl
resource "google_compute_instance_template" "app" {
  name_prefix  = "applocker-backend-tmpl-"
  machine_type = "e2-standard-2"

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.self_link
  }

  lifecycle { create_before_destroy = true }
}

resource "google_compute_instance_group_manager" "backend" {
  name               = "applocker-backend-mig"
  base_instance_name = "applocker-backend"
  zone               = "us-central1-a"
  target_size        = 3

  version {
    instance_template = google_compute_instance_template.app.self_link
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app.self_link
    initial_delay_sec = 60
  }
}
```

### 3.4 Health Checks

```hcl
resource "google_compute_health_check" "app" {
  name = "applocker-backend-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}
```

---

## 4. Cloud SQL — el MongoDB del AppLocker

> En el outline el caso AppLocker dice "MongoDB (Cloud SQL)". En realidad MongoDB
> no es Cloud SQL (es Postgres/MySQL/SQL Server). El curso lo modela como
> **Cloud SQL for PostgreSQL** (o MySQL) por restricción de provider.

### 4.1 Ediciones y tiers

- **Editions**: `ENTERPRISE` (default), `ENTERPRISE_PLUS` (HA reforzado, hasta 128 vCPU).
- **Tiers**: `db-f1-micro`, `db-g1-small`, `db-custom-N-M` (N vCPU, M MB RAM).
- **HA** (`availability_type = REGIONAL`): standby síncrono en otra zone.
- **Backups**: automatizados diarios + ventana configurable + PITR.
- **Maintenance window**: actualizaciones programadas.

### 4.2 Terraform: instancia PostgreSQL

```hcl
resource "google_sql_database_instance" "main" {
  name             = "applocker-db"
  database_version = "POSTGRES_15"
  region           = "us-central1"

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "REGIONAL"
    disk_size         = 50
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
    }

    maintenance_window {
      day  = 7   # Sunday
      hour = 4
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.self_link
      require_ssl     = true
    }
  }

  deletion_protection = true
}

resource "google_sql_database" "applocker" {
  name     = "applocker"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  name     = "applocker_app"
  instance = google_sql_database_instance.main.name
  password = data.google_secret_manager_secret_version.db_pass.secret_data
}
```

### 4.3 Cloud SQL Proxy (conexión segura)

- Service account del cliente con rol `roles/cloudsql.client`.
- Binario `cloud-sql-proxy` abre un túnel TLS local sin abrir firewall.
- Recomendado para AppLocker: cada VM con la SA de runtime accede vía proxy.

```bash
cloud-sql-proxy --port=5432 applocker-db:us-central1:applocker-db
```

---

## 5. VPC, Subnets y Firewall — la red del AppLocker

### 5.1 Conceptos

- **VPC**: red privada global (no regional). Aísla proyectos.
- **Subnets**: sí regionales. Definen rangos CIDR y zonas accesibles.
- **Modo auto vs custom**: auto = una subnet por region; custom = tú defines los rangos.
- **Private Google Access**: VMs sin IP pública pueden hablar con APIs GCP.
- **Cloud NAT**: salida a internet sin IP pública en VMs.
- **Firewall rules**: stateless a nivel de VPC (default: deny ingress, allow egress).

### 5.2 Terraform: VPC 3-tier para AppLocker

```hcl
resource "google_compute_network" "main" {
  name                    = "applocker-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "app" {
  name          = "applocker-app"
  region        = "us-central1"
  ip_cidr_range = "10.10.0.0/24"
  network       = google_compute_network.main.id
}

resource "google_compute_subnetwork" "data" {
  name          = "applocker-data"
  region        = "us-central1"
  ip_cidr_range = "10.10.10.0/24"
  network       = google_compute_network.main.id
}

# Firewall: solo permitir tráfico interno entre tiers
resource "google_compute_firewall" "app_to_mw" {
  name    = "app-to-mw"
  network = google_compute_network.main.name
  source_tags = ["tier-app"]
  target_tags = ["tier-mw"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_compute_firewall" "mw_to_lock" {
  name    = "mw-to-lock"
  network = google_compute_network.main.name
  source_tags = ["tier-mw"]
  target_tags = ["tier-lock"]

  allow {
    protocol = "tcp"
    ports    = ["8081"]
  }
}

resource "google_compute_firewall" "lock_to_db" {
  name    = "lock-to-db"
  network = google_compute_network.main.name
  source_tags = ["tier-lock"]
  target_tags = ["tier-db"]

  allow { protocol = "tcp"; ports = ["5432"] }
}
```

### 5.3 Reglas implícitas que aplican siempre

- `default-allow-internal`: tráfico entre VMs de la misma VPC (puerto cualquiera).
- `default-allow-ssh`: TCP 22 desde `0.0.0.0/0` (⚠️ restringir en prod).
- **No** hay default `allow egress` que tape nada — el egress suele estar abierto por defecto.

> **Buena práctica**: Network tags por tier (`tier-app`, `tier-mw`, `tier-lock`, `tier-db`) y reglas source/target tag. Es la base del **zero-trust a nivel de red**.

### 5.4 Cloud Router + Cloud NAT (para VMs sin IP pública)

```hcl
resource "google_compute_router" "main" {
  name    = "applocker-router"
  region  = "us-central1"
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name   = "applocker-nat"
  router = google_compute_router.main.name
  region = "us-central1"

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
```

---

## 6. IAM y Service Accounts — el corazón del Módulo 4

### 6.1 Tipos de principals

- **Google Account**: usuario final (`alice@mediamarkt.com`).
- **Service Account**: identidad para workloads (no personas). Email: `name@PROJECT.iam.gserviceaccount.com`.
- **Google Group**: agrupación de usuarios para asignar roles.
- **GSuite/Cloud Identity Domain**: workspace corporativo.

### 6.2 Service Account: la pieza clave del curso

Cada VM de AppLocker corre con **una service account dedicada** con permisos mínimos:

```hcl
resource "google_service_account" "app_runtime" {
  account_id   = "applocker-app-runtime"
  display_name = "AppLocker Backend runtime"
}

# Permisos finos
resource "google_project_iam_member" "app_secrets_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.app_runtime.email}"
}

resource "google_project_iam_member" "app_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app_runtime.email}"
}

# Workload Identity para GKE (no usado en este curso, referencia)
# resource "google_service_account_iam_member" "wi" { ... }
```

### 6.3 Roles predefinidos frecuentes

| Rol | Uso |
|---|---|
| `roles/compute.admin` | Gestión completa de Compute. |
| `roles/compute.instanceAdmin.v1` | Solo gestión de VMs (no red). |
| `roles/iam.serviceAccountUser` | Permite que un recurso use una SA. |
| `roles/cloudsql.client` | Conectarse vía proxy a Cloud SQL. |
| `roles/secretmanager.secretAccessor` | Leer secretos. |
| `roles/storage.objectAdmin` | Leer/escribir objetos en GCS. |
| `roles/storage.objectViewer` | Solo lectura. |

> ⚠️ **Nunca** asignar `roles/owner` o `roles/editor` por Terraform. Usar siempre **predefined** o **custom roles**.

### 6.4 Impersonation para pipelines

Las pipelines de Terraform (Módulo 5) necesitan una SA con permisos para crear recursos:

```bash
gcloud iam service-accounts create terraform-deployer \
  --display-name="Terraform deployer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/editor"

# Generar key (solo para GitHub Actions con OIDC sería mejor)
gcloud iam service-accounts keys create key.json \
  --iam-account=terraform-deployer@$PROJECT_ID.iam.gserviceaccount.com
```

Mejor práctica 2026: **Workload Identity Federation** (evita JSON keys) con GitHub Actions OIDC.

---

## 7. Secret Manager — credenciales sin texto plano

### 7.1 Modelo

- **Secret**: contenedor. Puede tener varias **versions**.
- **Version**: estado del valor (`latest`, `1`, `2`, ...).
- **Replication**: `automatic` o `user-managed` (multi-region).
- **Access**: solo vía `secretmanager.secretAccessor`. Nunca lectura directa desde disco.
- **Audit**: Cloud Logging registra cada `access()`.

### 7.2 Terraform: crear y consumir

```hcl
resource "google_secret_manager_secret" "db_pass" {
  secret_id = "applocker-db-pass"
  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_version" "db_pass_v1" {
  secret      = google_secret_manager_secret.db_pass.id
  secret_data = random_password.db.result
}

data "google_secret_manager_secret_version" "db_pass" {
  secret  = google_secret_manager_secret.db_pass.id
  version = "latest"
}
```

### 7.3 Buenas prácticas

- **Una versión `latest` + versiones inmutables** con tag semántico.
- **Rotación automática**: Cloud Function programada que crea nueva versión.
- **Cifrado CMEK**: opcional, con Cloud KMS.
- **Desde VMs**: usar **ADC** + rol `secretAccessor` (sin JSON keys).

---

## 8. Labels — el arma secreta para costes

### 8.1 ¿Por qué importan?

- GCP **no** cobra por labels, pero permiten **desglosar facturación**.
- **Budgets + alertas** por label son la única forma práctica de controlar coste.
- Con **Active Assist / Recommender** puedes detectar VMs ociosas por entorno.

### 8.2 Labels obligatorios del curso

```
env         = prod | staging | dev
app         = applocker
tier        = backend | middleware | lock-mgmt | db
team        = platform | payments | ops
managed-by  = terraform
cost-center = CC-1234
```

### 8.3 Terraform: aplicar masivamente

```hcl
locals {
  common_labels = {
    env        = var.env
    app        = "applocker"
    managed-by = "terraform"
    team       = "platform"
  }
}

resource "google_compute_instance" "backend" {
  # ...
  labels = merge(local.common_labels, {
    tier = "backend"
  })
}
```

> Los labels son **mutables** sin recrear el recurso, pero GCP solo acepta letras minúsculas, dígitos, `_` y `-`.

---

## 9. APIs que el curso habilita (orden de aparición)

| API | Endpoint | Módulo |
|---|---|---|
| Cloud Storage | `storage-api.googleapis.com` | M1 |
| Service Usage | `serviceusage.googleapis.com` | M1 |
| Compute Engine | `compute.googleapis.com` | M3 |
| Cloud SQL Admin | `sqladmin.googleapis.com` | M3 |
| Secret Manager | `secretmanager.googleapis.com` | M4 |
| IAM | `iam.googleapis.com` | M4 |
| Cloud Resource Manager | `cloudresourcemanager.googleapis.com` | M4 |

Habilitación típica:

```hcl
resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"
  disable_on_destroy = false
}
```

---

## 10. Terraform Cloud + GitHub Actions (Módulo 5)

### 10.1 Terraform Cloud — qué hace

- **Remote runs**: `plan` y `apply` en la infraestructura de HashiCorp (o self-hosted agents).
- **State remoto** alternativo a GCS (en este curso el state se queda en GCS).
- **Sentinel / OPA**: policy as code en el momento del apply.
- **Workspaces** = entornos (cada uno con sus variables y su state).
- **Variables**: marcadas como `sensitive` no se exponen en logs.

### 10.2 Flujo GitOps con GitHub Actions

```yaml
name: terraform-plan
on:
  pull_request:
    paths: ['**.tf']

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.10.x

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account: terraform-deployer@${{ vars.PROJECT_ID }}.iam.gserviceaccount.com

      - run: terraform fmt -check -recursive
      - run: terraform init
      - run: terraform validate
      - run: terraform plan -no-color
        env:
          GOOGLE_OAUTH_ACCESS_TOKEN: ${{ steps.auth.outputs.access_token }}
```

```yaml
name: terraform-apply
on:
  push:
    branches: [main]

jobs:
  apply:
    environment: production   # gate manual en GitHub
    runs-on: ubuntu-latest
    steps:
      # mismo bloque de auth...
      - run: terraform apply -auto-approve
```

### 10.3 OPA / Conftest para policy

```rego
package terraform.policies

deny[msg] {
  resource := input.resource.google_compute_instance[name]
  resource.machine_type == "e2-micro"
  msg := sprintf("VM %s usa e2-micro: no permitido en prod", [name])
}

deny[msg] {
  bucket := input.resource.google_storage_bucket[name]
  bucket.uniform_bucket_level_access == false
  msg := sprintf("Bucket %s sin uniform_bucket_level_access", [name])
}
```

```bash
conftest test plan.json --policy policies/
```

---

## 11. Disaster Recovery y migración (Módulo 6)

### 11.1 Snapshots de disco y Cloud SQL

```bash
gcloud compute disks snapshot backend-disk --zone=us-central1-a
gcloud sql instances clone applocker-db applocker-db-dr --region=us-central1
```

### 11.2 Multi-region / DR patterns

- **Piloto / Warm standby**: segunda región con datos replicados, sin tráfico.
- **Backup/Restore**: backups + runbook para levantar en región alternativa.
- **Multi-region active-active**: solo viable con datos particionados (anti-patrón para SQL).

### 11.3 Estrategias de migración de state (Terraform)

- **`terraform state mv`**: refactor entre recursos sin destruir.
- **`terraform import`**: meter recursos manuales al state.
- **`moved {}` blocks** (1.1+): Terraform entiende el renombrado sin tocar el state.
- **`terraform state rm` + `import`**: para splits complejos.

### 11.4 Zero-downtime migration pattern

```
1. Crear infraestructura nueva (terraform plan + apply).
2. Replicar datos (CDC, dump+restore, read replica).
3. Validar nueva infra (smoke tests, shadow traffic).
4. Cutover DNS / LB (TTL bajo, gradual).
5. Apagar infraestructura vieja (terraform destroy).
```

---

## 12. Costes — el pragmatismo en GCP

### 12.1 Pricing essentials

- **Compute**: por segundo tras 1 min mínimo.
- **Cloud SQL**: por hora de instancia + almacenamiento + red.
- **GCS**: por GB almacenado + operaciones (clase A: mutaciones, clase B: lecturas).
- **Egress**: gratis entre zones de la misma region; de pago entre regions y a internet.

### 12.2 Herramientas de control

- **Budgets & Alerts** (en Billing): notificaciones al cruzar umbral.
- **Quotas**: límites duros por región/proyecto (sirven también para evitar runaway).
- **Committed Use Discounts (CUD)**: 1 o 3 años, hasta 57% en Compute y 52% en SQL.
- **Sustained Use Discounts (SUD)**: automáticos para VMs que corren >25% del mes.
- **Active Assist / Recommender**: detecta VMs ociosas, SQL sobreaprovisionados, buckets fríos.

### 12.3 Anti-patrones de coste que el curso evita

- VMs encendidas 24/7 sin autohealing ni MIG.
- Cloud SQL `REGIONAL` para entornos `dev`/`staging`.
- GCS `Standard` para logs antiguos (mover a `Coldline` o `Archive`).
- Egress masivo por no usar `Private Google Access` + Cloud NAT.

---

## 13. Comandos de troubleshooting habituales

```bash
# ¿Por qué falla el apply?
gcloud compute operations list --filter="zone:us-central1-a" --limit=5
gcloud sql operations list --instance=applocker-db --limit=5

# ¿Qué SA está usando una VM?
gcloud compute instances describe vm-app --zone=us-central1-a \
  --format="value(serviceAccounts[].email)"

# Logs estructurados
gcloud logging read "resource.type=compute_instance AND resource.labels.instance_id=123" --limit=50

# Estado del bucket de state
gsutil ls -L -b gs://tfstate-eu-prod-1234

# Drift: Terraform vs realidad
terraform plan -detailed-exitcode
# 0 = sin cambios, 1 = error, 2 = drift detectado
```

---

## 14. Glosario rápido

| Término | Significado |
|---|---|
| **Project** | Unidad de aislamiento, billing y cuota. |
| **Billing Account** | Cuenta de pago asociada a uno o más proyectos. |
| **Organization** | Nodo raíz del árbol de recursos (requiere Workspace/Cloud Identity). |
| **Folder** | Agrupación lógica bajo la organización. |
| **Region / Zone** | Region = geográfica; Zone = punto físico dentro de una region. |
| **VPC** | Red privada virtual global. |
| **Subnet** | Rango de IPs dentro de una VPC, acotado a una región. |
| **MIG** | Managed Instance Group — grupo de VMs idénticas auto-gestionadas. |
| **SA** | Service Account — identidad no humana para workloads. |
| **ADC** | Application Default Credentials — cadena de búsqueda de credenciales. |
| **CMEK** | Customer-Managed Encryption Key — claves KMS gestionadas por ti. |
| **PITR** | Point-in-Time Recovery — restaurar SQL a un momento dado. |
| **WIF** | Workload Identity Federation — autenticar desde GitHub Actions sin JSON key. |
| **CUD / SUD** | Committed Use Discount / Sustained Use Discount. |

---

## 15. Referencias oficiales

- Google Cloud documentation — [https://cloud.google.com/docs](https://cloud.google.com/docs)
- Terraform Google Provider — [https://registry.terraform.io/providers/hashicorp/google/latest/docs](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
- GCS backend — [https://developer.hashicorp.com/terraform/language/settings/backends/gcs](https://developer.hashicorp.com/terraform/language/settings/backends/gcs)
- Cloud SQL best practices — [https://cloud.google.com/sql/docs/postgres/best-practices](https://cloud.google.com/sql/docs/postgres/best-practices)
- VPC firewall rules — [https://cloud.google.com/vpc/docs/firewalls](https://cloud.google.com/vpc/docs/firewalls)
- IAM roles reference — [https://cloud.google.com/iam/docs/understanding-roles](https://cloud.google.com/iam/docs/understanding-roles)
- Secret Manager — [https://cloud.google.com/secret-manager/docs](https://cloud.google.com/secret-manager/docs)
- Managed Instance Groups — [https://cloud.google.com/compute/docs/instance-groups](https://cloud.google.com/compute/docs/instance-groups)
- Terraform Cloud — [https://developer.hashicorp.com/terraform/cloud-docs](https://developer.hashicorp.com/terraform/cloud-docs)
- Workload Identity Federation — [https://cloud.google.com/iam/docs/workload-identity-federation](https://cloud.google.com/iam/docs/workload-identity-federation)