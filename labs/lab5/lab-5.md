# Lab 1 — Pipeline GitOps para AppLocker

> **Guion del formador** — Lab integrador del Módulo 5.
> **Duración estimada**: 75 minutos.
> **Caso AppLocker**: cerrar el círculo de GitOps. Cualquier cambio a la infra pasa por PR, se valida, se planea, se valida con políticas OPA y se aplica con gate humano.

---

## 0. Objetivo general

Al terminar este lab, se habrá:

- Creado un workspace en **Terraform Cloud** vinculado al bucket GCS del M1.
- Configurado **Workload Identity Federation** para que GitHub Actions se autentique contra GCP sin JSON keys.
- Construido el workflow `terraform-plan.yml` (PR) que ejecuta `fmt + validate + plan + conftest`.
- Construido el workflow `terraform-apply.yml` (push a main) con gate manual vía GitHub Environment.
- Construido el workflow `terraform-drift.yml` (cron) que abre issues si detecta drift.
- Creado **5 políticas OPA/Conftest** que bloquean anti-patrones (región, labels, Cloud SQL, tipos de máquina, buckets públicos).
- Validado el flujo completo con un PR real.

---

## 1. Prerrequisitos

Haber completado M1-M4:

```bash
# Repositorio con el código de M1-M4
ls infra/envs/dev

# Bucket GCS accesible
gcloud storage ls gs://${TF_STATE_BUCKET}/terraform/state/

# SA terraform-applocker-prd con permisos
gcloud iam service-accounts list \
  --project=${TF_VAR_project_id} \
  --filter="email~'terraform-applocker-.*'"

# Secretos en Secret Manager
gcloud secrets list --project=${TF_VAR_project_id} \
  --filter="name~'applocker-'"
```

```powershell
# Repositorio con el código de M1-M4
Get-ChildItem infra\envs\dev

# Bucket GCS accesible
gcloud storage ls gs://$env:TF_STATE_BUCKET/terraform/state/

# SA terraform-applocker-prd con permisos
gcloud iam service-accounts list `
  --project=$env:TF_VAR_project_id `
  --filter="email~'terraform-applocker-.*'"

# Secretos en Secret Manager
gcloud secrets list --project=$env:TF_VAR_project_id `
  --filter="name~'applocker-'"
```

Cuentas/herramientas:

- Terraform Cloud (cuenta gratuita válida para el curso).
- Cuenta de GitHub con permisos para crear repositorios y GitHub Apps.
- `gcloud`, `terraform` y `gh` CLI instalados y autenticados.

---

## 2. Recursos necesarios

- 1 workspace de Terraform Cloud.
- 1 Workload Identity Pool + 1 Provider OIDC en GCP.
- 3 archivos de workflow en `.github/workflows/`.
- 5 archivos de políticas OPA en `envs/prd/policies/`.
- 1 GitHub Environment `production` con reviewer.
- Tiempo total estimado: ~1h 15min.

---

## 3. Parte 1 — Crear el workspace de Terraform Cloud (~10 min)

### 3.1 Crear la organización en TFC

1. Ir a <https://app.terraform.io/>.
2. Crear cuenta gratuita (si no se tiene).
3. Crear organización: `applocker-<sufijo>`.

### 3.2 Crear el workspace

1. **Workspaces → New workspace**.
2. Tipo: **CLI-driven workflow** (queremos gestionar el state en GCS, no en TFC).
   - **Nota**: si se elige **Version control workflow**, TFC gestiona los runs automáticamente. Para este lab, **CLI-driven** es más explícito.
3. Nombre: `applocker-prd`.
4. Execution mode: **Remote** (los planes corren en infraestructura de TFC).
5. Apply method: **Auto apply** (desactivado — queremos gate manual).

### 3.3 Vincular el state al bucket GCS (no al storage interno de TFC)

En `infra/envs/prd/backend.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "tf-state-applocker-eu-<sufijo>"
    prefix = "envs/prd"
  }
}
```

> **Nota**: *"El state sigue en GCP. TFC solo orquesta los runs. Esto evita Vendor lock-in: si mañana migramos a Atlantis o a GitHub Actions puro, el state no se mueve."*

### 3.4 Definir variables en TFC

En **Variables** del workspace:

| Variable | Valor | Sensitive |
|---|---|---|
| `TF_VAR_project_id` | `applocker-prd` | No |
| `TF_VAR_region` | `us-central1` | No |

> ⚠️ **NO guardar credenciales GCP en TFC**. El auth va por WIF (Parte 2).

---

## 4. Parte 2 — Configurar Workload Identity Federation (~10 min)

### 4.1 Definir variables

```bash
export PROJECT_ID="applocker-prd"
export POOL_ID="github-actions-pool"
export PROVIDER_ID="github-actions-provider"
export SA="terraform-applocker-prd@${PROJECT_ID}.iam.gserviceaccount.com"
export GITHUB_REPO="mi-org/applocker-iac"   # sustituir por el repo real
```

```powershell
$env:PROJECT_ID = "applocker-prd"
$env:POOL_ID = "github-actions-pool"
$env:PROVIDER_ID = "github-actions-provider"
$env:SA = "terraform-applocker-prd@$env:PROJECT_ID.iam.gserviceaccount.com"
$env:GITHUB_REPO = "mi-org/applocker-iac"   # sustituir por el repo real
```

### 4.2 Crear el Workload Identity Pool

```bash
gcloud iam workload-identity-pools create "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --display-name="GitHub Actions Pool"
```

```powershell
gcloud iam workload-identity-pools create $env:POOL_ID `
  --project=$env:PROJECT_ID `
  --location="global" `
  --display-name="GitHub Actions Pool"
```

