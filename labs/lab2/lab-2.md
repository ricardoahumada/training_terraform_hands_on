# Lab 1 — Detectar duplicación en `main.tf` del M1

> **Mini-lab guiado** — Sirve de motivación para la sección de módulos.
> **Duración estimada**: 5 minutos.
> **Caso AppLocker**: ver con sus propios ojos por qué el bloque del bucket de state es candidato a módulo desde ya.

---

## 0. Objetivo

Identificar, sobre el código del M1, qué partes varían entre `dev` y `prod` y qué partes son constantes. Es la base conceptual para entender el "por qué" de los módulos antes de escribir el primero.

---

## 1. Prerrequisitos

- Haber completado el Módulo 1.
- Tener a mano el archivo `main.tf` del Lab 3 del M1 (workspace `dev`).

---

## 2. Pasos

### 2.1 Abrir el repositorio del M1

```bash
cd ~/labs/m1-backend
terraform workspace select dev
cat main.tf
```

```powershell
Set-Location "$HOME\labs\m1-backend"
terraform workspace select dev
Get-Content main.tf
```

### 2.2 Imaginar la versión `prod`

Escribir en un papel o en un comentario del archivo cómo se vería `main.tf` si tuviéramos que replicar la configuración para `staging` y `prod`. Hacer las siguientes preguntas en voz alta:

> 🗣️ **Preguntas**:
> - ¿Qué partes del bloque `google_storage_bucket.tf_state` variarían entre entornos?
> - ¿Y del bloque `google_storage_bucket.artifacts`?
> - ¿Qué partes son constantes y, por tanto, candidatas a extraerse a un módulo?

### 2.3 Conclusión

Aunque en este curso vamos a extraer el módulo de **Cloud SQL** (que es donde hay más lógica de negocio que encapsular), el bucket de state es ya un candidato. La pregunta no es "¿se va a reutilizar más de una vez?" sino "¿tiene lógica de negocio que deba quedar tras un contrato estable?".

> 🗣️ **Nota**: *"Si la respuesta es sí, módulo. Si es no, un simple `count` o `for_each` basta. No over-engineer."*


---

## 3. Resultado esperado

Entiende la diferencia entre "reutilizar" y "parametrizar", y puede defender cuándo extraer un módulo y cuándo no.

---

## 4. Limpieza

No hay recursos creados en este mini-lab.

---

## 5. Referencias oficiales

- Terraform Modules: <https://developer.hashicorp.com/terraform/language/modules>
- Module development best practices: <https://developer.hashicorp.com/terraform/language/modules/develop>

---


# Lab 2 — Crear el esqueleto del módulo `cloudsql` para AppLocker

> **Guion del formador** — Lab guiado paso a paso.
> **Duración estimada**: 15 minutos.
> **Caso AppLocker**: construir la base del módulo que se publicará como v1.0.0 en el Lab 4 y se consumirá desde M3.

---

## 0. Objetivo

Al terminar este lab, se habrá creado la estructura canónica de un módulo Terraform en `infra/modules/cloudsql/` con:

- `versions.tf`
- `variables.tf` con 9 entradas tipadas
- `main.tf` con un `google_sql_database_instance` placeholder
- `outputs.tf` con 5 salidas
- Validación con `terraform fmt` y `terraform validate`

---

## 1. Prerrequisitos

- Terraform `>= 1.5`.
- Haber completado el M1.
- Carpeta de trabajo para el módulo:
  ```bash
  mkdir -p ~/labs/m2-modules && cd ~/labs/m2-modules
  ```

  ```powershell
  New-Item -ItemType Directory -Force -Path "$HOME\labs\m2-modules" | Out-Null
  Set-Location "$HOME\labs\m2-modules"
  ```

---

## 2. Recursos necesarios

- Ningún recurso cloud. El módulo se valida localmente sin aplicar nada.

---

## 3. Pasos

### 3.1 Crear la estructura de directorios

```bash
mkdir -p infra/modules/cloudsql/examples/simple
cd infra/modules/cloudsql
```

```powershell
New-Item -ItemType Directory -Force -Path "infra\modules\cloudsql\examples\simple" | Out-Null
Set-Location infra\modules\cloudsql
```

