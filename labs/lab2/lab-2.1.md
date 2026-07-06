# Lab 2.1 — Sistema modular end-to-end: network + subredes pública/privada + VMs conectadas

> **Duración estimada**: 40 minutos.
> **Caso AppLocker**: el alumno experimenta de primera mano el patrón "root module consume módulos secundarios" antes de meterse en versionado y registries (Labs 3 y 4 del M2).
> **Foco del lab**: estructura modular local (sin Public Registry, sin GCS Private Registry). El versionado y la publicación se trabajan en Labs 3 y 4.

---

## 0. Objetivo

Al terminar este lab, el alumno habrá:

1. Creado **2 módulos secundarios locales** (`infra/modules/network` y `infra/modules/compute`) con su estructura canónica (`versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`).
2. Compuesto ambos desde un **root module** en `infra/envs/dev/`.
3. Desplegado una **VPC nueva** con **2 subredes** (una pública, una privada) en la misma región.
4. Desplegado **2 VMs** (una en cada subred) **conectadas entre sí por IP interna**.
5. Ejecutado `terraform plan` y `terraform apply` desde el **root** (gestión global de toda la infra).

> 🗣️ **Nota del formador**: *"El root es el cerebro. Los módulos son las manos. Hoy vais a ver cómo las manos construyen, pero las órdenes las da siempre el root."*

---

## 1. Prerrequisitos

- Labs M1 completados (cuenta GCP activa, `gcloud` configurado, autenticación por ADC).
- Terraform `>= 1.5` y provider `hashicorp/google ~> 5.0`.
- Bucket de state remoto del M1 disponible: `applocker-tf-state-<sufijo>`.

```bash
# Verificar versiones
terraform version
gcloud --version
gcloud auth application-default login
```

```powershell
terraform version
gcloud --version
gcloud auth application-default login
```

---

## 2. Recursos necesarios en GCP

| Recurso | Nombre | Región/Zona |
|---|---|---|
| VPC | `applocker-vpc` | `europe-west1` (REGIONAL) |
| Subred pública | `applocker-pub` | `europe-west1` / CIDR `10.10.1.0/24` |
| Subred privada | `applocker-priv` | `europe-west1` / CIDR `10.10.2.0/24` |
| VM pública | `applocker-pub-vm` | `europe-west1-b` / `e2-small` |
| VM privada | `applocker-priv-vm` | `europe-west1-b` / `e2-small` |
| Firewall intra-VPC | `applocker-allow-internal` | Permite TCP/UDP/ICMP entre subredes |

> ⚠️ **No se crea Cloud NAT en este lab** (la subred privada no tiene salida a Internet — es deliberado para mostrar el aislamiento).

---

## 3. Estructura de directorios objetivo

```
~/labs/m2-modular/
└── infra/
    ├── modules/
    │   ├── network/
    │   │   ├── versions.tf
    │   │   ├── variables.tf
    │   │   ├── main.tf
    │   │   └── outputs.tf
    │   └── compute/
    │       ├── versions.tf
    │       ├── variables.tf
    │       ├── main.tf
    │       └── outputs.tf
    └── envs/
        └── dev/
            ├── versions.tf
            ├── providers.tf
            ├── backend.tf
            ├── variables.tf
            ├── main.tf
            ├── outputs.tf
            └── terraform.tfvars
```

---

## 4. Pasos del lab

### 4.1 Crear la estructura de directorios (~2 min)

```bash
LAB_DIR="$HOME/labs/m2-modular"
mkdir -p "$LAB_DIR/infra/modules/network"
mkdir -p "$LAB_DIR/infra/modules/compute"
mkdir -p "$LAB_DIR/infra/envs/dev"
cd "$LAB_DIR"
tree -L 3 infra
```

```powershell
$LabDir = Join-Path $HOME "labs\m2-modular"
New-Item -ItemType Directory -Force -Path "$LabDir\infra\modules\network" | Out-Null
New-Item -ItemType Directory -Force -Path "$LabDir\infra\modules\compute" | Out-Null
New-Item -ItemType Directory -Force -Path "$LabDir\infra\envs\dev" | Out-Null
Set-Location $LabDir
Get-ChildItem -Recurse infra | Select-Object FullName
```

---

### 4.2 Módulo `network` (~10 min)

#### 4.2.1 `infra/modules/network/versions.tf`

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

> 🗣️ **Nota**: *"El provider se declara también aquí para que el módulo sea autocontenido. Cuando lo consumamos desde el root, Terraform reutilizará la misma versión ya descargada."*

