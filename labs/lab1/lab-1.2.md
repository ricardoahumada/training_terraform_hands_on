# Lab 1.2 — Crear, conectar y destruir una VM con Terraform

> **Duración estimada**: 30-35 minutos.
> **Caso AppLocker**: primer contacto del alumno con un recurso de **Compute** en GCP bajo Terraform. La VM se levanta en la red `default` a propósito: todavía no toca aprender VPC a medida (eso es M3). El foco es el `resource` de instancia + verificar que está viva entrando por SSH. La red y el `startup-script` se abordan en el M3.
> **Posición recomendada**: ejecutar tras el `lab-1.1`. El alumno ya sabe inicializar un proyecto Terraform y aplicar cambios.

---

## 0. Objetivo

Al terminar este lab, habrá:

- Habilitado la API `compute.googleapis.com` en el proyecto.
- Declarado y aprovisionado una VM con `google_compute_instance` (Debian 12, `e2-micro`).
- Asignado una IP pública efímera mediante `access_config`.
- Verificado el despliegue entrando por SSH a la VM y comprobando la metadata de la instancia con `curl` al metadata server.
- Cambiado un atributo in-place (`machine_type`) y destruido la VM al final.

---

## 1. Prerrequisitos

- Terraform `>= 1.5` instalado (`terraform -version`).
- `gcloud` autenticado y con `application-default login` hecho.
- Permisos `compute.instanceAdmin.v1` en el proyecto.
- Sufijo personal definido (mismo criterio que en lab-1: iniciales + DDMM, por ejemplo `ricar0107`).

> 💡 **Recomendado**: haber hecho antes el `lab-1.1` (crear un bucket con Terraform) para tener frescos `init` / `plan` / `apply` / `destroy`. Este lab se puede hacer de forma independiente si ya se conocen esos comandos.

> 📎 Ref. oficial autenticación ADC: <https://cloud.google.com/docs/authentication/application-default-credentials>

---

## 2. Recursos necesarios

- 1 proyecto GCP de prueba (uno por alumno).
- Conexión a Internet desde la terminal.

---

## 3. Pasos

### 3.0 Habilitar la API de Compute Engine

> Si el formador ya la habilitó en el proyecto compartido, este paso se puede saltar.

```bash
gcloud services enable compute.googleapis.com \
  --project="$(gcloud config get-value project)"
```

```powershell
gcloud services enable compute.googleapis.com `
  --project="$(gcloud config get-value project)"
```

> 💬 **Nota del formador**: *"Sin esta API, Terraform no puede crear la VM: la primera llamada devuelve 403 'API not enabled'. En proyectos de producción la habilitación la hace el equipo de plataforma, no el desarrollador. Aquí la hacemos nosotros para no quedarnos atascados en el primer apply."*

### 3.1 Crear la carpeta de trabajo y entrar en ella

```bash
mkdir -p ~/labs/m1-vm && cd ~/labs/m1-vm
```

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\labs\m1-vm" | Out-Null
Set-Location "$HOME\labs\m1-vm"
```

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
  zone    = var.zone
}
```

### 3.3 Declarar las variables de entrada

Crear el archivo `variables.tf`:

```hcl
variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = "Región por defecto para el provider"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona para la VM (debe pertenecer a la región)"
  type        = string
  default     = "us-central1-a"
}

variable "vm_suffix" {
  description = "Sufijo personal del alumno (ej. ricar0107)"
  type        = string
}
```

### 3.4 Declarar la VM

Crear el archivo `main.tf`:

```hcl
resource "google_compute_instance" "web" {
  name         = "applocker-web-${var.vm_suffix}"
  machine_type = "e2-micro"
  zone         = var.zone

  # Imagen mínima de Debian 12 (soportada y barata)
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Bloque vacío = Terraform pide una IP pública efímera a GCP
    }
  }

  metadata_startup_script = <<-BASH
    #!/usr/bin/env bash
    cat > /srv/www/index.html <<HTML
    <!doctype html>
    <html><head><title>Lab 1.2</title></head>
    <body><h1>Hola desde ${var.vm_suffix}</h1>
    <p>Levantado con Terraform en el lab 1.2.</p>
    </body></html>
    HTML
    nohup python3 -m http.server 80 --directory /srv/www >/var/www.log 2>&1 &
  BASH

  labels = {
    entorno = "lab"
    curso   = "terraform-hands-on"
    owner   = var.vm_suffix
    modulo  = "m1"
  }
}

output "vm_name" {
  value       = google_compute_instance.web.name
  description = "Nombre de la VM"
}

output "vm_external_ip" {
  value       = google_compute_instance.web.network_interface[0].access_config[0].nat_ip
  description = "IP pública efímera de la VM"
}