### 3.2 Crear `versions.tf`

```hcl
terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}
```

> 🗣️ **Nota**: *"El `~> 1.5` significa `>= 1.5, < 2.0`. Terraform nunca va a bajar de minor y nunca va a saltar a major sin avisar. El provider `google` queda pinneado a la 5.x: cualquier release 6.x os obligará a decidir conscientemente."*

### 3.3 Crear `variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se desplegará la instancia."
}

variable "name" {
  type        = string
  description = "Nombre de la instancia Cloud SQL (sin prefijo de proyecto)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.name))
    error_message = "El nombre debe empezar por minúscula y contener solo minúsculas, dígitos o guiones."
  }
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Región GCP donde se desplegará la instancia."
}

variable "tier" {
  type        = string
  default     = "db-custom-2-7680"
  description = "Tier de máquina dedicado a Cloud SQL (ej: db-custom-2-7680, db-f1-micro)."

  validation {
    condition     = can(regex("^db-", var.tier))
    error_message = "El tier debe empezar por 'db-' (ej: db-custom-2-7680)."
  }
}

variable "availability_type" {
  type        = string
  default     = "REGIONAL"
  description = "ZONAL o REGIONAL. REGIONAL ofrece HA con failover automático (recomendado para prod)."

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type debe ser ZONAL o REGIONAL."
  }
}

variable "database_version" {
  type        = string
  default     = "POSTGRES_15"
  description = "Versión del motor de base de datos."
}

variable "disk_size" {
  type        = number
  default     = 50
  description = "Tamaño del disco en GB. Mínimo 10, máximo 65536."

  validation {
    condition     = var.disk_size >= 10 && var.disk_size <= 65536
    error_message = "disk_size debe estar entre 10 y 65536 GB."
  }
}

variable "private_network" {
  type        = string
  description = "Self-link de la red VPC donde se conectará la instancia (IP privada)."
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Si es true, protege la instancia contra borrados accidentales."
}
```

> 🗣️ **Nota**: *"Los `validation` blocks son código que se ejecuta en cada `plan`. Si alguien intenta pasar `availability_type = "REGIONAAL"`, Terraform falla antes de tocar la nube. Es la diferencia entre un módulo 'que funciona' y un módulo 'que se puede usar de forma segura'."*

### 3.4 Crear `main.tf` (placeholder)

```hcl
resource "google_sql_database_instance" "main" {
  project          = var.project_id
  name             = var.name
  region           = var.region
  database_version = var.database_version

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_size         = var.disk_size
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.private_network
      require_ssl     = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      location                       = "eu"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
      }
    }
  }
}

resource "google_sql_database" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  name     = "applocker"
}

resource "google_sql_user" "app" {
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  name     = "applocker_app"
  password = data.google_secret_manager_secret_version.db_password.secret_data
}

data "google_secret_manager_secret_version" "db_password" {
  project = var.project_id
  secret  = "applocker-db-password"
}
```

> 🗣️ **Nota**: *"El bloque `data "google_secret_manager_secret_version"` adelanta el patrón de M4 (Secret Manager). En M2 lo dejamos como referencia conceptual; en M4 lo cableamos de verdad."*

### 3.5 Crear `outputs.tf`

```hcl
output "instance_name" {
  value       = google_sql_database_instance.main.name
  description = "Nombre de la instancia Cloud SQL."
}

output "connection_name" {
  value       = google_sql_database_instance.main.connection_name
  description = "Connection name en formato project:region:name. Usar desde Cloud SQL Proxy o clientes GCP."
}

output "self_link" {
  value       = google_sql_database_instance.main.self_link
  description = "URI self-link del recurso."
}

output "private_ip" {
  value       = google_sql_database_instance.main.private_ip_address
  description = "IP privada de la instancia (solo accesible desde la VPC)."
}

output "database_name" {
  value       = google_sql_database.app.name
  description = "Nombre de la base de datos creada."
}
```

### 3.6 Crear el ejemplo módulo publicable mínimo

`examples/simple/main.tf`:

```hcl
module "cloudsql" {
  source = "../.."

