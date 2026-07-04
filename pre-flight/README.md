# Módulo 0 — Bootstrap del entorno

> Setup **previo al M1**. Si algo de esto falla, el curso empieza con fricción. Reservar 1 hora.

## Quick start

```bash
# Linux / macOS
./bootstrap.sh

# Windows (PowerShell)
.\bootstrap.ps1
```

Y después:

```bash
./verify.sh        # o .\verify.ps1 en Windows
```

Si todo dice `OK`, arrancar el M1.

---

## Checklist manual (paso a paso)

Marca cada item cuando lo completes.

### A. Toolchain local

- [ ] `terraform -version` ≥ 1.5
- [ ] `gcloud version` instalado
- [ ] `git --version` instalado
- [ ] Extensión HashiCorp Terraform en VS Code (opcional)

### B. Cuenta GCP

- [ ] Cuenta GCP con billing activo
- [ ] Permiso de **Owner** sobre el proyecto del curso (o `Editor` + service account user)
- [ ] Project ID **único a nivel global** (sufijo con tu nombre/año)

### C. Autenticación

```bash
gcloud auth login                          # abre navegador
gcloud auth application-default login      # credenciales para Terraform
gcloud config set project <PROJECT_ID>
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a
```

- [ ] `gcloud config get-value project` → tu project ID
- [ ] `gcloud auth application-default print-access-token` → token válido

### D. APIs habilitadas

```bash
gcloud services enable \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  storage-api.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  servicenetworking.googleapis.com
```

- [ ] `gcloud services list --enabled | grep compute` muestra resultados

### E. Bucket de state remoto

```bash
export TF_STATE_BUCKET="tfstate-<empresa>-tf-<env>-<sufijo>"
gsutil mb -l us-central1 -b on gs://$TF_STATE_BUCKET
gsutil versioning set on gs://$TF_STATE_BUCKET
```

- [ ] El bucket existe: `gsutil ls -b gs://$TF_STATE_BUCKET`
- [ ] Versionado ON: `gsutil versioning get gs://$TF_STATE_BUCKET` → `Enabled`

### F. Budget alert (opcional)

- [ ] Budget creado en Billing → $50-100 USD
- [ ] Alertas al 50%, 80%, 100%
- [ ] Notificación por email configurada

---

## Naming conventions del curso

| Recurso | Convención | Ejemplo |
|---|---|---|
| **Project ID** | `<empresa>-tf-<env>-<sufijo>` | `mediamarkt-tf-prod-ricar` |
| **Bucket state** | `tfstate-<empresa>-tf-<env>-<sufijo>` | `tfstate-mediamarkt-tf-prod-ricar` |
| **Service accounts** | `applocker-<tier>-runtime` | `applocker-app-runtime` |
| **Recursos** | `<app>-<tier>-<env>` | `applocker-backend-prod` |
| **Labels** | `env`, `app`, `tier`, `team`, `managed-by` | `managed-by=terraform` |

---

## ¿Si algo falla?

1. Correr `verify.sh` (o `verify.ps1`) — que indica qué falla.
2. Si el mensaje de error no es claro, abrir [troubleshooting.md](./troubleshooting.md).
3. Si sigue sin resolverse, contactar al formador.

---

## Próximo paso

Una vez completado todo esto, arrancar el [Módulo 1 — State y Remote Backend](../module-1/outline.md).