#### 4.2.2 `infra/modules/network/variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP donde se desplegará la red."
}

variable "network_name" {
  type        = string
  description = "Nombre de la VPC."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.network_name))
    error_message = "El nombre debe empezar por minúscula y contener solo minúsculas, dígitos o guiones."
  }
}

variable "region" {
  type        = string
  description = "Región GCP para las subredes (ambas en la misma región)."
}

variable "public_subnet_name" {
  type        = string
  description = "Nombre de la subred pública."
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR de la subred pública (formato a.b.c.d/n)."

  validation {
    condition     = can(cidrnetmask(var.public_subnet_cidr))
    error_message = "Debe ser un CIDR válido (ej: 10.10.1.0/24)."
  }
}

variable "private_subnet_name" {
  type        = string
  description = "Nombre de la subred privada."
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR de la subred privada (formato a.b.c.d/n)."

  validation {
    condition     = can(cidrnetmask(var.private_subnet_cidr))
    error_message = "Debe ser un CIDR válido (ej: 10.10.2.0/24)."
  }
}
```

#### 4.2.3 `infra/modules/network/main.tf`

```hcl
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "public" {
  project       = var.project_id
  name          = var.public_subnet_name
  ip_cidr_range = var.public_subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id

  # Sin private_ip_google_access: la subred pública sí tiene salida directa a Internet
  # (las VMs con access_config pueden hablar hacia fuera).
}

resource "google_compute_subnetwork" "private" {
  project       = var.project_id
  name          = var.private_subnet_name
  ip_cidr_range = var.private_subnet_cidr
  region        = var.region
  network       = google_compute_network.this.id

  # Activamos private_ip_google_access para que las VMs privadas puedan
  # hablar con APIs de GCP (GCS, Secret Manager...) sin Cloud NAT.
  # Para Internet genérico necesitaríamos Cloud NAT — fuera de scope de este lab.
  private_ip_google_access = true
}

# Firewall que permite tráfico interno entre las dos subredes de esta VPC.
# Es la pieza que hace que las VMs "se vean entre sí".
resource "google_compute_firewall" "allow_internal" {
  project = var.project_id
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.this.name

  source_ranges = [var.public_subnet_cidr, var.private_subnet_cidr]

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  description = "Permite tráfico interno entre las subredes de la VPC ${var.network_name}."
}
```

> 🗣️ **Nota**: *"El firewall `allow_internal` es lo único que une lógica y red. Sin él, el `ping` desde la VM pública a la privada se queda en silencio aunque estén en la misma VPC. La nube no es 'todo abierto por defecto'."*

#### 4.2.4 `infra/modules/network/outputs.tf`

```hcl
output "network_self_link" {
  value       = google_compute_network.this.self_link
  description = "Self-link de la VPC (úsalo desde otros módulos que necesiten referenciarla)."
}

output "network_id" {
  value       = google_compute_network.this.id
  description = "ID de la VPC."
}

output "public_subnet_self_link" {
  value       = google_compute_subnetwork.public.self_link
  description = "Self-link de la subred pública."
}

output "public_subnet_name" {
  value       = google_compute_subnetwork.public.name
  description = "Nombre de la subred pública."
}

output "private_subnet_self_link" {
  value       = google_compute_subnetwork.private.self_link
  description = "Self-link de la subred privada."
}

output "private_subnet_name" {
  value       = google_compute_subnetwork.private.name
  description = "Nombre de la subred privada."
}
```

#### 4.2.5 Validar el módulo `network` aislado

```bash
cd ~/labs/m2-modular/infra/modules/network
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

```powershell
Set-Location "$HOME\labs\m2-modular\infra\modules\network"
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

Salida esperada:

```
Success! The configuration is valid.
```

> 🗣️ **Nota**: *"`init -backend=false` evita que el módulo intente conectarse al backend GCS. No queremos state aquí — los módulos secundarios NO deben tener state propio. El state vive solo en el root."*

---

### 4.3 Módulo `compute` (~8 min)

#### 4.3.1 `infra/modules/compute/versions.tf`

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

#### 4.3.2 `infra/modules/compute/variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "zone" {
  type        = string
  description = "Zona donde se crearán las VMs."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "Tipo de máquina para ambas VMs."
}

variable "image" {
  type        = string
  default     = "debian-cloud/debian-12"
  description = "Imagen base (project/family)."
}

variable "network_self_link" {
  type        = string
  description = "Self-link de la VPC donde se conectarán las VMs."
}

