# Terraform en pocas palabras — Guía resumida (2026)

> Resumen de referencia para el curso *Terraform Hands-on* (MediaMarkt, GCP).
> No reemplaza la documentación oficial; sirve como mapa mental rápido.

---

## 1. Definición de Terraform

Terraform es una herramienta de **Infrastructure as Code (IaC)** declarativa, desarrollada originalmente por HashiCorp y publicada como proyecto open source bajo la Business Source License (BUSL) desde la versión 1.5. Sucesor del modelo: **OpenTofu**, fork comunitario bajo MPL 2.0 gobernado por la Linux Foundation.

### Qué hace
- Describe la infraestructura deseada en ficheros HCL (HashiCorp Configuration Language).
- Genera un **plan** de cambios antes de aplicarlos.
- Aplica los cambios de forma idempotente contra un proveedor (provider).
- Mantiene un **estado** (state) que mapea recursos reales con la configuración.

### Modelo conceptual
```
Configuración (HCL)  -->  Plan (diff)  -->  Apply  -->  Estado (state)
        ^                                                          |
        |__________________________________________________________|
                              refresh / reconcile
```

### Características clave
- **Declarativo**: describes el "qué", no el "cómo".
- **Multi-proveedor**: AWS, GCP, Azure, Kubernetes, GitHub, Datadog, etc. (>3.000 providers).
- **Grafo de dependencias**: Terraform ordena automáticamente la creación/destrucción de recursos.
- **Plan/Apply separados**: revisión humana antes de tocar producción.

---

## 2. Instalación de Terraform

### Opción A — Binario oficial (recomendado para curso)

**Linux (incl. Cloud Shell)**
```bash
# Terraform 1.10.x (última estable a fecha de esta guía)
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
terraform -version
```

**macOS**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

**Windows**
```powershell
winget install Hashicorp.Terraform
# o descarga el zip desde https://developer.hashicorp.com/terraform/install
```

### Opción B — OpenTofu (fork open source)
```bash
# Linux/macOS
brew install opentofu
# o binarios en https://opentofu.org/docs/intro/install/
tofu -version
```

### Opción C — tfenv (gestor de versiones)
```bash
brew install tfenv           # macOS
tfenv install 1.10.5
tfenv use 1.10.5
```

### Autocompletado y helpers
```bash
terraform -install-autocomplete   # bash/zsh
```

### Verificación rápida
```bash
terraform -version
terraform init          # inicializa directorio de trabajo
```

---

## 3. Fundamentos de Terraform

### 3.1 Flujo de trabajo básico
| Comando | Función |
|---|---|
| `terraform init` | Descarga providers y módulos. |
| `terraform validate` | Valida sintaxis y referencias internas. |
| `terraform plan` | Calcula el diff entre estado actual y deseado. |
| `terraform apply` | Aplica el plan (con confirmación o `-auto-approve`). |
| `terraform destroy` | Elimina toda la infraestructura gestionada. |
| `terraform fmt` | Formatea ficheros HCL. |
| `terraform output` | Muestra los outputs declarados. |
| `terraform state ...` | Manipula el state (list, mv, rm, pull, push). |
| `terraform import` | Importa un recurso existente al state. |

### 3.2 Sintaxis HCL — bloques esenciales

**Bloque Terraform (configuración del proyecto)**
```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "mi-proyecto-tfstate"
    prefix = "prod/network"
  }
}
```

**Bloque Provider**
```hcl
provider "google" {
  project = var.project_id
  region  = "us-central1"
}
```

**Recurso (resource)**
```hcl
resource "google_storage_bucket" "data" {
  name     = "${var.project_id}-data-lake"
  location = "EU"
  uniform_bucket_level_access = true
  labels = {
    env  = "prod"
    team = "platform"
  }
}
```

**Fuente de datos (data source)**
```hcl
data "google_compute_zones" "available" {
  region = "us-central1"
}
```

**Variables**
```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP"
  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id no puede estar vacío."
  }
}
```

**Outputs**
```hcl
output "bucket_url" {
  value       = google_storage_bucket.data.url
  description = "URL del bucket creado"
  sensitive   = false
}
```

### 3.3 State: el corazón de Terraform

El **state** es un JSON que Terraform usa para saber qué recursos existen realmente y mapearlos con la configuración. Es la fuente de verdad para el próximo `plan`.

