# Lab 1 — Patrones avanzados y migración zero-downtime de AppLocker

> **Duración estimada**: 80 minutos.
> **Caso AppLocker**: intercalar un tier de cache (Memorystore Redis) entre Middleware y Locker Management, **sin que AppLocker deje de responder ni un solo segundo**. Se aplica el patrón **replicar → validar → cutover → apagar**.
>
> **Punto de partida**: la plantilla `module-4/labs/infra` (state en `gs://applocker-tf-state-<sufijo>`, root en `infra/envs/dev/`, módulos en `infra/modules/{network,compute,cloudsql,iam}/`). **Este lab NO usa el pipeline GitOps del M5**: el formador comanda y los alumnos aplican con `terraform apply` desde su workstation contra el proyecto GCP del curso.

---

## 0. Objetivo general

Al terminar este lab, se habrá cumplido **cada uno de los 6 objetivos del M6**:

1. **`dynamic blocks`** — refactorizar las 3 reglas de firewall del M3 en una sola parametrizada con `dynamic "allow"`, y añadir la regla nueva `allow_middleware_to_redis`.
2. **`for_each` vs `count`** — desplegar las 2 instancias Memorystore (una en `dev`, una en `prod`) con `for_each = var.environments`, justificando por qué `for_each` y no `count`.
3. **`data sources`** — descubrir la VPC (`google_compute_network`) y la red Memorystore (`google_redis_instance`) desde Terraform, sin hardcodear IDs ni IPs.
4. **Refactor de state** — usar `terraform state mv` para mover la declaración de Redis desde la raíz a un módulo nuevo `modules/cache`, y dejar un bloque `moved {}` en el root para que la transición quede registrada en el repositorio.
5. **Migración zero-downtime** — ejecutar el patrón **replicar → validar → cutover → apagar** sobre la infraestructura en producción.
6. **Update seguro de provider** — bumpear el provider `google` de la rama `5.x` a `~> 6.0` con `lifecycle { create_before_destroy = true }` y ventana de mantenimiento, sin destruir el Redis recién creado.

---

## 1. Prerrequisitos

### 1.0 Cargar variables de entorno

> ⚠️ **Trampa común de PowerShell**: si `$env:TF_VAR_*` no existe, PowerShell deja el token literal y `terraform` recibe valores vacíos.

```bash
export TF_STATE_BUCKET="applocker-tf-state-<sufijo>"
export TF_VAR_project_id="$(gcloud config get-value project)"
export TF_VAR_region="us-central1"
export TF_VAR_env="dev"
export TF_VAR_suffix="<sufijo>"
```

```powershell
$env:TF_STATE_BUCKET = "applocker-tf-state-<sufijo>"
$env:TF_VAR_project_id = (gcloud config get-value project)
$env:TF_VAR_region     = "us-central1"
$env:TF_VAR_env        = "dev"
$env:TF_VAR_suffix     = "<sufijo>"
```

Verificar:

```bash
echo "$TF_STATE_BUCKET | $TF_VAR_project_id | $TF_VAR_region | $TF_VAR_env | $TF_VAR_suffix"
```

```powershell
Write-Host "$($env:TF_STATE_BUCKET) | $($env:TF_VAR_project_id) | $($env:TF_VAR_region) | $($env:TF_VAR_env) | $($env:TF_VAR_suffix)"
```

### 1.1 Resto de prerrequisitos

- **Infraestructura del M3 + M4 desplegada y verificada**:
  - M1: bucket de state remoto `gs://applocker-tf-state-<sufijo>` en `us-central1`, con prefijos por sub-stack (`modules/network`, `modules/compute`, `modules/cloudsql`, `envs/dev/root`).
  - M3: VPC 3-tier (`applocker-vpc-${env}-${sufijo}`) con subnets `app`, `middleware`, `lock`, `data`; Cloud Router + NAT; firewall segmentado por tags (`app`, `middleware`, `lock`); 3 reglas de firewall (`app_to_mw`, `mw_to_lock`, `lock_to_data`).
  - M4: módulo `iam` con la SA `sa-app-${env}-${sufijo}` y 4 bindings (`logging.logWriter`, `monitoring.metricWriter`, `cloudsql.client`, `secretmanager.secretAccessor`); secreto `applocker-db-password` importado; user `applocker_app` en Cloud SQL; labels comunes (`app=applocker`, `env`, `team=platform-mm`, `managed-by=terraform`, `cost-center=cc-1042`).
- Repositorio del curso con permisos de push.
- `gcloud`, `terraform >= 1.5`, `gh` CLI autenticados.
- APIs habilitadas:
  ```bash
  gcloud services enable redis.googleapis.com
  ```

  ```powershell
  gcloud services enable redis.googleapis.com
  ```

> **Nota**: *"Hoy la infra es código y está bajo control de cambios. ¿Qué pasa cuando la realidad cambia más rápido que el código? Eso es lo que vamos a aprender hoy."*

---

## 2. Punto de partida (heredado de M3 + M4)

```
infra/
├── envs/dev/
│   ├── backend.tf
│   ├── locals.tf          (common_labels)
│   ├── main.tf            (módulo iam)
│   ├── secrets.tf         (db_password + sql_user)
│   ├── variables.tf
│   ├── outputs.tf         (app_service_account_email/member, common_labels)
│   └── terraform.tfvars
└── modules/
    ├── network/           (VPC + subnets + NAT + 3 reglas firewall)
    ├── compute/           (MIG app + health check + snapshot policy)
    ├── cloudsql/          (PostgreSQL privado con HA + PITR)
    └── iam/               (SA app + 4 bindings)
```

