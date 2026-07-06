# Lab 1 — Migración zero-downtime de AppLocker

> **Duración estimada**: 80 minutos.
> **Caso AppLocker**: intercalar un tier de cache (Memorystore Redis) entre Middleware y Locker Management, **sin que AppLocker deje de responder ni un solo segundo**. Se aplica el patrón **replicar → validar → cutover → apagar**.

---

## 0. Objetivo general

Al terminar este lab, se habrá:

- Creado un módulo `cache` con `dynamic blocks` y `for_each` para Memorystore Redis.
- Consumido el endpoint de Redis con `data sources` (no hardcodeando IPs).
- Refactorizado las reglas de firewall con `dynamic blocks` para soportar la nueva regla `allow_middleware_to_redis`.
- Aplicado la migración siguiendo el patrón **replicar → validar → cutover → apagar** vía el pipeline GitOps del M5.
- Simulado un disaster recovery en `dev` (borrar y restaurar la instancia Redis).
- Validado que el `terraform plan` final es no-op y que no se ha destruido nada de M3-M5.

---

## 1. Prerrequisitos

- Recursos de M3-M5 desplegados y verificados.
- Acceso al repositorio del curso con permisos de PR.
- `gcloud`, `terraform >= 1.5`, `gh` CLI autenticados.
- Variable `TF_VAR_project_id` apuntando al proyecto GCP del curso.
- El pipeline GitOps del M5 sigue verde (último `apply` OK).
- APIs habilitadas:
  ```bash
  gcloud services enable redis.googleapis.com
  ```

  ```powershell
  gcloud services enable redis.googleapis.com
  ```

> **Nota**: *"Hoy la infra es código y está bajo control de cambios. ¿Qué pasa cuando la realidad cambia más rápido que el código? Eso es lo que vamos a aprender hoy."*

---

## 2. Punto de partida (heredado de M3-M5)

- M1: bucket de state remoto importado y versionado en GCS.
- M2: módulo `cloud-sql` publicado en el Private Registry.
- M3: VPC 3-tier, Managed Instance Groups, Cloud SQL privado con HA, firewall por tags.
- M4: service accounts dedicadas, secretos en Secret Manager, labels de coste, backups y PITR.
- M5: pipeline GitOps con Terraform Cloud + GitHub Actions + Workload Identity Federation + OPA.

**El problema del día**: el equipo de locker-mgmt reporta latencia alta en los picos de apertura. Se decide **intercalar un tier de cache** (Memorystore Redis) entre Middleware y Locker Management.

**El reto**: hacerlo **sin que AppLocker deje de responder ni un solo segundo**.

---

## 3. Recursos necesarios

- 2 instancias Memorystore Redis (1 BASIC en `dev`, 1 STANDARD_HA en `prod`).
- 1 módulo `cache` reutilizable.
- 1 regla de firewall `allow_middleware_to_redis` (nueva, no destructiva).
- Tiempo total estimado: ~1h 20min.

---

## 4. Estructura esperada al final del lab

```
infra/
├── envs/dev/
│   ├── main.tf
│   ├── locals.tf
│   ├── secrets.tf
│   ├── network/
│   ├── compute/
│   ├── cloudsql/
│   └── modules/
│       ├── iam/         (de M4)
│       └── cache/       (NUEVO en M6)
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
```

---

## 5. Parte 1 — Crear el módulo `cache` con `dynamic blocks` y `for_each` (~15 min)

### 5.1 Crear la estructura

```bash
mkdir -p infra/envs/dev/modules/cache
cd infra/envs/dev/modules/cache
```

```powershell
New-Item -ItemType Directory -Force -Path "infra\envs\dev\modules\cache" | Out-Null
Set-Location infra\envs\dev\modules\cache
```

### 5.2 `versions.tf`

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
```

### 5.3 `variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "network_self_link" {
  type        = string
  description = "Self-link de la VPC donde se conectará Redis."
}

