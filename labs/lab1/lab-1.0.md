# Lab 1 — Backend GCS con locking

> **Duración estimada**: 25 minutos.
> **Caso AppLocker**: sentar las bases del state remoto para que toda la infraestructura del curso viva bajo Terraform desde el primer minuto.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Creado manualmente un bucket de GCS con `uniform bucket-level access` que simula el estado "pre-Terraform" de AppLocker.
- Habilitado el versionado en el bucket (red de seguridad para el `tfstate`).
- Declarado un `backend "gcs"` en HCL.
- Ejecutado `terraform init` y visto la migración del state local a remoto.
- Validado el **locking** concurrente abriendo dos terminales.

---

## 1. Prerrequisitos

- Terraform `>= 1.5` instalado (`terraform -version`).
- `gcloud` autenticado y con un proyecto activo: `gcloud config get-value project`.
- Permisos `storage.admin` en el proyecto.
- Variable de entorno `<sufijo>` definida (cada alumno usa su sufijo personal; sugerencia: iniciales + DDMM, por ejemplo `ricar0107`).

> 📎 Ref. oficial: <https://cloud.google.com/storage/docs/authentication>

---

## 2. Recursos necesarios

- 1 proyecto GCP de prueba (uno por alumno).
- Bucket GCS que se creará en el paso 3 (no existía antes de este lab).
- Conexión a Internet desde la terminal.

---

## 3. Pasos

### 3.1 Definir las variables 
```bash
# Sustituir <sufijo> por el identificador personal
export TF_STATE_BUCKET="applocker-tf-state-${USER}"
export TF_STATE_REGION="us-central1"

# Verificar valores
echo $TF_STATE_BUCKET
echo $TF_STATE_REGION

# Verificar el proyecto activo
gcloud config get-value project
```

```powershell
# Sustituir <sufijo> por el identificador personal
$env:TF_STATE_BUCKET = "applocker-tf-state-$env:USERNAME"
$env:TF_STATE_REGION = "us-central1"

# Verificar valores
echo $env:TF_STATE_BUCKET
echo $env:TF_STATE_REGION

# Verificar el proyecto activo
gcloud config get-value project

# Cambiar a proyecto que se desea, si necesario
gcloud config set project <nombre_proyecto>
```

> 🗣️ **Nota**: *"Cada uno tiene su propio bucket. El sufijo es la red de seguridad para que no os piséis los recursos durante el curso."*


### 3.2 Crear el bucket manualmente (simula estado "pre-Terraform")

```bash
gcloud storage buckets create gs://${TF_STATE_BUCKET} \
  --location=${TF_STATE_REGION} \
  --uniform-bucket-level-access
```

```powershell
gcloud storage buckets create gs://$env:TF_STATE_BUCKET `
  --location=$env:TF_STATE_REGION `
  --uniform-bucket-level-access
```

```
gcloud storage buckets list --uri
```

> 🗣️ **Nota**: *"Esto es exactamente lo que pasa cuando un equipo de plataforma crea la infraestructura a mano y después decide meterla bajo Terraform. Vamos a tratar este bucket como si fuera legacy."*


### 3.3 Habilitar el versionado en el bucket

```bash
gcloud storage buckets update gs://${TF_STATE_BUCKET} --versioning
```

```powershell
gcloud storage buckets update gs://$env:TF_STATE_BUCKET --versioning
```

> 🗣️ **Nota**: *"El versionado en el bucket de state es nuestra red de seguridad. Si un `apply` rompe el state, podemos restaurar una versión anterior exactamente igual que con un commit de Git."*


### 3.4 Crear la carpeta de trabajo y declarar el backend en HCL

