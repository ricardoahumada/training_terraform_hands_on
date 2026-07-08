# Apunte — Patrón simple: rol por usuario (usuario) en GCP con Terraform

> Complemento al lab 4. Caso de uso: asignar a la cuenta de un usuario un rol
> que le permita manipular la base de datos (`roles/cloudsql.client`) y
> apoyarse en la SA del tier app para leer el secreto de la password.

## 1. Variable con los usuarios (en el módulo `iam`)

Añadir en `infra/modules/iam/locals.tf`:

```hcl
locals {
  usuarios = toset([
    "usuario1@netmind.es",
    # añadir más emails según el curso
  ])
}
```

## 2. Roles a nivel de proyecto

Añadir en `infra/modules/iam/main.tf`:

```hcl
# --- usuarios: conexión a Cloud SQL y lectura del secreto ---

resource "google_project_iam_member" "usuario_cloudsql_client" {
  for_each = local.usuarios

  project = data.google_project.project.project_id
  role    = "roles/cloudsql.client"
  member  = "user:${each.key}"
}

resource "google_project_iam_member" "usuario_secret_accessor" {
  for_each = local.usuarios

  project = data.google_project.project.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "user:${each.key}"
}
```

## 3. Impersonation de la SA del tier app

Para que el usuario pueda actuar como la SA y leer el secreto sin descargar
keys, añadir el binding IAM sobre la SA:

```hcl
resource "google_service_account_iam_member" "usuario_token_creator" {
  for_each = local.usuarios

  service_account_id = google_service_account.app.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.key}"
}
```

## 4. Aplicar

```bash
cd infra/envs/dev
terraform apply -target="module.iam"
```

Esperar ~30 s tras el apply (la propagación IAM tiene consistencia eventual).

## 5. Verificación desde la cuenta del usuario

```bash
# ¿Qué roles efectivos tengo?
gcloud projects get-iam-policy ${TF_VAR_project_id} \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:usuario1@netmind.es" \
  --format="table(bindings.role)"

# Leer el secreto impersonando a la SA
gcloud secrets versions access latest \
  --secret=applocker-db-password \
  --project=${TF_VAR_project_id} \
  --impersonate-service-account=sa-app-${TF_VAR_env}-${TF_VAR_suffix}@${TF_VAR_project_id}.iam.gserviceaccount.com

# Conectarse a la BD
gcloud sql connect applocker-db-${TF_VAR_env}-${TF_VAR_suffix} \
  --user=applocker_app \
  --project=${TF_VAR_project_id} \
  --quiet
```

## 6. Reglas prácticas

- `member = "user:<email>"` exige que el usuario sea un usuario del Workspace (o del IdP federado). Emails personales externos fallan al binding.
- Para grupos de usuarios (más de ~5), usar un grupo de Workspace y `member = "group:<email-grupo>"`.
- `roles/cloudsql.client` solo abre conexiones; no permite crear/eliminar instancias ni usuarios de BD. Si necesitas DDL, añade un rol superior con justificación y revisión.
- Quitar un usuario: sacar su email de `locals.usuarios` y volver a `terraform apply -target="module.iam"`. No requiere `destroy`.

## 7. Rol personalizado para usuarios

### 7.1 Por qué un rol custom

Los roles predefinidos de GCP agrupan permisos que a veces son demasiado amplios (p. ej. `roles/cloudsql.client` permite listar/borrar databases). Para los usuarios conviene un rol con permisos *exactos* sobre la BD del lab, evitando DDL destructivo.

### 7.2 Definición del rol

Crear `infra/modules/iam/custom-role.tf`:

```hcl
resource "google_project_iam_custom_role" "usuario_db_user" {
  project     = data.google_project.project.project_id
  role_id     = "usuarioDbUser"
  title       = "usuario DB User (lab)"
  description = "Acceso mínimo a Cloud SQL: connect, list y read sobre databases/users del usuario."
  stage       = "GA"

  permissions = [
    "cloudsql.instances.connect",
    "cloudsql.instances.get",
    "cloudsql.databases.get",
    "cloudsql.databases.list",
    "cloudsql.users.list",
    "secretmanager.versions.access",
  ]
}
```