**Problemas típicos con state local**
- Sin colaboración (un solo usuario a la vez).
- Riesgo de pérdida si se borra `terraform.tfstate`.
- Sin historial ni locking.

**Solución: Remote Backend con GCS** (foco del Módulo 1 del curso)
```hcl
terraform {
  backend "gcs" {
    bucket = "tfstate-bucket-eu"
    prefix = "env/prod"
  }
}
```
- **Versionado nativo** del bucket.
- **Locking** mediante objetos `default.tflock` (sin necesidad de DynamoDB).
- Cifrado en reposo y en tránsito.

### 3.4 Ciclo de vida de un recurso
- `create` → `read` durante `terraform plan`/`refresh` → `update` / `delete` / `replace`.
- Argumentos `lifecycle` para controlar el comportamiento:
```hcl
resource "google_sql_database_instance" "main" {
  name = "main-db"
  # ...
  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
    ignore_changes        = [settings[0].disk_size]
  }
}
```

### 3.5 Expresiones y funciones útiles
- **Referenciar recursos**: `google_storage_bucket.data.name`
- **Funciones comunes**: `format`, `join`, `split`, `lookup`, `merge`, `try`, `jsonencode`, `cidrsubnet`.
- **For expressions** (HCL2+): construir listas/maps a partir de otras.
- **Splats**: `aws_instance.web[*].public_ip`.

---

## 4. Conceptos avanzados

### 4.1 Módulos
Un módulo = carpeta con `.tf` reusable. Estructura estándar:
```
modules/
  cloud-sql/
    main.tf
    variables.tf
    outputs.tf
    versions.tf
    README.md
    examples/
      basic/
```

**Uso**
```hcl
module "app_db" {
  source  = "./modules/cloud-sql"
  version = "1.2.0"   # solo para módulos de registry

  project_id = var.project_id
  region     = "us-central1"
  tier       = "db-custom-2-7680"
  databases  = ["orders", "catalog"]
}
```

**Versionado**
- **Semantic Versioning** (MAJOR.MINOR.PATCH).
- Tags Git = versiones.
- Registry público (`registry.terraform.io`) o privado (GCS, GitLab, GitHub).

### 4.2 Workspaces
Permiten mantener múltiples estados con la misma configuración.
```bash
terraform workspace new prod
terraform workspace select staging
terraform workspace list
```
Útil para `dev`/`staging`/`prod` cuando no se puede parametrizar todo por variables.

### 4.3 Dynamic blocks
Generan bloques anidados de forma repetitiva.
```hcl
resource "google_compute_firewall" "rules" {
  name    = "app-rules"
  network = google_compute_network.main.id

  dynamic "allow" {
    for_each = var.allowed_ports
    content {
      protocol = "tcp"
      ports    = [allow.value]
    }
  }
}
```

### 4.4 Meta-arguments
| Meta-argument | Propósito |
|---|---|
| `count` | Crear N instancias de un recurso. |
| `for_each` | Crear instancias indexadas por map/set. |
| `depends_on` | Dependencias explícitas (evítalo si puedes). |
| `provider` | Seleccionar provider alias. |
| `lifecycle` | Controlar create/destroy/ignore. |

### 4.5 Buenas prácticas de estructura
```
infra-live/
  modules/                # módulos reutilizables
    network/
    cloud-sql/
  envs/                   # una carpeta por entorno
    prod/
      main.tf
      backend.tf
      variables.tf
      terraform.tfvars
    staging/
    dev/
```
Cada entorno con su **propio state** y su **propio backend**.

### 4.6 Importar infraestructura existente
```bash
terraform import google_storage_bucket.legacy legacy-bucket-name
terraform plan   # Terraform propondrá los atributos detectados
terraform apply  # los atributos pasan a managed
```
Desde 1.5+: bloques `import` para importar múltiples recursos con código.
```hcl
import {
  to = google_storage_bucket.legacy
  id = "legacy-bucket-name"
}
```

### 4.7 Moved blocks (refactor sin destruir)
```hcl
moved {
  from = google_compute_instance.old
  to   = module.compute.google_compute_instance.app
}
```

### 4.8 Testing
- **`terraform validate`** — sintaxis.
- **`terraform plan`** — diff esperado.
- **`tflint`** — linting.
- **`checkov` / `tfsec`** — análisis estático de seguridad.
- **`terraform test`** (1.6+) — tests de módulos con mocks.
- **`kitchen-terraform` / `terratest`** — tests de integración (Go).