### 4.3 Crear el Provider OIDC

```bash
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
```

```powershell
gcloud iam workload-identity-pools providers create-oidc $env:PROVIDER_ID `
  --project=$env:PROJECT_ID `
  --location="global" `
  --workload-identity-pool=$env:POOL_ID `
  --display-name="GitHub Actions Provider" `
  --issuer-uri="https://token.actions.githubusercontent.com" `
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" `
  --attribute-condition="assertion.repository=='$env:GITHUB_REPO'"
```

### 4.4 Permitir a GitHub Actions impersonar la SA

```bash
gcloud iam service-accounts add-iam-policy-binding "${SA}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"
```

```powershell
$PROJECT_NUMBER = gcloud projects describe $env:PROJECT_ID --format='value(projectNumber)'
gcloud iam service-accounts add-iam-policy-binding $env:SA `
  --project=$env:PROJECT_ID `
  --role="roles/iam.workloadIdentityUser" `
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$env:POOL_ID/attribute.repository/$env:GITHUB_REPO"
```

### 4.5 Configurar secrets en GitHub

Ir a `Settings > Secrets and variables > Actions` del repo `applocker-iac`:

| Secret | Valor |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider` |
| `GCP_SERVICE_ACCOUNT` | `terraform-applocker-prd@applocker-prd.iam.gserviceaccount.com` |
| `TF_API_TOKEN` | Token de TFC (user) |
| `TF_ORGANIZATION` | `applocker-<sufijo>` |

> **Nota**: *"No hay JSON keys en GitHub Secrets. Solo referencias OIDC. Si alguien se fuga el token, no puede hacer nada: GitHub Actions se autentica contra GCP solo cuando se ejecuta el workflow, y la impersonación está limitada al repo configurado."*

---

## 5. Parte 3 — Workflow `terraform-plan.yml` (PR) (~10 min)

### 5.1 Crear el archivo

`.github/workflows/terraform-plan.yml`:

```yaml
name: "Terraform Plan"

on:
  pull_request:
    branches: [main]
    paths:
      - 'envs/**'
      - 'modules/**'
      - '.github/workflows/**'

permissions:
  id-token: write   # obligatorio para WIF
  contents: read
  pull-requests: write

jobs:
  terraform-plan:
    name: "fmt + validate + plan + conftest"
    runs-on: ubuntu-latest
    environment: staging   # sin reviewers obligatorios, solo etiqueta

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Authenticate to GCP (WIF)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.6

      - name: Terraform fmt
        run: terraform fmt -check -recursive
        working-directory: envs/prd

      - name: Terraform init
        run: terraform init -backend=false
        working-directory: envs/prd

      - name: Terraform validate
        run: terraform validate
        working-directory: envs/prd

      - name: Terraform plan
        id: plan
        run: |
          terraform plan -out=tfplan -input=false
          terraform show -json tfplan > tfplan.json
        working-directory: envs/prd

      - name: Install Conftest
        run: |
          curl -sSL -o conftest.tar.gz https://github.com/open-policy-agent/conftest/releases/download/v0.55.0/conftest_0.55.0_Linux_x86_64.tar.gz
          tar xzf conftest.tar.gz
          sudo mv conftest /usr/local/bin/

      - name: Run OPA policies
        run: conftest test tfplan.json --policy policies/ --output stdout
        working-directory: envs/prd

      - name: Upload plan artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: envs/prd/tfplan

      - name: Comment PR with plan summary
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('envs/prd/tfplan.json', 'utf8');
            const summary = JSON.parse(plan).resource_changes
              .map(r => `\`${r.address}\` → ${r.change.actions.join(',')}`)
              .slice(0, 50)
              .join('\n');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Resumen del plan\n\n${summary}`
            });
```