  project_id       = "my-project"
  name             = "applocker-db-dev"
  private_network = "projects/my-project/global/networks/applocker-vpc"
}
```

### 3.7 Verificar el módulo

```bash
cd ~/labs/m2-modules/infra/modules/cloudsql

terraform fmt -recursive
terraform init -backend=false
terraform validate
```

```powershell
Set-Location "$HOME\labs\m2-modules\infra\modules\cloudsql"

terraform fmt -recursive
terraform init -backend=false
terraform validate
```

Salida esperada de `validate`:

```
Success! The configuration is valid.
```

> 🗣️ **Nota**: *"`validate` solo chequea sintaxis y referencias internas. No conecta con GCP. Para eso haríamos un `plan` con credenciales, que se hace en M3."*


---

## 4. Resultado esperado

Estructura completa del módulo:

```
infra/modules/cloudsql/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
└── examples/
    └── simple/
        └── main.tf
```

Validación: `Success! The configuration is valid.`

---

## 5. Limpieza

No hay recursos cloud. Si se quiere borrar el directorio local:

```bash
rm -rf ~/labs/m2-modules
```

```powershell
Remove-Item -Recurse -Force "$HOME\labs\m2-modules"
```

---

## 6. Referencias oficiales

- Module structure: <https://developer.hashicorp.com/terraform/language/modules/develop>
- Input variable validation: <https://developer.hashicorp.com/terraform/language/values#input-variable-validation>
- `terraform fmt`: <https://developer.hashicorp.com/terraform/cli/commands/fmt>
- `google_sql_database_instance`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance>

---


## 0. Objetivo

Ver cómo se consume un módulo desde el Public Registry, entendiendo que el bloque `module` es contractual (mismas variables y outputs que el `README` del módulo).

---

## 1. Prerrequisitos

- Haber completado el Lab 2.
- Tener un proyecto GCP con las APIs necesarias habilitadas.
- (Opcional) un bucket de state remoto del M1 todavía vivo.

---

## 2. Recursos necesarios

- El módulo público `terraform-google-modules/sql-db/google//modules/postgresql`.
- Una Cloud SQL instance que se creará y destruirá en este lab.

---

## 3. Pasos

### 3.1 Crear la carpeta de consumo

```bash
mkdir -p ~/labs/m2-public-registry && cd ~/labs/m2-public-registry
```

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\labs\m2-public-registry" | Out-Null
Set-Location "$HOME\labs\m2-public-registry"
```

### 3.2 Escribir `main.tf`

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
  region  = "us-central1"
}

variable "project_id" {
  type = string
}

module "cloudsql" {
  source  = "terraform-google-modules/sql-db/google//modules/postgresql"
  version = "~> 22.0"

  project_id        = var.project_id
  region            = "us-central1"
  name              = "applocker-db-dev"
  database_version  = "POSTGRES_15"
  tier              = "db-f1-micro"   # pequeño para el lab

  ip_configuration = {
    ipv4_enabled    = false
    private_network = null   # para el lab: el módulo requiere private_network o null
  }

  deletion_protection = false   # para el lab
}
```

### 3.3 Inicializar

```bash
terraform init
```

Salida esperada (recortada):

```
Initializing the backend...
Initializing modules...
Downloading terraform-google-modules/sql-db/google 22.x.x for cloudsql...
```

> 🗣️ **Nota**: *"`terraform init` descarga el módulo y lo cachea en `.terraform/`. El pin `~> 22.0` significa: cualquier 22.x.y pero nunca una 23. Si sale una 22.5 con un bugfix, Terraform la bajará automáticamente; si sale una 23.0, deberéis actualizar el `version` conscientemente."*


### 3.4 Validar y planificar

```bash
terraform validate
terraform plan
```


> 🗣️ **Nota**: *"El plan os va a pedir credenciales. Como no vamos a aplicar nada en este lab, salid con `Ctrl+C` en cuanto veáis el primer `google_sql_database_instance.cloudsql` aparecer. Lo importante es ver que el módulo se ha resuelto correctamente."*

### 3.5 Inspeccionar el módulo descargado

```bash
ls .terraform/modules/cloudsql/
cat .terraform/modules/cloudsql/README.md | head -50
```