Notas:
- `role_id` debe ser único en el proyecto, lowercase y sin espacios.
- `stage` puede ser `GA`, `BETA` o `ALPHA` según madurez.
- Los permisos deben estar **habilitados a nivel de API** en el proyecto; si no, fallan silenciosamente al evaluarlos.

### 7.3 Asignación a los usuarios

Reusar `for_each = local.usuarios`:

```hcl
resource "google_project_iam_member" "usuario_custom_db" {
  for_each = local.usuarios

  project = data.google_project.project.project_id
  role    = google_project_iam_custom_role.usuario_db_user.id
  member  = "user:${each.key}"
}
```

### 7.4 Aplicar

Doble `apply` recomendado: el primero crea el rol (la API exige que exista antes de cualquier binding), el segundo asigna.

```bash
cd infra/envs/dev
terraform apply -target="google_project_iam_custom_role.usuario_db_user"
terraform apply -target="module.iam"
```

### 7.5 Verificación

```bash
# ¿Qué permisos tiene el rol?
gcloud iam roles describe usuarioDbUser --project=${TF_VAR_project_id}

# ¿Lo tengo asignado?
gcloud projects get-iam-policy ${TF_VAR_project_id} \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:usuario1@netmind.es" \
  --format="table(bindings.role)"
```

### 7.6 Reglas prácticas

- Limitar `permissions` al mínimo; revisar con `gcloud iam roles describe <rol>`.
- No incluir `cloudsql.instances.*` (mutaciones) ni `cloudsql.users.create`/`update`.
- Si el usuario necesita crear tablas → `cloudsql.databases.create` *solo* bajo justificación.
- Custom roles son **idempotentes**: Terraform detecta cambios en `permissions` y hace `update`.
- Para borrar: `terraform destroy -target="google_project_iam_member.usuario_custom_db"` primero (bindings), luego `terraform destroy -target="google_project_iam_custom_role.usuario_db_user"`.

## 8. Prácticas recomendadas

### ✅ Cosas que SÍ se deben hacer

- Definir la lista de usuarios en un `local` único.
- Usar `for_each = local.usuarios` para que el módulo sea idempotente.
- Mantener al usuario solo con el set mínimo de roles necesarios.
- Definir el rol custom **antes** de cualquier binding que lo referencie (orden de `terraform apply`).
- Empezar con un set mínimo de permisos en el rol custom e ir abriendo por necesidad.

### ❌ Cosas que NO se deben hacer

- NO dar `roles/owner` ni `roles/cloudsql.admin` por defecto.
- NO mezclar usuarios en `locals.usuarios` con SAs en los mismos archivos sin separación clara.
- NO usar `google_project_iam_policy` (sustituye toda la policy del proyecto y borra bindings que no estén en el HCL).
- NO añadir el email del usuario como `var` por usuario: usar `toset()` y `for_each`.
- NO dar `roles/owner` "temporal" en lugar de crear el rol custom.
- NO incluir permisos que no se entiendan: leer primero la doc de cada permiso (`gcloud iam roles describe --flatten`).
- NO mezclar permisos de lectura y escritura en el mismo rol si la intención es "solo lectura".

## 9. Referencias

- IAM — `roles/cloudsql.client`: <https://cloud.google.com/sql/docs/postgres/iam-roles>
- IAM — predefined roles: <https://cloud.google.com/iam/docs/understanding-roles>
- IAM — `serviceAccountTokenCreator`: <https://cloud.google.com/iam/docs/service-accounts#the_service_account_token_creator_role>
- Terraform — `google_project_iam_member`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam_member>
- Terraform — `google_service_account_iam_member`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_service_account_iam_member>
- IAM — Custom roles: <https://cloud.google.com/iam/docs/understanding-custom-roles>
- Terraform — `google_project_iam_custom_role`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam_custom_role>
