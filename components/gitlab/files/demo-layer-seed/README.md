# Demo layer

Per-demo configuration for Developer Hub, synced by Argo CD (application `demo-layer`)
into the `rhdh` namespace. Change it here to brand the portal or change the catalog;
Developer Hub restarts automatically when `manifests/app-config-demo.yaml` changes.

- `manifests/app-config-demo.yaml`: app-config overrides (title, branding, catalog
  locations). Loaded after the platform's base config, so it wins.
- `catalog/`: catalog entities. Teams and people come from Keycloak (realm `sso`), so
  use Keycloak group names as owners (e.g. `group:default/platform-team`).