**El problema del día**: el equipo de locker-mgmt reporta latencia alta en los picos de apertura de cerraduras. El equipo de plataforma decide **intercalar un tier de cache** (Memorystore Redis) entre Middleware y Locker Management para absorber lecturas repetidas.

**El reto**: hacerlo **sin que AppLocker deje de responder ni un solo segundo**.

> **Diferencia con el `lab-6.md` original**: este `lab-6-alt.md` **no usa el pipeline GitOps del M5**. Todo se aplica directamente con `terraform apply` desde la workstation del alumno, en una rama `feature/m6-cache-tier`, contra el entorno `dev` del proyecto GCP del curso. Esto simplifica el lab y lo centra en los 6 objetivos del M6.

---

## 3. Recursos necesarios

- 2 instancias Memorystore Redis (1 BASIC en `dev`, 1 STANDARD_HA en `prod`).
- 1 módulo `cache` reutilizable.
- 4 reglas de firewall (las 3 del M3 refactorizadas + 1 nueva `allow_middleware_to_redis`).
- 2 secretos en Secret Manager con el endpoint de Redis (uno por entorno).
- 2 IAM bindings para que la SA `app` pueda leer los secretos del endpoint.
- Tiempo total estimado: ~1h 20min.

---

## 4. Estructura esperada al final del lab

```
infra/
├── envs/dev/                  (root con state en prefix "envs/dev/root")
│   ├── backend.tf
│   ├── locals.tf
│   ├── main.tf                (module "iam" + module "cache" + moved {})
│   ├── secrets.tf             (db_password + sql_user + redis_endpoint)
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── modules/
    ├── network/               (M3 — refactorizado con dynamic blocks en §7)
    ├── compute/               (M3)
    ├── cloudsql/              (M3)
    ├── iam/                   (M4)
    └── cache/                 (NUEVO en M6 — módulo Memorystore)
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## 5. Parte 1 — Declarar Redis en el root y aplicar el primer `terraform apply` (~10 min)

> **Por qué este primer paso es "declarar en el root" y NO "crear el módulo `cache`"**: el módulo es **el resultado del refactor de la Parte 4**. Empezamos declarando el `google_redis_instance` directamente en `infra/envs/dev/main.tf` para que el primer `plan` sea trivial, y luego lo movemos a `modules/cache` con `terraform state mv` + bloque `moved {}`. Así se ve el refactor en dos pasos claros.

### 5.1 Crear la rama de trabajo

```bash
cd <raíz del repo>
git checkout -b feature/m6-cache-tier
```

```powershell
Set-Location <raíz del repo>
git checkout -b feature/m6-cache-tier
```

### 5.2 Añadir el bloque de Redis en `infra/envs/dev/main.tf`

Editar `infra/envs/dev/main.tf` y, **debajo del bloque `module "iam"` que ya existe del M4**, añadir:

```hcl
# --- M6: Memorystore Redis (tier de cache) ---
# Versión 1: declarado directamente en el root. En la Parte 4 lo
# moveremos a modules/cache/ usando `terraform state mv` + bloque moved.

resource "google_redis_instance" "applocker_cache" {
  for_each = {
    dev  = { tier = "BASIC",       memory_gb = 1, region = "us-central1" }
    prod = { tier = "STANDARD_HA", memory_gb = 5, region = "us-central1" }
  }

  project        = var.project_id
  name           = "applocker-cache-${each.key}-${var.sufijo}"
  tier           = each.value.tier
  memory_size_gb = each.value.memory_gb
  region         = each.value.region
  redis_version  = "REDIS_7_2"

  authorized_network = data.terraform_remote_state.network.outputs.vpc_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  labels = merge(local.common_labels, {
    tier = "cache"
    env  = each.key
  })

  lifecycle {
    create_before_destroy = true
  }
}
```

> **Objetivo 2 — `for_each` vs `count`**: usamos `for_each` porque las 2 instancias tienen **atributos diferentes** (tier, memory_gb). Si fueran idénticas y solo cambiara el número de réplicas, `count` sería correcto. Mezclar atributos distintos en `count` requiere índices mágicos; `for_each` los declara por clave (`dev`, `prod`).

### 5.3 Añadir el `data "terraform_remote_state" "network"` en el root

> El root del M4 (`infra/envs/dev/`) **aún no lee el remote state de `network/`**: eso lo hacen los sub-stacks. Como ahora el root necesita la `vpc_self_link` para autorizar Redis, hay que añadir el `data source` en el root.

Editar `infra/envs/dev/main.tf` y añadir al inicio (junto a la cabecera, **fuera de cualquier `module { ... }`**):

```hcl
# --- Remote state del sub-stack network/ (necesario para authorized_network) ---

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "applocker-tf-state-${var.sufijo}"
    prefix = "modules/network"
  }
}
```

> **Trampa**: si este `data` está declarado **dentro** de un `module { ... }`, Terraform lo expone como `module.<x>.data.terraform_remote_state.network` y el código siguiente no lo encuentra. Va siempre a nivel de root.

### 5.4 Validar y planificar

```bash
cd infra/envs/dev
terraform init -upgrade
terraform plan
```

```powershell
Set-Location infra\envs\dev
terraform init -upgrade
terraform plan
```

El plan debe proponer **`+ create`** para **2** instancias Redis (`applocker-cache-dev-<sufijo>` y `applocker-cache-prod-<sufijo>`), **sin destruir nada**.

> **Objetivo 3 — data sources**: el atributo `authorized_network` se resuelve vía `data.terraform_remote_state.network.outputs.vpc_self_link`. Si quisiéramos **más** datos del recurso real (p. ej. el host después del apply), usaríamos `data "google_compute_network" "applocker"` con `name` en vez del self_link — eso lo veremos en la Parte 3.

### 5.5 Aplicar

```bash
cd infra/envs/dev
terraform apply
```

```powershell
Set-Location infra\envs\dev
terraform apply
```

Verificar que las 2 instancias están activas:

```bash
gcloud redis instances list \
  --project=${TF_VAR_project_id} \
  --region=${TF_VAR_region} \
  --format="table(name,tier,memorySizeGb,state)"
