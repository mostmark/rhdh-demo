# rhdh-demo

Bootstrap an empty OpenShift cluster into a Red Hat Developer Hub (RHDH) 2.1 demo
environment: one script installs OpenShift GitOps, then Argo CD installs everything
else from this repository.

> **Status:** `main` is verified with a fresh bootstrap on a single-node OpenShift 4.22
> cluster: Developer Hub 2.1.0 with Keycloak sign-in and users/groups from Keycloak,
> GitLab, a demo layer with catalog, workloads and a software template (GitLab repo,
> Tekton build, Argo CD deployment), plus the Orchestrator, Dev Spaces and Quay.
>
> **To do:** Clair for Quay, so the Quay tab shows real vulnerability results
> (`components/quay/values.yaml` already points `scanner.endpoint` at `http://clair:8080`).

## What you get

| Component | How | Notes |
|---|---|---|
| OpenShift GitOps | `bootstrap.sh` (Subscription, channel `gitops-1.22`) | Platform Argo CD (`openshift-gitops`) that syncs this repo |
| OpenShift Pipelines | Argo CD, Subscription | Tekton for templates and the Tekton tab |
| GitLab | Argo CD, single `gitlab-ce` container + PVC | In-cluster Git server; sign-in through Keycloak |
| Keycloak configuration | Argo CD hook Jobs | Uses the cluster's existing Keycloak and realm `sso`: clients (platform), teams and people (from the demo layer) |
| Apps from templates | `demo-apps` AppProject + ApplicationSet `service-apps` in the platform Argo CD | Every repo in GitLab group `development` with a `deploy/` folder becomes an app in `demo-<repo>`, in the owning team's project `team-<team>` (GitLab topic set by the template) or else `demo-apps`; only GitLab sources, `demo-*` namespaces, Namespace as the only cluster-scoped kind |
| CI for those apps | Argo CD, Tekton EventListener (`rhdh-demo-ci`) + GitLab system hook | Every push to `main` in `development` runs the repo's pipeline `<repo>-ci` |
| Developer Hub 2.1 | Argo CD, RHDH operator (`fast-2.1`) + `Backstage` CR | Keycloak sign-in, users from Keycloak, RBAC per team (*Administration → RBAC*) |
| Team access | Demo-layer hook Job `team-access` | From the demo organisation: Developer Hub roles (platform team → `platform-admin`, other teams → `developer`), one OpenShift group and one Argo CD project per team (each team sees its own apps) |
| Demo layer | Argo CD app reading a repo in the in-cluster GitLab | Branding, teams and people, catalog, workloads: changed per demo without touching this repo |

| Orchestrator | Argo CD: Serverless (`stable-1.37`) + Serverless Logic (1.39.2) operators, Knative, the CR's `orchestrator` flavour | Sample workflow `greeting` (prebuilt image); Notifications + Signals |
| Dev Spaces | Argo CD: operator + CheCluster | `https://devspaces.<apps>`, sign-in through OpenShift (Keycloak), GitLab OAuth for clone/push; template repos get an *Open in Dev Spaces* link and a devfile |
| Quay | Argo CD: Quay 3.17 + PostgreSQL + Redis as plain Deployments | **Demo-grade**: images on a PVC (LocalStorage); scanning switched on but no Clair yet, so tags show *Queued*; `https://quay.<apps>`, admin `quayadmin`; Quay tab in Developer Hub (no token: public repositories) |

Each of these three can be switched off with the root Application's toggles
(`components.orchestrator`, `components.devSpaces`, `components.quay`).

Requirements: OpenShift 4.19–4.22 with a default storage class, a trusted ingress
certificate, the Red Hat build of Keycloak with realm `sso` (as provided by the target
cluster type), and `oc` logged in as cluster admin. A single node (32 vCPU, 128 GiB,
250 pods) fits phase 1 and 2.

## How it works