```powershell
Get-ChildItem .terraform\modules\cloudsql\
Get-Content .terraform\modules\cloudsql\README.md -TotalCount 50
```

> 🗣️ **Nota**: *"El `README.md` del módulo es el contrato humano. La sección 'Inputs' y 'Outputs' os dice exactamente qué variables espera y qué outputs devuelve. Si no documenta, no es un módulo publicable: es un script con pretensiones."*

---

## 4. Resultado esperado

Entiende el flujo de consumo desde el Public Registry: declarar el `module`, dejar que Terraform descargue, validar y planificar.

---

## 5. Limpieza

En este lab no se llega a aplicar, así que no hay recursos que limpiar. Eliminar el directorio local:

```bash
rm -rf ~/labs/m2-public-registry
```

```powershell
Remove-Item -Recurse -Force "$HOME\labs\m2-public-registry"
```

> ⚠️ Si se llegó a aplicar, destruir con:
> ```bash
> terraform destroy
> ```
>
> ```powershell
> terraform destroy
> ```

---

## 6. Referencias oficiales

- Public Registry: <https://registry.terraform.io/>
- Módulo `terraform-google-modules/sql-db/google//modules/postgresql`: <https://github.com/terraform-google-modules/terraform-google-sql-db>
- Module sources: <https://developer.hashicorp.com/terraform/language/modules/sources>
- Version constraints: <https://developer.hashicorp.com/terraform/language/modules#version>

---


# Lab 4 — Private Module Registry con GCS

> **Guion del formador** — Cierra el Módulo 2.
> **Duración estimada**: 15 minutos.
> **Caso AppLocker**: publicar el módulo del Lab 2 como v1.0.0 en el bucket del M1 y consumirlo desde `envs/dev`.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Empaquetado el módulo `cloudsql` en un zip.
- Subido el zip al bucket de state del M1 bajo la ruta `modules/cloudsql/1.0.0/`.
- Cambiado el `source` del módulo en `envs/dev` para que apunte al GCS registry.
- Validado que el plan es idéntico al del Lab 2.

---

## 1. Prerrequisitos

- Haber completado el Lab 2 (módulo `cloudsql` con todos los archivos).
- Bucket de state del M1 (`applocker-tf-state-<sufijo>`) accesible. Reemplaza `<sufijo>` por tu personalizador (por ejemplo, el `username` que usaste en el M1: `applocker-tf-state-jgarcia`).
- `zip` instalado en la terminal (`zip --version`).

---

## 2. Recursos necesarios

- 1 zip `cloudsql.zip` que se sube al bucket.
- 1 módulo publicado en `gs://<bucket>/modules/cloudsql/1.0.0/cloudsql.zip`.

---

## 3. Pasos

### 3.1 Empaquetar el módulo

```bash
cd ~/labs/m2-modules/infra/modules/cloudsql

# Limpia cualquier rastro de un init local previo (.terraform/ deja
# subdirectorios que pueden colarse en el zip y romper la extracción
# en el consumidor).
rm -rf .terraform .terraform.lock.hcl

# Empaqueta SOLO los .tf (sin el .terraform/, sin state, sin lock).
# El `-x ".terraform/*"` solo excluye archivos DENTRO de .terraform;
# necesitamos también `-x ".terraform"` para excluir el directorio raíz.
zip -r /tmp/cloudsql.zip . \
  -x "*.tfstate*" \
  -x ".terraform/*" \
  -x ".terraform" \
  -x ".terraform.lock.hcl"
ls -lh /tmp/cloudsql.zip

# Verifica: el zip NO debe contener un directorio .terraform/ anidado.
unzip -l /tmp/cloudsql.zip | grep -i terraform || echo "OK: zip limpio, sin .terraform/"
```