```

```powershell
gcloud redis instances list `
  --project=$env:TF_VAR_project_id `
  --region=$env:TF_VAR_region `
  --format="table(name,tier,memorySizeGb,state)"
```

Debe devolver 2 filas: `applocker-cache-dev-<sufijo>` (BASIC, 1GB) y `applocker-cache-prod-<sufijo>` (STANDARD_HA, 5GB).

---

## 6. Parte 2 — Consumir el endpoint con `data sources` (~10 min)

> **Objetivo 3**: demostrar que podemos **leer** el endpoint de Redis desde Terraform sin hardcodear IPs. Los `data sources` se refrescan en cada plan, así que detectan drift.

### 6.1 Añadir el `data source` en el root

Editar `infra/envs/dev/main.tf` y añadir al final (después de los recursos):

```hcl
# --- Data source para descubrir el endpoint de Redis ---
# Cada vez que se ejecuta `terraform plan`, este data source consulta
# la API de Memorystore y refresca host/port. Si alguien cambia el
# tier o la región fuera de Terraform, el siguiente plan lo detecta.

data "google_redis_instance" "applocker_cache" {
  for_each = google_redis_instance.applocker_cache

  name   = each.value.name
  region = each.value.region
}

locals {
  redis_endpoint = {
    for k, r in data.google_redis_instance.applocker_cache : k => "${r.host}:${r.port}"
  }
}
```

> **Nota**: *"Los `data sources` no crean nada. Son lecturas. Por eso el plan no muestra `+ create` para ellos. Pero Terraform los evalúa en cada plan, lo que nos permite validar que los datos son consistentes con el state."*

### 6.2 Exponer el endpoint como output

En `infra/envs/dev/outputs.tf`, añadir:

```hcl
output "redis_endpoint" {
  value       = local.redis_endpoint
  description = "Mapa host:port de Redis por entorno (dev, prod)."
  sensitive   = false   # no contiene secretos
}

output "redis_hosts" {
  value = {
    for k, r in data.google_redis_instance.applocker_cache : k => r.host
  }
  description = "Hosts de Redis por entorno."
}

output "redis_ports" {
  value = {
    for k, r in data.google_redis_instance.applocker_cache : k => r.port
  }
  description = "Puertos de Redis por entorno."
}
```

### 6.3 Validar el discovery

```bash
cd infra/envs/dev
terraform plan
```

El plan **no debe proponer cambios** (los data sources son lecturas y los outputs son nuevos pero no tocan infraestructura).

```bash
terraform console
> data.google_redis_instance.applocker_cache["prod"].host
> data.google_redis_instance.applocker_cache["prod"].port
> local.redis_endpoint
```

> ⚠️ **Importante**: este paso requiere que las instancias ya existan (Parte 5 aplicada). Si no, el `data source` devuelve error `404`.

---

## 7. Parte 3 — Refactorizar firewall con `dynamic blocks` (~15 min)

> **Objetivo 1**: sustituir las 3 reglas hardcodeadas del M3 por una sola parametrizada con `for_each` + `dynamic "allow"`, y añadir la regla `allow_middleware_to_redis`.

### 7.1 Estado actual en `infra/modules/network/main.tf`

El M3 tiene 3 reglas hardcodeadas:

```hcl
resource "google_compute_firewall" "app_to_mw" { ... }
resource "google_compute_firewall" "mw_to_lock" { ... }
resource "google_compute_firewall" "lock_to_data" { ... }
```

Cada una con su propio bloque `allow { protocol = "tcp" ports = [...] }` literal.

### 7.2 Reemplazar por una versión parametrizada

En `infra/modules/network/main.tf`, **borrar los 3 `google_compute_firewall` antiguos** y sustituirlos por:

```hcl
locals {
  firewall_rules = {
    allow_app_to_mw = {
      description = "App tier to Middleware (8080)"
      source_tags = ["app"]
      target_tags = ["middleware"]
      ports       = ["8080"]
    }
    allow_mw_to_lock = {
      description = "Middleware to Locker Mgmt (9000)"
      source_tags = ["middleware"]
      target_tags = ["lock"]
      ports       = ["9000"]
    }
    allow_lock_to_data = {
      description = "Locker Mgmt to Cloud SQL (5432)"
      source_tags = ["lock"]
      target_tags = ["data"]
      ports       = ["5432"]
    }
    # NUEVO en M6: regla hacia Redis
    allow_middleware_to_redis = {
      description = "Middleware to Redis cache (6379)"
      source_tags = ["middleware"]
      target_tags = ["data"]   # las instancias Redis están en la subnet data
      ports       = ["6379"]
    }
  }
}

resource "google_compute_firewall" "applocker" {
  for_each = local.firewall_rules

  project     = var.project_id
  name        = "applocker-${replace(each.key, "_", "-")}-${var.env}-${var.sufijo}"
  network     = google_compute_network.applocker.id
  description = each.value.description
  direction   = "INGRESS"

  source_tags = each.value.source_tags
  target_tags = each.value.target_tags

  dynamic "allow" {
    for_each = each.value.ports
    content {
      protocol = "tcp"
      ports    = [allow.value]
    }
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
```