output "vm_zone" {
  value       = google_compute_instance.web.zone
  description = "Zona donde se ha creado la VM"
}
```

> 💬 **Nota del formador**: *"Fíjate en tres detalles: (1) el bloque `boot_disk` con `initialize_params` declara un disco NUEVO desde una imagen pública; si el alumno quiere mantener un disco entre applies usaría `boot_disk.attachment` en su lugar. (2) `network_interface` con `access_config` vacío = IP pública efímera, asignada por GCP. Sin ese bloque la VM solo tendría IP privada. (3) La etiqueta `default` en `network` indica que usamos la VPC por defecto del proyecto: aquí no tocamos subredes, eso es M3."*

### 3.5 Crear `terraform.tfvars` con los valores del alumno

Crear el archivo `terraform.tfvars` (NO commitear):

```hcl
project_id = "<PROJECT_ID>"   # pegar aquí el ID del proyecto activo
zone       = "us-central1-a"
vm_suffix  = "<sufijo>"       # mismo sufijo que en lab-1.1
```

```bash
gcloud config get-value project
```

```powershell
gcloud config get-value project
```

> ⚠️ **Importante**: sustituir `<PROJECT_ID>` y `<sufijo>` por los valores reales.

### 3.6 Inicializar el proyecto

```bash
terraform init
```

### 3.7 Previsualizar el plan

```bash
terraform plan
```

Salida esperada (recortada):

```
Terraform will perform the following actions:

  # google_compute_instance.web will be created
  + ...

Plan: 1 to add, 0 to change, 0 to destroy.
```

### 3.8 Aplicar el plan

```bash
terraform apply
```

Confirmar con `yes`. Salida esperada (recortada):

```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

vm_name       = "applocker-web-<sufijo>"
vm_external_ip = "34.x.x.x"
vm_zone       = "us-central1-a"
```

> ⚠️ **Cronometra**: la VM tarda ~30-60 s en arrancar y pasar a estado `RUNNING`. `terraform apply` espera a que el recurso esté provisionado antes de devolver el control, así que cuando vuelves al prompt la VM ya está lista para SSH.

### 3.9 Comprobar el estado por `gcloud`

```bash
gcloud compute instances describe "applocker-web-${var.vm_suffix}" \
  --zone="${var.zone}" \
  --format="value(name,status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)"
```

```powershell
$env:VM_SUFFIX = "<sufijo>"
$env:ZONE = "us-central1-a"
gcloud compute instances describe "applocker-web-$env:VM_SUFFIX" `
  --zone=$env:ZONE `
  --format="value(name,status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)"
```

Debe devolver algo como `applocker-web-ricar0107 RUNNING e2-micro 34.x.x.x`.

### 3.10 Conectar por SSH a la VM

```bash
gcloud compute ssh "applocker-web-${var.vm_suffix}" --zone="${var.zone}"
```

```powershell
gcloud compute ssh "applocker-web-$env:VM_SUFFIX" --zone=$env:ZONE
```

La primera vez puede pedir confirmación de la host key (responder `y`) o propagar la clave SSH (esperar unos segundos).

> 💬 **Nota del formador**: *"Si es la primera vez que el alumno hace `gcloud compute ssh` en esta máquina, la herramienta genera un par de claves, lo sube al metadata del proyecto y cachea la host key. Eso puede tardar 20-30 s la primera vez. Las siguientes son instantáneas."*

### 3.11 Comprobar que estamos dentro de la VM correcta

Una vez dentro de la sesión SSH, lanzar:

```bash
# hostname del sistema operativo
hostname
# nombre de la VM que ve la metadata de GCP
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/name
# zona donde corre
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/zone
```

Deben coincidir con el `name` y la `zone` que devuelve `terraform output`.

### 3.11.1 Comprobar el `startup-script` con un `curl` interno

El `metadata_startup_script` levanta un servidor HTTP con `python3`. Comprobamos que está vivo:

```bash
curl -s http://localhost | grep -o '<h1>.*</h1>'
```

Debe devolver `<h1>Hola desde <sufijo></h1>`.

> ⚠️ **Cronometra**: el `startup-script` se ejecuta al primer boot de la VM. Si el alumno entra por SSH en los primeros 30-60 s puede que aún no haya terminado. Si `curl localhost` falla, esperar y reintentar.

> 💬 **Nota del formador**: *"Si `curl localhost` devuelve 'Connection refused', los logs del script están en `/var/www.log` y en `gcloud compute instances get-serial-port-output <vm>`. Lo más rápido para diagnosticar: `gcloud compute ssh ... --command 'cat /var/www.log'`."*

Salir de la sesión SSH:

```bash
exit
```

> 💬 **Nota del formador**: *"El `curl` al metadata server es la forma más fiable de saber que estás DENTRO de la VM correcta. La URL `metadata.google.internal` solo resuelve desde la propia instancia. Esto se usa mucho en scripts de arranque (cloud-init) y en módulos de Terraform (data sources) para leer atributos de la instancia. Lo veremos en M3 y M4."*

### 3.12 Confirmar que el segundo plan está limpio

```bash
terraform plan
```

Salida esperada:

```
No changes. Your infrastructure matches the configuration.
```

> 💬 **Nota del formador**: *"Esto demuestra la idempotencia: si vuelves a aplicar el mismo HCL, Terraform detecta que no hay nada que cambiar. Es la diferencia clave con un script de `gcloud`, que intentaría crear la VM otra vez y fallaría por nombre duplicado."*

---

## 4. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Error 403: Compute Engine API has not been used` en el `apply` | API no habilitada en el proyecto | Repetir paso 3.0 |
| `Error: Invalid value for field 'network'` | La red `default` no existe en el proyecto o está en otro | `gcloud compute networks list` y revisar |
| `terraform apply` se queda colgado ~1 min y termina OK | Normal: VM tarda en arrancar | Esperar; comprobar `gcloud compute instances list` |
| `gcloud compute ssh` se queda esperando "Updating project ssh metadata..." | El wrapper está propagando la clave SSH al proyecto | Esperar 20-30 s; la segunda vez es instantáneo |
| `gcloud compute ssh` pide confirmar host key (Plink en Windows) | Primera conexión a esa IP | Responder `y`; queda cacheada |
| `gcloud compute ssh` pide passphrase | No hay clave SSH configurada para `gcloud` | `gcloud compute config-ssh` y aceptar la nueva clave |
| `Permission denied (publickey)` | Las claves SSH del proyecto están rotas | `gcloud compute config-ssh` y reintentar |
| `curl localhost` devuelve `Connection refused` dentro de la VM | El `startup-script` aún no terminó (raro: este script no toca red) | Esperar 10-20 s y reintentar. Si persiste, `gcloud compute ssh ... --command 'cat /var/www.log'` |