```
bootstrap.sh
 ├─ checks the oc login, reads the apps domain
 ├─ installs the OpenShift GitOps operator, waits for the openshift-gitops Argo CD
 ├─ gives its application controller the permissions to install operators
 ├─ generates the secrets in the cluster (never in Git): demo password, GitLab root
 │  password, Keycloak client secrets, RHDH session and backend secrets
 └─ applies bootstrap/root-app.yaml with parameters: apps domain, repo URL, revision,
    component toggles
root Application (Helm chart charts/root) → one Application per component, sync waves:
 wave 0  operators: Pipelines, RHDH operator
         devspaces (operator, CheCluster; before the gitlab seed writes its OAuth Secret)
 wave 1  gitlab (+ PostSync seed Job: groups, demo-layer repo, Developer Hub token)
         keycloak-config (PostSync Job: clients rhdh and gitlab in realm sso)
         gitops-config (demo-apps AppProject, ApplicationSet service-apps,
                       PostSync Job: Argo CD token for Developer Hub)
         ci-triggers (EventListener: GitLab pushes start service pipelines)
         orchestrator-infra (Serverless, Serverless Logic, KnativeServing/Eventing)
         quay (Quay, PostgreSQL, Redis; Jobs: secrets, first user quayadmin)
 wave 2  demo-layer (Application → in-cluster GitLab repo demo/rhdh-demo-config,
         + components/demo-layer-hooks: Quay sync (Sync hook, before the workload apps:
           organisation, public repos, image tags), team access (Sync hook, before the
           workload apps: Developer Hub RBAC policy, OpenShift groups, Argo CD projects
           team-<team>), org sync (PostSync: teams and
           people → Keycloak) and GitLab access (PostSync: people → Developers in
           `development`))
 wave 3  developer-hub (ConfigMaps, Backstage CR, Kubernetes reader)
 wave 4  orchestrator-workflows (SonataFlow greeting)
```

## Repository layout

```
bootstrap.sh                      # the only thing you run
bootstrap/root-app.yaml           # template for the root Application (parameters filled in by the script)
charts/root/                      # Helm chart: renders the per-component Applications
components/
  operators/                      # Subscriptions/OperatorGroups (Pipelines, RHDH)
  gitlab/                         # GitLab Deployment, PVCs, Route, seed Job; files/demo-layer-seed = initial demo layer
  keycloak-config/                # Job: clients in realm sso
  demo-layer-hooks/               # Jobs run on every demo-layer sync: team access (RBAC, groups, Argo CD projects), Keycloak org sync, GitLab access, Quay sync
  gitops-config/                  # demo-apps AppProject, ApplicationSet service-apps, Argo CD token Job
  ci-triggers/                    # Tekton EventListener for GitLab push events
  developer-hub/                  # Backstage CR, base app-config, dynamic plugins, Kubernetes reader
  orchestrator-infra/             # Serverless + Serverless Logic operators, Knative
  orchestrator-workflows/         # sample workflow greeting
  devspaces/                      # Dev Spaces operator + CheCluster
  quay/                           # demo-grade Quay
docs/                             # design notes, versions, troubleshooting
```

No secrets, passwords or cluster domains are committed; the domain and the toggles are
parameters of the root Application.

## Developer Hub configuration (verified on RHDH 2.1.0)

- `Backstage` CR `v1alpha5`: `flavours` with `intelligent-assistant` disabled; a
  `deployment.patch` raising the `dynamic-plugins-root` volume to 5Gi (the 2Gi default
  is too small for this plugin set).
- Plugins: GA and Technology Preview plugins by `ref://` name; the community Argo CD,
  Roadie Argo CD and Tekton plugins by pinned `oci://ghcr.io/…@sha256:` references
  (they are not in the plugin catalog index, so `ref://` fails for them).
- Sign-in: native Keycloak provider, `signInPage: keycloak`; users and groups imported
  with the Keycloak org provider. Catalog provider modules are only enabled together
  with their configuration (otherwise backend startup fails silently).
- Network: RHDH runs behind default-deny NetworkPolicies that allow only 443/6443 out,
  so it reaches GitLab, Keycloak and Argo CD through their routes.
- Kubernetes/Topology plugins use a read-only ClusterRole for their service account
  (no `cluster-admin`) and verify the API server with the cluster CA (`caFile`, mounted
  from the service account's token Secret). This needs
  `GLOBAL_AGENT_FORCE_GLOBAL_AGENT=false`: the backend's corporate-proxy support
  otherwise replaces the plugin's TLS settings (`skipTLSVerify` doesn't work either).
- The operator mounts each app-config ConfigMap key as a file under
  `/opt/app-root/src/`, so keys must be unique across ConfigMaps (here
  `app-config-base.yaml`, `app-config-demo.yaml`); a duplicate key silently replaces the
  other file. It doesn't retry when a referenced ConfigMap appears later, which is why
  the demo layer syncs in an earlier wave.
- RBAC: `permission.enabled` with the RBAC backend's CSV and conditional policy files
  from ConfigMap `rbac-policies` (written by the team-access hook), mounted as a
  directory, so `policyFileReload` applies changes without a restart. The RBAC page is
  `ref://backstage-community-plugin-rbac`. Roles need `homepage.default-widgets.read`,
  or the Home page shows no default widgets. Roles created on the RBAC page are stored
  in the database and survive restarts.