### 7.3 Validar el refactor

```bash
cd infra/modules/network
terraform plan
```


El plan debe mostrar:

- **`- destroy`** para las 3 reglas antiguas (`app_to_mw`, `mw_to_lock`, `lock_to_data`).
- **`+ create`** para las **4 reglas nuevas** (las 3 anteriores + `allow_middleware_to_redis`).

> **Nota**: *"Esto es `ForceNew` masivo. Si lo aplicamos tal cual, GCP puede tardar varios minutos. Por eso lo probamos primero en `dev` y por eso el M6 lo simplifica (sin pipeline GitOps): el alumno ve el coste del refactor de firewall directamente."*

### 7.4 Aplicar el firewall

```bash
cd infra/modules/network
terraform apply
```

Verificar:

```bash
gcloud compute firewall-rules list \
  --project=${TF_VAR_project_id} \
  --filter="name~'applocker-allow_'" \
  --format="table(name,direction,sourceTags,targetTags,allowed)"
```

```powershell
gcloud compute firewall-rules list `
  --project=$env:TF_VAR_project_id `
  --filter="name~'applocker-allow-'" `
  --format="table(name,direction,sourceTags,targetTags,allowed)"
```

Debe devolver 4 reglas: `allow_app_to_mw`, `allow_mw_to_lock`, `allow_lock_to_data`, `allow_middleware_to_redis`.

---

## 8. Parte 4 — Refactor de state: `terraform state mv` + bloques `moved {}` (~15 min)

> **Objetivo 4**: sacar la declaración de Redis del root y moverla a un módulo `modules/cache/` reutilizable, **sin destruir la instancia**. Dos técnicas combinadas: `terraform state mv` para mover el state, y un bloque `moved {}` para que el refactor quede registrado en el repositorio.

### 8.1 Crear el módulo `cache`

```bash
mkdir -p infra/modules/cache
```

```powershell
New-Item -ItemType Directory -Force -Path "infra\modules\cache" | Out-Null
```

#### 8.1.1 `infra/modules/cache/main.tf`

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

resource "google_redis_instance" "applocker_cache" {
  for_each = var.environments

  project        = var.project_id
  name           = "applocker-cache-${each.key}-${var.sufijo}"
  tier           = each.value.tier
  memory_size_gb = each.value.memory_gb
  region         = each.value.region
  redis_version  = "REDIS_7_2"

  authorized_network = var.network_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  labels = var.labels

  lifecycle {
    create_before_destroy = true
  }
}
```

#### 8.1.2 `infra/modules/cache/variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "sufijo" {
  type        = string
  description = "Sufijo único del alumno (mismo que en el resto del curso)."
}

variable "network_self_link" {
  type        = string
  description = "Self-link de la VPC donde se conectará Redis."
}

variable "environments" {
  type = map(object({
    tier      = string
    memory_gb = number
    region    = string
  }))
  description = "Mapa de entornos con su tier, memoria y región."

  validation {
    condition     = alltrue([for e in var.environments : contains(["BASIC", "STANDARD_HA"], e.tier)])
    error_message = "El tier debe ser BASIC o STANDARD_HA."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels comunes a aplicar a las instancias."
  default     = {}
}
```

#### 8.1.3 `infra/modules/cache/outputs.tf`

```hcl
output "hosts" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => r.host
  }
  description = "Mapa de hosts de Redis por entorno."
}

output "ports" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => r.port
  }
  description = "Mapa de puertos de Redis por entorno."
}

output "instance_addresses" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => {
      host   = r.host
      port   = r.port
      region = r.region
    }
  }
  description = "Mapa completo de direcciones (host:port y región) por entorno."
}

```

### 8.2 Instanciar el módulo desde el root

Editar `infra/envs/dev/main.tf`:

- **Borrar** el bloque `resource "google_redis_instance" "applocker_cache"` (de la Parte 5) **y** el bloque `data "google_redis_instance" "applocker_cache"` (de la Parte 6).
- **Añadir** el módulo nuevo:

```hcl
module "cache" {
  source = "../../modules/cache"

  project_id        = var.project_id
  sufijo            = var.sufijo
  network_self_link = data.terraform_remote_state.network.outputs.vpc_self_link
  labels            = local.common_labels

  environments = {
    dev  = { tier = "BASIC",       memory_gb = 1, region = "us-central1" }
    prod = { tier = "STANDARD_HA", memory_gb = 5, region = "us-central1" }
  }
}
```

Y volver a declarar el `data source`, ahora leyendo del módulo:

```hcl
data "google_redis_instance" "applocker_cache" {
  for_each = module.cache.instance_addresses

  name   = "applocker-cache-${each.key}-${var.sufijo}"
  region = each.value.region
}
```

### 8.3 Dejar el bloque `moved {}` registrado en el repositorio

En `infra/envs/dev/main.tf`, añadir el bloque `moved {}` **justo antes** de la declaración `module "cache"`:

```hcl
# --- Refactor de M6 Parte 4: la declaración de Redis se movió del root
#     al módulo modules/cache. Este bloque `moved` re-escribe el state
#     automáticamente al planificar, sin tocar la infraestructura.
moved {
  from = google_redis_instance.applocker_cache["dev"]
  to   = module.cache.google_redis_instance.applocker_cache["dev"]
}