```powershell
Set-Location "$HOME\labs\m2-modules\infra\modules\cloudsql"

# Limpia cualquier rastro de un init local previo.
Remove-Item -Recurse -Force .terraform, .terraform.lock.hcl -ErrorAction SilentlyContinue

# Empaqueta SOLO los .tf del directorio actual.
Get-ChildItem -File -Filter *.tf |
  Compress-Archive -DestinationPath "$env:TEMP\cloudsql.zip" -Force
Get-Item "$env:TEMP\cloudsql.zip"

# Verifica: el zip NO debe contener un directorio .terraform/ anidado.
$entries = [IO.Compression.ZipFile]::OpenRead("$env:TEMP\cloudsql.zip").Entries.FullName
if ($entries | Where-Object { $_ -like '*.terraform*' }) {
  Write-Warning "El zip contiene .terraform/. Revisa los excludes."
} else {
  Write-Host "OK: zip limpio, sin .terraform/"
}
```

> 🗣️ **Nota**: *"El zip debe contener un solo directorio raíz con los `.tf`. Aquí ese directorio es `cloudsql/` porque el `zip` lo hicimos desde dentro de `modules/`. Si zipeáis desde la raíz, Terraform se quejará."*

> 🗣️ **Nota**: el `main.tf` del paso 3.4 se genera automáticamente reusando `$TF_STATE_BUCKET` / `$env:TF_STATE_BUCKET` del shell. No hay que editar nada a mano, pero si se ha cerrado la terminal entre 3.2 y 3.4, la variable ya no está y el `main.tf` queda con un placeholder vacío (`tf_state_bucket = ""`). Solución: re-ejecutar el `export`/`$env:` del paso 3.2 antes del bloque `cat > main.tf`.

### 3.2 Subir el zip al bucket de state

```bash
export TF_STATE_BUCKET="applocker-tf-state-<sufijo>"
gcloud storage cp /tmp/cloudsql.zip \
  gs://${TF_STATE_BUCKET}/modules/cloudsql/1.0.0/cloudsql.zip
```

```powershell
$env:TF_STATE_BUCKET = "applocker-tf-state-<sufijo>"
gcloud storage cp "$env:TEMP\cloudsql.zip" `
  "gs://$env:TF_STATE_BUCKET/modules/cloudsql/1.0.0/cloudsql.zip"
```

Verificar:

```bash
gcloud storage ls gs://${TF_STATE_BUCKET}/modules/cloudsql/1.0.0/
# debe listar: cloudsql.zip
```

```powershell
gcloud storage ls "gs://$env:TF_STATE_BUCKET/modules/cloudsql/1.0.0/"
# debe listar: cloudsql.zip
```


### 3.3 Crear el tag Git (recomendado)

```bash
cd ~/labs/m2-modules
git init   # si no estaba inicializado
git add .
git commit -m "feat: initial release of cloudsql module"
git tag -a v1.0.0 -m "Initial release: Cloud SQL module for AppLocker"
git push origin v1.0.0   # solo si hay remote
```

```powershell
Set-Location "$HOME\labs\m2-modules"
git init   # si no estaba inicializado
git add .
git commit -m "feat: initial release of cloudsql module"
git tag -a v1.0.0 -m "Initial release: Cloud SQL module for AppLocker"
git push origin v1.0.0   # solo si hay remote
```

> 🗣️ **Nota**: *"El tag Git y la versión del zip deben coincidir. Esto es lo que permite a un consumidor saber que `v1.0.0` en Git y `1.0.0` en el zip son el mismo artefacto."*

### 3.4 Cambiar el `source` del módulo en `envs/dev`

```bash
mkdir -p ~/labs/m2-consume && cd ~/labs/m2-consume
```

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\labs\m2-consume" | Out-Null
Set-Location "$HOME\labs\m2-consume"
```

Genera el `main.tf` con el nombre del bucket ya relleno:

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
  region  = "us-central1"
}

variable "project_id" { type = string }
variable "vpc_self_link" { type = string }

locals {
  tf_state_bucket = "applocker-tf-state-<sufijo>"
}

module "cloudsql" {
  source = "gcs::https://www.googleapis.com/storage/v1/${local.tf_state_bucket}/modules/cloudsql/1.0.0/cloudsql.zip"

  project_id       = var.project_id
  name             = "applocker-db-dev"
  private_network  = var.vpc_self_link
}