### 4.9 CI/CD y GitOps
Patrón típico (foco del Módulo 5 del curso):
```
PR  --> terraform fmt -check, validate, tflint, checkov
     --> terraform plan (comentado en PR)
main --> terraform apply (manual approve o auto en staging)
```
Herramientas: GitHub Actions, GitLab CI, Cloud Build, Atlantis, Spacelift, env0, Terraform Cloud.

### 4.10 Policy as Code
- **Sentinel** (Terraform Cloud/Enterprise).
- **OPA / Conftest** con Rego.
- **Checkov** policies personalizadas.
Ejemplo (OPA):
```rego
deny[msg] {
  resource := input.resource.google_storage_bucket[name]
  resource.uniform_bucket_level_access == false
  msg := sprintf("Bucket %s debe tener uniform_bucket_level_access=true", [name])
}
```

### 4.11 Seguridad
- **Secretos**: nunca en `tfvars` commiteados. Usar Secret Manager + `data` sources.
- **State**: puede contener secretos en texto plano → cifrar el bucket y limitar IAM.
- **`sensitive = true`** en variables/outputs para evitar logs.
- **`-var`/`-var-file`** desde CI, no desde disco.

### 4.12 Drift detection
`terraform plan` en CI periódico detecta recursos modificados fuera de Terraform.
```yaml
# GitHub Actions: nightly plan
on:
  schedule:
    - cron: '0 6 * * *'
```

---

## 5. Terraform y Google Cloud

### 5.1 Provider `hashicorp/google`
```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
```

### 5.2 Autenticación
Orden de precedencia del provider:
1. Variable `GOOGLE_CREDENTIALS` (JSON inline).
2. Archivo apuntado por `GOOGLE_CREDENTIALS_PATH`.
3. Variable `GOOGLE_APPLICATION_CREDENTIALS` (ruta).
4. **ADC** (Application Default Credentials) via `gcloud auth application-default login`.
5. Cuenta de servicio adjunta al recurso (GCE, Cloud Build, Cloud Run, GKE).

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT_ID
```

### 5.3 Remote State en GCS — configuración completa
```hcl
terraform {
  backend "gcs" {
    bucket                      = "tfstate-eu-prod-1234"
    prefix                      = "network"
    location                    = "EU"
    uniform_bucket_level_access = true
  }
}
```
**Pre-requisitos manuales** (one-time):
```bash
gsutil mb -l EU -b on gs://tfstate-eu-prod-1234
gsutil versioning set on gs://tfstate-eu-prod-1234
```
Locking automático vía `default.tflock`. Para forzar unlock (con cuidado):
```bash
terraform force-unlock <LOCK_ID>
```

### 5.4 Servicios clave cubiertos por el provider
- **Compute**: `google_compute_instance`, `google_compute_instance_group_manager`, `google_compute_instance_template`.
- **Red**: `google_compute_network`, `google_compute_subnetwork`, `google_compute_firewall`, `google_compute_router`, `google_compute_router_nat`.
- **Almacenamiento**: `google_storage_bucket`, `google_compute_disk`.
- **Bases de datos**: `google_sql_database_instance`, `google_sql_database`, `google_sql_user`, `google_redis_instance`.
- **IAM**: `google_service_account`, `google_project_iam_member`, `google_kms_key_ring`.
- **Serverless**: `google_cloud_run_service`, `google_cloudfunctions2_function`, `google_cloudfunctions_function`.
- **Secretos**: `google_secret_manager_secret`, `google_secret_manager_secret_version`.
- **Pub/Sub**: `google_pubsub_topic`, `google_pubsub_subscription`.

### 5.5 Data sources frecuentes en GCP
```hcl
data "google_project" "current" {}
data "google_compute_zones" "available" { region = var.region }
data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}
data "google_client_config" "current" {}
```

### 5.6 IAM granular con Terraform
```hcl
resource "google_service_account" "app" {
  account_id   = "app-runtime"
  display_name = "Runtime SA para app"
}