variable "environments" {
  type = map(object({
    tier       = string
    memory_gb  = number
    region     = string
  }))
  description = "Mapa de entornos con su tier de Redis, memoria y región."

  validation {
    condition     = alltrue([for e in var.environments : contains(["BASIC", "STANDARD_HA"], e.tier)])
    error_message = "El tier debe ser BASIC o STANDARD_HA."
  }
}
```

### 5.4 `main.tf`

```hcl
resource "google_redis_instance" "applocker_cache" {
  for_each = var.environments

  project        = var.project_id
  name           = "applocker-cache-${each.key}"
  tier           = each.value.tier
  memory_size_gb = each.value.memory_gb
  region         = each.value.region
  redis_version  = "REDIS_7_2"

  authorized_network = var.network_self_link
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  labels = {
    app     = "applocker"
    env     = each.key
    managed = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

### 5.5 `outputs.tf`

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

output "self_links" {
  value = {
    for k, r in google_redis_instance.applocker_cache : k => r.self_link
  }
  description = "Mapa de self-links por entorno."
}
```

### 5.6 Consumir el módulo desde la raíz

En `infra/envs/dev/main.tf`, añadir:

```hcl
module "cache" {
  source = "./modules/cache"

  project_id        = var.project_id
  network_self_link = module.network.vpc_self_link

  environments = {
    dev  = { tier = "BASIC",       memory_gb = 1, region = "us-central1" }
    prod = { tier = "STANDARD_HA", memory_gb = 5, region = "us-central1" }
  }
}
```

### 5.7 Validar el módulo

```bash
cd infra/envs/dev/modules/cache
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

```powershell
Set-Location infra\envs\dev\modules\cache
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

Debe devolver: `Success! The configuration is valid.`

### 5.8 Plan desde la raíz

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

El plan debe proponer **crear** dos instancias Redis (una en `dev` y otra en `prod`), **sin destruir nada**.

---

## 6. Parte 2 — Consumir el endpoint con `data sources` (~10 min)

### 6.1 Añadir data sources en el módulo del middleware

En `infra/envs/dev/compute/middleware.tf` (crear si no existe):

```hcl
data "google_redis_instance" "applocker_cache" {
  for_each = module.cache.instance_addresses

  name   = "applocker-cache-${each.key}"
  region = each.value.region
}

locals {
  redis_endpoint = {
    for k, r in data.google_redis_instance.applocker_cache : k => "${r.host}:${r.port}"
  }
}

output "redis_endpoint" {
  value     = local.redis_endpoint
  sensitive = false   # no contiene secretos
}
```

### 6.2 Plan

```bash
cd infra/envs/dev
terraform plan
```

```powershell
Set-Location infra\envs\dev
terraform plan
```

El plan debe proponer **añadir** los `data sources` y un `output`, sin crear ni destruir recursos reales.

> **Nota**: *"Los `data sources` no crean nada. Son lecturas. Por eso el plan no muestra `+ create` para ellos. Pero Terraform los evalúa en cada plan, lo que nos permite validar que los datos son consistentes con el state."*

### 6.3 Validar el discovery

```bash
terraform console
> data.google_redis_instance.applocker_cache["prod"].host
> data.google_redis_instance.applocker_cache["prod"].port
> local.redis_endpoint
```

> ⚠️ **Importante**: este paso requiere que las instancias ya existan (Parte 5 aplicada). Si todavía no, el `data source` devolverá error.

---

## 7. Parte 3 — Refactorizar firewall con `dynamic blocks` (~15 min)

### 7.1 Modificar la sección de firewall en `network/main.tf`

Reemplazar las 3 reglas hardcodeadas (`app_to_mw`, `mw_to_lock`, `lock_to_data`) por una sola regla parametrizada con `for_each` y `dynamic blocks`:

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
  name        = "applocker-${each.key}-${var.env}"
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

### 7.2 Eliminar las 3 reglas hardcodeadas anteriores

Comentar o borrar los `google_compute_firewall.app_to_mw`, `mw_to_lock`, `lock_to_data` del `main.tf`.

### 7.3 Plan

```bash
cd infra/envs/dev/network
terraform plan
```

```powershell
Set-Location infra\envs\dev\network
terraform plan
```

El plan debe mostrar:

- `- destroy` para las 3 reglas antiguas.
- `+ create` para las 4 reglas nuevas (las 3 anteriores + la de Redis).

> **Nota**: *"Esto es `ForceNew` masivo. Si lo aplicamos tal cual, GCP puede tardar varios minutos. Por eso lo aplicamos vía pipeline (M5), con gate manual, y por eso lo probamos primero en `dev`."*

### 7.4 Commit en feature branch

```bash
git checkout -b feature/m6-cache-tier
git add infra/envs/dev/modules/cache infra/envs/dev/main.tf infra/envs/dev/network/main.tf
git commit -m "feat(m6): add cache tier with Memorystore Redis and refactor firewall with dynamic blocks"
git push origin feature/m6-cache-tier
```

```powershell
git checkout -b feature/m6-cache-tier
git add infra\envs\dev\modules\cache, infra\envs\dev\main.tf, infra\envs\dev\network\main.tf
git commit -m "feat(m6): add cache tier with Memorystore Redis and refactor firewall with dynamic blocks"
git push origin feature/m6-cache-tier
```

Abrir PR → el pipeline del M5 ejecuta `terraform-plan.yml` → debe pasar todas las políticas OPA → mergear a `main` (con aprobación).

---

## 8. Parte 4 — Aplicar el patrón zero-downtime (~20 min)

### 8.1 Replicar

**El PR anterior ya está mergeado.** El workflow `terraform-apply.yml` del M5 ejecuta el `terraform apply` automáticamente (tras el gate manual del environment `production`).

Esperar a que el apply termine. Verificar en consola GCP:

- 2 instancias Memorystore Redis (`applocker-cache-dev` y `applocker-cache-prod`).
- Las nuevas 4 reglas de firewall.
- Las 3 reglas antiguas destruidas.

### 8.2 Validar

Ejecutar un smoke test desde una VM bastion (o desde Cloud Shell con `gcloud compute ssh`):

```bash
# Obtener el host de Redis de prod
REDIS_HOST=$(terraform output -json | jq -r '.cache.hosts.value.prod')
REDIS_PORT=$(terraform output -json | jq -r '.cache.ports.value.prod')

# Conectar y hacer PING
gcloud compute ssh applocker-mw-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a \
  --command="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} PING"
```

```powershell
# Obtener el host de Redis de prod
$output = terraform output -json | ConvertFrom-Json
$REDIS_HOST = $output.cache.hosts.value.prod
$REDIS_PORT = $output.cache.ports.value.prod

# Conectar y hacer PING
gcloud compute ssh applocker-mw-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a `
  --command="redis-cli -h $REDIS_HOST -p $REDIS_PORT PING"
```

Resultado esperado: `PONG`

> Si `redis-cli` no está instalado en la VM, instalarlo o usar un contenedor:
> ```bash
> gcloud compute ssh ... --command="docker run --rm redis:7 redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} PING"
> ```

### 8.3 Cutover

Ahora hay que actualizar el middleware para que apunte a Redis. Para este lab, lo simulamos actualizando el Secret Manager con el endpoint de Redis y reiniciando el MIG.

#### 8.3.1 Crear el secreto con el endpoint

```hcl
# En infra/envs/dev/secrets.tf, añadir:
resource "google_secret_manager_secret" "redis_endpoint" {
  secret_id = "applocker-redis-endpoint-${var.env}"
  project   = var.project_id

  replication {
    automatic = true
  }

  labels = merge(local.common_labels, { tier = "middleware" })
}

resource "google_secret_manager_secret_version" "redis_endpoint" {
  secret      = google_secret_manager_secret.redis_endpoint.id
  secret_data = "redis://${module.cache.hosts[var.env]}:${module.cache.ports[var.env]}"
}
```

#### 8.3.2 Permitir al middleware leer el secreto

```hcl
resource "google_secret_manager_secret_iam_member" "redis_endpoint_reader" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.redis_endpoint.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = module.iam.service_accounts["middleware"].member
}
```

#### 8.3.3 Reiniciar el MIG

Para forzar al MIG a leer el nuevo secreto, recreamos las VMs:

```bash
gcloud compute instance-groups managed recreate-instances applocker-mw-mig-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a
```

```powershell
gcloud compute instance-groups managed recreate-instances applocker-mw-mig-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a
```

#### 8.3.4 Validar el cutover

```bash
gcloud compute ssh applocker-mw-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a \
  --command="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} PING"
```

```powershell
gcloud compute ssh applocker-mw-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a `
  --command="redis-cli -h $REDIS_HOST -p $REDIS_PORT PING"
```

Resultado esperado: `PONG` (el middleware ahora habla con Redis).

### 8.4 Apagar

> **Nota**: *"El cuarto paso del patrón es 'apagar'. En este lab, el código antiguo que iba directo a SQL para lecturas cacheables se queda intacto durante un ciclo de release. NO se borra en caliente."*

Marcar un `TODO` con fecha en el código para retirar la llamada antigua:

```hcl
# TODO(M6+1release): retirar la llamada directa a SQL para lecturas cacheables.
# Actualmente se mantiene por seguridad (rollback en caso de problema con Redis).
```

---

## 9. Parte 5 — Simular disaster recovery (~10 min)

> ⚠️ El lab se ejecuta **siempre contra el entorno `dev`**, nunca contra `prod`.

### 9.1 Exportar un snapshot de la instancia `dev`

```bash
# Crear un bucket de snapshots (si no existe)
gcloud storage buckets create gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env} \
  --location=us-central1 || true

# Exportar la instancia dev
gcloud redis instances export applocker-cache-${TF_VAR_env} \
  --gcs-location=gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/ \
  --async
```

```powershell
# Crear un bucket de snapshots (si no existe)
gcloud storage buckets create gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env `
  --location=us-central1
# Si ya existe, ignorar el error en consola

# Exportar la instancia dev
gcloud redis instances export applocker-cache-$env:TF_VAR_env `
  --gcs-location=gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/ `
  --async
```

> **Nota**: *"Memorystore exporta el RDB a un bucket GCS. Es un backup consistente, no un snapshot de disco. La importación es `redis-cli BGREWRITEAOF` bajo el capó."*

### 9.2 Borrar la instancia `dev` (simulando pérdida)

```bash
gcloud redis instances delete applocker-cache-${TF_VAR_env} \
  --region=us-central1
```

```powershell
gcloud redis instances delete applocker-cache-$env:TF_VAR_env `
  --region=us-central1
```

### 9.3 Recrear con Terraform

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

### 9.4 Importar el snapshot

```bash
# Listar el snapshot exportado
gcloud storage ls gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/

# Importar (el nombre del archivo lo da el export anterior)
SNAPSHOT=$(gcloud storage ls gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/ | head -1)

gcloud redis instances import applocker-cache-${TF_VAR_env} \
  --gcs-location=${SNAPSHOT} \
  --region=us-central1
```

```powershell
# Listar el snapshot exportado
gcloud storage ls gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/

# Importar (el nombre del archivo lo da el export anterior)
$SNAPSHOT = (gcloud storage ls gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/ | Select-Object -First 1).Trim()

gcloud redis instances import applocker-cache-$env:TF_VAR_env `
  --gcs-location=$SNAPSHOT `
  --region=us-central1
```

---

## 10. Parte 6 — Validación final (~10 min)

### 10.1 Plan limpio

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

### 10.2 Verificar que no se ha destruido nada de M3-M5

```bash
terraform state list | grep -E "(cloudsql|network|compute)" | head -20
```

```powershell
terraform state list | Select-String -Pattern "(cloudsql|network|compute)" | Select-Object -First 20
```

Debe listar todos los recursos del M3-M5.

```bash
gcloud compute instances list --filter="labels.app=applocker"
gcloud sql instances list --filter="name=applocker-db-*"
```

```powershell
gcloud compute instances list --filter="labels.app=applocker"
gcloud sql instances list --filter="name=applocker-db-*"
```

### 10.3 Confirmar labels

```bash
gcloud compute instances list \
  --filter="labels.app=applocker" \
  --format="table(name,zone,labels.env,labels.managed-by,labels.tier)"
```

```powershell
gcloud compute instances list `
  --filter="labels.app=applocker" `
  --format="table(name,zone,labels.env,labels.managed-by,labels.tier)"
```

### 10.4 Confirmar el cutover

```bash
# El middleware debe poder hablar con Redis
gcloud compute ssh applocker-mw-${TF_VAR_env} \
  --zone=${TF_VAR_region}-a \
  --command="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} PING"
```

```powershell
# El middleware debe poder hablar con Redis
gcloud compute ssh applocker-mw-$env:TF_VAR_env `
  --zone=$env:TF_VAR_region-a `
  --command="redis-cli -h $REDIS_HOST -p $REDIS_PORT PING"
```

Resultado esperado: `PONG`.

---

## 11. Limpieza del lab

```bash
# Dejar prod tal cual (sigue siendo la infraestructura del curso)

# Si se creó un bucket de snapshots para el paso 9.1, vaciarlo y borrarlo
gsutil rm -r gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_ENV}/
gsutil rb gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_ENV}/

