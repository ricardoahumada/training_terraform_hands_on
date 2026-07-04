#!/usr/bin/env bash
#
# Bootstrap script — Terraform Hands-on (MediaMarkt / GCP)
# Pre-flight setup antes del Módulo 1.
#
# Idempotente: puede ejecutarse varias veces sin romper nada.
# Interactivo: pide confirmación antes de acciones destructivas.

set -euo pipefail

# ── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()     { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
section() { printf "\n${BOLD}${BLUE}── %s ──${RESET}\n" "$*"; }

# ── Verificaciones previas ─────────────────────────────────────────────────
section "Verificando pre-requisitos"

command -v gcloud >/dev/null 2>&1 || { err "gcloud CLI no instalado. Ver anexo §1.1."; exit 1; }
command -v terraform >/dev/null 2>&1 || { err "Terraform no instalado. Ver anexo §2."; exit 1; }
command -v gsutil >/dev/null 2>&1 || { err "gsutil no disponible. Reinstala Google Cloud SDK."; exit 1; }
command -v git >/dev/null 2>&1 || { err "git no instalado."; exit 1; }
ok "Toolchain básica presente"

# ── Variables de configuración ─────────────────────────────────────────────
section "Configuración"

# Default naming convention.
DEFAULT_ORG="mediamarkt"
DEFAULT_ENV="prod"

read -r -p "Empresa / organización [${DEFAULT_ORG}]: " ORG
ORG=${ORG:-$DEFAULT_ORG}

read -r -p "Entorno (dev/staging/prod) [${DEFAULT_ENV}]: " ENV
case "${ENV:-${DEFAULT_ENV}}" in
  dev|staging|prod) ;; 
  *) err "Entorno inválido."; exit 1 ;;
esac

# Sufijo único a nivel global (default: timestamp corto)
DEFAULT_SUFFIX="$(date +%y%m%d)"
read -r -p "Sufijo único (letras/dígitos) [${DEFAULT_SUFFIX}]: " SUFFIX
SUFFIX=${SUFFIX:-$DEFAULT_SUFFIX}

PROJECT_ID="${ORG}-tf-${ENV}-${SUFFIX}"
BUCKET_NAME="tfstate-${ORG}-tf-${ENV}-${SUFFIX}"
REGION="us-central1"
ZONE="us-central1-a"

info "Project ID:     ${PROJECT_ID}"
info "Bucket state:   gs://${BUCKET_NAME}"
info "Región / Zone:  ${REGION} / ${ZONE}"
echo
warn "Si el Project ID ya existe en GCP, este script fallará."
warn "Es un identificador ÚNICO A NIVEL MUNDIAL — elegí un sufijo que te identifique."
read -r -p "¿Continuar? [y/N]: " CONFIRM
[[ "${CONFIRM:-N}" =~ ^[Yy]$ ]] || { info "Cancelado."; exit 0; }

# ── Login y proyecto ───────────────────────────────────────────────────────
section "Autenticación"

ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  warn "No hay cuenta activa. Ejecutando gcloud auth login..."
  gcloud auth login
else
  ok "Cuenta activa: ${ACTIVE_ACCOUNT}"
fi

# Detectar la primera organizacion accesible. Se usara como parent al crear
# el proyecto. Si la cuenta no pertenece a ninguna org, queda vacia y el
# proyecto se crea sin parent (comportamiento legacy de cuentas personales).
ORG_ID=$(gcloud organizations list --format="value(name)" --limit=1 2>/dev/null | head -n1 || true)
# El formato es "organizations/XXXXXX" pero --organization espera solo el ID.
if [[ "$ORG_ID" =~ ^organizations/(.+)$ ]]; then
  ORG_ID="${BASH_REMATCH[1]}"
fi
if [[ -n "$ORG_ID" ]]; then
  ok "Organizacion: ${ORG_ID} (se asociara al crear el proyecto)"
else
  info "Sin organizacion detectable (cuenta personal o sin permisos). El proyecto se creara sin parent."
fi

