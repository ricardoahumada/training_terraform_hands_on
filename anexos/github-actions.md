# GitHub Actions en pocas palabras — Guía resumida (2026)

> Resumen de referencia para el curso *Terraform Hands-on* (MediaMarkt, GCP).
> Cubre solo lo que el módulo 5 necesita: workflows para Terraform, autenticación OIDC contra GCP, environments como gates y drift detection. No es un manual exhaustivo de GitHub Actions.

---

## 1. Qué es GitHub Actions

GitHub Actions es el motor de **CI/CD nativo de GitHub**: ejecuta workflows definidos como código YAML dentro de `.github/workflows/`. Cada workflow reacciona a eventos del repo (push, PR, schedule, manual) y encadena **jobs** compuestos por **steps**.

### Modelo mental

```
Evento (push, PR, schedule, workflow_dispatch)
    │
    ▼
Workflow (YAML en .github/workflows/*.yml)
    │
    ▼
Job (corre en un runner, con permisos y matriz definidos)
    │
    ▼
Step (action reutilizable o comando shell)
    │
    ▼
Artifact / comentario en PR / log
```

### Por qué encaja con Terraform

- **Detecta PRs** y ejecuta `fmt` + `validate` + `plan` automáticamente.
- **Publica el plan como artifact** para revisión humana.
- **Permite comentar el PR** con el resumen del plan (vía actions).
- **Dispara applies** desde `push a main` o manualmente, con gates de aprobación (Environments).
- **Corre jobs programados** (`schedule`) para detectar drift.
- **Sin credenciales persistentes**: se autentica contra GCP con **OIDC + Workload Identity Federation**.

### Características clave (2026)

- **Runners hosted** (Linux, macOS, Windows) con caché de dependencias y red de gigabytes.
- **Runners self-hosted** ejecutables en GKE, ECS, VMs o Actions Runner Controller (ARC) en Kubernetes.
- **Composite actions** y **reusable workflows** para factorizar pipelines entre repos.
- **GitHub Environments** como unidades de despliegue con secrets, variables y reviewers obligatorios.
- **OpenID Connect (OIDC)** nativo: emite tokens JWT firmados por `token.actions.githubusercontent.com` que los clouds (GCP, AWS, Azure) pueden federar.

---

## 2. Anatomía de un workflow

### Estructura mínima

```yaml
name: terraform-plan                      # nombre visible en la UI de Actions

on:                                      # trigger(s)
  pull_request:
    branches: [main]
    paths:
      - 'envs/**'
      - 'modules/**'
      - '.github/workflows/**'

permissions:                              # permisos del GITHUB_TOKEN (mejorar seguridad)
  id-token: write   # necesario para OIDC contra GCP/AWS/Azure
  contents: read
  pull-requests: write

jobs:
  terraform-plan:
    name: fmt + validate + plan
    runs-on: ubuntu-latest                # runner hosted por GitHub
    environment: staging                  # environment opcional (gate lógico)

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.10.4

      - name: Authenticate to GCP (OIDC)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: terraform fmt
        run: terraform fmt -check -recursive
        working-directory: envs/prd

      - name: terraform init
        run: terraform init -backend=false
        working-directory: envs/prd

      - name: terraform validate
        run: terraform validate
        working-directory: envs/prd

      - name: terraform plan
        run: terraform plan -out=tfplan -no-color
        working-directory: envs/prd

      - name: Convert plan to JSON
        run: terraform show -json tfplan > tfplan.json
        working-directory: envs/prd

      - name: Upload plan artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: envs/prd/tfplan
```

### Triggers útiles para Terraform

| Trigger | Caso de uso |
|---|---|
| `pull_request` | Ejecutar `fmt` + `validate` + `plan` y comentar el PR. |
| `push` en `main` | Disparar `apply` (con gate). |
| `workflow_dispatch` | Lanzar `apply` manualmente desde la UI. |
| `schedule` (cron) | Drift detection diario o semanal. |
| `repository_dispatch` | Disparar desde herramientas externas (Terraform Cloud webhooks). |

### Buenas prácticas de triggers

- `paths` siempre que se pueda → evita correr el workflow si cambia `README.md`.
- `branches` restrictivo (solo `main` para apply).
- `concurrency` con `group` para evitar applies concurrentes sobre el mismo target:
  ```yaml
  concurrency:
    group: terraform-apply-prd
    cancel-in-progress: false   # true cancela apply en curso si entra otro; normalmente false para apply
  ```

---

## 3. Autenticación contra GCP con OIDC (Workload Identity Federation)

> El curso exige **no usar JSON keys**. GitHub Actions emite un token OIDC; GCP lo acepta vía WIF y lo intercambia por un token de corta duración de una Service Account.