resource "google_project_iam_member" "app_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app.email}"
}
```
**Anti-patrón**: usar `roles/owner` o `roles/editor` concedidos por Terraform.

### 5.7 Secret Manager desde Terraform
```hcl
data "google_secret_manager_secret_version" "db_pass" {
  secret  = google_secret_manager_secret.db_pass.id
  version = "latest"
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.main.name
  password = data.google_secret_manager_secret_version.db_pass.secret_data
}
```

### 5.8 Buenas prácticas específicas en GCP
- **Labels obligatorios** en todos los recursos (`env`, `team`, `managed-by=terraform`).
- **Location/region explícitos**: nunca dejar defaults implícitos.
- **Service Accounts dedicados por workload**, no la default compute SA.
- **Bucket force_destroy = false** en producción.
- **`uniform_bucket_level_access = true`** en buckets.
- **Backends de state separados por entorno** (carpetas o prefijos distintos).
- **Project factory**: módulo que genera proyectos GCP con VPC, IAM, APIs habilitadas.

### 5.9 Limitaciones a recordar
- `terraform import` no genera el código HCL (1.5+ ayuda con bloques `import`).
- Cambios fuera de Terraform = drift → usar `terraform plan` en CI.
- Recursos con `lifecycle.prevent_destroy = true` bloquearán `destroy`.
- `count` y `for_each` no se pueden mezclar en el mismo recurso.

---

## 5.10 Buenas prácticas en la definición de módulos

> Principios para que un módulo sea **reusable, testeable y versionable**. Aplican tanto a módulos internos (`./modules/...`) como a módulos publicados en el registry.

### Diseño y responsabilidad
- **Un módulo, una responsabilidad**. Si describe "red", que no cree VMs; si crea "Cloud SQL", que no toque IAM de proyecto.
- **Nombres descriptivos del dominio**, no del recurso: `cloud_sql_postgres`, no `main_db_instance`.
- **Composable**: prefiere varios módulos pequeños que uno monolítico. Un módulo "application" debería componer `network` + `compute` + `database`.

### Interfaz (variables y outputs)
- **Variables = contrato público**. Todo lo configurable del módulo debe ser variable; nada de valores hardcodeados en `main.tf`.
- **Tipos estrictos** (`string`, `number`, `bool`, `list(...)`, `map(object(...))`). Evita `any` salvo último recurso.
- **Defaults sensatos** que cubran el 80% de los casos, pero sin ocultar decisiones críticas (no defaultees `project_id`, `region` o credenciales).
- **Validación con bloques `validation`** para invariantes (formato, longitud, valores permitidos).
- **Outputs = valor para el consumidor**. Expón identificadores (`id`, `self_link`), nombres, endpoints y connection strings, no atributos internos irrelevantes.
- **Documenta cada variable y output** (`description` obligatorio). Es lo único que verá quien use el módulo.

```hcl
variable "tier" {
  type        = string
  description = "Tier de Cloud SQL. Ver https://cloud.google.com/sql/docs/pricing."
  default     = "db-custom-2-7680"

  validation {
    condition     = can(regex("^db-custom-[0-9]+-[0-9]+$", var.tier))
    error_message = "tier debe seguir el patrón db-custom-<cpu>-<memory_mb>."
  }
}
```

### Estructura de ficheros
```
modules/cloud-sql/
  main.tf        # recursos
  variables.tf   # inputs
  outputs.tf     # outputs
  versions.tf    # required_version + required_providers
  README.md      # uso, requisitos, ejemplo
  examples/
    basic/       # ejemplo mínimo ejecutable
    complete/    # ejemplo con todas las opciones
```
- **`versions.tf` siempre presente**: declara `terraform { required_version, required_providers }`. Evita el clásico "en mi máquina funciona".
- **`README.md` generado y mantenido**: inputs/outputs autogenerados con `terraform-docs`, ejemplo funcional al inicio.

### Versionado y publicación
- **SemVer estricto**: MAJOR (cambio incompatible), MINOR (feature compatible), PATCH (bugfix).
- **Tag Git por release**: `v1.4.2`. Nunca publiques sin tag.
- **`CHANGELOG.md`** con breaking changes destacados.
- **Para registry público**: tag + release en GitHub, y referencea con `version = "~> 1.4"` (no `>= 1.0`).
- **Pin de providers** en `versions.tf` (ej. `version = "~> 6.0"`), nunca `latest`.

### Testing
- **`terraform validate`** en cada PR.
- **`terraform plan` contra un sandbox** (proyecto efímero por PR) como integration test mínimo.
- **`terraform test`** (1.6+) para unit tests de módulos con `mock_provider`.
- **`tflint`** y **`checkov`** en el pipeline.
- **Terratest** (Go) si necesitas assertions reales sobre la infraestructura desplegada.

### Anti-patrones
- ❌ Módulo que recibe la SA, crea la SA y le asigna permisos a la SA en el mismo `apply`.
- ❌ Recursos con `name` hardcodeado (impide reutilización).
- ❌ Módulos "Dios" que hacen de todo en un solo `apply`.
- ❌ Mezclar recursos de **varios proveedores** en un módulo "de GCP".
- ❌ Modificar `main.tf` después de un release sin bump de MAJOR.

---

## 5.11 Buenas prácticas generales de Terraform

> Aplica a todo proyecto Terraform, independientemente del proveedor.

### Estructura del repositorio
```
infra-live/
  modules/                  # módulos reutilizables (sin state)
    network/
    cloud-sql/
  envs/                     # root modules por entorno
    dev/
      main.tf
      backend.tf
      variables.tf
      terraform.tfvars
      providers.tf
    staging/
    prod/