# ADC para Terraform
ADC_SCOPES="https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email"
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  warn "ADC no configurado. Iniciando flujo OAuth..."
  info "Si tu organización restringe scopes, se te pedirá consentimiento para 'cloud-platform'."
  info "En la pantalla de Google: cliquea 'Permitir' cuando pida permisos ampliados."
  echo ""

  # Intento 1: navegador + scopes explícitos
  if ! gcloud auth application-default login --scopes="$ADC_SCOPES"; then
    warn "Fallo con navegador. Reintentando en modo headless (pega la URL manualmente)..."
    echo ""
    # Intento 2: --no-launch-browser para entornos sin GUI / políticas restrictivas
    gcloud auth application-default login --no-launch-browser --scopes="$ADC_SCOPES"
  fi

  # Verificación final
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    err "ADC sigue sin funcionar. Opciones:"
    echo "  1. Verifica que en la pantalla de Google cliqueaste 'Permitir' (no 'Cancelar')." >&2
    echo "  2. Si tu organización bloquea el scope cloud-platform, pide al formador una service account key:" >&2
    echo "     export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json" >&2
    exit 1
  fi
  ok "ADC configurado correctamente"
else
  ok "ADC configurado"
fi

# ── Verificar / crear proyecto ─────────────────────────────────────────────
section "Proyecto GCP"

# Estrategia de deteccion robusta: un proyecto existe si CUALQUIERA de estas
# dos condiciones se cumple:
#   1. `gcloud projects describe` devuelve el projectId exacto (tenemos acceso).
#   2. `gcloud projects list --filter` lo lista (existe en nuestro namespace).
# Esto evita el caso clasico donde `describe` falla con "does not have permission"
# sobre un proyecto que SI existe pero donde no somos owner.
SEEN_IN_DESCRIBE=false
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  SEEN_IN_DESCRIBE=true
fi
SEEN_IN_LIST=false
if gcloud projects list --format="value(projectId)" --filter="projectId=$PROJECT_ID" 2>/dev/null | grep -q "$PROJECT_ID"; then
  SEEN_IN_LIST=true
fi

if $SEEN_IN_DESCRIBE; then
  ok "Proyecto $PROJECT_ID existe y la cuenta activa tiene acceso directo"
elif $SEEN_IN_LIST; then
  warn "Proyecto $PROJECT_ID existe, pero la cuenta activa no es owner."
  warn "Se usara tal cual. Algunas operaciones Terraform podrian requerir"
  warn "que el formador te agregue como 'roles/owner' o 'roles/editor'."