# Eliminar los PRs mergeados de feature branches si el repo lo requiere
git branch -d feature/m6-cache-tier
git push origin --delete feature/m6-cache-tier
```

```powershell
# Si se creó un bucket de snapshots para el paso 9.1, vaciarlo y borrarlo
gcloud storage rm -r gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/
gcloud storage buckets delete gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/

# Eliminar los PRs mergeados de feature branches si el repo lo requiere
git branch -d feature/m6-cache-tier
git push origin --delete feature/m6-cache-tier
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

## 12. Recursos creados durante el lab (resumen)

| Recurso | Ubicación | Propósito |
|---|---|---|
| Módulo `cache` | `infra/envs/dev/modules/cache/` | Memorystore reutilizable |
| 2 instancias Redis | `applocker-cache-dev`, `applocker-cache-prod` | Cache tier |
| 4 reglas de firewall | Refactorizadas con `dynamic blocks` | + nueva regla `allow_middleware_to_redis` |
| 1 secreto | `applocker-redis-endpoint-${env}` | Endpoint Redis en Secret Manager |
| 1 binding IAM | `roles/secretmanager.secretAccessor` | Middleware puede leer el endpoint |

---

## 13. Validación final (gate del formador)

- [ ] `terraform plan -detailed-exitcode` devuelve exit 0.
- [ ] Las 2 instancias Redis están activas.
- [ ] Las 4 reglas de firewall están operativas (3 refactorizadas + 1 nueva).
- [ ] El middleware puede hacer `PING` a Redis.
- [ ] El smoke test de DR (Parte 9) se ejecutó en `dev` sin afectar a `prod`.
- [ ] Los recursos de M3-M5 siguen activos (no se destruyó nada).
- [ ] El commit final se ha subido a `main`.

