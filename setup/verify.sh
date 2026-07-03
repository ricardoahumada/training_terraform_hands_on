#!/usr/bin/env bash
#
# verify.sh — Pre-flight check antes del Módulo 1.
# Lee PROJECT_ID y TF_STATE_BUCKET del entorno (o los pide).
# Devuelve exit code 0 si todo OK, 1 si algo falla.

set -uo pipefail

# ── Colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'

ok()   { printf "${GREEN}  ✓${RESET} %s\n" "$*"; }
fail() { printf "${RED}  ✗${RESET} %s\n" "$*"; }
info() { printf "${BLUE}  ·${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}  !${RESET} %s\n" "$*"; }

section() { printf "\n${BLUE}── %s ──${RESET}\n" "$*"; }

ERRORS=0

# ── Variables ───────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi

if [[ -z "$TF_STATE_BUCKET" ]]; then
  read -r -p "Nombre del bucket de state (sin gs://) [vacio para omitir]: " TF_STATE_BUCKET
fi

# ── Toolchain ───────────────────────────────────────────────────────────────
section "Toolchain local"

if command -v gcloud >/dev/null 2>&1; then
  ok "gcloud: $(gcloud version 2>/dev/null | head -n1)"
else
  fail "gcloud no encontrado"; ERRORS=$((ERRORS + 1))
fi

if command -v terraform >/dev/null 2>&1; then
  TERRA_VERSION=$(terraform -version 2>/dev/null | head -n1 | awk '{print $2}')
  if [[ "$(printf '%s\n' "1.5" "$TERRA_VERSION" | sort -V | head -n1)" == "1.5" ]]; then
    ok "terraform: $TERRA_VERSION"
  else
    fail "terraform $TERRA_VERSION (necesita >= 1.5)"; ERRORS=$((ERRORS + 1))
  fi
else
  fail "terraform no encontrado"; ERRORS=$((ERRORS + 1))
fi

if command -v gsutil >/dev/null 2>&1; then
  ok "gsutil: presente"
else
  fail "gsutil no encontrado"; ERRORS=$((ERRORS + 1))
fi

if command -v git >/dev/null 2>&1; then
  ok "git: $(git --version | awk '{print $3}')"
else
  fail "git no encontrado"; ERRORS=$((ERRORS + 1))
fi

# ── Autenticación ──────────────────────────────────────────────────────────
section "Autenticación"

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)
  ok "ADC: token emitido (long ${#TOKEN})"
else
  fail "ADC no configurado. Ejecutá: gcloud auth application-default login"
  ERRORS=$((ERRORS + 1))
fi

ACTIVE=$(gcloud config get-value account 2>/dev/null || true)
if [[ -n "$ACTIVE" ]]; then
  ok "Cuenta activa: $ACTIVE"
else
  fail "Sin cuenta gcloud. Ejecutá: gcloud auth login"
  ERRORS=$((ERRORS + 1))
fi

# ── Proyecto ────────────────────────────────────────────────────────────────
section "Proyecto GCP"

if [[ -z "$PROJECT_ID" ]]; then
  fail "PROJECT_ID no definido. Configurá con: gcloud config set project <ID>"
  ERRORS=$((ERRORS + 1))
else
  if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    ok "Proyecto $PROJECT_ID existe"
  else
    fail "Proyecto $PROJECT_ID NO existe en GCP"
    ERRORS=$((ERRORS + 1))
  fi

  BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null || true)
  if [[ -n "$BILLING" && "$BILLING" != "billingAccountName is not set" ]]; then
    ok "Billing asociado: $BILLING"
  else
    fail "Billing no asociado al proyecto"
    ERRORS=$((ERRORS + 1))
  fi
fi

# ── Defaults ────────────────────────────────────────────────────────────────
section "Defaults de gcloud"

DEFAULT_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
DEFAULT_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
[[ -n "$DEFAULT_REGION" ]] && ok "compute/region: $DEFAULT_REGION" || warn "compute/region sin definir (default us-central1)"
[[ -n "$DEFAULT_ZONE" ]]   && ok "compute/zone: $DEFAULT_ZONE"     || warn "compute/zone sin definir (default us-central1-a)"

# ── APIs críticas ──────────────────────────────────────────────────────────
section "APIs habilitadas"

for api in compute.googleapis.com storage-api.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com; do
  if gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
    ok "$api"
  else
    fail "$api (no habilitada)"; ERRORS=$((ERRORS + 1))
  fi
done

# ── Bucket state ────────────────────────────────────────────────────────────
section "Bucket de state"

if [[ -n "$TF_STATE_BUCKET" ]]; then
  if gsutil ls -b "gs://$TF_STATE_BUCKET" >/dev/null 2>&1; then
    ok "Bucket gs://$TF_STATE_BUCKET existe"

    VERSIONING=$(gsutil versioning get "gs://$TF_STATE_BUCKET" 2>/dev/null | awk '{print $NF}')
    [[ "$VERSIONING" == "Enabled" ]] && ok "Versionado ON" || { fail "Versionado OFF"; ERRORS=$((ERRORS + 1)); }

    UNIFORM=$(gsutil ls -L -b "gs://$TF_STATE_BUCKET" 2>/dev/null | grep -c "uniformBucketLevelAccess")
    [[ "$UNIFORM" -gt 0 ]] && ok "Uniform bucket-level access activado" || warn "Uniform bucket-level access no detectado"
  else
    fail "Bucket gs://$TF_STATE_BUCKET NO existe"
    ERRORS=$((ERRORS + 1))
  fi
else
  warn "TF_STATE_BUCKET no definido — no se puede validar"
fi

# ── Veredicto ───────────────────────────────────────────────────────────────
section "Veredicto"

if [[ $ERRORS -eq 0 ]]; then
  printf "${GREEN}✔ Todo OK.${RESET} Listo para el Módulo 1.\n"
  exit 0
else
  printf "${RED}✘ Hay $ERRORS problema(s) a resolver.${RESET}\n"
  printf "Revisá ${BLUE}module-0/troubleshooting.md${RESET} o contactá al formador.\n"
  exit 1
fi
