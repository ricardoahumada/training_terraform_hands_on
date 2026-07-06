# Lab 1.1 — Crear y configurar un bucket de GCS con Terraform

> **Duración estimada**: 30-35 minutos.
> **Caso AppLocker**: primer contacto del alumno con Terraform sobre un recurso real de GCP. Pensado para perfiles incipientes: se trabaja con un bucket "de prácticas" (distinto del bucket de state del lab-1) para no contaminar el setup del módulo.
> **Posición recomendada**: ejecutar antes o al inicio del lab-1, según el nivel del aula.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Inicializado un proyecto Terraform desde cero con el provider `google`.
- Declarado y aprovisionado un bucket de GCS con `google_storage_bucket` y su configuración básica completa (location, UBLA, versioning, lifecycle, labels).
- Verificado el recurso con `terraform plan` y `apply` y contrastado con la consola de GCS.
- Ejecutado un cambio in-place (sin destruir) para entender el símbolo `~` del plan.
- Limpiado el bucket con `terraform destroy`.

---

## 1. Prerrequisitos

- Terraform `>= 1.5` instalado (`terraform -version`).
- `gcloud` autenticado y con un proyecto activo: `gcloud config get-value project`.
- Permisos `storage.admin` en el proyecto.
- Sufijo personal definido (mismo criterio que en lab-1: iniciales + DDMM, por ejemplo `ricar0107`).

> 📎 Ref. oficial provider Google: <https://registry.terraform.io/providers/hashicorp/google/latest/docs>

---

## 2. Recursos necesarios

- 1 proyecto GCP de prueba (uno por alumno).
- Bucket GCS de prácticas que se creará en el paso 3 (no existía antes de este lab).
- Conexión a Internet desde la terminal.

> ⚠️ **Importante**: este bucket es **distinto** del bucket de state `applocker-tf-state-<sufijo>` del lab-1. Aquí creamos un bucket cualquiera para aprender a usar Terraform. El bucket de state se aborda en el lab-1 y siguientes.

---

## 3. Pasos

### 3.1 Crear la carpeta de trabajo y entrar en ella

```bash
mkdir -p ~/labs/m1-bucket && cd ~/labs/m1-bucket
```

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\labs\m1-bucket" | Out-Null
Set-Location "$HOME\labs\m1-bucket"
```

> 💬 **Nota del formador**: *"Este directorio está vacío. Aquí empieza nuestro proyecto Terraform. Recordad: un proyecto = una carpeta. Mezclar dos proyectos en la misma carpeta acaba con estados cruzados y sustos."*

### 3.2 Declarar el provider de Google

Crear el archivo `providers.tf`:

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
}
```

> 💬 **Nota del formador**: *"El bloque `terraform { required_providers }` le dice a Terraform de dónde bajar el plugin. El `provider "google"` le dice cómo autenticarse: usa el proyecto y la región que declaramos en variables, y las credenciales que ya tenéis en `gcloud auth application-default login`."*

### 3.3 Declarar las variables de entrada

Crear el archivo `variables.tf`:

```hcl
variable "project_id" {
  description = "ID del proyecto GCP donde se creará el bucket"
  type        = string
}

variable "region" {
  description = "Región por defecto para el provider"
  type        = string
  default     = "us-central1"
}

variable "bucket_suffix" {
  description = "Sufijo personal para evitar colisiones (ej. ricar0107)"
  type        = string
}
```

### 3.4 Crear `terraform.tfvars` con los valores del alumno

Crear el archivo `terraform.tfvars` (NO commitear en producción, aquí es local):

```hcl
project_id     = "<PROJECT_ID>"   # pegar aquí el ID del proyecto activo
region         = "us-central1"
bucket_suffix  = "<sufijo>"        # mismo sufijo que en el lab-1
```

```bash
# Comprobar el ID de proyecto actual
gcloud config get-value project
```

```powershell
# Comprobar el ID de proyecto actual
gcloud config get-value project
```

> ⚠️ **Importante**: sustituir `<PROJECT_ID>` y `<sufijo>` por los valores reales del alumno.

### 3.5 Declarar el bucket y su configuración

Crear el archivo `main.tf`:

```hcl
resource "google_storage_bucket" "practicas" {
  name                        = "applocker-practicas-${var.bucket_suffix}"
  location                    = "US"
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 365
      matches_storage_class = ["STANDARD"]
    }
  }

  labels = {
    entorno  = "lab"
    curso    = "terraform-hands-on"
    owner    = var.bucket_suffix
    modulo   = "m1"
  }
}

output "bucket_name" {
  value       = google_storage_bucket.practicas.name
  description = "Nombre del bucket aprovisionado"
}

output "bucket_url" {
  value       = google_storage_bucket.practicas.self_link
  description = "URL canónica del bucket en GCP"
}
```