```
- **Un root module por entorno** (dev/staging/prod), cada uno con su **propio state**.
- **`backend.tf`, `providers.tf`, `variables.tf`, `main.tf`** separados por responsabilidad.
- **`terraform.tfvars` por entorno**; **nunca** commitear secretos (usa Secret Manager o CI vars).

### Versionado y proveedores
- **`required_version`** fijado (ej. `~> 1.10`).
- **Pin exacto de providers** en `required_providers`; usa `~>` para actualizaciones menores.
- **Lock file** (`terraform.lock.hcl`) **commiteado** para reproducibilidad. `terraform init -upgrade` solo cuando se decide actualizar.

### State y backend
- **Remote backend siempre** (GCS, S3, Azure Storage, Terraform Cloud). Nada de state local en equipo.
- **Versionado del bucket** activado; **soft delete / retention** si está disponible.
- **Una cuenta/proyecto dedicado para el state** (separado del workload).
- **Locking nativo** del backend; evita soluciones externas (DynamoDB para S3, etc.).
- **No mezclar entornos** en el mismo state. Un `apply` de prod no debe poder tocar staging.

### Variables y outputs
- **`description` obligatorio** en cada variable y output.
- **`type` explícito** (nunca `any` salvo para forwards compatibles).
- **`sensitive = true`** en variables y outputs que contengan secretos; aparecerá como `***` en logs.
- **Validación** (`validation {}`) para invariantes críticas (nombre de bucket único, formato de CIDR, region válida).
- **Outputs mínimos**: lo que el siguiente módulo o el operador necesita, nada más.

### Naming y estilo
- **`terraform fmt`** en pre-commit y en CI.
- **Convención de nombres**: `snake_case` para recursos, variables, outputs. `kebab-case` para nombres de buckets y recursos cloud.
- **Convención de `name` en recursos**: incluir entorno y propósito (`prod-data-lake`, `staging-app-vm`).
- **`count` vs `for_each`**: prefiere **`for_each` con `sets` o `maps`** (índices estables); `count` solo para crear N instancias idénticas sin identidad individual.
- **`lifecycle`** explícito cuando aplique: `create_before_destroy`, `prevent_destroy` en producción, `ignore_changes` para atributos gestionados fuera (ej. `disk_size` autoajustado por Cloud SQL).

### Seguridad
- **Secretos fuera del código**: Secret Manager, Vault, SSM Parameter Store. Nunca en `.tfvars` commiteado.
- **Cifrado del state**: habilita CMEK en el bucket cuando sea posible.
- **IAM mínimo**: cada ejecución de Terraform usa una **SA dedicada con roles mínimos**, separada por entorno.
- **`preconditions` y `postconditions`** en recursos para validar invariantes de seguridad:
```hcl
resource "google_storage_bucket" "data" {
  # ...
  lifecycle {
    precondition {
      condition     = contains(["EU", "US"], var.location)
      error_message = "El bucket de datos debe residir en EU o US por compliance."
    }
  }
}
```

### Operativa
- **PRs con `terraform plan` obligado** y output en el comentario del PR.
- **`terraform apply` desde CI**, no desde portátil (excepto labs).
- **`-target`** solo para emergencias, **nunca** en pipelines automatizados.
- **Drift detection**: cron job que ejecuta `terraform plan` y alerta si hay diff sin PR.
- **Backups del state**: versioning del bucket + política de retención.
- **`terraform state mv`** antes que `rm` + `import` cuando refactorizas.

### Documentación
- **`terraform-docs`** genera automáticamente la sección de inputs/outputs en el README del módulo.
- **Diagrama de arquitectura** junto al root module (overview, no exhaustivo).
- **ADRs** (Architecture Decision Records) para decisiones no triviales (por qué GCS en vez de Terraform Cloud, por qué un módulo monolítico, etc.).

---

## 5.12 Buenas prácticas Terraform en Google Cloud

> Específicas del provider `hashicorp/google`. Complementan a las anteriores.

### Provider y autenticación
- **Pin de versión** del provider google y google-beta en `required_providers`.
- **Variables para `project` y `region`**; nunca hardcodees el proyecto en el código.
- **Prefiere ADC (Application Default Credentials)** en máquinas personales y **Service Accounts en CI**.
- **SA dedicada por pipeline/entorno** con **Workload Identity Federation** (sin JSON keys de larga vida).
- **`provider = google-beta`** solo en recursos marcados como `Beta` en la docs; no abuses.

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    managed-by = "terraform"
    env        = var.environment
    team       = var.team
  }
}
```