### 5.2 Commit y push

```bash
git add .github/workflows/terraform-plan.yml
git commit -m "ci(m5): add terraform-plan workflow for PRs"
git push origin feature/m5-pipeline
```

```powershell
git add .github/workflows/terraform-plan.yml
git commit -m "ci(m5): add terraform-plan workflow for PRs"
git push origin feature/m5-pipeline
```

---

## 6. Parte 4 — Workflow `terraform-apply.yml` (push a main) (~10 min)

### 6.1 Crear el archivo

`.github/workflows/terraform-apply.yml`:

```yaml
name: "Terraform Apply"

on:
  push:
    branches: [main]
    paths:
      - 'envs/**'
      - 'modules/**'
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  terraform-apply:
    name: "apply (gate manual)"
    runs-on: ubuntu-latest
    environment: production   # gate: 1 aprobador obligatorio

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Authenticate to GCP (WIF)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.6

      - name: Terraform init
        run: terraform init
        working-directory: envs/prd

      - name: Terraform plan
        run: terraform plan -out=tfplan -input=false
        working-directory: envs/prd

      - name: Install Conftest
        run: |
          curl -sSL -o conftest.tar.gz https://github.com/open-policy-agent/conftest/releases/download/v0.55.0/conftest_0.55.0_Linux_x86_64.tar.gz
          tar xzf conftest.tar.gz
          sudo mv conftest /usr/local/bin/

      - name: Run OPA policies
        run: conftest test tfplan.json --policy policies/ --output stdout
        working-directory: envs/prd

      - name: Terraform apply
        run: terraform apply -input=false tfplan
        working-directory: envs/prd
```

### 6.2 Configurar el environment con reviewer

Ir a **Settings > Environments > New environment**:

1. Nombre: `production`.
2. **Required reviewers**: añadir al formador (o al equipo de plataforma).
3. Guardar.

### 6.3 Commit y merge

```bash
git add .github/workflows/terraform-apply.yml
git commit -m "ci(m5): add terraform-apply workflow with manual gate"
git push origin feature/m5-pipeline
```

```powershell
git add .github/workflows/terraform-apply.yml
git commit -m "ci(m5): add terraform-apply workflow with manual gate"
git push origin feature/m5-pipeline
```

Abrir PR → mergear a `main` → esperar el gate manual → comprobar que el apply se ejecuta contra el bucket GCS.

---

## 7. Parte 5 — Workflow de drift detection (cron) (~5 min)

`.github/workflows/terraform-drift.yml`:

```yaml
name: "Terraform Drift Detection"

on:
  schedule:
    - cron: '0 6 * * 1-5'   # lunes a viernes a las 06:00 UTC
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  issues: write

jobs:
  drift-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP (WIF)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.6

      - name: Terraform init
        run: terraform init
        working-directory: envs/prd

      - name: Detect drift
        id: drift
        run: |
          terraform plan -detailed-exitcode -out=tfplan -input=false > plan.txt 2>&1 || echo "exit=$?"
          terraform show -json tfplan > tfplan.json
        working-directory: envs/prd

      - name: Open issue on drift
        if: steps.drift.outputs.exit == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('envs/prd/tfplan.json', 'utf8');
            const changes = JSON.parse(plan).resource_changes;
            if (changes.length === 0) return;
            const body = changes
              .map(r => `- \`${r.address}\` → ${r.change.actions.join(',')}`)
              .join('\n');
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '🌊 Drift detectado en infra AppLocker',
              body: `El plan detectó cambios no gestionados por Terraform:\n\n${body}\n\nRevisar y reconciliar.`
            });