variable "public_subnet_self_link" {
  type        = string
  description = "Self-link de la subred pública."
}

variable "private_subnet_self_link" {
  type        = string
  description = "Self-link de la subred privada."
}

variable "public_vm_name" {
  type        = string
  description = "Nombre de la VM pública."
}

variable "private_vm_name" {
  type        = string
  description = "Nombre de la VM privada."
}
```

#### 4.3.3 `infra/modules/compute/main.tf`

```hcl
# VM PÚBLICA — tiene IP externa efímera, sirve como "puerta de entrada".
# Solo esta VM es accesible desde Internet.
resource "google_compute_instance" "public" {
  project      = var.project_id
  zone         = var.zone
  name         = var.public_vm_name
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = var.network_self_link
    subnetwork = var.public_subnet_self_link

    # access_config con bloque vacío = IP externa efímera (la asigna GCP).
    access_config {}
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  labels = {
    role     = "public"
    lab      = "m2-modular"
    managed  = "terraform"
  }
}

# VM PRIVADA — sin IP externa, solo accesible desde dentro de la VPC.
# Para llegar a ella hay que pasar por la VM pública (SSH bastion).
resource "google_compute_instance" "private" {
  project      = var.project_id
  zone         = var.zone
  name         = var.private_vm_name
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = var.network_self_link
    subnetwork = var.private_subnet_self_link

    # Sin access_config = sin IP externa. Solo IP interna (10.10.2.x).
  }

  # Permite IAP (Identity-Aware Proxy) para SSH sin IP externa.
  # Útil más adelante en M4 cuando veamos patrones de bastión seguro.
  metadata = {
    enable-oslogin = "TRUE"
  }

  labels = {
    role     = "private"
    lab      = "m2-modular"
    managed  = "terraform"
  }
}
```

> 🗣️ **Nota**: *"Fíjate en la asimetría: la VM pública tiene `access_config {}` (un bloque vacío = IP efímera). La privada NO tiene ese bloque, así que GCP no le asigna IP externa. Es exactamente la diferencia entre 'puerta abierta al mundo' y 'vive solo dentro de la VPC'."*

#### 4.3.4 `infra/modules/compute/outputs.tf`

```hcl
output "public_vm_name" {
  value       = google_compute_instance.public.name
  description = "Nombre de la VM pública."
}

output "public_vm_internal_ip" {
  value       = google_compute_instance.public.network_interface[0].network_ip
  description = "IP interna de la VM pública."
}

output "public_vm_external_ip" {
  value       = google_compute_instance.public.network_interface[0].access_config[0].nat_ip
  description = "IP externa (efímera) de la VM pública — necesaria para SSH desde el formador."
}

output "private_vm_name" {
  value       = google_compute_instance.private.name
  description = "Nombre de la VM privada."
}

output "private_vm_internal_ip" {
  value       = google_compute_instance.private.network_interface[0].network_ip
  description = "IP interna de la VM privada — la que usaremos para el ping."
}
```

#### 4.3.5 Validar el módulo `compute` aislado

```bash
cd ~/labs/m2-modular/infra/modules/compute
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

```powershell
Set-Location "$HOME\labs\m2-modular\infra\modules\compute"
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

---

### 4.4 Root module en `infra/envs/dev/` (~12 min)

> 🗣️ **Nota del formador**: *"Aquí el root se convierte en el 'director de orquesta'. No crea VPCs ni VMs directamente: llama a los módulos. La complejidad vive en los módulos; el root solo compone."*

#### 4.4.1 `infra/envs/dev/versions.tf`

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

#### 4.4.2 `infra/envs/dev/providers.tf`

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
```

#### 4.4.3 `infra/envs/dev/backend.tf`

```hcl
# Reutilizamos el bucket de state del M1.
# El prefijo `modular/dev` separa este estado del de M1.
terraform {
  backend "gcs" {
    bucket = "applocker-tf-state-<sufijo>"  # <-- CAMBIAR por el sufijo del alumno
    prefix = "modular/dev"
  }
}
```

> ⚠️ **Cambiar `<sufijo>`** por el identificador único del alumno (el mismo que usó en M1).

#### 4.4.4 `infra/envs/dev/variables.tf`