### Organización: proyecto, VPC y folder
- **Project factory**: módulo que genera un proyecto GCP con VPC compartida, APIs habilitadas, IAM base y billing.
- **Una VPC por entorno**, no compartir VPC entre prod y no-prod.
- **Subnets por región y propósito** (`app`, `db`, `gke`). No metas app y db en la misma subnet.
- **Private Service Access / Private Google Access** activado para hablar con APIs de Google sin salir por Internet.
- **Cloud NAT** para egress controlado de workloads sin IP pública.

### IAM y Service Accounts
- **Principio de least privilege**: roles específicos (`roles/cloudsql.client`), nunca `roles/editor` u `roles/owner`.
- **SA por workload**, no la default compute SA.
- **Workload Identity** para GKE; **IAM Conditions** (`condition {}`) para acceso por horario, IP o atributo.
- **Módulo `iam-roles`** que reciba `roles = [{role, members, condition}]` para no repetir 100 `google_project_iam_member`.

```hcl
resource "google_project_iam_member" "app_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app.email}"

  condition {
    title       = "only-from-vpc"
    description = "SA app solo accede desde la VPC de prod"
    expression  = "request.resource.name == 'projects/${var.project_id}/zones/...' "
  }
}
```

### Storage y bases de datos
- **`uniform_bucket_level_access = true`** en todos los buckets (excepto casos legacy justificados).
- **Versionado activado** en buckets críticos (`data`, `tfstate`, `logs`).
- **Lifecycle rules** explícitas: clase Standard → Nearline tras 30 días → Coldline tras 90 → Archive tras 365.
- **Cifrado con CMEK** para datos sensibles; `encryption.default_kms_key_name` a nivel de bucket/organización.
- **`force_destroy = false`** en buckets de producción (defensa contra `destroy` accidental).
- **`deletion_protection`** activado en Cloud SQL y Redis.
- **Backups automatizados** con PITR habilitado (`point_in_time_recovery_enabled`) y ventana explícita.
- **HA Cloud SQL** regional, no zonal, salvo dev.

### Compute, GKE y serverless
- **Imágenes base oficiales** (`debian-cloud`, `cos-cloud`, `ubuntu-os-cloud`), nunca imágenes de la comunidad.
- **Shielded VMs** (`shielded_instance_config`) en producción.
- **Confidential VMs** para workloads sensibles.
- **GKE Autopilot** sobre Standard salvo necesidad justificada de configurar nodos.
- **Cloud Run con `--no-allow-unauthenticated`** + IAM; nunca expuesto público sin intención.
- **Serverless VPC Access** para que Cloud Run/Cloud Functions alcancen recursos privados.

### Redes
- **Firewall rules en módulos reutilizables** parametrizadas por `source_ranges`, `target_tags`, `allowed_ports`.
- **No usar `0.0.0.0/0`** salvo regla muy específica justificada y con tag restrictivo.
- **Cloud Armor** delante de cualquier HTTP(S) Load Balancer público.
- **Identity-Aware Proxy (IAP)** para acceso SSH/RDP sin bastion ni VPN.

### Observabilidad y seguridad
- **Labels obligatorios** (`env`, `team`, `managed-by`, `cost-center`). Úsalos vía `default_labels` en el provider.
- **Audit logs** activados a nivel de organización para datos críticos.
- **Security Command Center** activado; alertas a Pub/Sub gestionado por Terraform.
- **VPC Flow Logs** en subnets de prod.

