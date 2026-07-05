# bootstrap.ps1 - Terraform Hands-on (MediaMarkt / GCP)
# Pre-flight setup antes del Modulo 1 (Windows PowerShell 5.1+).
# Idempotente e interactivo.

$ErrorActionPreference = 'Continue'
# NOTA: usamos 'Continue' en vez de 'Stop' porque muchos comandos gcloud/gsutil
# lanzan excepciones no-terminantes en casos ESPERADOS (proyecto no existe,
# bucket no existe, etc.). Las manejamos explicitamente con try/catch o
# capturando $LASTEXITCODE tras cmd /c.

# Helpers
function Write-Info { param($m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Section    { param($m) Write-Host "" ; Write-Host "-- $m --" -ForegroundColor Magenta }

# Verificaciones previas
Section "Verificando pre-requisitos"

foreach ($cmd in @('gcloud','terraform','gsutil','git')) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Err "$cmd no esta instalado. Ver anexo seccion 1.1 / 2."
    exit 1
  }
}
Write-Ok "Toolchain basica presente"

# Configuracion
Section "Configuracion"

$defaultOrg = "mediamarkt"
$defaultEnv = "prod"

$org = Read-Host "Empresa / organizacion [$defaultOrg]"
if ([string]::IsNullOrWhiteSpace($org)) { $org = $defaultOrg }

$env = Read-Host "Entorno (dev/staging/prod) [$defaultEnv]"
if ([string]::IsNullOrWhiteSpace($env)) { $env = $defaultEnv }
if ($env -notin @('dev','staging','prod')) {
  Write-Err "Entorno invalido."
  exit 1
}

$defaultSuffix = (Get-Date).ToString('yyMMdd')
$suffix = Read-Host "Sufijo unico (letras/digitos) [$defaultSuffix]"
if ([string]::IsNullOrWhiteSpace($suffix)) { $suffix = $defaultSuffix }

$projectId = "$org-tf-$env-$suffix"
$bucketName = "tfstate-$org-tf-$env-$suffix"
$region = "us-central1"
$zone = "us-central1-a"

Write-Info "Project ID:     $projectId"
Write-Info "Bucket state:   gs://$bucketName"
Write-Info "Region / Zone:  $region / $zone"
Write-Host ""
Write-Warn "Si el Project ID ya existe en GCP, este script fallara."
Write-Warn "Es un identificador UNICO A NIVEL MUNDIAL ÔÇö elegi un sufijo que te identifique."
$confirm = Read-Host "Continuar? [y/N]"
if ($confirm -notin @('y','Y','yes','YES')) {
  Write-Info "Cancelado."
  exit 0
}

# Login y proyecto
Section "Autenticacion"

$activeAccount = gcloud config get-value account 2>$null
if ([string]::IsNullOrWhiteSpace($activeAccount)) {
  Write-Warn "No hay cuenta activa. Ejecutando gcloud auth login..."
  gcloud auth login
} else {
  Write-Ok "Cuenta activa: $activeAccount"
}

# Detectar la primera organizacion accesible. Se usara como parent al crear
# el proyecto. Si la cuenta no pertenece a ninguna org, queda vacia y el
# proyecto se crea sin parent (comportamiento legacy de cuentas personales).
$orgId = cmd /c "gcloud organizations list --format=value(name) --limit=1 2>&1"
$orgId = ($orgId | Select-Object -First 1).Trim()
# El formato es "organizations/XXXXXX" pero --organization espera solo el ID.
if ($orgId -match '^organizations/(.+)$') { $orgId = $Matches[1] }
if (-not [string]::IsNullOrWhiteSpace($orgId)) {
  Write-Ok "Organizacion: $orgId (se asociara al crear el proyecto)"
} else {
  Write-Info "Sin organizacion detectable (cuenta personal o sin permisos). El proyecto se creara sin parent."
}

