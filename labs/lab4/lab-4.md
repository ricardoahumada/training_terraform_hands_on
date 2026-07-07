# Lab 1 — Hardening de AppLocker

> **Duración estimada**: 120 minutos.
> **Caso AppLocker**: endurecer la arquitectura 3-tier desplegada en M3 con service accounts dedicadas, Secret Manager, labels obligatorios, backups con PITR y disciplina de drift detection.

---

## 0. Objetivo general

Al terminar este lab, se habrán aplicado los 4 bloques de seguridad sobre la infraestructura del M3:

- **Service accounts (SA) dedicadas por tier** con privilegio mínimo (sin `roles/owner`, sin la default Compute Engine SA).
- **Secret Manager** para credenciales de BD, consumido desde Terraform (data source) y desde las VMs (metadata server).
- **Labels obligatorios** (`env`, `app`, `tier`, `team`, `managed-by`, `cost-center`) con `locals` + `merge`.
- **Backups automatizados + PITR** en Cloud SQL, más snapshot schedule para los discos del MIG (Managed Instance Group).
- **Drift detection** con `terraform plan -detailed-exitcode` (debe devolver exit code 0).

---

## 1. Prerrequisitos

### 1.0 Cargar variables de entorno (obligatorio antes de cualquier comando)

> ⚠️ **Trampa común de PowerShell**: si `$env:TF_VAR_*` no existe, PowerShell deja el token literal y `gcloud`/`terraform` recibe `--project=` / `--region=` vacíos, fallando con `HTTPError 400` o "variable not declared".

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
```

Verificar antes de seguir:

```bash
echo "$TF_STATE_BUCKET | $TF_VAR_project_id | $TF_VAR_region | $TF_VAR_env"
```

```powershell
Write-Host "$($env:TF_STATE_BUCKET) | $($env:TF_VAR_project_id) | $($env:TF_VAR_region) | $($env:TF_VAR_env)"
```

### 1.1 Resto de prerrequisitos

- Repositorio del M3 intacto en `infra/modules` con la raíz del proyecto AppLocker.
- State remoto del M1 funcionando en `gs://applocker-tf-state-<sufijo>`. El aislamiento por entorno se hace por **prefijo GCS** (`envs/dev/network`, `envs/dev/compute`, `modules/cloudsql`, `envs/dev/root`), **no por workspaces de Terraform** — los workspaces se reservaron para `infra/state/` del M1.
- Permisos necesarios en el proyecto:
  - `roles/iam.serviceAccountAdmin`
  - `roles/secretmanager.admin`
  - `roles/billing.admin` (solo para crear el budget, opcional en este lab)
  - **`roles/iam.serviceAccountTokenCreator` sobre la SA `sa-app-${env}-${suffix}`** aplicado al usuario humano que ejecuta el smoke test (necesario para el §9.5; sin este binding, la impersonation falla con `Permission 'iam.serviceAccounts.getAccessToken' denied`). Se concede con:
    
    ```bash
    gcloud iam service-accounts add-iam-policy-binding \
      "sa-app-${TF_VAR_env}-${TF_VAR_suffix}@${TF_VAR_project_id}.iam.gserviceaccount.com" \
      --project=${TF_VAR_project_id} \
      --role="roles/iam.serviceAccountTokenCreator" \
      --member="user:<EMAIL_DEL_ALUMNO>"
    ```

    ```powershell
    gcloud iam service-accounts add-iam-policy-binding `
      "sa-app-$env:TF_VAR_env-$env:TF_VAR_suffix@$env:TF_VAR_project_id.iam.gserviceaccount.com" `
      --project=$env:TF_VAR_project_id `
      --role="roles/iam.serviceAccountTokenCreator" `
      --member="user:<EMAIL_DEL_ALUMNO>"
    ```

    Tras crearlo, esperar ~30–60 s antes de ejecutar §9.5 (la propagación IAM tiene consistencia eventual).
- APIs habilitadas:

```bash
gcloud services enable \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  cloudbilling.googleapis.com
```

```powershell
gcloud services enable `
  iam.googleapis.com `
  secretmanager.googleapis.com `
  cloudbilling.googleapis.com
```

---

## 2. Punto de partida (heredado de M1-M3)

- M1: bucket de state remoto `applocker-tf-state-<sufijo>` en `us-central1`, versionado, con locking y workspaces `dev` / `prod`.
- M2: módulo `cloudsql` publicado en el Private Registry (GCS) y consumido desde `envs/dev` y `envs/prod`.
- M3: VPC 3-tier con subnets `app`, `middleware`, `lock`, `data`; Cloud NAT; MIG de backend con health check y autohealing; instancia Cloud SQL PostgreSQL privada con HA regional; firewall segmentado por tags.

En M4 **no se crea infraestructura nueva de red ni de cómputo**: se **endurece** la existente.

---

## 3. Recursos necesarios

- 1 service account (`sa-app-${env}-${suffix}`) para el único MIG existente en el lab-3 (`applocker-app-mig`).
- 4 `google_project_iam_member` para asignar roles predefined: `logging.logWriter`, `monitoring.metricWriter`, `cloudsql.client`, `secretmanager.secretAccessor`.
- 1 import a state de un secreto existente en Secret Manager (`applocker-db-password`, creado en el lab-3 §10.1.1).
- 1 `google_sql_user` para AppLocker (`applocker_app`).
- Modificaciones sobre `google_compute_instance_template.backend` (SA adjunta + labels): el nombre interno del recurso es `backend`, pero el valor del label `tier` y el tag de red es `app` (alineado con el lab-3).
- 1 `google_compute_resource_policy` para snapshots de disco del MIG.
- Tiempo total estimado: ~1h 50min.

---

## 4. Estructura esperada al final del lab

```
infra/
├── envs/
│   └── dev/
│       ├── backend.tf
│       ├── locals.tf          ← nuevos labels comunes
│       ├── main.tf
│       ├── outputs.tf
│       ├── secrets.tf         ← nuevo: secreto + user de Cloud SQL
│       ├── terraform.tfvars
│       └── variables.tf
└── modules/
    ├── cloudsql/
    ├── compute/
    ├── iam/                   ← nuevo módulo introducido en M4
    │   ├── main.tf
    │   ├── outputs.tf
    │   └── variables.tf
    └── network/
        