```hcl
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP."
}

variable "region" {
  type        = string
  default     = "europe-west1"
  description = "Región GCP."
}

variable "zone" {
  type        = string
  default     = "europe-west1-b"
  description = "Zona GCP para las VMs."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "Tipo de máquina para ambas VMs."
}

variable "network_name" {
  type        = string
  default     = "applocker-vpc"
  description = "Nombre de la VPC."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.10.1.0/24"
  description = "CIDR de la subred pública."
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.10.2.0/24"
  description = "CIDR de la subred privada."
}
```

#### 4.4.5 `infra/envs/dev/terraform.tfvars`

```hcl
project_id = "TU-PROYECTO-GCP"  # <-- CAMBIAR por el project_id real del alumno

# El resto tiene defaults razonables vía variables.tf.
```

#### 4.4.6 `infra/envs/dev/main.tf` (el root)

```hcl
# ─────────────────────────────────────────────────────────────────────────────
# ROOT MODULE
# Compone los módulos network + compute para el entorno `dev`.
# Toda la gestión (init/plan/apply/destroy) se ejecuta desde aquí.
# ─────────────────────────────────────────────────────────────────────────────

module "network" {
  source = "../../modules/network"

  project_id = var.project_id
  region     = var.region

  network_name        = var.network_name
  public_subnet_name  = "${var.network_name}-pub"
  private_subnet_name = "${var.network_name}-priv"

  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
}

module "compute" {
  source = "../../modules/compute"

  project_id = var.project_id
  zone       = var.zone
  machine_type = var.machine_type

  # Cableamos los outputs del módulo network hacia los inputs del módulo compute.
  network_self_link        = module.network.network_self_link
  public_subnet_self_link  = module.network.public_subnet_self_link
  private_subnet_self_link = module.network.private_subnet_self_link

  public_vm_name  = "${var.network_name}-pub-vm"
  private_vm_name = "${var.network_name}-priv-vm"
}
```

> 🗣️ **Nota**: *"Mirad cómo el root solo cablea: `module.network.public_subnet_self_link` alimenta `module.compute.public_subnet_self_link`. Esa dependencia implícita hace que Terraform sepa el orden correcto: primero red, luego compute. Nada de `depends_on` manual — el grafo de Terraform lo resuelve solo."*

#### 4.4.7 `infra/envs/dev/outputs.tf`

```hcl
output "network_name" {
  value       = module.network.network_self_link
  description = "Self-link de la VPC creada."
}

output "public_subnet_name" {
  value       = module.network.public_subnet_name
  description = "Nombre de la subred pública."
}

output "private_subnet_name" {
  value       = module.network.private_subnet_name
  description = "Nombre de la subred privada."
}

output "public_vm_name" {
  value       = module.compute.public_vm_name
  description = "Nombre de la VM pública."
}

output "public_vm_external_ip" {
  value       = module.compute.public_vm_external_ip
  description = "IP externa de la VM pública (para SSH)."
}

output "private_vm_name" {
  value       = module.compute.private_vm_name
  description = "Nombre de la VM privada."
}

output "private_vm_internal_ip" {
  value       = module.compute.private_vm_internal_ip
  description = "IP interna de la VM privada — el target del ping."
}
```

---

### 4.5 Plan + Apply desde el root (~5 min)

> 🗣️ **Nota del formador**: *"A partir de aquí, todos los comandos se ejecutan SIEMPRE desde `infra/envs/dev`. Nunca desde `modules/`. El root es el único punto de verdad."*

```bash
cd ~/labs/m2-modular/infra/envs/dev

terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

```powershell
Set-Location "$HOME\labs\m2-modular\infra\envs\dev"

terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Salida esperada del apply (resumen):

```
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

Outputs:
+ network_name            = "https://www.googleapis.com/compute/v1/projects/.../networks/applocker-vpc"
+ private_subnet_name     = "applocker-vpc-priv"
+ private_vm_internal_ip  = "10.10.2.2"
+ private_vm_name         = "applocker-vpc-priv-vm"
+ public_subnet_name      = "applocker-vpc-pub"
+ public_vm_external_ip   = "34.1.2.3"
+ public_vm_name          = "applocker-vpc-pub-vm"
```

> 🗣️ **Nota**: *"6 recursos en un solo `apply`. Una VPC, dos subredes, un firewall, dos VMs. ¿Veis cómo el root no tiene ni una sola línea de `resource`? Toda la carne está en los módulos. Esa es la potencia del patrón."*

---

### 4.6 Verificación de conectividad VM pública → VM privada (~3 min)

#### 4.6.1 Obtener la IP externa de la VM pública

```bash
terraform output -raw public_vm_external_ip
```

```powershell
terraform output -raw public_vm_external_ip
```