### Flujo conceptual

```
┌────────────────────┐   1. JOB START    ┌────────────────────┐
│  GitHub Actions    │ ───────────────▶  │ token.actions.     │
│  runner            │ ◀─── JWT (OIDC) ─ │ githubusercontent   │
└─────────┬──────────┘                   └────────────────────┘
          │
          │ 2. POST a STS con JWT
          ▼
┌─────────────────────────────────────────────┐
│  GCP IAM: Security Token Service (STS)      │
│  - Valida firma del JWT                     │
│  - Verifica attribute-condition (repo)      │
│  - Emite token de SA (corta duración)       │
└─────────┬───────────────────────────────────┘
          │
          │ 3. Token inyectado en GOOGLE_APPLICATION_CREDENTIALS
          ▼
┌────────────────────┐
│  gcloud / TF       │
│  habla con GCP     │
└────────────────────┘
```

### Configuración única en GCP (una vez por proyecto)

```bash
PROJECT_ID="applocker-prd"
POOL_ID="github-actions-pool"
PROVIDER_ID="github-actions-provider"
SA="terraform-applocker-prd@${PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_REPO="mi-org/applocker-iac"

# 1. Pool de identidades
gcloud iam workload-identity-pools create "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# 2. Provider OIDC
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'"

# 3. Permiso para que la SA sea impersonable desde el pool
gcloud iam service-accounts add-iam-policy-binding "${SA}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"
```

> ⚠️ Para minimizar blast radius, se puede usar `attribute-condition` con rama o branch específicas: `assertion.repository=='mi-org/applocker-iac' && assertion.ref=='refs/heads/main'`.

### Secrets en GitHub (solo referencias, no credenciales)

| Secret | Valor |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider` |
| `GCP_SERVICE_ACCOUNT` | `terraform-applocker-prd@applocker-prd.iam.gserviceaccount.com` |

### Action de autenticación

```yaml
- name: Authenticate to GCP (OIDC)
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
```

> Tras este step, `GOOGLE_APPLICATION_CREDENTIALS` apunta a un JSON efímero válido solo durante el job. No se almacena nada en disco de larga duración.

### Por qué nunca JSON keys

- Rotación manual y propensa a errores.
- Filtración ⇒ blast radius permanente.
- Auditoría difícil: cualquier humano con la key la puede usar fuera de GitHub.
- WIF lo resuelve con **tokens de corta duración, auditables y limitados por `attribute-condition`**.

---

## 4. GitHub Environments como gates de despliegue

Un **Environment** de GitHub Actions representa un destino de despliegue (staging, prod). Permite:

- **Secrets y variables** con scope al environment.
- **Reviewers obligatorios**: el job se queda en pausa hasta N aprobaciones.
- **Wait timer**: espera N minutos antes de ejecutar (enfriamiento).
- **Branch protection**: reglas independientes por environment.

### Configurar un environment `production`

1. `Settings → Environments → New environment → production`.
2. **Required reviewers**: añadir al menos 2 personas del equipo de plataforma.
3. **Deployment branches**: solo `main` o reglas por tag.
4. Definir secrets y variables scoped al environment.

### Uso en workflow

```yaml
jobs:
  terraform-apply:
    runs-on: ubuntu-latest
    environment: production        # pide aprobación antes de ejecutar
    steps:
      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
      # ... init, plan, apply ...
```

### Buenas prácticas

- **Separar environments por entorno** (`staging`, `production`) y por cuenta GCP si aplica.
- **Requerir reviewers** en production, no en staging.
- **No compartir secrets entre environments**. Cada uno con su SA y WIF provider.
- Limitar **branches permitidos** a los releases / `main`.

---

## 5. Comentarios automáticos del plan en el PR

Para que el PR muestre el diff de Terraform sin que el revisor abra la UI de Actions:

### Opción A — Action oficial de HashiCorp

```yaml
- name: Comment plan summary on PR
  uses: hashicorp/tf-publish-action@v1
  env:
    TFACTION_COMMENT: true
  with:
    plan_file: envs/prd/tfplan
```

### Opción B — Custom step con `terraform show -json` y curl

Menos recomendado, pero útil cuando se quiere control fino sobre el formato.

---

## 6. Drift detection programado

El **drift** ocurre cuando la infraestructura real diverge del state (alguien cambió algo por consola, otro IaC, scripts manuales). GitHub Actions puede detectarlo con un cron que ejecute `plan` y abra un issue si hay cambios.

### Workflow de ejemplo

```yaml
name: terraform-drift