# ADC
$adcScopes = 'https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email'
try {
  $null = gcloud auth application-default print-access-token 2>$null
  Write-Ok "ADC configurado"
} catch {
  Write-Warn "ADC no configurado. Iniciando flujo OAuth..."
  Write-Info "Si tu organizacion restringe scopes, se te pedira consentimiento para 'cloud-platform'."
  Write-Info "En la pantalla de Google: cliquea 'Permitir' cuando pida permisos ampliados."
  Write-Host ""

  # Intento 1: navegador + scopes explicitos
  try {
    gcloud auth application-default login --scopes=$adcScopes
  } catch {
    Write-Warn "Fallo con navegador. Reintentando en modo headless (pega la URL manualmente)..."
    Write-Host ""
    # Intento 2: --no-launch-browser para entornos sin GUI / politicas restrictivas
    gcloud auth application-default login --no-launch-browser --scopes=$adcScopes
  }

  # Verificacion final
  try {
    $null = gcloud auth application-default print-access-token 2>$null
    Write-Ok "ADC configurado correctamente"
  } catch {
    Write-Err "ADC sigue sin funcionar. Opciones:"
    Write-Host "  1. Verifica que en la pantalla de Google clicaste 'Permitir' (no 'Cancelar')." -ForegroundColor Gray
    Write-Host "  2. Si tu organizacion bloquea el scope cloud-platform, pide al formador una service account key:" -ForegroundColor Gray
    Write-Host "     `$env:GOOGLE_APPLICATION_CREDENTIALS = 'C:\path\to\sa-key.json'" -ForegroundColor Gray
    exit 1
  }
}

# Verificar / crear proyecto
Section "Proyecto GCP"

# Estrategia de deteccion robusta: un proyecto existe si CUALQUIERA de estas
# dos condiciones se cumple:
#   1. `gcloud projects describe` devuelve el projectId exacto (tenemos acceso).
#   2. `gcloud projects list --filter` lo lista (existe en nuestro namespace).
# Esto evita el caso clasico donde `describe` falla con "does not have permission"
# sobre un proyecto que SI existe pero donde no somos owner.
$describeOut = cmd /c "gcloud projects describe $projectId --format=value(projectId) 2>&1"
$listOut = cmd /c "gcloud projects list --format=value(projectId) --filter=projectId=$projectId 2>&1"

$seenInDescribe = ($describeOut | Select-String -Pattern "^$projectId$").Line -eq $projectId
$seenInList     = $listOut -match [regex]::Escape($projectId)
$projectExists  = $seenInDescribe -or $seenInList