#### 4.6.2 SSH a la VM pública desde el formador/alumno

```bash
# Ajusta la zona si difiere
gcloud compute ssh applocker-vpc-pub-vm \
  --project="$(terraform output -raw network_name | awk -F/ '{print $5}')" \
  --zone="europe-west1-b"
```

```powershell
# PowerShell: equivalente vía gcloud
gcloud compute ssh applocker-vpc-pub-vm --project="TU-PROYECTO" --zone="europe-west1-b"
```

#### 4.6.3 Desde dentro de la VM pública, hacer ping a la privada

```bash
PRIV_IP=$(gcloud compute instances describe applocker-vpc-priv-vm \
  --zone="europe-west1-b" \
  --format="get(networkInterfaces[0].networkIP)")

echo "IP privada: $PRIV_IP"
ping -c 4 "$PRIV_IP"
```

Salida esperada:

```
IP privada: 10.10.2.2
PING 10.10.2.2 (10.10.2.2) 56(84) bytes of data.
64 bytes from 10.10.2.2: icmp_seq=1 ttl=64 time=1.23 ms
64 bytes from 10.10.2.2: icmp_seq=2 ttl=64 time=0.98 ms
64 bytes from 10.10.2.2: icmp_seq=3 ttl=64 time=1.05 ms
64 bytes from 10.10.2.2: icmp_seq=4 ttl=64 time=1.11 ms
```

> ✅ **Resultado esperado**: la VM pública ve a la privada por IP interna. El firewall `allow_internal` y que ambas estén en la misma VPC hacen el trabajo.

#### 4.6.4 Demostración inversa (sin NAT → no hay salida a Internet desde la privada)

Desde la VM pública, haz SSH a la privada:

```bash
gcloud compute ssh applocker-vpc-priv-vm \
  --zone="europe-west1-b" \
  --ssh-flag="-o ProxyCommand='gcloud compute ssh applocker-vpc-pub-vm --zone=europe-west1-b --command=nc %h %p'"
```

Y dentro de la VM privada:

```bash
ping -c 2 8.8.8.8
```

Salida esperada:

```
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
--- 8.8.8.8 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss
```

> 🗣️ **Nota**: *"Esto NO es un bug. Es lo esperado: la subred privada está aislada de Internet. En M6 veremos Cloud NAT para darle salida controlada. Hoy la lección es entender la separación pública/privada."*

---

## 5. Resultado esperado

- Estructura de 2 módulos secundarios compilando localmente.
- 1 root module (`envs/dev`) que los compone.
- 6 recursos en GCP: 1 VPC, 2 subredes, 1 firewall, 2 VMs.
- VMs en subredes distintas pero **conectadas por IP interna**.
- `terraform plan` muestra **0 cambios** tras el apply (state consistente).
- Ping `VM pública → VM privada` ✅.
- Ping `VM privada → 8.8.8.8` ❌ (sin NAT, esperado).

---

## 5.b Ejercicio consolidador (~5 min)


El alumno debe **modificar el sistema modular en caliente** (sin rehacer el lab desde cero). El cambio sigue siendo pequeño pero toca las 3 capas (módulo secundario → módulo consumidor → root).

### Reto A — Añadir una etiqueta común a toda la infra

**Objetivo**: que todos los recursos del lab lleven una etiqueta extra `course = "terraform-m2"`, definida en **un único sitio** y propagada automáticamente a `network` y `compute`.


### Reto B — Añadir una regla de firewall mínima y realista

**Objetivo**: limitar el firewall interno a **solo ICMP y TCP/22** (preparando el terreno para que M4 aplique reglas estrictas). El alumno descubre que **modificar un módulo implica releer su contrato**.

---

## 6. Limpieza

> 🗣️ **SIEMPRE** ejecutar destroy al final del lab. Recursos huérfanos = coste inesperado.

```bash
cd ~/labs/m2-modular/infra/envs/dev
terraform destroy -auto-approve
```

```powershell
Set-Location "$HOME\labs\m2-modular\infra\envs\dev"
terraform destroy -auto-approve
```

Salida esperada:

```
Destroy complete! Resources: 6 destroyed.
```

Verificación adicional:

```bash
# Confirmar que no quedan VMs del lab
gcloud compute instances list --filter="labels:lab=m2-modular" --format="table(name,zone,status)"
```

```powershell
gcloud compute instances list --filter="labels:lab=m2-modular" --format="table(name,zone,status)"
```

Salida esperada: lista vacía.

Borrar el directorio local (opcional):