```bash
mkdir -p ~/labs/m1-backend && cd ~/labs/m1-backend
```

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\labs\m1-backend" | Out-Null
Set-Location "$HOME\labs\m1-backend"
```

`backend.tf`:

```hcl
terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"
    prefix = "terraform/state"
  }
}
```

> ⚠️ **Importante**: se debe sustituir `<sufijo>` por el suyo en el archivo.

### 3.5 Inicializar y verificar la migración a remoto

```bash
terraform init
```

Salida esperada (recortada):

```
Initializing the backend...
Successfully configured the backend "gcs"! Terraform will automatically
use this backend unless the backend configuration changes.
```

```bash
terraform plan
```

Salida esperada:

```
No changes. Your infrastructure matches the configuration.
```

> 🗣️ **Nota**: *"El plan está vacío porque el bucket existe y el backend solo guarda el state. No hay nada que crear todavía. La gracia viene ahora: el state ya no vive en tu portátil."*


### 3.6 Verificar que el state ha migrado a GCS

```bash
gcloud storage ls gs://${TF_STATE_BUCKET}/terraform/state/
# Debe listar default.tfstate
```

```powershell
gcloud storage ls gs://$env:TF_STATE_BUCKET/terraform/state/
# Debe listar default.tfstate
```

### 3.7 Validar el locking concurrente

1. Abrir dos terminales en la misma carpeta del proyecto.
2. **Terminal A**: ejecutar `terraform plan` (tarda unos segundos).
3. **Terminal B**: mientras A está corriendo, ejecutar `terraform apply`.

Salida esperada en la terminal B:

```
│ Error: Error acquiring the state lock
│
│ Error message: Failed to lock GCS state file: 2 conflicts:
│   - lock acquired by user "<alumno-A>"
│
│ Terraform acquires a lock when accessing the state file.
│ ...
```

> 🗣️ **Nota**: *"Esto es lo que evita corrupción del state cuando dos personas aplican a la vez. Si el bloqueo no existiera, los dos aplicarían cambios y la última escritura ganaría. Habríais perdido el trabajo del compañero."*


### 3.8 Liberar el lock (solo si quedó colgado)

```bash
# El ID aparece en el mensaje de error
terraform force-unlock <LOCK_ID>
```

> ⚠️ **Solo usar si realmente nadie está aplicando**. Comprobar siempre con un compañero antes.

---

## 4. Resultados esperados

- Bucket `applocker-tf-state-<sufijo>` creado en `us-central1` con versionado y UBLA.
- Backend GCS configurado y funcional.
- State en `gs://<bucket>/terraform/state/default.tfstate`.
- Locking validado con dos terminales.

---

## 5. Limpieza

En este lab **NO se debe destruir el bucket**: lo reutilizaremos en los labs 2 y 3 del módulo y como state remoto durante todo el curso. Lo único que se elimina es el directorio local de trabajo si el formador lo indica:

```bash
# Solo si el formador lo pide explícitamente
rm -rf ~/labs/m1-backend
# NUNCA borrar el bucket GCS aquí
```

```powershell
# Solo si el formador lo pide explícitamente
Remove-Item -Recurse -Force "$HOME\labs\m1-backend"
# NUNCA borrar el bucket GCS aquí
```

Confirmar que el bucket sigue activo:

```bash
gcloud storage buckets describe gs://${TF_STATE_BUCKET} \
  --format="value(versioning.enabled,iamConfiguration.uniformBucketLevelAccess.enabled)"
```

```powershell
gcloud storage buckets describe gs://$env:TF_STATE_BUCKET `
  --format="value(versioning.enabled,iamConfiguration.uniformBucketLevelAccess.enabled)"
```

Debe devolver: `True True`

---

## 6. Referencias oficiales

- Backend GCS: <https://developer.hashicorp.com/terraform/language/backend/gcs>
- `gcloud storage buckets create`: <https://cloud.google.com/sdk/gcloud/reference/storage/buckets/create>
- Versionado de objetos en GCS: <https://cloud.google.com/storage/docs/object-versioning>
- Terraform State: <https://developer.hashicorp.com/terraform/language/state>
- State Locking: <https://developer.hashicorp.com/terraform/language/state/locking>

---


# Lab 2 — Importar el bucket de state al control de Terraform

> **Duración estimada**: 30 minutos.
> **Caso AppLocker**: meter el bucket "legacy" al estado de Terraform sin destruirlo.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Declarado el bloque `resource "google_storage_bucket" "tf_state"` con los atributos exactos del bucket real.
- Ejecutado `terraform import` para añadir el bucket al state.
- Confirmado con `terraform plan` que no hay drift.
- Provocado (didáctico) un drift para ver cómo responde Terraform.

---

## 1. Prerrequisitos

- Haber completado el Lab 1 con éxito.
- Misma carpeta de trabajo `~/labs/m1-backend` con el backend GCS configurado.
- Permisos `storage.admin` en el proyecto.

---

## 2. Recursos necesarios

- Bucket `applocker-tf-state-<sufijo>` (creado en el Lab 1).
- Directorio `~/labs/m1-backend` con `backend.tf`.

---

## 3. Pasos

### 3.1 Declarar el recurso en HCL

`main.tf` (mismo directorio):

```hcl
resource "google_storage_bucket" "tf_state" {
  name          = "applocker-tf-state-<sufijo>"
  location      = "us-central1"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  labels = {
    managed_by = "terraform"
    module     = "bootstrap"
  }
}
```

> 🗣️ **Nota**: *"El bloque HCL debe coincidir con la realidad. Si os falta un atributo o tiene un valor distinto, `plan` propondrá cambios. Import no es magia: solo añade el recurso al state, no genera el código."*

### 3.2 Importar el recurso

```bash
terraform import google_storage_bucket.tf_state applocker-tf-state-<sufijo>
```

Salida esperada:

```
google_storage_bucket.tf_state: Importing from ID "applocker-tf-state-<sufijo>"...
google_storage_bucket.tf_state: Import prepared!
  Prepared google_storage_bucket for import
