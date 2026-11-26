# Demo layer

Per-demo configuration for Developer Hub, synced by Argo CD (application `demo-layer`)
into the `rhdh` namespace. Change it here to brand the portal or change the catalog;
Developer Hub restarts automatically when `manifests/app-config-demo.yaml` changes.

- `manifests/app-config-demo.yaml`: app-config overrides (title, branding, catalog
  locations). Loaded after the platform's base config, so it wins.
- `manifests/keycloak-org.yaml`: the demo organisation (teams and people). The
  platform's org sync Job applies it to Keycloak realm `sso` after every sync; Developer
  Hub imports users and groups from there. Removing someone here removes them.
- `catalog/`: catalog entities. Teams and people come from Keycloak, so use the team
  names from `keycloak-org.yaml` as owners (e.g. `group:default/platform-team`).
- `manifests/hello-service-app.yaml` + `apps/hello-service/`: a sample workload
  (Deployment, Route, Tekton pipeline) that Argo CD deploys to `demo-hello` in the
  `demo-apps` project; it fills the Argo CD, Topology, Kubernetes and Tekton tabs of the
  `hello-service` component. Delete both to remove it.

- `templates/`: software templates (`templates/all.yaml` is registered in the app-config).
  `web-service` creates a repo in GitLab group `development` with a Tekton pipeline and
  Kubernetes manifests in `deploy/`; the platform's ApplicationSet `service-apps` deploys
  every such repo to `demo-<name>`, and every push to `main` runs the pipeline.

The bootstrap's seed Job keeps this repo up to date with the platform's seed content
only as long as every commit here is a seed commit. Once you commit yourself, the seed
leaves the repo alone.