```

---

## 5. Parte 1 — Crear el módulo `iam` con las service accounts (~15 min)

### 5.0 Preparar el root del environment (orden obligatorio)

> **Por qué este orden importa**: `terraform init` desde `infra/envs/dev/` valida que toda variable y `local` referenciada en los archivos del directorio esté declarada y tenga valor. Si falta `variables.tf`, `locals.tf` o `terraform.tfvars`, `init` falla antes de poder aplicar nada. Por eso **primero se deja el root listo, luego se crea el módulo**.

Crear los 4 archivos del root en este orden estricto:

#### 5.0.1 `infra/envs/dev/backend.tf` (provider + backend)

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
    # Sustituir <sufijo> por el sufijo real del bucket creado en M1.
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "envs/dev/root"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(local.common_labels, {
    managed-by = "terraform"
  })
}
```

#### 5.0.2 `infra/envs/dev/variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Región GCP por defecto para los recursos del entorno."
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Nombre del entorno (dev, staging, prod)."
}

variable "tf_state_bucket" {
  type        = string
  default     = "applocker-tf-state-<sufijo>"
  description = "Bucket GCS donde se persiste el state. Sustituir <sufijo> por el valor real creado en M1."
}
```

#### 5.0.3 `infra/envs/dev/locals.tf`

```hcl
locals {
  common_labels = {
    app         = "applocker"
    env         = var.env
    team        = "platform-mm"
    managed-by  = "terraform"
    cost-center = "cc-1042"
  }
}
```

#### 5.0.4 `infra/envs/dev/terraform.tfvars` (a partir del `.example`)

```bash
cp infra/envs/dev/terraform.tfvars.example infra/envs/dev/terraform.tfvars
# Editar terraform.tfvars y rellenar:
#   project_id      = "<PROJECT_ID_REAL>"
#   tf_state_bucket = "<bucket real creado en M1, sin <...>>"
```

```powershell
Copy-Item infra\envs\dev\terraform.tfvars.example infra\envs\dev\terraform.tfvars -Force
# Editar terraform.tfvars y rellenar:
#   project_id      = "<PROJECT_ID_REAL>"
#   tf_state_bucket = "<bucket real creado en M1, sin <...>>"
```

Verificar que los 4 archivos están en su sitio:

```bash
ls infra/envs/dev/{backend,variables,locals}.tf infra/envs/dev/terraform.tfvars
```

```powershell
Get-ChildItem infra\envs\dev\backend.tf, infra\envs\dev\variables.tf, infra\envs\dev\locals.tf, infra\envs\dev\terraform.tfvars
```

### 5.1 Crear la estructura del módulo IAM

```bash
mkdir -p infra/modules/iam
cd infra/modules/iam
```

```powershell
New-Item -ItemType Directory -Force -Path "infra\modules\iam" | Out-Null
Set-Location infra\modules\iam
```

### 5.2 `variables.tf` (del módulo `iam`)

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "env" {
  type        = string
  description = "Entorno (dev, staging, prod)."
}
```

### 5.3 `main.tf`

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

# Única SA del M3: el MIG `applocker-app-mig` del lab-3 ya está en producción.
# Los tiers `mw`, `lock` y `data` solo existen como subnets vacías hoy;
# cuando se desplieguen sus VMs (futuros labs) se les creará su propia SA
# con `terraform apply -target=module.iam` extendido.
locals {
  app_tier = "app"
}

# --- Service account dedicada para el MIG `app` ---

resource "google_service_account" "app" {
  account_id   = "sa-app-${var.env}-${var.sufijo}"
  display_name = "AppLocker App (${var.env}-${var.sufijo})"
  description  = "SA dedicada al tier app del entorno ${var.env} (MIG del lab-3)."
  project      = var.project_id
}

# --- Roles para la SA del tier app (privilegio mínimo) ---

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_project_iam_member" "app_logging" {
  project = data.google_project.project.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.app.member
}

resource "google_project_iam_member" "app_monitoring" {
  project = data.google_project.project.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.app.member
}

# El tier app abre conexiones a Cloud SQL y lee el secreto de password.
resource "google_project_iam_member" "app_sql_client" {
  project = data.google_project.project.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.app.member
}

resource "google_project_iam_member" "app_secret_accessor" {
  project = data.google_project.project.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = google_service_account.app.member
}
```

### 5.4 `outputs.tf`

```hcl
# Map original — útil si en el futuro se exponen más tiers.
output "service_accounts" {
  value = {
    app = {
      email  = google_service_account.app.email
      member = google_service_account.app.member
    }
  }
  description = "SA del tier app, lista para adjuntar al instance template."
}

# Outputs planos — necesarios para que los sub-stacks de lab-3
# (compute/, cloudsql/, network/) puedan leer la SA vía
# `data "terraform_remote_state" "root"`. Los outputs de remote_state
# tienen que ser valores escalares o mapas simples, no anidados
# profundamente como el map `service_accounts` de arriba.
output "app_service_account_email" {
  value       = google_service_account.app.email
  description = "Email de la SA `app` (para `data.terraform_remote_state.root.outputs.*`)."
}

