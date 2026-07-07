# Módulo 3 — Lab integrador (AppLocker 3-tier)

Código Terraform listo para `terraform init/plan/apply` siguiendo el guion de
[`../lab-3.md`](../lab-3.md).

## Estructura

```
infra/live/
├── network/    VPC, subnets, Cloud Router/NAT, firewalls, peering con services
├── compute/    Instance template, health check, MIG con autohealing
└── cloudsql/   Cloud SQL for PostgreSQL privado con HA, módulo cloudsql@1.0.0
```

## Orden de aplicación

Los stacks están desacoplados por state pero tienen dependencias de datos.
Aplicar **siempre** en este orden:

1. `network` — VPC + subnets + NAT + firewall + peering con services.
2. `compute` — MIG del tier `app` (necesita la subnet `app` y la VPC).
3. `cloudsql` — PostgreSQL privado (necesita la VPC y el peering).

## Configuración previa

Antes de empezar:

1. Sustituir `<sufijo>` en los tres `backend.tf` por el sufijo real del bucket
   creado en M1.
2. Copiar cada `terraform.tfvars.example` a `terraform.tfvars` y rellenar:
   - `project_id`, `region`, `env` (compartidos).
   - En `compute` y `cloudsql`: pegar los `self_link` reales obtenidos con
     `terraform output` desde el stack `network`.

## Variación respecto al guion

El guion de la Parte 6 (10.2) muestra `depends_on = [var.network_self_link]`,
que es **inválido** en Terraform (`depends_on` solo admite referencias a
recursos, no a variables). Aquí se sustituye por un recurso `terraform_data`
trivially dependiente de la variable, que sí expresa la orden de aplicación:

```hcl
resource "terraform_data" "peering_dependency" {
  input = var.network_self_link
}

module "cloudsql" {
  # ...
  depends_on = [terraform_data.peering_dependency]
}
```

## Limpieza

NO destruir los recursos durante el curso: son la base de M4 (seguridad),
M5 (GitOps) y M6 (migración zero-downtime). Solo limpiar los artefactos
locales si el formador lo pide:

```bash
for d in network compute cloudsql; do
  rm -rf "$d/.terraform" "$d"/*.tfstate*
done
```