on:
  schedule:
    - cron: '0 6 * * 1-5'         # L-V a las 06:00 UTC
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  issues: write

jobs:
  drift-check:
    runs-on: ubuntu-latest
    environment: production

    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP (OIDC)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.10.4

      - name: terraform init
        working-directory: envs/prd
        run: terraform init

      - name: terraform plan (drift)
        id: plan
        working-directory: envs/prd
        run: |
          terraform plan -detailed-exitcode -no-color > plan.txt
          echo "exit=$?" >> "$GITHUB_OUTPUT"
          # 0 = sin cambios, 1 = error, 2 = drift detectado

      - name: Open issue si hay drift
        if: steps.plan.outputs.exit == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const body = fs.readFileSync('envs/prd/plan.txt', 'utf8');
            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '🚨 Drift detectado en producción',
              body: '```\n' + body + '\n```',
              labels: ['drift', 'terraform']
            });
```

> `-detailed-exitcode` hace que `plan` devuelva `2` cuando hay cambios. Es la forma estándar de detectar drift en CI.

---

## 7. Acciones oficiales más usadas en pipelines de Terraform

| Acción | Versión | Para qué |
|---|---|---|
| `actions/checkout` | v4 | Clonar el repo. Usar siempre `fetch-depth: 0` si se hace `terraform plan` con módulos referenciados por tag. |
| `hashicorp/setup-terraform` | v3 | Instalar una versión exacta de Terraform, habilitar CLI de TFC. |
| `google-github-actions/auth` | v2 | Autenticación contra GCP vía OIDC/WIF. Soporta ADC, SA keys y WIF. |
| `hashicorp/tf-publish-action` | v1 | Publicar el plan como artifact + comentario en PR. |
| `hashicorp/tfc-workflows-github` | última | Disparar runs de Terraform Cloud desde GHA. |
| `actions/upload-artifact` | v4 | Subir el plan binario / JSON para descarga. |
| `actions/download-artifact` | v4 | Recuperar el plan (ej. para `apply` desde un workflow distinto). |
| `conftestplus/conftest-action` | última | Ejecutar políticas OPA/Rego contra el plan JSON. |

---

## 8. Seguridad del workflow

### `permissions` por defecto (principio de menor privilegio)

```yaml
permissions:
  id-token: write    # obligatorio para OIDC
  contents: read     # checkout del código
  pull-requests: write  # comentar el PR
  # explícitamente NO dar issues: write si no hace falta
```

Nunca `permissions: write-all`.

### Pinning de versiones

- Pinear SHA en lugar de tag cuando el proveedor es externo:
  ```yaml
  uses: google-github-actions/auth@v2.2.0     # ❌ mutable
  uses: google-github-actions/auth@aabbccd... # ✅ SHA inmutable
  ```
- GitHub bloquea automáticamente acciones de terceros sin SHA si el repo está en organización con esa política.

### Secretos

- Preferir **OIDC** siempre que el destino lo soporte (GCP, AWS, Azure, Vault).
- Para secrets clásicos (TFC API token): rotar periódicamente y limitar el scope al menor necesario.

### Hardening de runners

- **Hosted runners**: stateless, red saliente a internet; adecuado para la mayoría.
- **Self-hosted**: usar en Kubernetes con ARC (Actions Runner Controller). Útil para planes que requieren acceso a recursos privados (Cloud SQL privado, VPC SC).
- **Matriz OS**: restringir a Linux salvo necesidad real; macOS/Windows cuestan 10x.

---

## 9. Costes y rendimiento

| Concepto | Detalle (2026) |
|---|---|
| Minutos incluidos en plan Free | 2 000 min/mes en runners Linux. |
| Runners Linux vs otros | Linux es 1x, Windows 2x, macOS 10x. |
| Caché de providers | `setup-terraform` usa automáticamente el caché de Actions para providers descargados. Reduce minutos y latencia. |
| Artifacts | 500 MB por artifact por defecto; retención 90 días. El plan de Terraform rara vez supera 10 MB. |
| Matrix | Multiplica los minutos por número de combinaciones. Usar solo cuando aporta valor (ej. `terraform plan` en dev y prd). |

### Trucos

- **Caché explícito de `~/.terraform.d/plugin-cache`**:
  ```yaml
  - uses: actions/cache@v4
    with:
      path: ~/.terraform.d/plugin-cache
      key: ${{ runner.os }}-terraform-plugins-${{ hashFiles('**/.terraform.lock.hcl') }}
  ```
- **Evitar `terraform init` en plan si es posible**, usando `-backend=false` cuando el state no se necesita para validar.
- **Concurrencia cancelable** en jobs de plan para no gastar minutos en commits posteriores.

---

## 10. Patrones avanzados

### 10.1 Composite actions para reutilizar lógica

```yaml
# .github/actions/terraform-prep/action.yml
name: terraform-prep
description: Setup Terraform + WIF auth
runs:
  using: composite
  steps:
    - uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: 1.10.4
    - uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ inputs.wif-provider }}
        service_account: ${{ inputs.sa }}