### State y locking
- **Backend `gcs`** con `uniform_bucket_level_access = true`, versioning y CMEK.
- **Prefijos distintos por entorno** (`prod/network`, `staging/network`).
- **Forzar `prevent_destroy`** en el state bucket: `lifecycle { prevent_destroy = true }` (sí, el state bucket merece su propio Terraform que lo gestione).
- **`bucket_policy_only` y `iam_configuration`** del bucket de state gestionados con cuidado.

### Limitaciones a recordar
- **`terraform import` no escribe el HCL** completo; complétalo manualmente.
- **Drift detection en CI** es obligatorio: GCP cambia recursos fuera de Terraform (autoscaler, IAM manual).
- **Recursos beta** pueden cambiar su schema entre versiones del provider; revisa el CHANGELOG antes de upgrade.
- **`google-beta`** introduce cambios incompatibles más a menudo que `google`; evita pincharte con él en producción.

---

## 5.13 Terraform test (`terraform test`, nativamente)

> Framework de testing **nativo de Terraform** (estable desde 1.6). Complementa a `validate`, `tflint` y `checkov`, y es la opción recomendada para **unit tests de módulos** sin salir de HCL.

### Por qué importa
- Hasta 1.6 los tests de módulos requerían **Terratest (Go)** o **kitchen-terraform (Ruby)**: dependencias pesadas, runner externo, curva de aprendizaje alta.
- `terraform test` corre con el propio binario de Terraform, usa sintaxis `.tftest.hcl`, soporta **mocks** y se ejecuta en segundos.
- No despliega infraestructura real → barato, idempotente, seguro en CI.

### Estructura recomendada en un módulo
```
modules/cloud-sql/
  main.tf
  variables.tf
  outputs.tf
  versions.tf
  tests/
    basic.tftest.hcl
    defaults.tftest.hcl
    validation.tftest.hcl
    network.tftest.hcl
```

### Anatomía de un test

```hcl
# tests/basic.tftest.hcl

run "creates_cloud_sql_instance" {
  command = plan   # o apply (requiere credenciales)

  variables {
    project_id = "test-project"
    region     = "europe-west1"
    name       = "app-db"
    tier       = "db-custom-2-7680"
  }

  # Assertions sobre el plan
  assert {
    condition     = google_sql_database_instance.main.name == "app-db"
    error_message = "El nombre de la instancia debe coincidir con el input."
  }

  assert {
    condition     = google_sql_database_instance.main.settings[0].tier == "db-custom-2-7680"
    error_message = "El tier debe propagarse al bloque settings."
  }
}
```

### Tres modos de ejecución

| Modo | Qué hace | Credenciales |
|---|---|---|
| `command = plan` | Genera el plan y valida assertions **sin hablar con la API**. | **No requiere.** Es el modo por defecto en CI. |
| `command = apply` | Aplica el módulo, valida outputs y destruye al final. | Sí (SA con permisos sobre los recursos creados). |
| `command = refresh` | Actualiza el state contra la infraestructura real. | Sí. |

> Regla práctica: usa `plan` para la mayoría de tests; reserva `apply` para casos donde necesitas verificar atributos **post-provisión** (ej. URL autogenerada, IP asignada).

### Mocks de providers y recursos

Cuando un módulo depende de recursos que **no quieres crear** (un proyecto, una red, una imagen):

```hcl
# tests/network.tftest.hcl

mock_provider "google" {
  mock_data "google_compute_network" {
    defaults = {
      self_link = "projects/test-project/global/networks/mock-vpc"
    }
  }

  mock_resource "google_compute_subnetwork" {
    defaults = {
      self_link = "projects/test-project/regions/europe-west1/subnetworks/mock-subnet"
    }
  }
}

run "creates_instance_in_subnet" {
  command = plan

  variables {
    project_id = "test-project"
    region     = "europe-west1"
    name       = "app-db"
    network    = "projects/test-project/global/networks/mock-vpc"
  }

  assert {
    condition     = strcontains(google_sql_database_instance.main.settings[0].ip_configuration[0].private_network, "mock-vpc")
    error_message = "La instancia debe asociarse a la red mockeada."
  }
}
```

Y para **mockear módulos completos**:

```hcl
mock_provider "google" {}

mock_resource "google_compute_network" {
  defaults = { self_link = "mock-vpc" }
}

# Reemplaza un módulo entero por valores fijos
override_module {
  target = module.network
  outputs = {
    vpc_id   = "mock-vpc"
    subnet_id = "mock-subnet"
  }
}
```