else
  warn "Proyecto $PROJECT_ID NO existe. Creando..."
  # GCP limita display_name a 30 chars. Truncamos defensivamente.
  DISPLAY_NAME="TF Course ${ENV}"
  if [[ ${#DISPLAY_NAME} -gt 30 ]]; then
    DISPLAY_NAME="${DISPLAY_NAME:0:30}"
  fi

  # Intentar crear asociado a la organizacion. Si falla por permisos
  # (comun si la cuenta no tiene resourcemanager.projects.create sobre la org),
  # fallback a creacion sin parent.
  if [[ -n "$ORG_ID" ]]; then
    if ! gcloud projects create "$PROJECT_ID" --name="$DISPLAY_NAME" --organization="$ORG_ID"; then
      warn "No se pudo crear bajo la organizacion $ORG_ID (fallo de permisos?). Fallback a creacion sin parent."
      if ! gcloud projects create "$PROJECT_ID" --name="$DISPLAY_NAME"; then
        err "Fallo creando proyecto. Revisa la salida de gcloud arriba."
        exit 1
      fi
    fi
  else
    if ! gcloud projects create "$PROJECT_ID" --name="$DISPLAY_NAME"; then
      err "Fallo creando proyecto. Revisa la salida de gcloud arriba."
      exit 1
    fi
  fi
  ok "Proyecto creado"

  # Garantizar que la cuenta activa es owner del proyecto recién creado.
  if ! gcloud projects add-iam-policy-binding "$PROJECT_ID" \
       --member="user:$ACTIVE_ACCOUNT" \
       --role="roles/owner" \
       --quiet >/dev/null 2>&1; then
    warn "No se pudo asignar owner (probablemente ya lo sos). Continuando..."
  else
    ok "Owner asignado: $ACTIVE_ACCOUNT"
  fi
fi

if ! gcloud config set project "$PROJECT_ID" >/dev/null 2>&1; then
  err "No se pudo activar el proyecto $PROJECT_ID."
  exit 1
fi
ACTIVE_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [[ "$ACTIVE_PROJECT" != "$PROJECT_ID" ]]; then
  err "No se pudo activar el proyecto. Activo: '$ACTIVE_PROJECT', esperado: '$PROJECT_ID'"
  exit 1
fi
ok "Proyecto activo: $ACTIVE_PROJECT"

# ── Billing ────────────────────────────────────────────────────────────────
section "Billing"

BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null || true)
if [[ -n "$BILLING_ACCOUNT" && "$BILLING_ACCOUNT" != "billingAccountName is not set" ]]; then
  ok "Billing ya asociado: ${BILLING_ACCOUNT}"
else
  warn "No hay billing asociado al proyecto."
  ACTIVE_BILLING=$(gcloud billing accounts list --format="value(name)" --limit=1 2>/dev/null | head -n1 || true)
  if [[ -z "$ACTIVE_BILLING" ]]; then
    err "No hay cuentas de billing disponibles en gcloud. Asociá una desde la consola."
    exit 1
  fi
  read -r -p "¿Asociar billing ${ACTIVE_BILLING} al proyecto? [y/N]: " BILL_OK
  [[ "${BILL_OK:-N}" =~ ^[Yy]$ ]] || { err "Sin billing no se puede continuar."; exit 1; }
  gcloud billing projects link "$PROJECT_ID" --billing-account="$ACTIVE_BILLING"
  ok "Billing asociado"
fi

# ── APIs ────────────────────────────────────────────────────────────────────
section "Habilitando APIs"

APIS=(
  compute.googleapis.com
  sqladmin.googleapis.com
  storage-api.googleapis.com
  secretmanager.googleapis.com
  iam.googleapis.com
  cloudresourcemanager.googleapis.com
  serviceusage.googleapis.com
  servicenetworking.googleapis.com
)

for api in "${APIS[@]}"; do
  if gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
    ok "API ${api} ya habilitada"
  else
    info "Habilitando ${api}..."
    gcloud services enable "$api" --quiet
  fi
done

# ── Bucket de state ────────────────────────────────────────────────────────
section "Bucket de state remoto"

if gsutil ls -b "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
  ok "Bucket gs://${BUCKET_NAME} ya existe"
else
  info "Creando bucket gs://${BUCKET_NAME}..."
  gsutil mb -l "$REGION" -b on "gs://${BUCKET_NAME}"
fi

VERSIONING=$(gsutil versioning get "gs://${BUCKET_NAME}" 2>/dev/null | awk '{print $NF}')
if [[ "$VERSIONING" == "Enabled" ]]; then
  ok "Versionado ya está ON"
else
  info "Habilitando versionado..."
  gsutil versioning set on "gs://${BUCKET_NAME}"
fi

# ── Defaults de gcloud ─────────────────────────────────────────────────────
section "Defaults de gcloud"

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

# ── Resumen ────────────────────────────────────────────────────────────────
section "Resumen"
printf "${BOLD}Project ID:${RESET}   %s\n" "$PROJECT_ID"
printf "${BOLD}Bucket:${RESET}       gs://%s\n" "$BUCKET_NAME"
printf "${BOLD}Region/Zone:${RESET}  %s / %s\n" "$REGION" "$ZONE"
printf "${BOLD}Cuenta:${RESET}       %s\n" "$(gcloud config get-value account)"
echo
ok "Bootstrap completo. Corré ./verify.sh para confirmación."
info "Próximo paso: Módulo 1 — State y Remote Backend."