if ($projectExists) {
  if ($seenInDescribe) {
    Write-Ok "Proyecto $projectId existe y la cuenta activa tiene acceso directo"
  } else {
    # Aparece en list pero no en describe: existe pero la cuenta activa no es owner.
    # Aun asi lo usamos (Terraform solo necesita los scopes correctos para actuar),
    # pero avisamos al usuario.
    Write-Warn "Proyecto $projectId existe, pero la cuenta activa no es owner."
    Write-Warn "Se usara tal cual. Algunas operaciones Terraform podrian requerir"
    Write-Warn "que el formador te agregue como 'roles/owner' o 'roles/editor'."
  }
} else {
  Write-Warn "Proyecto $projectId NO existe. Creando..."
  # GCP limita display_name a 30 chars. Truncamos con $env al final que es lo
  # mas distintivo (dev/staging/prod).
  $displayName = "TF Course $env"
  if ($displayName.Length -gt 30) { $displayName = $displayName.Substring(0, 30) }

  # Intentar crear asociado a la organizacion. Si falla por permisos
  # (comun si la cuenta no tiene resourcemanager.projects.create sobre la org),
  # fallback a creacion sin parent.
  if (-not [string]::IsNullOrWhiteSpace($orgId)) {
    $createOut = cmd /c "gcloud projects create $projectId --name=`"$displayName`" --organization=$orgId 2>&1"
    if ($LASTEXITCODE -ne 0) {
      Write-Warn "No se pudo crear bajo la organizacion $orgId (fallo de permisos?). Fallback a creacion sin parent."
      Write-Host "  Detalle: $createOut" -ForegroundColor Gray
      $createOut = cmd /c "gcloud projects create $projectId --name=`"$displayName`" 2>&1"
      if ($LASTEXITCODE -ne 0) {
        Write-Err "Fallo creando proyecto. Salida de gcloud:"
        Write-Host $createOut -ForegroundColor Gray
        exit 1
      }
    }
  } else {
    $createOut = cmd /c "gcloud projects create $projectId --name=`"$displayName`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
      Write-Err "Fallo creando proyecto. Salida de gcloud:"
      Write-Host $createOut -ForegroundColor Gray
      exit 1
    }
  }
  Write-Ok "Proyecto creado"

  # Garantizar que la cuenta activa es owner del proyecto recien creado.
  # (gcloud normalmente asigna owner al creador, pero lo explicitamos por si
  # la org tiene politicas que lo impiden.)
  $ownerOut = cmd /c "gcloud projects add-iam-policy-binding $projectId --member=user:$activeAccount --role=roles/owner --quiet 2>&1"
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "Owner asignado: $activeAccount"
  } else {
    Write-Warn "No se pudo asignar owner (probablemente ya lo sos). Continuando..."
  }
}

# Activar el proyecto. Si falla, NO seguir (todo lo demas dependeria de el).
$setOut = cmd /c "gcloud config set project $projectId 2>&1"
$activeProject = cmd /c "gcloud config get-value project 2>&1"
if ($activeProject -ne $projectId) {
  Write-Err "No se pudo activar el proyecto. Activo: '$activeProject', esperado: '$projectId'"
  Write-Host $setOut -ForegroundColor Gray
  exit 1
}
Write-Ok "Proyecto activo: $activeProject"

# Billing
Section "Billing"

try {
  $billing = gcloud billing projects describe $projectId --format="value(billingAccountName)" 2>$null
  if ($billing -and $billing -ne "billingAccountName is not set") {
    Write-Ok "Billing ya asociado: $billing"
  } else { throw "no billing" }
} catch {
  Write-Warn "No hay billing asociado al proyecto."
  $activeBilling = (gcloud billing accounts list --format="value(name)" --limit=1 2>$null | Select-Object -First 1)
  if (-not $activeBilling) {
    Write-Err "No hay cuentas de billing disponibles. Asosciar una desde la consola."
    exit 1
  }
  $billOk = Read-Host "Asociar billing $activeBilling al proyecto? [y/N]"
  if ($billOk -notin @('y','Y','yes','YES')) {
    Write-Err "Sin billing no se puede continuar."
    exit 1
  }
  gcloud billing projects link $projectId --billing-account=$activeBilling
  Write-Ok "Billing asociado"
}

# APIs
Section "Habilitando APIs"

$apis = @(
  'compute.googleapis.com',
  'sqladmin.googleapis.com',
  'storage-api.googleapis.com',
  'secretmanager.googleapis.com',
  'iam.googleapis.com',
  'cloudresourcemanager.googleapis.com',
  'serviceusage.googleapis.com',
  'servicenetworking.googleapis.com'
)

foreach ($api in $apis) {
  $enabled = gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>$null
  if ($enabled -match [regex]::Escape($api)) {
    Write-Ok "API $api ya habilitada"
  } else {
    Write-Info "Habilitando $api..."
    gcloud services enable $api --quiet | Out-Null
  }
}

# Bucket de state
Section "Bucket de state remoto"

# gsutil ls falla con BucketNotFoundException cuando el bucket no existe.
# Capturamos la salida con cmd /c y buscamos el nombre para no depender
# de $null streams (que en PowerShell no silencian excepciones no-terminantes).
$bucketListOut = cmd /c "gsutil ls -b gs://$bucketName 2>&1"
if ($LASTEXITCODE -eq 0 -and $bucketListOut -match [regex]::Escape("gs://$bucketName")) {
  Write-Ok "Bucket gs://$bucketName ya existe"
} else {
  Write-Info "Creando bucket gs://$bucketName..."
  $mbOut = cmd /c "gsutil mb -l $region -b on gs://$bucketName 2>&1"
  if ($LASTEXITCODE -ne 0) {
    Write-Err "Fallo creando bucket. Salida de gsutil:"
    Write-Host $mbOut -ForegroundColor Gray
    exit 1
  }
  Write-Ok "Bucket creado"
}

$versioning = (cmd /c "gsutil versioning get gs://$bucketName 2>&1") | Out-String
if ($versioning -match 'Enabled') {
  Write-Ok "Versionado ya esta ON"
} else {
  Write-Info "Habilitando versionado..."
  $versioningSet = cmd /c "gsutil versioning set on gs://$bucketName 2>&1"
  if ($LASTEXITCODE -ne 0) {
    Write-Err "Fallo habilitando versionado:"
    Write-Host $versioningSet -ForegroundColor Gray
    exit 1
  }
}

# Defaults de gcloud
Section "Defaults de gcloud"

gcloud config set compute/region $region | Out-Null
gcloud config set compute/zone $zone | Out-Null

# Resumen
Section "Resumen"
Write-Host "Project ID:   $projectId"           -ForegroundColor White
Write-Host "Bucket:       gs://$bucketName"     -ForegroundColor White
Write-Host "Region/Zone:  $region / $zone"     -ForegroundColor White
Write-Host "Cuenta:       $(gcloud config get-value account)" -ForegroundColor White
Write-Host ""
Write-Ok "Bootstrap completo. Corre .\verify.ps1 para confirmacion."
Write-Info "Proximo paso: Modulo 1 - State y Remote Backend."