google_storage_bucket.tf_state: Refreshing state...

Import successful!

The resources that were imported are shown above. These resources are now in
your Terraform state and will henceforth be managed by Terraform.
```

### 3.3 Verificar que el plan está limpio

```bash
terraform plan
```

Salida esperada:

```
No changes. Your infrastructure matches the configuration.
```

> 🗣️ **Nota**: *"Este es el momento clave: el plan dice que no hay drift. Si el bloque HCL no coincidiera con la realidad, veríais un `~ update in-place` o, peor, un `-/+ destroy and create`. `force_destroy = false` en un bucket con objetos protegería contra el segundo caso, pero la disciplina es: HCL primero, import después, plan limpio."*
> *Comprabar con: `gcloud storage buckets describe gs://applocker-tf-state-<sufijo> --format=json`*


### 3.4 Reproducir un error común (didáctico)

Cambiar temporalmente el `location` en el HCL:

```hcl
resource "google_storage_bucket" "tf_state" {
  # ...
  location = "EU"   # cambiado temporalmente
  # ...
}
```

```bash
terraform plan
```

Salida esperada:

```
# google_storage_bucket.tf_state must be rebuilt
~ resource "google_storage_bucket" "tf_state" {
    ~ location = "EU" -> "us-central1" # forces replacement
      name      = "applocker-tf-state-<sufijo>"
      # ...
}
```

> 🗣️ **Nota**: *"`location` es un atributo `ForceNew`: cambiarlo obliga a destruir y recrear el bucket. En producción esto es catastrófico. Regla: si ves un `-/+` en un recurso crítico, para, lee, consulta, y no confirmes el apply."*

Restaurar el `location` original:

```hcl
location = "us-central1"
```

```bash
terraform plan
# Debe volver a: "No changes."
```

### 3.5 Confirmar el versionado activo (punto de control)

```bash
gcloud storage buckets describe gs://${TF_STATE_BUCKET} \
  --format="value(versioning.enabled)"
# Debe devolver: True
```

```powershell
gcloud storage buckets describe gs://$env:TF_STATE_BUCKET `
  --format="value(versioning.enabled)"
# Debe devolver: True
```

### 3.6 Listar el state completo

```bash
terraform state list
# Debe devolver: google_storage_bucket.tf_state
```

```bash
terraform show
# Revisar los atributos del bucket registrados en el state
```

---

## 4. Resultados esperados

- Bucket `applocker-tf-state-<sufijo>` bajo control de Terraform.
- `terraform plan` limpio.
- Entiende la diferencia entre "import" y "drift": el primero añade al state, el segundo lo detecta.

---

## 5. Limpieza

**NO destruir el bucket**. Se reutiliza en M2-M6 como state remoto.

Únicamente, si el formador lo pide, eliminar el directorio local de pruebas:

```bash
rm -rf ~/labs/m1-backend
```

```powershell
Remove-Item -Recurse -Force "$HOME\labs\m1-backend"
```

Confirmar que el bucket sigue activo y versionado:

```bash
gcloud storage buckets describe gs://${TF_STATE_BUCKET} \
  --format="value(name,versioning.enabled)"