output "app_service_account_member" {
  value       = google_service_account.app.member
  description = "Member IAM de la SA `app` (formato `serviceAccount:email`)."
}
```

### 5.5 Declarar el `module "iam"` en `infra/envs/dev/main.tf`

> **Por qué va aquí y no en 5.4**: `terraform apply -target=module.iam` solo funciona si en `infra/envs/dev/` existe un bloque `module "iam"` que instancie el módulo que acabamos de crear. Sin él, el apply falla con `module not found`. Hay que crear `main.tf` en el root **antes** del primer apply.
>
> **Path del módulo**: el módulo vive en `infra/modules/iam/` (NO en `infra/envs/dev/modules/iam/`). Como el root está en `infra/envs/dev/`, el `source` relativo es `"../../modules/iam"`.

`infra/envs/dev/main.tf`:

```hcl
# --- Composición del environment root ---

module "iam" {
  source = "../../modules/iam"

  project_id = var.project_id
  env        = var.env
  sufijo = "<sufijo>"
}

# Los siguientes módulos se referencian desde sus propios archivos
# del lab-3 (infra/envs/dev/network, compute, cloudsql) y se aplican
# con `terraform apply` desde cada sub-stack, NO desde aquí.
# El root NO los re-llama para evitar doble aplicación y drift.
```

> **Nota**: *"Este root NO sustituye a los sub-stacks del lab-3. Es una capa adicional que solo gestiona lo que el M4 introduce: SAs, secretos y labels. Network, compute y cloudsql siguen siendo sus propios directorios con su propio `backend "gcs"` y se aplican por separado."*

### 5.6 Aplicar

```bash
cd infra/envs/dev
terraform init -upgrade
terraform apply -target="module.iam"
```

Verificar:

```bash
gcloud iam service-accounts list \
  --project=${TF_VAR_project_id} \
  --filter="email~'sa-app-*'" \
  --format="table(email,displayName)"
```

```powershell
gcloud iam service-accounts list `
  --project=$env:TF_VAR_project_id `
  --filter="email~'sa-app-*'" `
  --format="table(email,displayName)"
```

Debe devolver la SA `sa-app-dev-<sufijo>`.

### 5.7 Verificar los bindings IAM

```bash
gcloud projects get-iam-policy ${TF_VAR_project_id} \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:sa-app-*" \
  --format="table(bindings.role)"
```

```powershell
gcloud projects get-iam-policy $env:TF_VAR_project_id `
  --flatten="bindings[].members" `
  --filter="bindings.members:serviceAccount:sa-app-*" `
  --format="table(bindings.role)"
```

Salida esperada (4 roles para `sa-app-${env}-${var.sufijo}`):

- `roles/logging.logWriter`
- `roles/monitoring.metricWriter`
- `roles/cloudsql.client`
- `roles/secretmanager.secretAccessor`

> **Nota**: *"por qué `mw`, `lock` y `data` no tienen SA propia?: porque hoy solo existe el MIG `app`. Cuando esos tiers se desplieguen (futuro), se les añade su SA en un PR aparte — no se edita el módulo a mano. Esa es la regla del curso: cada tier solo abre lo que usa, y solo cuando existe."*

---

## 6. Parte 2 — Vincular SAs al MIG y a la instancia de Cloud SQL (~15 min)

### 6.1 Modificar el `instance_template` del backend

> **Aclaración de naming (importante)**: el `resource "google_compute_instance_template" "backend"` se llama así en el lab-3 (es el plano del MIG `applocker-app-mig`), pero el **valor del label `tier`, el tag de red y el `module.iam.service_accounts[...]` que usaremos es `app`**, no `backend`. Mantener ambos nombres en la cabeza.

En `infra/modules/compute/main.tf`, añadir el bloque `service_account` al instance template:

```hcl
# --- Remote state del root M4 (M4 introduce la SA dedicada) ---
# El módulo iam vive en infra/envs/dev/modules/iam, instanciado
# por infra/envs/dev/main.tf (root con prefix "envs/dev/root").
# Desde este sub-stack leemos sus outputs por terraform_remote_state
# (mismo patrón que compute/ ya usa con network/ en M3).

data "terraform_remote_state" "root" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "envs/dev/root"
  }
}