moved {
  from = google_redis_instance.applocker_cache["prod"]
  to   = module.cache.google_redis_instance.applocker_cache["prod"]
}
```

> **Por qué `moved {}` y no solo `terraform state mv`**: el bloque `moved {}` queda en el repositorio, en el PR y en el historial de git. Si alguien revierte el commit, Terraform sabe deshacer el refactor. `state mv` se pierde en cuanto muere el proceso que lo ejecutó.

### 8.4 Validar el refactor

```bash
cd infra/envs/dev
terraform init -upgrade
terraform plan
```

El plan debe:

- Reconocer los `moved {}` y **no proponer destruir** las instancias Redis.
- Mostrar **`+ create`** para los nuevos recursos bajo `module.cache.*` y **`- destroy`** para los del root (los `moved {}` canjean el uno por el otro).
- Para los recursos que ya están en el módulo vía `moved`, el plan debe mostrar **`moved` operation** (sin `+` ni `-`).

> **Si el plan muestra `- destroy` para las instancias Redis**: el bloque `moved {}` está mal declarado (falta una clave o el path no coincide). **NO aplicar**: revisa la sintaxis y vuelve a planificar.

### 8.5 Aplicar el refactor

```bash
cd infra/envs/dev
terraform apply
```

### 8.6 Verificar que las instancias siguen vivas

```bash
gcloud redis instances list \
  --project=${TF_VAR_project_id} \
  --region=${TF_VAR_region} \
  --format="table(name,tier,state)"
```

```powershell
gcloud redis instances list `
  --project=$env:TF_VAR_project_id `
  --region=$env:TF_VAR_region `
  --format="table(name,tier,state)"
```

Debe devolver las 2 instancias con `state: READY` (sin recreaciones).

### 8.7 Limpiar el state (opcional, si quedaron direcciones huérfanas)

Si `terraform state list | grep redis` (o `terraform state list | Select-String redis`) muestra direcciones antiguas tipo `google_redis_instance.applocker_cache[...]` además de las nuevas `module.cache.google_redis_instance.applocker_cache[...]`, ejecutar:

```bash
cd infra/envs/dev
terraform state mv \
  google_redis_instance.applocker_cache["dev"] \
  module.cache.google_redis_instance.applocker_cache["dev"]

terraform state mv \
  google_redis_instance.applocker_cache["prod"] \
  module.cache.google_redis_instance.applocker_cache["prod"]
```

```powershell
Set-Location infra\envs\dev
terraform state mv `
  google_redis_instance.applocker_cache["dev"] `
  module.cache.google_redis_instance.applocker_cache["dev"]

terraform state mv `
  google_redis_instance.applocker_cache["prod"] `
  module.cache.google_redis_instance.applocker_cache["prod"]
```



> **Si los bloques `moved {}` ya cubrieron el refactor (§8.3), este paso es innecesario**. Queda documentado por si el alumno necesita forzarlo manualmente en algún caso (p. ej. un merge conflict en el state).

### 8.8 Commit del refactor

```bash
git add infra/modules/cache infra/envs/dev/main.tf infra/envs/dev/outputs.tf
git commit -m "feat(m6): extract Memorystore to modules/cache with state mv + moved {}"
```

```powershell
git add infra\modules\cache, infra\envs\dev\main.tf, infra\envs\dev\outputs.tf
git commit -m "feat(m6): extract Memorystore to modules/cache with state mv + moved {}"
```

---

## 9. Parte 5 — Aplicar el patrón zero-downtime (~15 min)

> **Objetivo 5**: ejecutar **replicar → validar → cutover → apagar** sobre el Redis que ya está en producción (creado en la Parte 5, refactorizado en la Parte 8).

### 9.1 Replicar

> Las 2 instancias Redis **ya están desplegadas** desde la Parte 5/8 y la regla `allow_middleware_to_redis` **ya está aplicada** desde la Parte 7. El paso "replicar" es, en este lab, **verificar** que ambos están listos.

```bash
gcloud redis instances list \
  --project=${TF_VAR_project_id} \
  --region=${TF_VAR_region} \
  --format="table(name,tier,state,connectMode)"

gcloud compute firewall-rules list \
  --project=${TF_VAR_project_id} \
  --filter="name~'applocker-allow_middleware_to_redis'" \
  --format="table(name,sourceRanges,allowed)"
```

```powershell
gcloud redis instances list `
  --project=$env:TF_VAR_project_id `
  --region=$env:TF_VAR_region `
  --format="table(name,tier,state,connectMode)"

gcloud compute firewall-rules list `
  --project=$env:TF_VAR_project_id `
  --filter="name~'applocker-allow_middleware_to_redis'" `
  --format="table(name,sourceRanges,allowed)"
```

Debe devolver: 2 instancias en `READY` con `connectMode: PRIVATE_SERVICE_ACCESS` y 1 regla `applocker-allow_middleware_to_redis-dev-<sufijo>` con `tcp:6379`.

### 9.2 Validar

Ejecutar un smoke test desde Cloud Shell (o desde una VM bastion con `gcloud compute ssh`):

```bash
# Obtener el host y puerto del Redis de prod
REDIS_HOST=$(terraform output -json | jq -r '.redis_hosts.value.prod')
REDIS_PORT=$(terraform output -json | jq -r '.redis_ports.value.prod')

# Probar conexión con un contenedor efímero de redis-cli
docker run --rm redis:7 redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} PING
```

```powershell
# Obtener el host y puerto del Redis de prod
$output = terraform output -json | ConvertFrom-Json
$REDIS_HOST = $output.redis_hosts.value.prod
$REDIS_PORT = $output.redis_ports.value.prod

# Probar conexión
docker run --rm redis:7 redis-cli -h $REDIS_HOST -p $REDIS_PORT PING
```