- The plugins' default configs read environment variables and use fixed provider ids
  (`gitlab.default`, `keycloakOrg.default`); the app-config uses the same ids.

## Sync ordering

`bootstrap.sh` adds two Argo CD health checks so the sync waves really wait:
an `Application` counts as healthy only once it is Synced (otherwise an app whose repo
isn't reachable yet reports Healthy), and a `Backstage` resource only once its
`Deployed` condition is `True`.

## The demo layer

The repo `demo/rhdh-demo-config` in the in-cluster GitLab holds everything that changes
per demo (see its README): `manifests/` (synced by Argo CD: `app-config-demo.yaml` with
branding and catalog locations, `keycloak-org.yaml` with teams and people, Argo CD
Applications for workloads), `catalog/` (entities, read by Developer Hub) and `apps/`
(workload manifests). Teams and people live in Keycloak: the org sync Job creates them
with the demo password and deletes the ones removed from `keycloak-org.yaml`; Developer
Hub imports them from Keycloak. The GitLab access Job gives the same people a GitLab
account (signed in through Keycloak) and the Developer role in `development`, where
Developers may push and merge to `main` (so pushes from Dev Spaces start the CI
pipeline); people removed from the org lose that membership.

Software templates live in the demo repo's `templates/`. The seeded `web-service`
template creates a repo in `development` with a Dockerfile-style `Containerfile`, a
Tekton pipeline (git-clone, buildah into the cluster registry, rollout) and manifests in
`deploy/`; the ApplicationSet deploys it, a sync hook runs the first build, and pushes
trigger later builds.

**Team access** (`team-access` hook, every sync): the platform team (`"platform": true`
in `keycloak-org.yaml`, else the team named `platform-team`) gets the Developer Hub role
`platform-admin` (everything, including the RBAC page) and sees all demo apps in Argo
CD (OpenShift group `rhdh-demo-platform-admins`). Every other team gets `developer`: it
reads the whole catalog except templates tagged `platform-only`, runs templates and
workflows, and refreshes or unregisters only what it owns; in Argo CD it sees the apps
in its project `team-<team>` (read-only, with logs). The roles are platform defaults
(`components/demo-layer-hooks/files/rbac-roles.csv`, `conditional-policies.yaml`); a
demo replaces them with a ConfigMap `rbac-roles` in namespace `rhdh` (same keys, sync
wave `-2`), and if its CSV has `g` lines no bindings are generated. `keycloak-org.yaml`
must be in sync wave `-2`, so the hook sees a new organisation before the workload apps
need its projects.

The seed Job writes a small sample demo and keeps it current while the repo holds only
seed commits; after your first commit the repo is yours.

## Security notes

- The platform Argo CD's application controller gets cluster-admin, because it
  installs operators and CRDs. Template-created apps go into the restricted
  `demo-apps` AppProject; Developer Hub's Argo CD account (`rhdh`) can only see and
  manage applications in that project and the team projects `team-*`. Signed-in users
  get no default role: the platform team (OpenShift group `rhdh-demo-platform-admins`)
  has read-only access, including logs, to all demo projects, every other team to its
  own `team-<team>` project; platform applications stay hidden.
- The team-access Job may create, change and delete OpenShift Groups cluster-wide
  (the names are dynamic, so RBAC can't narrow it down). It only touches groups with the
  label `rhdh-demo/team-access=true` and never takes over an existing group of the same
  name.
- The Keycloak Job reads the existing admin credentials (`keycloak-initial-admin`) to
  add clients and users to realm `sso`; it does not change the realm import.
- The `demo-layer` Application runs in the `default` AppProject with the cluster-admin
  controller, so whoever can push to `demo/rhdh-demo-config` can change anything on the
  cluster. Keep that repo's write access to the people running the demo.
- Quay is demo-grade: one pod, images on a PVC, no vulnerability scanning yet (Clair
  is a to-do), new repositories public. Its admin credentials and an API token stay in
  Secret `quay/quay-admin`; the Quay sync Job uses them, Developer Hub doesn't get a
  token. The token belongs to the OAuth application `rhdh-demo-automation` in
  organization `platform` (10 years; repository and organization admin scopes, user
  admin to create organizations, no superuser scope). Revoke it there if needed; a
  sync of the `quay` application issues a new one.
- The GitLab OAuth application for Dev Spaces is trusted (no consent screen); its secret
  is in `openshift-devspaces/devspaces-gitlab-oauth`.
- Demo users share one password, generated by `bootstrap.sh` (or given with
  `DEMO_PASSWORD`). It's meant for short-lived demo clusters.

## Testing

Argo CD syncs from Git, so changes are tested from the `wip` branch:
`REVISION=wip ./bootstrap.sh`.