resource "google_compute_instance_template" "backend" {  # nombre interno del recurso
  # ... resto del bloque antes de `tags = ["app"]` ...
  service_account {
    email  = data.terraform_remote_state.root.outputs.app_service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  # ... resto del bloque ...
}
```

> Solo existe el instance template del tier `app` (los otros tiers son subnets vacías del lab-3; cuando se desplieguen sus VMs, se añadirán aquí sus propios bloques `service_account`).

### 6.2 Aplicar

> **`compute/` sigue siendo su propio sub-stack** (state en `gs://.../envs/dev/compute/`). La edición se aplica desde su directorio, **no** desde el root.

```bash
cd infra/modules/compute
terraform apply
```

> **Nota**: *"El MIG aplica `update_policy { type = PROACTIVE, minimal_action = REPLACE, replacement_method = SUBSTITUTE }` (ya configurado en el lab-3) y el instance template tiene `lifecycle { create_before_destroy = true }`. Terraform rota las VMs una a una: la nueva VM se crea antes de destruir la vieja, sin pérdida de capacidad. Si hubiera downtime visible sería porque no hay LB delante; en M6 cubriremos estrategias de zero-downtime."*

Verificar:

```bash
gcloud compute instance-groups managed list-instances applocker-app-mig-${TF_VAR_env}-${TF_VAR_suffix} \
  --region=${TF_VAR_region}
```

```powershell
gcloud compute instance-groups managed list-instances applocker-app-mig-$env:TF_VAR_env-$env:TF_VAR_suffix `
--zone=us-central1-a
```

---

## 7. Parte 3 — Secret Manager (~20 min)

### 7.0 Punto de partida: el secreto ya existe desde el lab-3

> **El secreto `applocker-db-password` ya se creó en el lab-3 §10.1.1** (bootstrap con `gcloud` para que el módulo `cloudsql@1.0.0` tuviera password en el primer `apply`). Aquí **no se vuelve a crear**: se importa al state de Terraform y se le añaden los IAM bindings y los labels que falten.

Verificar que existe y tiene al menos la versión 1:

```bash
gcloud secrets versions list applocker-db-password \
  --project=${TF_VAR_project_id} \
  --format="table(name,state)"
```

```powershell
gcloud secrets versions list applocker-db-password `
  --project=$env:TF_VAR_project_id `
  --format="table(name,state)"
```

Debe devolver al menos una versión. Si está vacío, hay que volver al lab-3 §10.1.1 y crearlo (no es parte de este lab).

### 7.0.1 Crear `infra/envs/dev/secrets.tf` con el bloque del secreto (mínimo viable)

```hcl
resource "google_secret_manager_secret" "db_password" {
  secret_id = "applocker-db-password"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = merge(local.common_labels, { tier = "data" })
}
```

> **Importante — no aplicar todavía**: tras crear este archivo, ejecuta solo `terraform init` (si aún no lo hiciste tras la Parte 1) para que el provider y los `data` resuelvan. **NO ejecutes `terraform apply`** todavía: el resto del archivo (`data "google_secret_manager_secret_version"`, `data "terraform_remote_state" "cloudsql"`, `google_sql_user`) se añade en §7.2, después del import. Si aplicas ahora, fallará por las referencias incompletas.

### 7.1 Importar el secreto existente al state de Terraform

> **Prerrequisito de orden**: la Parte 1 (módulo `iam`) tiene que estar **aplicada** en el state del root. Verificar con:
> ```bash
> cd infra/envs/dev && terraform state list | grep module.iam
> ```
>
> ```powershell
> Set-Location infra\envs\dev; terraform state list | Select-String module.iam
> ```
> Si no devuelve `module.iam.google_service_account.app`, vuelve a §5.6 antes de continuar.

Como el secreto vive en GCP pero Terraform aún no lo gestiona, lo importamos:

```bash
cd infra/envs/dev
terraform import google_secret_manager_secret.db_password \
  projects/${TF_VAR_project_id}/secrets/applocker-db-password
```

```powershell
Set-Location infra\envs\dev
terraform import google_secret_manager_secret.db_password `
  "projects/$env:TF_VAR_project_id/secrets/applocker-db-password"
```

> **Nota**: *"`terraform import` registra el recurso en el state pero **no** modifica nada en GCP. Después, los HCL declarados deben coincidir (o ser compatibles) con el recurso real."*

> ⚠️ **No ejecutar `terraform plan` entre este import y §7.2.1**: el state ya tiene `db_password` registrado pero `secrets.tf` aún no declara los recursos satélite (IAM bindings, `google_sql_user`, data sources). El plan fallará con "configuration not found" o devolverá drift falso. Está bien — sigue directamente a §7.2.1 para completar `secrets.tf`.

### 7.2 Completar `secrets.tf` con IAM bindings, data sources y `google_sql_user`

> **Por qué "completar" y no "declarar"**: el archivo `infra/envs/dev/secrets.tf` **ya existe** desde §7.0.1, donde se declaró solo el bloque `resource "google_secret_manager_secret" "db_password"` (con `secret_id`, `project`, `replication` y `labels`). Ese bloque **NO se duplica aquí**: si lo copias de nuevo, Terraform falla con `Duplicate resource configuration`.
>
> Lo que se añade en este paso es todo lo que faltaba para que el secreto sea operativo desde Terraform: el IAM binding para que la SA `app` pueda leerlo, los `data` sources (versión actual + remote_state de cloudsql) y el `google_sql_user.applocker_app`.

#### 7.2.0 Prerrequisito: añadir `cloudsql_instance_name` al output del sub-stack `cloudsql/`

Editar `infra/modules/cloudsql/outputs.tf` y añadir al final:

```hcl
# Añadido en M4: exponer el nombre simple de la instancia para que
# `google_sql_user.instance` lo consuma sin tener que parsear
# `cloudsql_connection_name` (formato project:region:name que la API
# rechaza para el campo `instance`).
output "cloudsql_instance_name" {
  value       = module.cloudsql.instance_name
  description = "Nombre simple de la instancia Cloud SQL (sin prefijo project/region)."
}
```

Aplicar:

```bash
# 1. cloudsql/: publica el output cloudsql_instance_name añadido en §7.2.0.
#    El plan no debería proponer NADA (solo es un output nuevo en el state,
#    no se crean recursos en GCP).
cd infra/modules/cloudsql
terraform apply
```

#### 7.2.1 Editar `infra/envs/dev/secrets.tf` para añadir los bloques pendientes

Editar `infra/envs/dev/secrets.tf` y, **debajo del bloque `resource "google_secret_manager_secret" "db_password"` que ya está del §7.0.1**, añadir lo siguiente:

```hcl
# --- Bindings IAM: la SA del tier app (única desplegada) puede leer el secreto ---
# Cuando se añadan las SAs de los tiers `middleware` y `lock` se añadirán aquí
# sus respectivos `google_secret_manager_secret_iam_member`.

resource "google_secret_manager_secret_iam_member" "db_password_readers" {
  for_each = toset(["app"])

  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = module.iam.service_accounts[each.key].member
}

# --- Consumir la versión actual desde Terraform ---

data "google_secret_manager_secret_version" "db_password" {
  project = var.project_id
  # Usar `.secret_id` (no `.id`) por portabilidad: `.id` devuelve
  # `projects/<project>/secrets/<id>` y el provider a veces lo rechaza.
  secret = google_secret_manager_secret.db_password.secret_id
}

# --- Remote state del sub-stack cloudsql/ (lab-3) para leer su instance_name ---
# El módulo `cloudsql` se consume en `infra/modules/cloudsql/main.tf`, NO en el
# root. Aquí leemos sus outputs por remote_state. Los outputs del sub-stack son:
#   - cloudsql_connection_name   (project:region:name, NO usar en `google_sql_user.instance`)
#   - cloudsql_private_ip
#   - cloudsql_self_link
#   - cloudsql_instance_name    ← M4 lo añadió; usar ESTE para google_sql_user.instance
# Este `secrets.tf` está en el root, así que el remote state es necesario para
# cruzar el límite entre sub-stacks.

data "terraform_remote_state" "cloudsql" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "modules/cloudsql"
  }
}

# --- Crear/actualizar el user de Cloud SQL con la password del secreto ---

resource "google_sql_user" "applocker_app" {
  project  = var.project_id
  # IMPORTANTE: NO usar `cloudsql_connection_name` (formato project:region:name)
  # porque la API añade OTRO prefijo de project y rompe. Usar `cloudsql_instance_name`,
  # añadido al output del sub-stack cloudsql/ en §7.2.0.
  instance = data.terraform_remote_state.cloudsql.outputs.cloudsql_instance_name
  name     = "applocker_app"
  password = data.google_secret_manager_secret_version.db_password.secret_data
}
```

### 7.3 Aplicar

> Hay **tres** `apply` separados: `cloudsql/` (publicar el nuevo output), el root (registra el secreto importado, aplica sus labels y crea el `google_sql_user`), y `cloudsql/` otra vez solo si después quieres verificar que el `plan` desde el sub-stack no propone cambios nuevos.
>
> **Prerrequisito de orden**: la Parte 1 (módulo `iam`) tiene que estar aplicada en el state del root. Verificar con `terraform state list | grep module.iam` desde `infra/envs/dev`. Si falta, vuelve a §5.6 antes de continuar.

```bash
# 2. root: registra el secreto importado, aplica sus labels
#    y crea el user de Cloud SQL.
cd ..
terraform apply
```

Verificar:

```bash
# 1. El secreto sigue teniendo al menos la versión 1 que se creó en lab-3
gcloud secrets versions list applocker-db-password \
  --project=${TF_VAR_project_id}

# 2. El secreto tiene los labels correctos (tier=data, app=applocker)
gcloud secrets describe applocker-db-password \
  --project=${TF_VAR_project_id} \
  --format="table(name,labels)"

# 3. El user de Cloud SQL está creado
gcloud sql users list \
  --instance=applocker-db-${TF_VAR_env} \
  --project=${TF_VAR_project_id}-${TF_VAR_suffix} \
  --format="table(name,type)"
```

```powershell
# 1. El secreto sigue teniendo al menos la versión 1 que se creó en lab-3
gcloud secrets versions list applocker-db-password `
  --project=$env:TF_VAR_project_id

# 2. El secreto tiene los labels correctos (tier=data, app=applocker)
gcloud secrets describe applocker-db-password `
  --project=$env:TF_VAR_project_id `
  --format="table(name,labels)"

# 3. El user de Cloud SQL está creado
gcloud sql users list `
  --instance=applocker-db-$env:TF_VAR_env-$env:TF_VAR_suffix `
  --project=$env:TF_VAR_project_id `
  --format="table(name,type)"
```

---

## 8. Parte 4 — Aplicar labels obligatorios con `locals` + `merge` (~15 min)

### 8.1 Reemplazar el `default_labels` del provider en cada subproyecto

> ⚠️ **Trampa silenciosa**: el `local.common_labels` **solo existe en el root** (`infra/envs/dev/locals.tf` creado en §5.0.3). En `network/`, `compute/` y `cloudsql/` **NO existe** porque en lab-3 cada subproyecto tenía su `default_labels = { ... }` literal en el provider, sin pasar por `locals`.

> Se deben exporer como outputs para que sean accesibles desde los módulos internos

#### Un solo `locals` compartido vía remote_state del root

El root publica los labels como outputs y cada sub-stack los lee. En `infra/envs/dev/main.tf` (root) — **al final del archivo, fuera de cualquier `module { ... }`**:

```hcl
# output "common_labels" DEBE estar al final del archivo, sin sangría de módulo.
# Si lo pegas dentro de `module "iam"`, Terraform lo expone como
# `module.iam.common_labels` y los sub-stacks no lo encuentran.
output "common_labels" {
  value       = local.common_labels
  description = "Labels comunes aplicados a todos los recursos del entorno."
}
```

En `infra/modules/compute/main.tf`, añadir al `locals { ... }` existente (NO crear un locals nuevo):

```hcl
locals {
  subnet_app_self_link = coalesce(
    var.subnet_app_self_link,
    data.terraform_remote_state.network.outputs.subnet_self_links["app"],
  )

  # Leer los labels comunes del root para no duplicar la definición.
  common_labels = data.terraform_remote_state.root.outputs.common_labels
}
```

Y reemplazar el bloque `provider "google"` actual:

```hcl
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(
    local.common_labels,
    { managed-by = "terraform" },   # redundante pero explícito
  )
}
```

Repetir el patrón en `network/main.tf` y `cloudsql/main.tf`.

> *¡Cuidado!*: En el `main.tf` debe existir:

```hcl
data "terraform_remote_state" "root" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-rix"
    prefix = "envs/dev/root"
  }
}
```

### 8.2 Aplicar labels a los instance templates

En `compute/main.tf`, reemplazar el bloque `labels = { tier = "app" }` existente del `google_compute_instance_template.backend` por:

```hcl
resource "google_compute_instance_template" "backend" {  # nombre del recurso, no del tier
  # ... resto igual hasta el bloque labels ...
  labels = merge(local.common_labels, { tier = "app" })   # tier = "app" (no "backend"), alineado con M3

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true

    # ESTE bloque no existía en lab-3: se AÑADE dentro del `disk` (no se reemplaza nada)
    labels = merge(local.common_labels, { tier = "app" })   # discos también
  }
  # ... resto igual ...
}
```

> **Diferencia clave entre el `labels` del recurso y el del `disk`**: el primero ya existe (lo reemplazas), el segundo NO existe (lo añades). Si Terraform dice "Attribute redefined" otra vez dentro del `disk`, revisa que no estés duplicándolo por error.

> **Aclaración de naming**: el `resource "google_compute_instance_template" "backend"` se llama así por tradición (es el plano del MIG `applocker-app-mig`), pero el **valor del label `tier` debe coincidir con el tag de red y el nombre del MIG**, que en el lab-3 es `app`. Por eso `tier = "app"`, no `tier = "backend"`. Cuando en futuros labs se añadan los instance templates `middleware` y `lock`, sus labels serán `tier = "middleware"` y `tier = "lock"`.

> **Regla práctica para el alumno**: cada argumento de un bloque `resource { ... }` puede declararse **una sola vez**. Si quieres modificar `labels`, `service_account`, `tags` o similar, **edita el bloque existente**, no añadas otro. Terraform no distingue "añadir" de "redefinir" — ambos son "definir dos veces".
>
> **Nota**: *"Los `disks` dentro de un `instance_template` también aceptan labels. Si no los ponéis, la VM tiene los labels del template pero los discos hijos no. Eso es drift silencioso."*

### 8.3 Aplicar

> **Orden obligatorio**:
> 1. **Root primero** — publica el `output "common_labels"` en el remote_state (sin él, los sub-stacks fallan con "Unsupported attribute", ver trampa en §8.1).
> 2. **Sub-stacks después** — cada uno lee `data.terraform_remote_state.root.outputs.common_labels`.
>
> Los `default_labels` del provider (8.1) se aplican en cada sub-stack por separado; los labels del instance template (8.2) solo desde `compute/`. El root normalmente no propondrá nada nuevo en el segundo `apply` (es solo para publicar el output).

```bash
# 1. Root: publica el output `common_labels` que los sub-stacks consumen.
cd infra/envs/dev
terraform apply

# 1b. CHECK POST-APPLY — el output DEBE existir antes de tocar los sub-stacks.
#     Si no aparece, NO sigas: vuelve a §8.1 (probablemente el output está
#     anidado dentro de un `module { ... }` por error de pegado).
terraform output common_labels > /dev/null \
  || { echo "ERROR: output common_labels no existe en el root"; exit 1; }

# 2. Sub-stacks: cada uno lee los labels comunes del root.
cd ../../compute
terraform apply

cd ../cloudsql
terraform apply

# 3. Root: re-aplicar para sincronizar (no debería proponer nada nuevo).
cd ../../envs/dev
terraform apply
```

```powershell
# 1. Root
Set-Location infra\envs\dev
terraform apply

# 1b. CHECK POST-APPLY — el output DEBE existir antes de tocar los sub-stacks.
terraform output common_labels | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "ERROR: output common_labels no existe en el root" -ForegroundColor Red
  Write-Host "Revisa §8.1 — probablemente el output está dentro de un module"
  return
}

# 2. Sub-stacks
Set-Location ..\..\compute
terraform apply
Set-Location ..\cloudsql
terraform apply

# 3. Root
Set-Location ..\..\envs\dev
terraform apply
```

Verificar:

```bash
gcloud compute instances list \
  --project=${TF_VAR_project_id} \
  --filter="labels.app=applocker" \
  --format="table(name,zone,labels.env,labels.tier,labels.team,labels.cost-center)"
```

```powershell
gcloud compute instances list `
  --project=$env:TF_VAR_project_id `
  --filter="labels.app=applocker" `
  --format="table(name,zone,labels.env,labels.tier,labels.team,labels.cost-center)"
```

Debe devolver las 2 VMs del MIG con los 6 labels visibles.

---

### 8.4 Snapshot schedule para los discos del MIG (~5 min)

En `infra/modules/compute/main.tf`, al final del archivo:

```hcl
resource "google_compute_resource_policy" "backend_snapshot" {
  project = var.project_id
  region  = var.region
  name    = "applocker-backend-snap-${var.env}-${var.sufijo}"

  snapshot_schedule_policy {
    schedule {
      hourly_schedule {
        hours_in_cycle = 24
        start_time     = "04:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      # M4: reutilizamos el mismo `local.common_labels` que en §8.1.
      # Si no existiera, los snapshots saldrían sin tier/env/cost-center
      # y el coste del backup sería invisible para billing.
      labels = local.common_labels
    }
  }
}
```

Aplicar:

```bash
terraform apply
```

> **Trampa común — el bucket de snapshots no aparece**: `local.common_labels` no existe en `compute/main.tf` si no añadiste la línea de §8.1.3 (`common_labels = data.terraform_remote_state.root.outputs.common_labels`). Si Terraform dice "Reference to undeclared resource" o "Unsupported attribute", vuelve a §8.1.3.

---

## 9. Parte 5 — Validación final con drift detection (~20 min)

### 9.1 Formatear y validar

```bash
cd infra/envs/dev
terraform fmt -recursive
terraform validate
```

### 9.2 Plan limpio

```bash
terraform plan -out="hardening.tfplan"
```

Debe proponer los cambios esperados (nuevas SAs, bindings IAM, secreto, user SQL, labels sobre recursos existentes). **Sin errores**.

### 9.3 Aplicar

```bash
terraform apply hardening.tfplan
```

### 9.4 Smoke test de drift

> **Importante**: este comando **debe ejecutarse en cada sub-stack por separado**, porque cada uno tiene su propio state remoto (root, `compute/`, `cloudsql/`). Si solo se ejecuta desde el root, NO se verá el estado real de las VMs ni de Cloud SQL, y dará un falso `Exit code 0`.

```bash
for d in infra/envs/dev infra/modules/compute infra/modules/cloudsql; do
  echo "=== $d ==="
  (cd "$d" && terraform plan -detailed-exitcode -input=false)
  echo "Exit code: $?"
done
```

```powershell
$d = "infra\envs\dev","infra\modules\compute","infra\modules\cloudsql"
foreach ($dir in $d) {
  Write-Host "=== $dir ==="
  Push-Location $dir
  terraform plan -detailed-exitcode -input=false
  Write-Host "Exit code: $LASTEXITCODE"
  Pop-Location
}
```

Salida esperada en los **3 stacks**:

```
Exit code: 0
```

> **Nota**: *"Cada `Exit code: 0` significa que la realidad de GCP coincide con el código Terraform de ese stack. Si uno devuelve `2`, hay drift en ese scope concreto: ir a `cd <stack>` y revisar el plan hasta entender qué diverge. En M5 este loop se mete como gate del pipeline: si CUALQUIER stack devuelve ≠ 0, el merge se bloquea."*

### 9.5 Smoke test de identidad

Como solo existe 1 SA (`sa-app-${env}-${suffix}`), el smoke test es **positivo para esa SA** y **negativo creando una SA ad-hoc sin `secretAccessor`**, para demostrar que el binding sí está limitando el acceso (no es que "cualquiera pueda leer el secreto").


```bash
# --- Caso positivo: SA del tier app SÍ debe poder leer el secreto ---

# Impersonar la SA de la app (no descargar keys, no "config set account")
gcloud secrets versions access latest \
  --secret=applocker-db-password \
  --project=${TF_VAR_project_id} \
  --impersonate-service-account=sa-app-*@${TF_VAR_project_id}.iam.gserviceaccount.com
# Debe devolver la password sin error (no debe decir "Permission denied")

# --- Caso negativo: una SA cualquiera SIN binding secretAccessor debe FALLAR ---

# Crear SA ad-hoc sin ningún binding IAM
gcloud iam service-accounts create sa-applocker-smoke-test \
  --project=${TF_VAR_project_id} \
  --display-name="Smoke test M4 (sin permisos)"

# Impersonarla para demostrar que NO puede leer el secreto
gcloud secrets versions access latest \
  --secret=applocker-db-password \
  --project=${TF_VAR_project_id} \
  --impersonate-service-account=sa-applocker-smoke-test@${TF_VAR_project_id}.iam.gserviceaccount.com
# Error esperado: Permission denied (403) o "caller does not have permission"

# --- Limpieza ---
gcloud iam service-accounts delete sa-applocker-smoke-test@${TF_VAR_project_id}.iam.gserviceaccount.com --project=${TF_VAR_project_id} --quiet
```

```powershell
# --- Caso positivo: SA del tier app SÍ debe poder leer el secreto ---

# Impersonar la SA de la app (no descargar keys, no "config set account")
gcloud secrets versions access latest `
  --secret=applocker-db-password `
  --project=$env:TF_VAR_project_id `
  --impersonate-service-account="sa-app-$env:TF_VAR_env-$env:TF_VAR_suffix@$env:TF_VAR_project_id.iam.gserviceaccount.com"
# Debe devolver la password sin error (no debe decir "Permission denied")

# --- Caso negativo: una SA cualquiera SIN binding secretAccessor debe FALLAR ---

# Crear SA ad-hoc sin ningún binding IAM
gcloud iam service-accounts create sa-applocker-smoke-test `
  --project=$env:TF_VAR_project_id `
  --display-name="Smoke test M4 (sin permisos)"

# Impersonarla para demostrar que NO puede leer el secreto
gcloud secrets versions access latest `
  --secret=applocker-db-password `
  --project=$env:TF_VAR_project_id `
  --impersonate-service-account="sa-applocker-smoke-test@$env:TF_VAR_project_id.iam.gserviceaccount.com"
# Error esperado: Permission denied (403) o "caller does not have permission"

# --- Limpieza ---
gcloud iam service-accounts delete "sa-applocker-smoke-test@$env:TF_VAR_project_id.iam.gserviceaccount.com" --project=$env:TF_VAR_project_id --quiet
```

> **Nota**: *"Esto demuestra que el `secretAccessor` está aplicado a nivel de secreto: la SA `app` puede leerlo porque tiene ese binding; una SA recién creada sin permisos, no. Si todas las SAs pudieran leerlo, no sería privilegio mínimo."*

### 9.6 Smoke test de labels

```bash
gcloud compute instances list \
  --filter="labels.app=applocker AND NOT labels.cost-center:cc-*" \
  --format="value(name)"
# Debe devolver lista vacía
```

```powershell
gcloud compute instances list `
  --filter="labels.app=applocker AND NOT labels.cost-center:cc-*" `
  --format="value(name)"
# Debe devolver lista vacía
```

Si devuelve VMs, falta algún label. Revisar los `default_labels` del provider y los `labels` de los recursos.

### 9.7 Verificar el secreto en el plan root (no debe aparecer en claro)

```bash
terraform output -json | jq .
# Ningún output debe contener la password en claro.
```

```powershell
terraform output -json | ConvertFrom-Json
# Ningún output debe contener la password en claro.
```

Si algún output expone la password → añadir `sensitive = true`.

---

## 11. Limpieza

> ⚠️ **No borrar la infraestructura** — todavía la necesitamos en M5 y M6.

Pasos de limpieza **a nivel de código** (no de recursos):

```bash
# Revisar que ningún output expone la password
grep -r "sensitive" infra/   # debe aparecer al menos en secrets.tf
grep -r "DB_PASSWORD" infra/ # debe aparecer solo en secrets.tf y references

# Confirmar que no quedan iam.serviceAccountKey.create invocaciones
grep -r "serviceAccountKey" infra/  # debe estar vacío

# Commit
git add . && git commit -m "feat(m4): harden AppLocker with IAM, Secret Manager, labels and backups"
git push origin main
```

```powershell
# Revisar que ningún output expone la password
Select-String -Path infra\*.tf -Pattern "sensitive"   # debe aparecer al menos en secrets.tf
Select-String -Path infra\*.tf -Pattern "DB_PASSWORD" # debe aparecer solo en secrets.tf y references

# Confirmar que no quedan iam.serviceAccountKey.create invocaciones
Select-String -Path infra\*.tf -Pattern "serviceAccountKey"  # debe estar vacío

# Commit
git add . ; git commit -m "feat(m4): harden AppLocker with IAM, Secret Manager, labels and backups"
git push origin main
```

Pasos a nivel de **consola** (sí se pueden ejecutar):

- Borrar el budget de prueba creado durante el lab si era efímero (o dejarlo y notarlo en el runbook).

Dejar el workspace `dev` activo para M5.

----

Si se quiere destruir toda la infra:

```powershell
$env:TF_VAR_project_id = (gcloud config get-value project)
$env:TF_VAR_env        = "dev"

# 1. Sub-stacks primero (lo que ellos crearon)
Set-Location infra\modules\cloudsql
terraform destroy -auto-approve

# 2. compute: aquí está la resource_policy de snapshots del M4.
#    Primero el schedule solo, luego el resto, por dependencias.
Set-Location ..\compute
terraform destroy -target=google_compute_resource_policy.backend_snapshot -auto-approve
terraform destroy -auto-approve

# 3. network (M3)
Set-Location ..\network
terraform destroy -auto-approve

# 4. Módulo iam (necesita su propio init/destroy porque tiene su propio state)
Set-Location ..\iam
terraform init -upgrade
terraform destroy -auto-approve

# 5. Root M4 AL FINAL. Destruye module.iam (ya vacío), db_password y el google_sql_user.
Set-Location ..\..\envs\dev
terraform destroy -auto-approve

# 6. Limpieza de humo del §9.5 si la dejaste creada
gcloud iam service-accounts delete "sa-applocker-smoke-test@$env:TF_VAR_project_id.iam.gserviceaccount.com" --project=$env:TF_VAR_project_id --quiet
```


---

## 12. Recursos endurecidos (resumen)

| Componente | Antes (M3) | Después (M4) |
|---|---|---|
| Identidad del MIG `app` | Compute Engine default SA | SA dedicada `sa-app-${env}-${suffix}` con 4 roles predefined |
| Roles IAM | `cloud-platform` (scope abierto) | Predefined roles mínimos (logging, monitoring, cloudsql.client, secretmanager.secretAccessor) |
| Password de Cloud SQL | Variable o en el código | Secret Manager (existente) + data source + `google_sql_user` |
| Labels | Inconsistentes | 6 labels obligatorios en todos los recursos del root + sub-stacks |
| Snapshots de disco | Ninguno | Snapshot schedule diario, retention 7 días en `compute/` (gestionado desde Terraform) |
| Backups Cloud SQL | Default (heredado de M3) | **Sin cambios en este lab** — el módulo `cloudsql@1.0.0` ya activa backups automáticos; PITR queda pendiente de bumpear a `cloudsql@1.1.0` con la fuente del módulo |
| Drift detection | Manual | `terraform plan -detailed-exitcode` por stack como gate |

---

## 13. Validación final (gate del formador)

- [ ] `terraform plan -detailed-exitcode` devuelve exit 0 en **cada uno de los 3 stacks** (root, `compute/`, `cloudsql/`).
- [ ] La SA `sa-app-dev` existe con los 4 bindings correctos (`logging.logWriter`, `monitoring.metricWriter`, `cloudsql.client`, `secretmanager.secretAccessor`).
- [ ] El secreto `applocker-db-password` está importado al state del root vía `terraform import` y tiene al menos la versión 1.
- [ ] El smoke test de identidad: la SA `app` lee OK el secreto; la SA ad-hoc `sa-applocker-smoke-test` falla con Permission Denied.
- [ ] El smoke test de labels: ninguna VM aparece en el filtro "sin cost-center".
- [ ] El bump a `cloudsql@1.1.0` (con PITR) queda anotado como trabajo pendiente para una sesión con el formador — requiere subir la fuente del módulo al repo.
- [ ] El commit se ha subido al repo.

---

## 14. Referencias oficiales

- IAM y roles: <https://cloud.google.com/iam/docs/understanding-roles>
- Service Accounts: <https://cloud.google.com/iam/docs/service-accounts>
- Secret Manager: <https://cloud.google.com/secret-manager/docs>
- Secret Manager — acceso desde aplicaciones: <https://cloud.google.com/secret-manager/docs/accessing-the-api>
- Labels: <https://cloud.google.com/resource-manager/docs/labels>
- Cloud Billing Budgets: <https://cloud.google.com/billing/docs/how-to/budgets>
- Cloud SQL — Backup y recovery: <https://cloud.google.com/sql/docs/postgres/backup-recovery>
- Cloud SQL — PITR: <https://cloud.google.com/sql/docs/postgres/instance-settings>
- Compute Engine — Snapshot schedules: <https://cloud.google.com/compute/docs/disks/schedule-snapshots>
- Terraform — `plan -detailed-exitcode`: <https://developer.hashicorp.com/terraform/cli/commands/plan#detailed-exitcode>
- Terraform — drift detection: <https://developer.hashicorp.com/terraform/tutorials/state/resource-drift>

---