Resultado esperado: `PONG`.

> Si no se puede usar Docker, instalar `redis-cli` localmente o usar `gcloud compute ssh` contra una VM del MIG `app` del M3.

### 9.3 Cutover

Para que el middleware pueda consumir el endpoint de Redis, lo publicamos en Secret Manager (mismo patrón del M4 con el `db_password`).

#### 9.3.1 Añadir el secreto en `infra/envs/dev/secrets.tf`

Editar `infra/envs/dev/secrets.tf` y, al final, añadir:

```hcl
# --- M6: endpoint de Redis en Secret Manager ---
# Patrón equivalente al db_password del M4: el secreto se declara
# en Terraform y el middleware lo lee vía metadata server.

resource "google_secret_manager_secret" "redis_endpoint" {
  for_each = toset(["dev", "prod"])

  secret_id = "applocker-redis-endpoint-${var.env}-${each.key}-${var.sufijo}"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = merge(local.common_labels, {
    tier = "middleware"
    env  = each.key
  })
}

resource "google_secret_manager_secret_version" "redis_endpoint" {
  for_each = google_secret_manager_secret.redis_endpoint

  secret      = each.value.id
  secret_data = "redis://${module.cache.hosts[each.key]}:${module.cache.ports[each.key]}"
}

# --- IAM binding: la SA del tier app puede leer el secreto de Redis ---
# (en M3 solo existe el MIG app; cuando se desplieguen mw/lock se amplía)

resource "google_secret_manager_secret_iam_member" "redis_endpoint_reader_app" {
  for_each = google_secret_manager_secret.redis_endpoint

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = module.iam.app_service_account_member
}
```

#### 9.3.2 Aplicar

```bash
cd infra/envs/dev
terraform apply
```

Verificar:

```bash
gcloud secrets list \
  --project=${TF_VAR_project_id} \
  --filter="name~'applocker-redis-endpoint'" \
  --format="table(name,labels)"

gcloud secrets versions access latest \
  --secret="applocker-redis-endpoint-${TF_VAR_env}-dev-${TF_VAR_suffix}" \
  --project=${TF_VAR_project_id}
```

```powershell
gcloud secrets list `
  --project=$env:TF_VAR_project_id `
  --filter="name~'applocker-redis-endpoint'" `
  --format="table(name,labels)"

gcloud secrets versions access latest `
  --secret="applocker-redis-endpoint-$env:TF_VAR_env-dev-$env:TF_VAR_suffix" `
  --project=$env:TF_VAR_project_id
```

El segundo comando debe devolver algo como `redis://10.123.45.67:6379`.

#### 9.3.3 Reiniciar el MIG para que lea el nuevo secreto

```bash
gcloud compute instance-groups managed recreate-instances \
  applocker-app-mig-${TF_VAR_env}-${TF_VAR_suffix} \
  --zone=${TF_VAR_region}-a
```

```powershell
gcloud compute instance-groups managed recreate-instances `
  applocker-app-mig-$env:TF_VAR_env-$env:TF_VAR_suffix `
  --zone=$env:TF_VAR_region-a
```

### 9.4 Apagar

> **Nota**: *"El cuarto paso del patrón es 'apagar'. En este lab, el código antiguo que iba directo a SQL para lecturas cacheables se queda intacto durante un ciclo de release. NO se borra en caliente."*

Marcar un `TODO` con fecha en el código para retirar la llamada antigua:

```hcl
# TODO(M6+1release): retirar la llamada directa a SQL para lecturas cacheables.
# Actualmente se mantiene por seguridad (rollback en caso de problema con Redis).
```

---

## 10. Parte 6 — Disaster recovery en `dev` (~10 min)

> ⚠️ El lab se ejecuta **siempre contra el entorno `dev`**, nunca contra `prod`.

### 10.1 Exportar un snapshot de la instancia `dev`

```bash
# Crear un bucket de snapshots (si no existe)
gcloud storage buckets create gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env} \
  --location=us-central1 || true

# Exportar la instancia dev
gcloud redis instances export applocker-cache-${TF_VAR_env}-${TF_VAR_suffix} \
  --gcs-location=gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/ \
  --async
```

```powershell
# Crear un bucket de snapshots (si no existe)
gcloud storage buckets create gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env `
  --location=us-central1
# Si ya existe, ignorar el error en consola

# Exportar la instancia dev
gcloud redis instances export applocker-cache-$env:TF_VAR_env-$env:TF_VAR_suffix `
  --gcs-location=gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/ `
  --async
```

> **Nota**: *"Memorystore exporta el RDB a un bucket GCS. Es un backup consistente, no un snapshot de disco. La importación es `redis-cli BGREWRITEAOF` bajo el capó."*

### 10.2 Borrar la instancia `dev` (simulando pérdida)

```bash
gcloud redis instances delete applocker-cache-${TF_VAR_env}-${TF_VAR_suffix} \
  --region=us-central1
```

```powershell
gcloud redis instances delete applocker-cache-$env:TF_VAR_env-$env:TF_VAR_suffix `
  --region=us-central1
```

### 10.3 Recrear con Terraform

```bash
cd infra/envs/dev
terraform plan
```

```powershell
Set-Location infra\envs\dev
terraform plan
```

El plan debe proponer **recrear** la instancia `dev` (gracias a que está en el state).

```bash
terraform apply
```

```powershell
terraform apply
```

Verificar que la instancia `dev` vuelve a estar activa.

### 10.4 Importar el snapshot

