# Pasos para recrear todo desde un proyecto nuevo

1. **Crear proyecto nuevo** en la consola GCP (o por gcloud):
   ```powershell
   gcloud projects create terraform-course-XXXX --name="TU_PROJECT_ID"
   ```

2. **Vincular billing** (obligatorio). Desde consola: Billing → proyecto → Vincular cuenta de pago. O por gcloud:
   ```powershell
   gcloud billing projects link NUEVO_PROYECTO --billing-account=XXXX-XXXX-XXXX

   gcloud auth application-default set-quota-project TU_PROJECT_ID
   ```

3. **Habilitar las APIs** mínimas que usan los labs. Te las dejo en un solo bloque (las he ido viendo a lo largo de los labs):
   ```powershell
   gcloud services enable `
     compute.googleapis.com `
     sqladmin.googleapis.com `
     servicenetworking.googleapis.com `
     cloudresourcemanager.googleapis.com `
     cloudresourcemanager.googleapis.com `
     iam.googleapis.com `
     secretmanager.googleapis.com `
     --project=TU_PROJECT_ID
   ```

4. **Ejecutar el bootstrap (módulo 0)**. Esto crea el bucket de state en **tu proyecto nuevo**, con el patrón `applocker-tf-state-${USER}` o el nombre que el `terraform-bootstrap.tf` decida:
   ```powershell
   cd module-0
   terraform -chdir=module-0 init
   terraform -chdir=module-0 apply -auto-approve
   ```
   El bootstrap te dirá el nombre exacto del bucket al terminar (output `tf_state_bucket`).

5. **Inyectar variables de entorno** (el ya conocido `1.1` del lab 1):
   ```powershell
   $env:TF_STATE_BUCKET   = "applocker-tf-state-NUEVO_PROYECTO"   # nombre del bucket del bootstrap
   $env:TF_VAR_project_id = "NUEVO_PROYECTO"
   $env:TF_VAR_region     = "us-central1"
   $env:TF_VAR_env        = "dev"
   ```

6. **Crear secreto DB** (lo pide el módulo cloudsql cuando consumas el zip):
   ```powershell
   echo -n "TerraformHandsOn2026!" | gcloud secrets create applocker-db-password `
     --project=NUEVO_PROYECTO --replication-policy=automatic --data-file=-
   ```

7. **Actualizar el lab 3**. **Como ahora `$TF_STATE_BUCKET` apunta al bucket del nuevo proyecto**, el mismo lab debería "casi" funcionar, pero hay dos arreglos pendientes antes del primer `terraform init`:

   - **main.tf línea 29** (cloudsql). Hoy dice `mediamarkt-tf-prod-260630-tf-modules`. Cámbialo a `applocker-tf-state-NUEVO_PROYECTO` (o usa el módulo local `source = "./modules/cloudsql"`). Si publicas un registry real, sustituye esa ruta.

   - **`backend.tf` en `module-3/labs/infra/live/network/cloudsql/compute/`**. Cambia `bucket` por el bucket real del nuevo proyecto.