> 💬 **Nota del formador**: *"Fíjate en la sintaxis: `resource "TIPO" "NOMBRE_LOCAL" { ... }`. El `TIPO` viene del provider; el `NOMBRE_LOCAL` lo elegimos nosotros y se usa para referenciar el recurso desde outputs, otros recursos o el state. Cada bloque anidado (versioning, labels, lifecycle_rule) es un argumento de tipo bloque, no un argumento simple. Lo importante: respeta la indentación de 2 espacios o Terraform fallará al validar."*

### 3.6 Inicializar el proyecto

```bash
terraform init
```

Salida esperada (recortada):

```
Initializing the provider plugins...
- Installing hashicorp/google v5.x.x ...
- Installed hashicorp/google v5.x.x

Terraform has been successfully initialized!
```

> 💬 **Nota del formador**: *"El provider se ha descargado a `.terraform/`. Esa carpeta NO se commitea. Si abres la carpeta del proyecto en el editor, verás `terraform.lock.hcl` y `.terraform/`. El primero sí se commitea (fija versiones), el segundo no."*

### 3.7 Previsualizar el plan

```bash
terraform plan
```

Salida esperada (recortada):

```
Terraform will perform the following actions:

  # google_storage_bucket.practicas will be created
  + resource "google_storage_bucket" "practicas" {
      + name                        = "applocker-practicas-<sufijo>"
      + location                    = "US"
      + force_destroy               = false
      + uniform_bucket_level_access = true
      ...
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

> 💬 **Nota del formador**: *"El plan muestra QUÉ va a pasar, pero todavía no ha tocado nada. Leedlo siempre: si veis un `-` o un `-/+` sobre algo que no esperáis, STOP. Nunca apliques un plan que no entiendas."*

### 3.8 Aplicar el plan

```bash
terraform apply
```

Terraform pedirá confirmación. Responder `yes`.

Salida esperada (recortada):

```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

bucket_name = "applocker-practicas-<sufijo>"
bucket_url  = "https://www.googleapis.com/storage/v1/b/applocker-practicas-<sufijo>"
```

### 3.9 Verificar en la consola y por CLI

En la consola de GCP (navegador):

📸 *Captura sugerida: vista del bucket en la consola → pestaña "Configuración" mostrando UBLA activado, versionado habilitado, etiquetas (entorno, curso, owner, modulo) y regla de ciclo de vida.*

Desde la terminal:

```bash
gcloud storage buckets describe gs://applocker-practicas-${var.bucket_suffix} \
  --format="value(iamConfiguration.uniformBucketLevelAccess.enabled,versioning.enabled,location)"
```

```powershell
gcloud storage buckets describe gs://applocker-practicas-<sufijo> `
  --format="value(iamConfiguration.uniformBucketLevelAccess.enabled,versioning.enabled,location)"
```

Debe devolver: `True True US` (o el valor de `location` que se haya declarado).

> 💬 **Nota del formador**: *"Si el valor no encaja, es la primera pista de drift: o el `main.tf` no coincide con la realidad, o alguien ha tocado el bucket a mano. Volvemos a la idea de 'infraestructura como código': la fuente de verdad es el HCL, no la consola."*

### 3.10 Confirmar que el segundo plan está limpio

```bash
terraform plan
```

Salida esperada:

```
No changes. Your infrastructure matches the configuration.
```

> 💬 **Nota del formador**: *"Esto demuestra la idempotencia: si vuelves a aplicar el mismo HCL, Terraform detecta que no hay nada que cambiar. Es la diferencia clave con un script de `gcloud`, que crearía el bucket otra vez y fallaría por nombre duplicado."*

---

## 4. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Error: project: required field is not set` | `project_id` no se ha pasado al provider | Comprobar `terraform.tfvars` y volver a `terraform apply` |
| `Error 409: You already own this bucket` | El nombre del bucket ya existe en el proyecto (propio o de un compañero) | Cambiar `<sufijo>` en `terraform.tfvars` y re-aplicar |
| `Error: google: could not find default credentials` | No estás autenticado en `gcloud` | Ejecutar `gcloud auth application-default login` |
| `Error: Invalid value for field 'location'` | `location` no es una región válida (GCS espera `US`, `EU`, `ASIA` o un nombre de región) | Revisar la doc oficial de ubicaciones |
| `Error: Failed to install provider` | Sin conexión a Internet o proxy corporativo | Revisar red / variables `HTTPS_PROXY` |
| `Error: Provider configuration not present` | El bloque `provider "google"` se borró o quedó comentado | Restaurar `providers.tf` y `terraform init` |