```bash
# Listar el snapshot exportado
gcloud storage ls gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/

# Importar (el nombre del archivo lo da el export anterior)
SNAPSHOT=$(gcloud storage ls gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/ | head -1)

gcloud redis instances import applocker-cache-${TF_VAR_env}-${TF_VAR_suffix} \
  --gcs-location=${SNAPSHOT} \
  --region=us-central1
```

```powershell
# Listar el snapshot exportado
gcloud storage ls gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/

# Importar (el nombre del archivo lo da el export anterior)
$SNAPSHOT = (gcloud storage ls gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/ | Select-Object -First 1).Trim()

gcloud redis instances import applocker-cache-$env:TF_VAR_env-$env:TF_VAR_suffix `
  --gcs-location=$SNAPSHOT `
  --region=us-central1
```

---

## 11. Parte 7 — Update seguro de provider (~5 min)

> **Objetivo 6**: bumpear el provider `google` de la rama `5.x` a `~> 6.0` con `lifecycle { create_before_destroy = true }` ya puesto en el módulo `cache` (§8.1.1) y con ventana de mantenimiento explícita.

### 11.1 Editar la versión del provider

En `infra/modules/cache/main.tf`, cambiar el bloque `required_providers`:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"   # antes era "~> 5.0"
    }
  }
}
```

Y en `infra/envs/dev/backend.tf`:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  # ...
}
```

> **Ventana de mantenimiento**: en producción real, este cambio se haría **fuera del horario de pico** y con doble aprobación. En el lab lo aplicamos directamente sobre `dev` para validar el flujo.

### 11.2 Inicializar y planificar

```bash
cd infra/envs/dev
terraform init -upgrade
terraform plan
```

El plan **no debe proponer destruir** las instancias Redis gracias al `lifecycle { create_before_destroy = true }` declarado en `modules/cache/main.tf`. Si aparecen `- destroy`, **NO aplicar**: revisar el `lifecycle` y reintentar.

### 11.3 Aplicar

```bash
cd infra/envs/dev
terraform apply
```

Verificar que las instancias siguen vivas:

```bash
gcloud redis instances list \
  --project=${TF_VAR_project_id} \
  --region=${TF_VAR_region} \
  --format="table(name,tier,state)"
```

```powershell
gcloud redis instances list `
  --project=$env:TF_VAR_project_id `
  --region=$env:TF_VAR_region `
  --format="table(name,tier,state)"
```

---

## 12. Validación final (~5 min)

### 12.1 Plan limpio desde el root

```bash
cd infra/envs/dev
terraform plan -detailed-exitcode
echo "Exit code: $?"
```

```powershell
Set-Location infra\envs\dev
terraform plan -detailed-exitcode
Write-Host "Exit code: $LASTEXITCODE"
```

Debe devolver: `Exit code: 0` (sin drift).

### 12.2 Plan limpio desde cada sub-stack

```bash
cd infra/modules/network && terraform plan -detailed-exitcode && echo "network: $?"
cd ../compute && terraform plan -detailed-exitcode && echo "compute: $?"
cd ../cloudsql && terraform plan -detailed-exitcode && echo "cloudsql: $?"
cd ../iam && terraform plan -detailed-exitcode && echo "iam: $?"
cd ../../cache && terraform plan -detailed-exitcode && echo "cache: $?"
```

```powershell
Set-Location infra\modules\network; terraform plan -detailed-exitcode; Write-Host "network: $LASTEXITCODE"
Set-Location ..\compute; terraform plan -detailed-exitcode; Write-Host "compute: $LASTEXITCODE"
Set-Location ..\cloudsql; terraform plan -detailed-exitcode; Write-Host "cloudsql: $LASTEXITCODE"
Set-Location ..\iam; terraform plan -detailed-exitcode; Write-Host "iam: $LASTEXITCODE"
Set-Location ..\..\cache; terraform plan -detailed-exitcode; Write-Host "cache: $LASTEXITCODE"
```

Todos deben devolver `Exit code: 0`.

### 12.3 Verificar que no se ha destruido nada de M3-M4

```bash
# M3: VPC, subnets, MIG
gcloud compute networks list --project=${TF_VAR_project_id} --filter="name~'applocker-vpc'"
gcloud compute instance-groups managed list --project=${TF_VAR_project_id} --filter="name~'applocker-app-mig'"

# M4: SA y secretos
gcloud iam service-accounts list --project=${TF_VAR_project_id} --filter="email~'sa-app-${TF_VAR_env}-${TF_VAR_suffix}'"
gcloud secrets list --project=${TF_VAR_project_id} --filter="name~'applocker-db-password'"
```

```powershell
# M3: VPC, subnets, MIG
gcloud compute networks list --project=$env:TF_VAR_project_id --filter="name~'applocker-vpc'"
gcloud compute instance-groups managed list --project=$env:TF_VAR_project_id --filter="name~'applocker-app-mig'"

# M4: SA y secretos
gcloud iam service-accounts list --project=$env:TF_VAR_project_id --filter="email~'sa-app-$env:TF_VAR_env-$env:TF_VAR_suffix'"
gcloud secrets list --project=$env:TF_VAR_project_id --filter="name~'applocker-db-password'"
```

### 12.4 Confirmar el cutover

```bash
# El endpoint del secreto debe apuntar al Redis real
gcloud secrets versions access latest \
  --secret="applocker-redis-endpoint-${TF_VAR_env}-dev-${TF_VAR_suffix}" \
  --project=${TF_VAR_project_id}

