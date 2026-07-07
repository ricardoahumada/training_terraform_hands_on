# Destroy total obligatorio (fin del curso)

> ⚠️ **Este paso ES OBLIGATORIO al cerrar el curso**. En el lab-4 §11 advertimos "no borrar la infraestructura — todavía la necesitamos en M5 y M6". Como este M6 es el último módulo, **ahora sí se destruye todo**. Antes de empezar:
>
> - Avisa al formador y al compañero de mesa.
> - Captura el output de `terraform state list` de cada sub-stack **antes** del destroy (evidencia del estado final del curso).
> - Verifica que la última `terraform plan` de cada stack devuelve **"No changes"** (si no, `terraform apply` primero hasta dejar todo limpio).

### 16.1 Orden estricto de destrucción

Terraform destruye en orden inverso al de creación: lo que se creó último, se destruye primero. La jerarquía de dependencias reales entre sub-stacks es:

```
compute    →  root (envs/dev)   (compute lee la SA y labels del root vía data.terraform_remote_state)
cloudsql   →  root (envs/dev)   (cloudsql lee applocker-db-password del root vía data source)
compute    →  network
cloudsql   →  network
compute    →  iam              (compute lleva la SA adjunta)
```

Orden de destroy derivado de esas dependencias (primero lo más "consumidor" de otras dependencias):

```
compute → cloudsql → root (envs/dev) → iam → network
```

Reglas críticas:
- `network` se destruye **el último** (VPC + subnets + NAT + firewall + reglas). Si se destruye antes que `compute`/`cloudsql`, GCP rechaza el destroy porque las VMs y la instancia Cloud SQL siguen referenciando subnets.
- `compute` se destruye **el primero**: su `main.tf` lee la SA del root vía `data.terraform_remote_state.root.outputs.app_service_account_email`. Mientras el root siga vivo, ese `data` resuelve OK.
- `cloudsql` se destruye **después** de compute y **antes** que el root: `cloudsql/main.tf` tiene `data "google_secret_manager_secret_version" "db_password"` que apunta al secreto `applocker-db-password`, que vive en el state del root.
- `root` (`envs/dev`) se destruye **después** de `compute` y `cloudsql`. Es donde viven `module.cache`, los secretos (`db_password`, `redis_endpoint`), el `google_sql_user` y los bindings IAM del `module.iam`. **Destruirlo antes que cloudsql rompe el `refresh` del data source del secreto** (ver §16.1.1).
- `iam` (SA + bindings) se destruye después del root: para entonces ni `compute` ni `cloudsql` la referencian; GCP no puede borrar una SA que sigue adjunta a una VM.
- El bucket de state remoto (`gs://applocker-tf-state-<sufijo>`) **NO se destruye** dentro de Terraform: se borra a mano al final con `gsutil`, y **solo si el formador lo confirma**.

#### 16.1.1 Trampa real detectada: data source del secreto

> **Origen del error**: ejecutar `terraform destroy` en `cloudsql` **después** de haber destruido `envs/dev` produce:
>
> ```
> Error: Error retrieving available secret manager secret versions:
>   googleapi: Error 404: Secret [projects/<id>/secrets/applocker-db-password] not found or has no versions.
>   with module.cloudsql.data.google_secret_manager_secret_version.db_password,
>   on .terraform/modules/cloudsql/main.tf line 47, in data "google_secret_manager_secret_version" "db_password":
>   47: data "google_secret_manager_secret_version" "db_password" {
> ```
>
> El data source falla en el `refresh` previo al `destroy` aunque la instancia Cloud SQL a destruir sea nuestra: Terraform consulta el secreto en GCP para validar el grafo de dependencias antes de proceder. Por eso `envs/dev` (donde vive el secreto) va **después** de `cloudsql`.

#### 16.1.2 Trampa detectada: output `common_labels` faltante en el root

> **Origen del error**: ejecutar `terraform destroy` (con o sin `-target`) desde `infra/modules/compute` produce:
>
> ```
> Error: Unsupported attribute
>   on main.tf line 35, in locals:
>   35:   common_labels = data.terraform_remote_state.root.outputs.common_labels
>     ├────────────────
>     │ data.terraform_remote_state.root.outputs is object with no attributes
>   This object does not have an attribute named "common_labels".
> ```
>
> **Causa**: el sub-stack `compute/` (y por patrón cualquier sub-stack) lee los labels comunes del root vía `data.terraform_remote_state.root.outputs.common_labels`. Si el root `envs/dev/outputs.tf` no declara ese output, **cualquier `plan` o `destroy` desde un sub-stack aborta**, aunque el recurso a destruir sea nuestro.
>
> **Fix antes de empezar §16.3**: añadir en `infra/envs/dev/outputs.tf`:
>
> ```hcl
> output "common_labels" {
>   value       = local.common_labels
>   description = "Labels comunes (app/env/team/managed-by/cost-center) consumidos por los sub-stacks."
> }
> ```
>
> Tras añadirlo, ejecutar `terraform apply` desde `envs/dev` **una vez** para que el output quede registrado en el state remoto del root (`envs/dev/root`); sin ese `apply` previo, el `refresh` desde `compute/` sigue sin verlo.