```

Commit:

```bash
git add .github/workflows/terraform-drift.yml
git commit -m "ci(m5): add drift detection workflow with cron schedule"
git push origin main
```

```powershell
git add .github/workflows/terraform-drift.yml
git commit -m "ci(m5): add drift detection workflow with cron schedule"
git push origin main
```

> **Nota**: *"El cron corre solo en horario laboral. Si alguien rompe la infra un sábado a las 3 de la mañana, no se entera el equipo hasta el lunes. Si la rotura es un disparate, mejor un pager (Cloud Monitoring + alerting), pero para drift 'silencioso' el cron está bien."*

---

## 8. Parte 6 — Crear las 5 políticas OPA (~10 min)

### 8.1 Crear el directorio

```bash
mkdir -p envs/prd/policies
```

```powershell
New-Item -ItemType Directory -Force -Path "envs\prd\policies" | Out-Null
```

### 8.2 `policies/region.rego`

```rego
package terraform.policies.region

deny[msg] {
  rc := input.resource_changes[_]
  rc.change.actions[_] != "delete"
  rc.change.after.region != "us-central1"
  rc.change.after.region != "europe-west3"
  rc.type != "google_client_config"
  msg := sprintf("%s está en región no permitida: %v", [rc.address, rc.change.after.region])
}
```

### 8.3 `policies/required_labels.rego`

```rego
package terraform.policies.labels

required_labels := {"env", "owner", "project", "managed_by"}

deny[msg] {
  rc := input.resource_changes[_]
  rc.change.actions[_] != "delete"
  labels := object.get(rc.change.after, "labels", {})
  missing := required_labels - object.keys(labels)
  count(missing) > 0
  msg := sprintf("%s le faltan labels obligatorios: %v", [rc.address, missing])
}
```

### 8.4 `policies/sql_protection.rego`

```rego
package terraform.policies.cloudsql

deny[msg] {
  rc := input.resource_changes[_]
  rc.type == "google_sql_database_instance"
  rc.change.actions[_] != "delete"
  rc.change.after.deletion_protection != true
  msg := sprintf("%s debe tener deletion_protection = true", [rc.address])
}

deny[msg] {
  rc := input.resource_changes[_]
  rc.type == "google_sql_database_instance"
  rc.change.actions[_] != "delete"
  rc.change.after.ip_configuration[_].ipv4_enabled == true
  msg := sprintf("%s no debe tener IP pública habilitada", [rc.address])
}
```

### 8.5 `policies/machine_types.rego`

```rego
package terraform.policies.machine_types

banned := {"n1-highmem-96", "n1-standard-96", "m1-ultramem-40"}

deny[msg] {
  rc := input.resource_changes[_]
  rc.type == "google_compute_instance_template"
  rc.change.actions[_] != "delete"
  mt := rc.change.after.machine_type
  banned[mt]
  msg := sprintf("%s usa tipo de máquina no permitido: %s", [rc.address, mt])
}
```

### 8.6 `policies/storage.rego`

```rego
package terraform.policies.storage

deny[msg] {
  rc := input.resource_changes[_]
  rc.type == "google_storage_bucket"
  rc.change.actions[_] != "delete"
  rc.change.after.iam[_].member == "allUsers"
  msg := sprintf("%s expone el bucket a allUsers", [rc.address])
}
```

### 8.7 Verificar localmente

```bash
cd envs/prd
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json

# Instalar conftest
brew install conftest   # macOS
# o: https://github.com/open-policy-agent/conftest/releases

conftest test tfplan.json --policy policies/
```

```powershell
Set-Location envs\prd
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json

# Instalar conftest (Windows): descargar de
# https://github.com/open-policy-agent/conftest/releases y añadir al PATH