# Hacer PING desde Cloud Shell o desde una VM del MIG
docker run --rm redis:7 redis-cli -h <HOST> -p 6379 PING
```

```powershell
gcloud secrets versions access latest `
  --secret="applocker-redis-endpoint-$env:TF_VAR_env-dev-$env:TF_VAR_suffix" `
  --project=$env:TF_VAR_project_id

docker run --rm redis:7 redis-cli -h <HOST> -p 6379 PING
```

Resultado esperado: `PONG`.

---

## 13. Limpieza del lab

```bash
# Si se creó un bucket de snapshots en §10.1, vaciarlo y borrarlo
gcloud storage rm -r gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/
gcloud storage buckets delete gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/

# Mergear la rama de feature a main (sin pipeline GitOps en este lab)
git checkout main
git merge feature/m6-cache-tier
git branch -d feature/m6-cache-tier
```

```powershell
# Si se creó un bucket de snapshots en §10.1, vaciarlo y borrarlo
gcloud storage rm -r gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/
gcloud storage buckets delete gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/

# Mergear la rama
git checkout main
git merge feature/m6-cache-tier
git branch -d feature/m6-cache-tier
```

Commit final:

```bash
git add .
git commit -m "feat(m6): complete zero-downtime migration with Memorystore cache"
git push origin main
```

```powershell
git add .
git commit -m "feat(m6): complete zero-downtime migration with Memorystore cache"
git push origin main
```

---

## 14. Recursos creados durante el lab (resumen)

| Recurso | Ubicación | Propósito |
|---|---|---|
| Módulo `cache` | `infra/modules/cache/` | Memorystore reutilizable con `for_each` |
| 2 instancias Redis | `applocker-cache-{dev,prod}-<sufijo>` | Cache tier |
| 4 reglas de firewall | Refactorizadas con `dynamic blocks` | + nueva regla `allow_middleware_to_redis` |
| 2 secretos | `applocker-redis-endpoint-{env}-{dev,prod}-<sufijo>` | Endpoint Redis en Secret Manager |
| 2 bindings IAM | `roles/secretmanager.secretAccessor` | SA `app` puede leer el endpoint |

---

## 15. Validación final (gate del formador)

### Cobertura de los 6 objetivos del M6

- [ ] **(Obj 1) `dynamic blocks`** — Las 4 reglas de firewall están definidas en una sola `resource` con `dynamic "allow"` y el plan muestra las 3 reglas antiguas como `- destroy` y las 4 nuevas como `+ create`.
- [ ] **(Obj 2) `for_each` vs `count`** — Las 2 instancias Redis están creadas con `for_each = var.environments` (no `count`).
- [ ] **(Obj 3) `data sources`** — El output `redis_endpoint` se resuelve vía `data "google_redis_instance"` (verificado en `terraform console`).
- [ ] **(Obj 4) Refactor de state** — El bloque `moved {}` está en `infra/envs/dev/main.tf` y `terraform plan` no muestra drift tras aplicar el refactor.
- [ ] **(Obj 5) Zero-downtime** — El lab recorrió los 4 pasos del patrón (replicar, validar, cutover, apagar) sin recrear la instancia `prod`.
- [ ] **(Obj 6) Update de provider** — El provider está en `~> 6.0` y el Redis sigue activo tras el upgrade.

### Estado final de la infraestructura

- [ ] `terraform plan -detailed-exitcode` devuelve exit 0 desde el root y desde cada sub-stack.
- [ ] Las 2 instancias Redis están activas (`READY`).
- [ ] Las 4 reglas de firewall están operativas.
- [ ] El middleware puede hacer `PING` a Redis (devuelto `PONG`).
- [ ] El smoke test de DR (§10) se ejecutó en `dev` sin afectar a `prod`.
- [ ] Los recursos de M3-M4 siguen activos (VPC, MIG, SA, secretos, user de Cloud SQL).
- [ ] El commit final se ha subido a `main`.

---


---

## 17. Referencias oficiales

- Dynamic blocks: <https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks>
- `for_each` vs `count`: <https://developer.hashicorp.com/terraform/language/meta-arguments/for_each>
- Data sources: <https://developer.hashicorp.com/terraform/language/data-sources>
- `terraform state mv`: <https://developer.hashicorp.com/terraform/cli/state/move>
- `terraform import`: <https://developer.hashicorp.com/terraform/cli/import>
- Bloques `moved {}`: <https://developer.hashicorp.com/terraform/language/moved>
- `lifecycle { create_before_destroy }`: <https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle>
- Memorystore para Redis: <https://cloud.google.com/memorystore/docs/redis>
- Cloud SQL — Disaster recovery: <https://cloud.google.com/sql/docs/postgres/disaster-recovery>
- `terraform force-unlock`: <https://developer.hashicorp.com/terraform/cli/commands/force-unlock>

---

## 18. Tabla de capturas sugeridas (resumen)

| Momento | Qué capturar |
|---|---|
| Inicio del lab | Estado de la infra antes de la migración (3 tiers, sin Redis) |
| Tras Parte 5 | Plan con 2 `+ create` para Redis declarados en el root |
| Tras Parte 7 | Plan con `- destroy` y `+ create` para firewall |
| Tras Parte 8 | Plan con `moved operation` y sin recreaciones de Redis |
| Tras Parte 9 | Consola de Memorystore con 2 instancias activas + `PING` → `PONG` |
| Tras Parte 10 | Smoke test de DR: la instancia `dev` se borra y vuelve vía Terraform |
| Tras Parte 11 | Plan no-op tras el bump del provider a `~> 6.0` |
| Final del lab | `terraform plan` no-op y `terraform state list` mostrando todo el patrimonio |