```

Uso:
```yaml
- uses: ./.github/actions/terraform-prep
  with:
    wif-provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    sa: ${{ secrets.GCP_SERVICE_ACCOUNT }}
```

### 10.2 Reusable workflows entre repos

```yaml
# repositorio central: .github/workflows/terraform-plan.yml
on:
  workflow_call:
    inputs:
      working-directory:
        type: string
        required: true

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ...
```

En el repo del alumno:
```yaml
on:
  pull_request:
    branches: [main]

jobs:
  call-plan:
    uses: mi-org/iac-pipelines/.github/workflows/terraform-plan.yml@main
    with:
      working-directory: envs/prd
```

### 10.3 Idempotencia del apply

Siempre aplicar a partir del **mismo plan** que se revisó:
```yaml
- uses: actions/download-artifact@v4
  with:
    name: tfplan
    path: envs/prd
- working-directory: envs/prd
  run: terraform apply -auto-approve tfplan
```

Si entre el plan y el apply hubo un push, se rechaza (drift). Esto evita aplicar planes obsoletos.

### 10.4 Notificaciones a Slack/Teams

```yaml
- name: Notify apply success
  if: success()
  uses: slackapi/slack-github-action@v1.27.0
  with:
    payload: |
      {"text": "✅ Terraform apply OK en `${{ github.ref_name }}` (${{ github.event.pull_request.number }})."}
  env:
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK }}
```

---

## 11. Cuándo usar GitHub Actions vs Terraform Cloud

| Necesidad | GitHub Actions | Terraform Cloud |
|---|---|---|
| Trigger por PR con plan + comentario | ✅ nativo | ✅ especulativo |
| Runs colaborativos y audit trail | parcial | ✅ Speculative + real runs en UI |
| State locking distribuido | manual (GCS) | ✅ nativo |
| Drift detection programado | cron manual | ✅ Health nativo |
| Policy as Code (OPA/Sentinel) | OPA externo (Conftest) | ✅ Sentinel (incluido) |
| Variables sensibles centralizadas | Secrets por environment | ✅ Variable sets |
| Costes | incluído en plan GitHub | licencia TFC |
| Ejecución en VPC privada | self-hosted runners | ✅ agentes privados TFC |

> Para AppLocker usamos **Terraform Cloud para state + runs colaborativos** y **GitHub Actions como disparador** del workflow GitOps (PR + apply con gate + drift).

---

## 12. Errores comunes

1. **Olvidar `permissions: id-token: write`**: el job no puede emitir el token OIDC y la auth contra GCP falla.
2. **Aplicar desde plan antiguo**: aplicar siempre con el `tfplan` descargado del PR, no correr `terraform apply` directo.
3. **JSON keys en secrets**: filtrables, sin rotación automática, auditables solo en logs de GitHub. Usar siempre OIDC.
4. **Runs concurrentes sin `concurrency`**: dos applies contra el mismo state pueden corromperlo.
5. **Caché de providers nunca se invalida**: usar la key sobre `.terraform.lock.hcl`.
6. **Plan sin `-out=tfplan`**: si hay outputs largos no se ven al final; siempre escribir a archivo y serializar a JSON para políticas OPA.
7. **Drift con cron silencioso**: sin abrir issue o notificar, el drift se ignora. Combinar siempre con un canal (Slack, issue, alerting).

---

## 13. Referencias oficiales (2026)

- GitHub Actions — Documentación general: <https://docs.github.com/en/actions>
- Workflow syntax reference: <https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions>
- Reusable workflows: <https://docs.github.com/en/actions/sharing-automations/reusing-workflows>
- OIDC en GitHub Actions: <https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect>
- Environments y aprobaciones: <https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment>
- Hardening de seguridad: <https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions>
- Google Auth Action (WIF): <https://github.com/google-github-actions/auth>
- Workload Identity Federation (GCP): <https://cloud.google.com/iam/docs/workload-identity-federation>
- HashiCorp setup-terraform: <https://github.com/hashicorp/setup-terraform>
- Terraform + GitHub Actions tutorial: <https://developer.hashicorp.com/terraform/tutorials/automation/github-actions>
- tf-publish-action: <https://github.com/hashicorp/tf-publish-action>
- Conftest (OPA en pipelines): <https://www.conftest.dev/>