### 16.2 Capturar evidencia previa

```bash
export TF_VAR_project_id="$(gcloud config get-value project)"
export TF_VAR_region="us-central1"
export TF_VAR_env="dev"
export TF_VAR_suffix="<sufijo>"

mkdir -p course-evidence
for stack in envs/dev modules/cloudsql modules/compute modules/network modules/iam; do
  ( cd "infra/$stack" && terraform state list > "../../course-evidence/state-${stack//\//_}.txt" )
done
```

```powershell
$env:TF_VAR_project_id = (gcloud config get-value project)
$env:TF_VAR_region     = "us-central1"
$env:TF_VAR_env        = "dev"
$env:TF_VAR_suffix     = "<sufijo>"

New-Item -ItemType Directory -Force -Path "course-evidence" | Out-Null
$stacks = @("envs\dev","modules\cloudsql","modules\compute","modules\network","modules\iam")
foreach ($stack in $stacks) {
  Set-Location "infra\$stack"
  $name = ($stack -replace "\\","_")
  terraform state list | Out-File "..\..\course-evidence\state-$name.txt"
}
Set-Location ..\..\
```

### 16.3 Destroy por sub-stack (orden estricto)

> ⚠️ **Antes de cada `-target`, valida con `terraform state list | grep <recurso>`** desde el directorio del sub-stack. Si el recurso no aparece, Terraform rechaza el `-target` con `Invalid target ... Resource specification must include a resource type and name` aunque la sintaxis sea correcta. Caso típico: el alumno nunca desplegó M4 desde el path que está mirando Terraform, y el state no contiene `google_compute_resource_policy.backend_snapshot`.

```bash
# 1. compute: primero porque tiene data.terraform_remote_state hacia el root.
#    Antes, snapshot policy sola por dependencias con el instance template.
cd infra/modules/compute

# Validar que el recurso existe en ESTE state antes de apuntar -target.
# Si el grep no devuelve nada, skip directo al `terraform destroy` general.
if terraform state list | grep -q 'google_compute_resource_policy.backend_snapshot'; then
  terraform destroy -target=google_compute_resource_policy.backend_snapshot -auto-approve
fi
terraform destroy -auto-approve

# 2. cloudsql: segundo, ANTES del root. Si el root ya está vacío,
#    el data source del secreto applocker-db-password falla con 404
#    en el refresh previo al destroy (ver §16.1.1).
cd ../cloudsql
terraform destroy -auto-approve

# 3. root (envs/dev): AHORA sí. Borra module.cache, secretos (db_password,
#    redis_endpoint), sql_user y los module.iam referenciados. Para entonces
#    ni compute ni cloudsql quedan en el proyecto, así que no hay data
#    source apuntando a recursos huérfanos.
cd ../../envs/dev
terraform destroy -auto-approve

# 4. iam: SA ya no está adjunta a ninguna VM porque compute la soltó en el paso 1.
cd ../../modules/iam
terraform init -upgrade
terraform destroy -auto-approve

# 5. network: SIEMPRE el último. VPC + subnets + NAT + firewall.
cd ../network
terraform destroy -auto-approve
```

```powershell
# 1. compute
Set-Location infra\modules\compute

# Validar que el recurso existe en ESTE state antes de apuntar -target.
# Si no aparece, skip directo al `terraform destroy` general.
#
# IMPORTANTE PowerShell: `terraform state list` emite objetos, no strings.
# `Select-String -Pattern` por pipeline falla con "InputObjectNotBound".
# Hay que forzar la conversión a string con `Out-String` (o `| %{ $_ }`).
$resourceAddress = 'google_compute_resource_policy.backend_snapshot'
if (terraform state list | Out-String | Select-String -Pattern ([regex]::Escape($resourceAddress))) {
  # PowerShell: usar espacio, no '='. La forma -target=valor falla con
  # "Too many command line arguments" en algunas versiones de Terraform
  # porque PowerShell expande '=' antes de pasar argumentos al proceso.
  terraform destroy -target $resourceAddress -auto-approve
}
terraform destroy -auto-approve

# 2. cloudsql (ANTES del root — ver §16.1.1)
Set-Location ..\cloudsql
terraform destroy -auto-approve

# 3. root (envs/dev): borra cache + secretos + sql_user
Set-Location ..\..\envs\dev
terraform destroy -auto-approve

# 4. iam: SA ya sin VMs adjuntas
Set-Location ..\..\modules\iam
terraform init -upgrade
terraform destroy -auto-approve

# 5. network: SIEMPRE el último
Set-Location ..\network
terraform destroy -auto-approve
```

> **PowerShell: usa espacio después de `-target`, no `=`**:
> ```powershell
> # Correcto (cualquier shell)
> terraform destroy -target google_compute_resource_policy.backend_snapshot -auto-approve
>
> # Funciona en Bash, pero en PowerShell puede dar:
> #   "Error: Too many command line arguments"
> #   "Error: Invalid target ... must include a resource type and name"
> terraform destroy -target=google_compute_resource_policy.backend_snapshot -auto-approve
> ```