> 📎 Ref. oficial troubleshooting Compute: <https://cloud.google.com/compute/docs/troubleshooting>

---

## 5. Limpieza

Una vez validada la VM, destruir el recurso:

```bash
terraform destroy
```

Confirmar con `yes`. Salida esperada (recortada):

```
Destroy complete! Resources: 1 destroyed.
```

Comprobar que no queda nada en el proyecto:

```bash
gcloud compute instances list --format="value(name)" | grep applocker
# No debe devolver nada
```

```powershell
gcloud compute instances list --format="value(name)" | Select-String applocker
# No debe devolver nada
```

Comprobar que el plan queda limpio:

```bash
terraform plan
# Debe devolver: No changes.
```

> 💬 **Nota del formador**: *"En este lab sí destruimos: la VM era de prácticas. En el lab-1 NO se destruye el bucket de state. La regla: si el recurso es 'desechable' (pruebas, demos, entornos efímeros) lo metemos en Terraform y lo destruimos sin miedo. Si es 'persistente' (state, datos productivos), el `destroy` es tabú."*

---

## 6. Ejercicio corto — Cambiar la machine type sin recrear (≈ 5 min)

> **Objetivo**: ver otro ejemplo de cambio `~ update in-place` (Compute permite cambiar `machine_type` sin recrear la VM).

### 6.1 Enunciado

1. Vuelve a aplicar el lab (paso 3.8) para tener la VM levantada.
2. Cambia en `main.tf` `machine_type = "e2-micro"` por `machine_type = "e2-small"`.
3. Ejecuta `terraform plan` y observa que muestra `~ update in-place` (NO `-/+ destroy/create`).
4. Aplica con `terraform apply`.
5. Verifica el cambio:
   ```bash
   gcloud compute instances describe "applocker-web-${var.vm_suffix}" \
     --zone="${var.zone}" \
     --format="value(machineType.basename())"
   ```
   En PowerShell: `gcloud compute instances describe "applocker-web-$env:VM_SUFFIX" --zone=$env:ZONE --format="value(machineType.basename())"`.
   Debe devolver `e2-small`.
6. Vuelve a poner `e2-micro` y ejecuta `terraform plan` → debe volver a `~ update in-place` y luego a `No changes` tras aplicar.

### 6.2 Verificación

El alumno debe mostrar al formador:

- Output del `plan` con `~ update in-place` (no `-/+`).
- Salida del `gcloud compute instances describe` con `e2-small`.
- `plan` limpio tras volver a `e2-micro`.

### 6.3 Limpieza del ejercicio

Tras el ejercicio el alumno deja el `main.tf` con `e2-micro` y ejecuta la sección 5 (`terraform destroy`) para dejar el proyecto limpio.

> 💬 **Nota del formador**: *"No todos los atributos son `~ in-place`. Si el alumno cambia la `zone` o la imagen del disco de arranque, Terraform propondrá `-/+ destroy/create` porque son `ForceNew`. La regla: antes de cualquier `apply`, leer el plan y entender qué va a pasar."*

---

## 7. Referencias oficiales

- `google_compute_instance`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance>
- Tipos de máquina: <https://cloud.google.com/compute/docs/machine-types>
- `gcloud compute ssh`: <https://cloud.google.com/sdk/gcloud/reference/compute/ssh>
- Metadata server: <https://cloud.google.com/compute/docs/metadata/overview>
- VPC default: <https://cloud.google.com/vpc/docs/default-vpc>

---