> 📎 Ref. oficial troubleshooting: <https://cloud.google.com/storage/docs/troubleshooting>

---

## 5. Limpieza

Una vez validado el bucket en consola y por CLI, destruir el recurso para dejar el proyecto limpio:

```bash
terraform destroy
```

Terraform pedirá confirmación. Responder `yes`.

Salida esperada (recortada):

```
Destroy complete! Resources: 1 destroyed.
```

Comprobar que el bucket ya no existe:

```bash
gcloud storage buckets list --format="value(name)" | grep practicas
# No debe devolver nada
```

```powershell
gcloud storage buckets list --format="value(name)" | Select-String practicas
# No debe devolver nada
```

Comprobar que el `plan` queda limpio (no hay nada huérfano declarado):

```bash
terraform plan
# Debe devolver: No changes.
```

> 💬 **Nota del formador**: *"En este lab sí destruimos: el bucket era de prácticas. En el lab-1 NO se destruye el bucket de state. Que los alumnos interioricen la diferencia: hay recursos 'desechables' y recursos 'persistentes' y Terraform los trata igual hasta que el `destroy` decide lo contrario."*

---

## 6. Ejercicio corto — Modificar el bucket sin destruirlo (≈ 5-8 min)

> **Objetivo**: ver el flujo de cambio in-place (`~ update in-place`) frente al de crear/destruir (`-/+ destroy/create`).

### 6.1 Enunciado

Antes de destruir el bucket, vamos a tocarlo un momento:

1. Sobre el `main.tf` actual, añade al recurso `google_storage_bucket.practicas` un bloque `cors` con una regla que permita `GET` desde `https://example.com` (max_age_seconds = 3600).
2. Ejecuta `terraform plan` y observa que el plan muestra `~ update in-place` (no `-/+ destroy/create`).
3. Aplica con `terraform apply` y comprueba que la regla CORS está activa:

   ```bash
   gcloud storage buckets describe gs://applocker-practicas-<sufijo> \
     --format="json(cors_config)"
   ```
4. Revierte el cambio (borra el bloque `cors`, deja el resto igual), aplica de nuevo y comprueba que Terraform marca `~` a vacío (sin destruir el bucket ni sus objetos).
5. Ejecuta la limpieza de la sección 5 (`terraform destroy`).

### 6.2 Pista

El bloque va como `cors { ... }` dentro del `resource`, no como argumento suelto. Lista la regla con `cors_rule { ... }`. Esquema de referencia:

```hcl
cors {
  origin          = ["https://example.com"]
  method          = ["GET"]
  response_header = ["*"]
  max_age_seconds = 3600
}
```

> 📎 Ref. oficial bloque `cors`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket#cors>

### 6.3 Verificación

El alumno debe mostrar al formador:

- Output del `plan` con `~ update in-place` (no `-/+`).
- Salida de `gcloud storage buckets describe ... --format="json(cors_config)"` con la regla presente.
- Salida tras la reversión con el array `cors` vacío en GCP y `No changes` en el `plan` posterior.

### 6.4 Limpieza del ejercicio

Tras el ejercicio el alumno deja el `main.tf` como estaba al final del 3.10 y hace `terraform plan` para confirmar `No changes`. Después ejecuta la sección 5 (`terraform destroy`) para dejar el proyecto limpio.

> 💬 **Nota del formador**: *"Este ejercicio entrena el músculo más importante del día a día con Terraform: leer un plan antes de aplicarlo. La diferencia entre `~` y `-/+` es la diferencia entre 'cambio de configuración' y 'recurso nuevo'. Si ven un `-/+` sobre algo que no esperaban, frenen."*

---

## 7. Referencias oficiales

- Provider `hashicorp/google`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs>
- Recurso `google_storage_bucket`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket>
- `gcloud storage buckets create`: <https://cloud.google.com/sdk/gcloud/reference/storage/buckets/create>
- Versionado de objetos en GCS: <https://cloud.google.com/storage/docs/object-versioning>
- Uniform bucket-level access: <https://cloud.google.com/storage/docs/uniform-bucket-level-access>
- Reglas de ciclo de vida: <https://cloud.google.com/storage/docs/lifecycle>
- CORS en GCS: <https://cloud.google.com/storage/docs/cross-origin>
- Terraform State (referencia al lab-1): <https://developer.hashicorp.com/terraform/language/state>

---
