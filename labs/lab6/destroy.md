# Destroy total obligatorio (fin del curso)

> ⚠️ **Este paso ES OBLIGATORIO al cerrar el curso**. En el lab-4 §11 advertimos "no borrar la infraestructura — todavía la necesitamos en M5 y M6". Como este M6 es el último módulo, **ahora sí se destruye todo**. Antes de empezar:
>
> - Avisa al formador y al compañero de mesa.
> - Captura el output de `terraform state list` de cada sub-stack **antes** del destroy (evidencia del estado final del curso).
> - Verifica que la última `terraform plan` de cada stack devuelve **"No changes"** (si no, `terraform apply` primero hasta dejar todo limpio).

### 16.1 Orden estricto de destrucción

Terraform destruye en orden inverso al de creación: lo que se creó último, se destruye primero. La jerarquía de dependencias entre sub-stacks es:

```
root (envs/dev) → cache → iam → cloudsql → compute → network
```

Reglas críticas:
- `network` se destruye **el último** (VPC + subnets + NAT + firewall + reglas). Si se destruye antes que `compute`/`cloudsql`, GCP rechaza el destroy porque las VMs y la instancia Cloud SQL siguen referenciando subnets.
- `compute` se destruye **antes** que `network` (las VMs y el MIG dependen de la VPC).
- `cloudsql` se destruye **antes** que `network` (la instancia privada cuelga de la subnet `data`).
- `cache` (Memorystore) se destruye **antes** que `network` (autorizada con la VPC).
- `iam` (SA + bindings) se destruye **antes** que `compute` (las VMs llevan la SA adjunta).
- `root` (envs/dev) se destruye **el último** porque contiene los secretos y el `google_sql_user` que aún no se han borrado.
- El bucket de state remoto (`gs://applocker-tf-state-<sufijo>`) **NO se destruye** dentro de Terraform: se borra a mano al final con `gsutil`, y **solo si el formador lo confirma**.

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

```bash
# 1. cache (Memorystore) — lo más nuevo, primero
cd infra/envs/dev
terraform destroy -auto-approve

# 2. iam (SA app + 4 bindings) — independiente pero lo destruimos antes que compute
cd ../../modules/iam
terraform init -upgrade
terraform destroy -auto-approve

# 3. cloudsql (PostgreSQL privado + backups)
cd ../../cloudsql
terraform destroy -auto-approve

# 4. compute (MIG + health check + resource_policy de snapshots).
#    Primero la snapshot policy sola, luego el resto, por dependencias
#    de la resource_policy sobre el instance template.
cd ../../compute
terraform destroy -target=google_compute_resource_policy.backend_snapshot -auto-approve
terraform destroy -auto-approve

# 5. network (VPC + subnets + NAT + firewall) — SIEMPRE EL ÚLTIMO
cd ../../network
terraform destroy -auto-approve
```

```powershell
# 1. cache (Memorystore) — lo más nuevo, primero
Set-Location infra\envs\dev
terraform destroy -auto-approve

# 2. iam (SA app + 4 bindings)
Set-Location ..\..\modules\iam
terraform init -upgrade
terraform destroy -auto-approve

# 3. cloudsql (PostgreSQL privado + backups)
Set-Location ..\..\cloudsql
terraform destroy -auto-approve

# 4. compute (MIG + health check + snapshot policy)
Set-Location ..\..\compute
terraform destroy -target=google_compute_resource_policy.backend_snapshot -auto-approve
terraform destroy -auto-approve

# 5. network (VPC + subnets + NAT + firewall) — SIEMPRE EL ÚLTIMO
Set-Location ..\..\network
terraform destroy -auto-approve
```

> **Nota**: *"El `destroy` del root del M4 (§11 original) se ejecutaba después de los sub-stacks porque gestionaba `db_password` y el `google_sql_user`. En este lab-6, el root gestiona `module.cache` (Memstore) y consume los outputs de los sub-stacks vía `data.terraform_remote_state`. Por eso va el **primero** (antes que `iam`): al destruir Redis ya no quedan referencias cruzadas, y al llegar al paso 2 los `data` se evalúan contra un state vacío sin errores."*

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