conftest test tfplan.json --policy policies/
```

Salida esperada: `0 failures`.

---

## 9. Parte 7 — Validación end-to-end (~10 min)

### 9.1 Caso positivo: cambio válido

```bash
git checkout -b feat/m5-test-positive
# Modificar un label de un recurso existente (cumpliendo las políticas)
sed -i 's/cost-center = "CC-1042"/cost-center = "CC-1042-2026"/' infra/envs/dev/main.tf
git add . && git commit -m "test: bump cost-center label"
git push origin feat/m5-test-positive
```

```powershell
git checkout -b feat/m5-test-positive
# Modificar un label de un recurso existente (cumpliendo las políticas)
(Get-Content infra\envs\dev\main.tf) -replace 'cost-center = "CC-1042"','cost-center = "CC-1042-2026"' | Set-Content infra\envs\dev\main.tf
git add . ; git commit -m "test: bump cost-center label"
git push origin feat/m5-test-positive
```

Abrir PR → comprobar que corre `terraform-plan.yml` → debe pasar todas las políticas OPA → comentario en el PR con el resumen.

### 9.2 Caso negativo: política debe fallar

```bash
git checkout main
git checkout -b feat/m5-test-negative
# Borrar un label obligatorio (debe fallar OPA)
sed -i '/cost-center = "CC-1042"/d' infra/envs/dev/main.tf
git add . && git commit -m "test: remove cost-center label (should fail OPA)"
git push origin feat/m5-test-negative
```

```powershell
git checkout main
git checkout -b feat/m5-test-negative
# Borrar un label obligatorio (debe fallar OPA)
(Get-Content infra\envs\dev\main.tf) | Where-Object { $_ -notmatch 'cost-center = "CC-1042"' } | Set-Content infra\envs\dev\main.tf
git add . ; git commit -m "test: remove cost-center label (should fail OPA)"
git push origin feat/m5-test-negative
```

Abrir PR → el workflow debe fallar en el step **Run OPA policies** con el mensaje:

```
FAIL - ...
applying label policy: envs/dev/... le faltan labels obligatorios: {"cost-center"}
```

### 9.3 Aprobar el positivo y mergear

Una vez verificado que las políticas bloquean lo que deben, mergear el PR positivo:

1. Aprobar el PR.
2. Esperar al gate del environment `production` (1 reviewer).
3. El apply se ejecuta contra el bucket GCS.
4. Verificar en consola GCP que el cambio se aplicó.

### 9.4 Disparar el drift manualmente

Ir a **Actions > Terraform Drift Detection > Run workflow**.

Verificar que:
- Si no hay drift: el job termina en verde sin crear issues.
- Si hay drift: abre un issue automático con título `🌊 Drift detectado en infra AppLocker`.

---

## 10. Limpieza

> ⚠️ **NO destruir infra** — solo limpiar artefactos del lab.

```bash
# Eliminar los branches de test
git branch -D feat/m5-test-positive feat/m5-test-negative
git push origin --delete feat/m5-test-positive feat/m5-test-negative

# Cerrar issues de drift abiertos durante el lab (si los hay)
gh issue list --label drift
```

```powershell
# Eliminar los branches de test
git branch -D feat/m5-test-positive, feat/m5-test-negative
git push origin --delete feat/m5-test-positive feat/m5-test-negative

# Cerrar issues de drift abiertos durante el lab (si los hay)
gh issue list --label drift
```

Dejar el pipeline GitOps en pie para M6.

---

## 11. Recursos creados durante el lab (resumen)

| Recurso | Ubicación | Propósito |
|---|---|---|
| Workspace TFC `applocker-prd` | Terraform Cloud | Orquestación de runs |
| WIF Pool `github-actions-pool` | GCP IAM | Identidad para GHA |
| WIF Provider OIDC | GCP IAM | Federación con GitHub |
| 3 workflows | `.github/workflows/` | Plan, apply, drift |
| 5 políticas OPA | `envs/prd/policies/` | Quality gates |
| Environment `production` | GitHub | Reviewer obligatorio |

---

## 12. Validación final (gate del formador)

- [ ] El workspace de TFC está creado y vinculado al bucket GCS.
- [ ] WIF está configurado y los 4 secrets de GitHub están listos.
- [ ] Los 3 workflows están commiteados en `main`.
- [ ] Las 5 políticas OPA pasan el test local (`conftest test` con 0 failures).
- [ ] El caso positivo del PR pasa todas las políticas.
- [ ] El caso negativo del PR falla en OPA con el mensaje correcto.
- [ ] El apply al mergear funciona y queda bloqueado hasta la aprobación manual.
- [ ] El workflow de drift abre un issue cuando hay cambios manuales.

---

## 13. Referencias oficiales

- Terraform Cloud: <https://developer.hashicorp.com/terraform/cloud-docs>
- Workspaces en TFC: <https://developer.hashicorp.com/terraform/cloud-docs/workspaces>
- GitHub Actions para Terraform: <https://developer.hashicorp.com/terraform/tutorials/automation/github-actions>
- Workload Identity Federation: <https://cloud.google.com/iam/docs/workload-identity-federation>
- GitHub Environments: <https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment>
- Open Policy Agent: <https://www.openpolicyagent.org/docs/latest>
- Conftest: <https://www.conftest.dev/>

---