### Assertions más habituales

```hcl
# Outputs esperados
assert {
  condition     = output.connection_name != ""
  error_message = "El output connection_name no puede estar vacío."
}

# Validaciones bloqueadas (variable validation)
assert {
  condition     = length(tfrun.variables) > 0
  error_message = "Debe haber variables declaradas."
}

# Cantidad de recursos
assert {
  condition     = length(google_sql_database.users) == 2
  error_message = "Deben crearse exactamente 2 usuarios SQL."
}

# Labels obligatorios
assert {
  condition     = google_sql_database_instance.main.settings[0].user_labels["managed-by"] == "terraform"
  error_message = "Falta el label managed-by=terraform."
}
```

### Buenas prácticas con `terraform test`

- **Un archivo `.tftest.hcl` por escenario**, no un megafichero con 30 `run`.
- **Nombres descriptivos de `run`**: `run "validates_tier_pattern"` > `run "test1"`.
- **Combina con `validation` blocks**: testea también que las validaciones rechacen inputs inválidos.
- **`command = plan` por defecto**; usa `apply` solo cuando no puedas asserts en plan (atributos computados).
- **Mocks explícitos** para proveedores de datos y recursos de los que depende el módulo pero no quieres crear.
- **Ejecuta en CI** junto a `fmt`, `validate`, `tflint`, `checkov`. Pipeline típico:
  ```yaml
  - terraform fmt -check -recursive
  - terraform init -backend=false
  - terraform validate
  - terraform test
  - tflint --recursive
  - checkov -d .
  ```
- **Cobertura mínima útil**: inputs obligatorios, defaults, combinación con módulos mockeados, validación de variables.
- **No reemplaza Terratest**: para tests de integración reales (latencias, conectividad, seguridad) sigue necesitando Terratest o tests con `apply` contra un sandbox efímero.

### Depuración y ejecución

```bash
# Ejecutar todos los tests de un módulo
terraform test

# Filtrar por archivo
terraform test -filter=tests/basic.tftest.hcl

# Verbose (muestra plan + valores de variables)
terraform test -verbose

# Modo JSON (para integraciones con CI / reporters)
terraform test -json
```

### Limitaciones a recordar
- Los `assert` evalúan **el plan o el apply**; no son tests funcionales del recurso desplegado.
- `mock_provider` **no valida** la API real — un plan con mocks puede ser válido pero el apply fallar.
- **`command = apply` deja residuos** si el cleanup falla. Aíslalo siempre en un proyecto/sandbox.
- Para tests cross-module con **state compartido**, sigue siendo mejor Terratest.

---

## 6. Referencias

### Documentación oficial
- Terraform: https://developer.hashicorp.com/terraform/docs
- Terraform Registry: https://registry.terraform.io/
- Google Provider: https://registry.terraform.io/providers/hashicorp/google/latest/docs
- OpenTofu: https://opentofu.org/

### Guías y tutoriales
- HashiCorp Learn — GCP: https://developer.hashicorp.com/terraform/tutorials/gcp-get-started
- Google Cloud Skills Boost — Terraform on GCP: https://www.skills.google/paths/12/course_templates/443?locale=es
- Terraform Up & Running (3.ª ed.) — Yevgeniy Brikman: https://www.terraformupandrunning.com/

### Libros recomendados
- *Terraform: Up & Running* — Yevgeniy Brikman (O'Reilly).
- *Terraform in Action* — Scott Winkler (Manning).
- *Infrastructure as Code (Patterns & Practices)* — Kief Morris (O'Reilly).

### Herramientas complementarias
- **tflint**: https://github.com/terraform-linters/tflint
- **tfsec / checkov**: https://github.com/aquasecurity/tfsec
- **terraform-docs**: https://terraform-docs.io/
- **terragrunt**: https://terragrunt.gruntwork.io/
- **atlantis**: https://www.runatlantis.io/
- **spacelift / env0**: plataformas GitOps para Terraform.

### Específico del curso
- Outline oficial del curso: [docs/sot/terraform_course_outline.md](../sot/terraform_course_outline.md)
- Notas y referencias: [docs/notas/notas.md](../notas/notas.md) · [docs/notas/refs.md](../notas/refs.md)

---

*Última revisión: 2026-06. Alineado con Terraform 1.10.x y Google provider 6.x.*