```

```powershell
gcloud storage buckets describe gs://$env:TF_STATE_BUCKET `
  --format="value(name,versioning.enabled)"
```

---

## 6. Referencias oficiales

- `terraform import`: <https://developer.hashicorp.com/terraform/cli/import>
- `google_storage_bucket` (provider reference): <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket>
- Atributos `ForceNew`: <https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#how-to-use-for_each-and-count-with-lifecycle>
- Drift detection: <https://developer.hashicorp.com/terraform/tutorials/state/resource-drift>

---


# Lab 3 — Workspaces para AppLocker

> **Duración estimada**: 25 minutos.
> **Caso AppLocker**: demostrar el aislamiento de state entre `dev` y `prod` usando workspaces.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Creado los workspaces `dev` y `prod` sobre el mismo backend GCS.
- Declarado un recurso parametrizado con `terraform.workspace`.
- Aplicado el plan en cada workspace y verificado que los buckets son distintos.
- Confirmado que los states están separados en GCS.

---

## 1. Prerrequisitos

- Haber completado los Labs 1 y 2.
- Misma carpeta `~/labs/m1-backend` con el backend GCS.
- Bucket `applocker-tf-state-<sufijo>` con versionado.

---

## 2. Recursos necesarios

- Bucket de state remoto del Lab 1.
- Dos nuevos buckets `applocker-artifacts-dev-<sufijo>` y `applocker-artifacts-prod-<sufijo>`.

---

## 3. Pasos

### 3.1 Crear los workspaces

```bash
cd ~/labs/m1-backend

terraform workspace list
# default  (el asterisco marca el actual)
```

```powershell
Set-Location "$HOME\labs\m1-backend"

terraform workspace list
# default  (el asterisco marca el actual)
```

```bash
terraform workspace new dev
terraform workspace new prod
```

```bash
terraform workspace list
# default
# dev
# prod  (sin asterisco todavía)
```

```bash
terraform workspace select dev
terraform workspace show
# debe devolver: dev
```

> 🗣️ **Nota**: *"Cada workspace tiene su propio `tfstate` dentro del mismo bucket. La separación la marca el `prefix` del backend y el nombre del workspace. La configuración HCL es la misma para todos."*


### 3.2 Declarar el provider, las variables y el segundo recurso parametrizado

Antes de añadir el recurso `artifacts`, el provider `google` necesita saber **a qué proyecto** enviar las llamadas a la API. Creamos un fichero `provider.tf` y un `variables.tf`:

`provider.tf`:

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}
```

`variables.tf`:

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se crearán los recursos"
}

variable "region" {
  type        = string
  description = "Región GCP por defecto para los recursos del provider"
  default     = "us-central1"
}

variable "suffix" {
  type        = string
  description = "Identificador personal (ej. iniciales+DDMM). Evita colisiones de nombres de bucket."
}
```

Pasamos los valores al provider desde variables de entorno (mismo convenio que para el bucket de state):

```bash
export TF_VAR_project_id=$(gcloud config get-value project)
export TF_VAR_suffix="<sufijo>"   # ej. ricar0107

# Verificar
echo "project_id=$TF_VAR_project_id"
echo "suffix=$TF_VAR_suffix"
```

```powershell
$env:TF_VAR_project_id = (gcloud config get-value project)
$env:TF_VAR_suffix = "<sufijo>"   # ej. ricar

# Verificar
echo $env:TF_VAR_project_id
echo $env:TF_VAR_suffix
```

Ahora añadimos el segundo recurso al `main.tf` (debajo del bucket de state) **usando la variable** en lugar del placeholder `<sufijo>`:

```hcl
resource "google_storage_bucket" "artifacts" {
  name          = "applocker-artifacts-${terraform.workspace}-${var.suffix}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  labels = {
    environment = terraform.workspace
    managed_by  = "terraform"
  }
}
```

> ⚠️ El nombre de bucket en GCS es global y único. La variable `suffix` evita pisar el bucket de un compañero.

### 3.3 Aplicar en `dev` y verificar

```bash
terraform workspace select dev
terraform plan
terraform apply -auto-approve
```

```bash
gcloud storage ls gs://applocker-artifacts-dev-${TF_VAR_suffix}/
# debe listar (puede estar vacío)
gcloud storage buckets describe gs://applocker-artifacts-dev-${TF_VAR_suffix} \
  --format="value(labels.environment)"