---

## 14. Referencias oficiales

- Dynamic blocks: <https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks>
- `for_each` vs `count`: <https://developer.hashicorp.com/terraform/language/meta-arguments/for_each>
- Data sources: <https://developer.hashicorp.com/terraform/language/data-sources>
- `terraform state mv`: <https://developer.hashicorp.com/terraform/cli/state/move>
- `terraform import`: <https://developer.hashicorp.com/terraform/cli/import>
- Bloques `moved {}`: <https://developer.hashicorp.com/terraform/language/modules#moved>
- Memorystore para Redis: <https://cloud.google.com/memorystore/docs/redis>
- Cloud SQL — Disaster recovery: <https://cloud.google.com/sql/docs/postgres/disaster-recovery>
- `terraform force-unlock`: <https://developer.hashicorp.com/terraform/cli/commands/force-unlock>

---


## 16. Tabla de capturas sugeridas (resumen)

| Momento | Qué capturar |
|---|---|
| Inicio del lab | Estado de la infra antes de la migración (3 tiers, sin Redis) |
| Tras Parte 1 | Plan con 2 `+ create` para Redis |
| Tras Parte 3 | Plan con `- destroy` y `+ create` para firewall |
| Tras Parte 4.1 | Consola de Memorystore con 2 instancias activas |
| Tras Parte 4.2 | `PING` → `PONG` desde una VM bastion |
| Tras Parte 4.3 | Métrica de Memorystore con conexiones activas subiendo |
| Tras Parte 5 | Smoke test de DR: la instancia `dev` se borra y vuelve a aparecer vía Terraform |
| Final del lab | `terraform plan` no-op y `terraform state list` mostrando todo el patrimonio |