> **Por qué este orden y no el del M4 §11**: el `lab-4.md` original ponía el root **el último** de los sub-stacks. Aquí mantenemos la misma idea (root al final), pero subimos `compute` y `cloudsql` por delante porque **ambos leen recursos del root** (uno vía `data.terraform_remote_state`, otro vía `data "google_secret_manager_secret_version"`). Destruir el root primero rompe las dos lecturas, no una sola.

### 16.4 Limpieza de humo post-destroy

```bash
# SA ad-hoc del smoke test del M4 §9.5, si quedó creada
gcloud iam service-accounts delete \
  "sa-applocker-smoke-test@${TF_VAR_project_id}.iam.gserviceaccount.com" \
  --project=${TF_VAR_project_id} --quiet

# Bucket de snapshots efímero del §10.1, si quedó creado
gsutil rm -r gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/
gsutil rb gs://${TF_STATE_BUCKET}-snapshots-${TF_VAR_env}/
```

```powershell
# SA ad-hoc del smoke test del M4 §9.5, si quedó creada
gcloud iam service-accounts delete `
  "sa-applocker-smoke-test@$env:TF_VAR_project_id.iam.gserviceaccount.com" `
  --project=$env:TF_VAR_project_id --quiet

# Bucket de snapshots efímero del §10.1, si quedó creado
gcloud storage rm -r gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/
gcloud storage buckets delete gs://$env:TF_STATE_BUCKET-snapshots-$env:TF_VAR_env/
```

### 16.5 Bucket de state remoto (opcional, solo con confirmación del formador)

```bash
# Listar versiones del bucket ANTES de borrar (evidencia)
gsutil ls -a gs://${TF_STATE_BUCKET}/ | tee course-evidence/state-bucket-versions.txt

# Vaciar y borrar el bucket SOLO si el formador lo autoriza
gsutil -m rm -r gs://${TF_STATE_BUCKET}/
gsutil rb gs://${TF_STATE_BUCKET}/
```

```powershell
# Listar versiones del bucket ANTES de borrar (evidencia)
gcloud storage ls --all-versions gs://$env:TF_STATE_BUCKET/ | Out-File course-evidence\state-bucket-versions.txt

# Vaciar y borrar el bucket SOLO si el formador lo autoriza
gcloud storage rm -r gs://$env:TF_STATE_BUCKET/
gcloud storage buckets delete gs://$env:TF_STATE_BUCKET/
```

> ⚠️ **El bucket contiene el historial de state de todo el curso (M1–M6)**. Si lo borrás, perdés la trazabilidad de qué se desplegó y cuándo. **Confirmá con el formador antes de ejecutar §16.5.** En la mayoría de las ediciones del curso, el bucket se conserva hasta la auditoría final del proveedor.

### 16.6 Verificación post-destroy

```bash
# No deben quedar recursos AppLocker en el proyecto
gcloud projects get-iam-policy ${TF_VAR_project_id} \
  --flatten="bindings[].members" \
  --filter="bindings.members:sa-app-dev-${TF_VAR_suffix}@" \
  --format="table(bindings.role)"

gcloud compute instances list --project=${TF_VAR_project_id} \
  --filter="name~'applocker'" --format="table(name,zone,status)"

gcloud sql instances list --project=${TF_VAR_project_id} \
  --filter="name~'applocker'" --format="table(name,region,state)"

gcloud redis instances list --project=${TF_VAR_project_id} \
  --region=${TF_VAR_region} --filter="name~'applocker-cache'" \
  --format="table(name,tier,state)"

gcloud compute networks list --project=${TF_VAR_project_id} \
  --filter="name~'applocker'" --format="table(name,subnet_mode)"
```

```powershell
# No deben quedar recursos AppLocker en el proyecto
gcloud projects get-iam-policy $env:TF_VAR_project_id `
  --flatten="bindings[].members" `
  --filter="bindings.members:sa-app-dev-$env:TF_VAR_suffix@" `
  --format="table(bindings.role)"

gcloud compute instances list --project=$env:TF_VAR_project_id `
  --filter="name~'applocker'" --format="table(name,zone,status)"

gcloud sql instances list --project=$env:TF_VAR_project_id `
  --filter="name~'applocker'" --format="table(name,region,state)"

gcloud redis instances list --project=$env:TF_VAR_project_id `
  --region=$env:TF_VAR_region --filter="name~'applocker-cache'" `
  --format="table(name,tier,state)"

gcloud compute networks list --project=$env:TF_VAR_project_id `
  --filter="name~'applocker'" --format="table(name,subnet_mode)"
```

Las 5 queries deben devolver **tablas vacías** (o el header solo). Si alguna devuelve recursos, repite el paso correspondiente del §16.3 antes de cerrar el curso.

### 16.7 Commit de cierre

```bash
git add .
git commit -m "chore(m6): document full course teardown procedure"
git push origin main
```

```powershell
git add . ; git commit -m "chore(m6): document full course teardown procedure"
git push origin main
```
