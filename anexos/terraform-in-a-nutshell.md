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