output "cloudsql_connection_name" {
  value = module.cloudsql.connection_name
}
```

### 3.5 Inicializar

```bash
terraform init -upgrade
```

> 🗣️ **Nota**: *"`-upgrade` fuerza a Terraform a volver a descargar el módulo. Sin él, si ya teníais el módulo cacheado del Lab 3, no veríais la descarga desde GCS."*

> 🗣️ **Errores típicos**:
> - `Error: Invalid registry module source address — a module registry source address must have either three or four slash-separated components` → se ha puesto `version = "1.0.0"` junto con un source `gcs::https://...`. Terraform interpreta que el source es una dirección de registry (formato `namespace/name/provider`) y no puede parsearlo. **Solución**: con sources `gcs::`, `s3::`, `http::`, etc. NO se usa `version`. La versión va en el path (`/1.0.0/`).
> - `Error: Failed to download module — InvalidBucketName: The specified bucket is not valid. Invalid bucket name: '$env:TF_STATE_BUCKET'` (PowerShell) o `Invalid bucket name: '${TF_STATE_BUCKET}'` (bash) → la variable del shell no se ha expandido en el `main.tf` y ha quedado como literal. En PowerShell hay que usar el patrón placeholder + `-replace` (ver paso 3.4). En bash, comprobar que el bloque `cat > main.tf <<EOF` se ejecutó sin errores.
> - `Error: Failed to download module` / `HTTP 404` → el nombre del bucket en el `source` no coincide con el bucket real al que se subió el zip en el paso 3.2 (suele pasar si el alumno cerró la terminal entre 3.2 y 3.4 y `$TF_STATE_BUCKET` / `$env:TF_STATE_BUCKET` están vacíos).


### 3.6 Validar la configuración consumidora

```bash
terraform validate
```

```powershell
terraform validate
```


Salida esperada de `validate`:

```
Success! The configuration is valid.
```

> 🗣️ **Nota**: *"Este lab NO hace `terraform plan`. Hacer un plan aquí exigiría credenciales GCP reales (cuenta de servicio autenticada, proyecto activo y una VPC existente para `vpc_self_link`) — recursos fuera del alcance de M2. Lo que demostramos en este lab es que el consumidor **resuelve y descarga** el módulo desde el GCS registry privado: con `validate` confirmamos que la sintaxis es correcta y el módulo está bien enlazado. El plan real se hace en M3, donde ya hay VPC provisionada."*


Verificación adicional de que el módulo se ha resuelto correctamente:

```bash
ls .terraform/modules/cloudsql/
# Debe listar los .tf del módulo: main.tf, variables.tf, outputs.tf, versions.tf
```

```powershell
Get-ChildItem .terraform\modules\cloudsql\
# Debe listar los .tf del módulo: main.tf, variables.tf, outputs.tf, versions.tf
```

> 🗣️ **Errores típicos**:
> - `Error: No value for required variable: var.vpc_self_link` (o `var.project_id`) → el alumno ha intentado hacer `terraform plan` en vez de quedarse en `terraform validate`. El plan requiere valores reales que no existen en este lab.
> - `Error: Failed to read module` → el zip descargado está vacío o corrupto. Volver al paso 3.1, limpiar `.terraform/` del módulo, reempaquetar y re-subir al bucket.

---

## 4. Resultado esperado

- Zip `cloudsql.zip` en `gs://<bucket>/modules/cloudsql/1.0.0/`.
- Tag Git `v1.0.0` en el repo del módulo.
- Módulo consumido desde GCS con éxito.

---

## 5. Limpieza

En este lab **no se aplica nada**, así que no hay recursos cloud que limpiar. Eliminar el directorio local:

```bash
rm -rf ~/labs/m2-consume /tmp/cloudsql.zip
```

```powershell
Remove-Item -Recurse -Force "$HOME\labs\m2-consume", "$env:TEMP\cloudsql.zip"
```

> ⚠️ El zip y el tag Git en el bucket NO se eliminan: el módulo `cloudsql@1.0.0` se consumirá desde el Módulo 3.

---

## 6. Referencias oficiales

- Module Registry Protocol: <https://developer.hashicorp.com/terraform/internals/module-registry-protocol>
- GCS as a module registry: <https://cloud.google.com/docs/terraform#use_gcs_as_a_module_registry>
- SemVer: <https://semver.org/>
- Module sources: <https://developer.hashicorp.com/terraform/language/modules/sources>

---