# debe devolver: dev
```

```powershell
gcloud storage ls gs://applocker-artifacts-dev-$env:TF_VAR_suffix/
# debe listar (puede estar vacío)
gcloud storage buckets describe gs://applocker-artifacts-dev-$env:TF_VAR_suffix `
  --format="value(labels.environment)"
# debe devolver: dev
```


### 3.4 Cambiar a `prod` y reaplicar

> ⚠️ **Antes de aplicar**: el `tf_state` se importó en el Lab 2 estando en el workspace `default`. Al cambiar de workspace, cada uno tiene su propio `tfstate` y el `prod` no sabe nada del bucket de state. Sin el import previo, el plan de `prod` propondría **crear también** el `tf_state` (que ya existe en GCP, así que la API devolvería un 409). Importamos primero:

```bash
terraform workspace select prod

# Importar el bucket de state en el state de prod
terraform import google_storage_bucket.tf_state applocker-tf-state-${TF_VAR_suffix}

# Verificar el plan: ya no debe proponer crear tf_state
terraform plan
# Debe devolver: "Plan: 1 to add, 0 to change, 0 to destroy."  (solo artifacts)
```

```powershell
terraform workspace select prod

terraform import google_storage_bucket.tf_state applocker-tf-state-$env:TF_VAR_suffix

terraform plan
# Debe devolver: "Plan: 1 to add, 0 to change, 0 to destroy."  (solo artifacts)
```

Aplicar:

```bash
terraform apply -auto-approve
```

```bash
gcloud storage ls gs://applocker-artifacts-prod-${TF_VAR_suffix}/
gcloud storage buckets describe gs://applocker-artifacts-prod-${TF_VAR_suffix} \
  --format="value(labels.environment)"
# debe devolver: prod
```

```powershell
gcloud storage ls gs://applocker-artifacts-prod-$env:TF_VAR_suffix/
gcloud storage buckets describe gs://applocker-artifacts-prod-$env:TF_VAR_suffix `
  --format="value(labels.environment)"
# debe devolver: prod
```

> 🗣️ **Nota**: *"Mismo código, distinto `name` en el bucket. El HCL es idéntico; lo que cambia es la variable implícita `terraform.workspace`. Esto es lo que nos permite tener un solo repositorio y N entornos."*
> *"Y otra lección: el `tf_state` existe físicamente en GCP y también debe existir en cada state de workspace. `import` no es una operación de GCP, es una operación sobre el state local de Terraform."*

### 3.5 Verificar el aislamiento de state en GCS

```bash
gcloud storage ls gs://${TF_STATE_BUCKET}/terraform/state/
# debe listar: dev.tfstate  prod.tfstate  default.tfstate (este último del Lab 2)
```

```powershell
gcloud storage ls gs://$env:TF_STATE_BUCKET/terraform/state/
# debe listar: dev.tfstate  prod.tfstate  default.tfstate (este último del Lab 2)
```

```bash
# Comparar el contenido de los dos states
terraform workspace select dev
terraform state list
# debe devolver:
#   google_storage_bucket.artifacts
#   google_storage_bucket.tf_state

terraform workspace select prod
terraform state list
# mismo listado
```

> 🗣️ **Nota**: *"Los states están separados. Si alguien rompe el state de `dev`, `prod` no se ve afectado. Si alguien aplica cambios contra `prod` por error, el PR review y el environment de GitHub (en M5) lo bloquean."*

### 3.6 Probar el aislamiento (extra)

Vamos a comprobar qué aíslan los workspaces (el state) y qué **no** aíslan (el código). La secuencia es: editar el HCL, aplicar en un workspace, observar qué pasa en el otro, restaurar el HCL.

**Paso 1 — Editar `main.tf` y aplicar el cambio en `prod`:**

```bash
terraform workspace select prod
```

Editar `main.tf` y poner:

```hcl
force_destroy = false   # temporalmente, para la prueba
```

```bash
terraform apply -auto-approve
# Cambia force_destroy de true → false SOLO en el state de prod
```

**Paso 2 — Comprobar el state de `prod` (lo que sí cambió):**

```bash
terraform state show google_storage_bucket.artifacts | grep force_destroy
# Esperado: force_destroy = false
```

```powershell
terraform state show google_storage_bucket.artifacts | Select-String force_destroy
# Esperado: force_destroy = false
```

**Paso 3 — Volver a `dev` y observar el `plan` (aquí está la lección):**

```bash
terraform workspace select dev
terraform plan
```

Salida esperada (recortada):

```
~ resource "google_storage_bucket" "artifacts" {
    ~ force_destroy = true -> false   # forces update
    # ...
}

