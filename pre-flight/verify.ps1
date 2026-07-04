# verify.ps1 - Pre-flight check antes del Modulo 1 (Windows PowerShell).
# Devuelve exit code 0 si todo OK, 1 si algo falla.

$ErrorActionPreference = 'Continue'
$errors = 0

function Ok    { param($m) Write-Host "  ok $m" -ForegroundColor Green }
function Fail  { param($m) Write-Host "  FAIL $m" -ForegroundColor Red; $script:errors++ }
function Info  { param($m) Write-Host "  .. $m" -ForegroundColor Cyan }
function Warn  { param($m) Write-Host "  !! $m" -ForegroundColor Yellow }
function Sect  { param($m) Write-Host "" ; Write-Host "-- $m --" -ForegroundColor Cyan }

# Variables
if (-not $env:PROJECT_ID) {
  $env:PROJECT_ID = (gcloud config get-value project 2>$null)
}
if (-not $env:TF_STATE_BUCKET) {
  $env:TF_STATE_BUCKET = Read-Host "Nombre del bucket de state (sin gs://) [vacio para omitir]"
}

# Toolchain
Sect "Toolchain local"

foreach ($cmd in @('gcloud','terraform','git')) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) {
    Ok "$cmd presente"
  } else {
    Fail "$cmd no encontrado"
  }
}

if (Get-Command terraform -ErrorAction SilentlyContinue) {
  try {
    $tv = (terraform -version 2>$null | Select-Object -First 1) -replace 'Terraform v',''
    $cmp = [version]$tv -ge [version]'1.5'
    if ($cmp) {
      Ok "terraform $tv"
    } else {
      Fail "terraform $tv (necesita >= 1.5)"
    }
  } catch {
    Warn "No se pudo parsear la version de terraform"
  }
}

# Autenticacion
Sect "Autenticacion"

try {
  $tok = gcloud auth application-default print-access-token 2>$null
  if ($tok) { Ok "ADC: token emitido (long $($tok.Length))" } else { Fail "ADC sin token" }
} catch {
  Fail "ADC no configurado. Ejecuta: gcloud auth application-default login"
}

$active = gcloud config get-value account 2>$null
if ($active) { Ok "Cuenta activa: $active" } else { Fail "Sin cuenta gcloud" }

# Proyecto
Sect "Proyecto GCP"

if (-not $env:PROJECT_ID) {
  Fail "PROJECT_ID no definido"
} else {
  $proj = gcloud projects describe $env:PROJECT_ID --format="value(projectId)" 2>$null
  if ($proj -eq $env:PROJECT_ID) {
    Ok "Proyecto $env:PROJECT_ID existe"
  } else {
    Fail "Proyecto $env:PROJECT_ID NO existe"
  }

  $billing = gcloud billing projects describe $env:PROJECT_ID --format="value(billingAccountName)" 2>$null
  if ($billing -and $billing -ne 'billingAccountName is not set') {
    Ok "Billing asociado: $billing"
  } else {
    Fail "Billing no asociado"
  }
}

# Defaults
Sect "Defaults de gcloud"

$region = gcloud config get-value compute/region 2>$null
$zone = gcloud config get-value compute/zone 2>$null
if ($region) { Ok "compute/region: $region" } else { Warn "compute/region sin definir" }
if ($zone)   { Ok "compute/zone: $zone" }     else { Warn "compute/zone sin definir" }

# APIs
Sect "APIs habilitadas"

foreach ($api in @('compute.googleapis.com','storage-api.googleapis.com','cloudresourcemanager.googleapis.com','iam.googleapis.com')) {
  $enabled = gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>$null
  if ($enabled -match [regex]::Escape($api)) {
    Ok $api
  } else {
    Fail "$api (no habilitada)"
  }
}

# Bucket
Sect "Bucket de state"

if ($env:TF_STATE_BUCKET) {
  $exists = gsutil ls -b "gs://$env:TF_STATE_BUCKET" 2>$null
  if ($exists) {
    Ok "Bucket gs://$env:TF_STATE_BUCKET existe"
    $ver = (gsutil versioning get "gs://$env:TF_STATE_BUCKET" 2>$null | Out-String)
    if ($ver -match 'Enabled') { Ok "Versionado ON" } else { Fail "Versionado OFF" }
  } else {
    Fail "Bucket gs://$env:TF_STATE_BUCKET NO existe"
  }
} else {
  Warn "TF_STATE_BUCKET no definido - sin validar"
}

# Veredicto
Sect "Veredicto"

if ($errors -eq 0) {
  Write-Host "OK Todo OK. Listo para el Modulo 1." -ForegroundColor Green
  exit 0
} else {
  Write-Host "FAIL Hay $errors problema(s) a resolver." -ForegroundColor Red
  Write-Host "Revisa module-0/troubleshooting.md o contacta al formador." -ForegroundColor Yellow
  exit 1
}