```bash
rm -rf ~/labs/m2-modular
```

```powershell
Remove-Item -Recurse -Force "$HOME\labs\m2-modular"
```

---

## 7. Errores comunes que el formador debe prevenir

| # | Error típico | Síntoma | Cómo prevenirlo en vivo |
|---|---|---|---|
| 1 | Olvidar el firewall `allow_internal` | El ping entre VMs se queda colgado sin respuesta. | Antes del `apply`, pedir al alumno que lea en voz alta el bloque `google_compute_firewall` y explique qué tráfico abre. |
| 2 | Poner `access_config {}` también en la VM privada | La VM privada obtiene IP externa y pierde el sentido del lab. | Mostrar el diff entre ambas VMs: la pública tiene `access_config`, la privada NO. |
| 3 | Declarar el provider en `envs/dev/providers.tf` con una versión distinta a la de los módulos | `terraform init` se queja de provider version mismatch. | Insistir en que las 3 `versions.tf` (network, compute, dev) compartan `~> 5.0`. |
| 4 | Ejecutar `terraform plan` desde dentro de `modules/network` o `modules/compute` | El módulo intenta buscar state/backend y falla. | Regla de oro: "init/plan/apply/destroy SOLO desde el root (`envs/dev`)". |
| 5 | Olvidar cambiar el sufijo del bucket en `backend.tf` | `terraform init` falla con 404 sobre `applocker-tf-state-<sufijo>`. | Pedir al alumno que copie el bucket EXACTO del M1 (de su `terraform.tfvars` o de la consola GCP). |
| 6 | Meter `private_ip_google_access = false` en la subred privada | La VM privada tampoco puede hablar con APIs de GCP (GCS, Secret Manager). | Explicar la diferencia entre "salida a Internet" (NAT) y "salida a APIs de GCP" (private_google_access). |

---

## 8. Notas para el formador

- **Tiempo real**: 40 min es el optimista. Si el cohort va justo, recortar la sección 4.6.4 (demo del ping a 8.8.8.8) — la idea conceptual ya queda clara con la explicación.
- **Por qué NO Cloud NAT en este lab**: NAT añade un recurso más (router + NAT) y otro módulo (network se complicaría). El foco de M2 es **módulos**, no networking avanzado. NAT se cubre en M6 (Cloud SQL Private Service Access, Serverless VPC Access, etc.).
- **Por qué el firewall permite TODO el rango de puertos internamente**: es un lab, no prod. En producción se limitaría a puertos específicos (22 para SSH, 5432 para Postgres, etc.). M4 (seguridad) retoma este punto.
- **Reaprovechamiento en M3 y M4**: estos mismos módulos `network` y `compute` se reutilizarán como base del proyecto AppLocker. El alumno verá que el patrón "extraer módulo cuando algo se reutiliza" se paga desde el primer minuto.
- **Si el alumno pregunta por `for_each`**: pertenece a M6. Aquí cada recurso es único (1 VPC, 2 subredes, 2 VMs) — no tiene sentido parametrizar todavía.
- **Pista para Q&A**: si alguien pregunta "¿y si quisiera la VM privada en otra zona?", la respuesta es: "cambia `var.zone` en el root y aplica — el módulo `compute` está parametrizado para soportarlo". Esto demuestra el valor del módulo frente al monolito.

---

## 9. Referencias oficiales

- Terraform Modules — <https://developer.hashicorp.com/terraform/language/modules>
- Module sources (local paths) — <https://developer.hashicorp.com/terraform/language/modules/sources#local-paths>
- Module development best practices — <https://developer.hashicorp.com/terraform/language/modules/develop>
- `google_compute_network` — <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network>
- `google_compute_subnetwork` — <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork>
- `google_compute_firewall` — <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall>
- `google_compute_instance` — <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance>
- Private Google Access — <https://cloud.google.com/vpc/docs/configure-private-google-access>

---

## 10. Conexión con el resto del M2

```
Lab 1 (5 min)   → detectar duplicación
Lab 2 (15 min)  → esqueleto módulo cloudsql
Lab 2.1 (40 min) → sistema modular end-to-end  ← ESTE LAB
Lab 3 (10 min)  → consumir del Public Registry
Lab 4 (15 min)  → publicar/consumir de GCS Private Registry
```

Este lab es el **puente** entre "sabes la teoría de módulos" y "sabes versionar/publicar módulos". Aquí se ve el **valor** del patrón; en Labs 3 y 4 se aprende a **compartirlo**.