Plan: 0 to add, 1 to change, 0 to destroy.
```

> 🗣️ **Nota**: *"Sorpresa: `dev` también ve el cambio. Los workspaces aíslan el **state**, no el **código**. El HCL es un único fichero en disco; al editarlo, **todos** los workspaces lo ven. Lo que está separado es el resultado de cada `apply` (cada uno en su `tfstate`). Por eso `prod` ahora tiene `false` aplicado y `dev` lo único que tiene es un `plan` que propone el cambio, todavía sin aplicar."*

**Paso 4 — Confirmar que el state de `dev` sigue intacto (no se aplicó nada):**

```bash
terraform state show google_storage_bucket.artifacts | grep force_destroy
# Esperado: force_destroy = true   (dev nunca se aplicó)
```

```powershell
terraform state show google_storage_bucket.artifacts | Select-String force_destroy
# Esperado: force_destroy = true   (dev nunca se aplicó)
```

**Paso 5 — Restaurar el HCL y dejar ambos workspaces limpios:**

Editar `main.tf` y dejar:

```hcl
force_destroy = true   # valor original
```

```bash
terraform workspace select prod
terraform plan
# Esperado: ~ force_destroy = false -> true   (drift en prod)

terraform apply -auto-approve
# Restaura force_destroy a true en prod
```

```bash
terraform workspace select dev
terraform plan
# Esperado: No changes. (dev sigue con true, HCL también)

terraform workspace select prod
terraform plan
# Esperado: No changes. (prod restaurado a true)
```

> 🗣️ **Nota**: *"Resumen de lo que hemos demostrado:*
> 1. *El state está aislado por workspace (`state show` muestra valores distintos).*
> 2. *El código NO está aislado: un cambio en `main.tf` lo ven todos los workspaces por igual.*
> 3. *Si queréis que un atributo sea distinto por entorno **sin** tocar el HCL cada vez, la solución es parametrizarlo (`terraform.workspace`, variables, o módulos). Eso lo veremos en M2 y M3."*

---

## 4. Resultados esperados

- Dos workspaces (`dev`, `prod`) operativos.
- Dos buckets de artefactos: `applocker-artifacts-dev-<sufijo>` y `applocker-artifacts-prod-<sufijo>`.
- Tres states en GCS: `default.tfstate`, `dev.tfstate`, `prod.tfstate`.
- Entiende que `terraform.workspace` permite parametrizar la configuración.

---

## 5. Limpieza

```bash
# Destruir ambos workspaces
terraform workspace select dev
terraform destroy

terraform workspace select prod
terraform destroy

# Volver a default y eliminar los workspaces
terraform workspace select default
terraform workspace delete dev
terraform workspace delete prod
```

> ⚠️ **NO destruir el bucket de state** (`applocker-tf-state-<sufijo>`). Se reutiliza en M2-M6.

Confirmar que el bucket de state sigue activo:

```bash
gcloud storage buckets describe gs://${TF_STATE_BUCKET} \
  --format="value(name,versioning.enabled)"
# debe devolver: applocker-tf-state-<sufijo  True
```

```powershell
gcloud storage buckets describe gs://$env:TF_STATE_BUCKET `
  --format="value(name,versioning.enabled)"
# debe devolver: applocker-tf-state-<sufijo  True
```

---

## 6. Referencias oficiales

- Terraform Workspaces: <https://developer.hashicorp.com/terraform/language/state/workspaces>
- `terraform.workspace`: <https://developer.hashicorp.com/terraform/language/expressions/references#terraform-workspace>
- Workspaces vs. directorios separados (discusión oficial): <https://developer.hashicorp.com/terraform/language/state/workspaces#when-to-use-multiple-workspaces>
- `terraform workspace` CLI: <https://developer.hashicorp.com/terraform/cli/workspace>

---
