# Platform software templates

Software templates every demo gets. The `gitlab` component copies this folder, at the
commit Argo CD synced, into the GitLab repo `platform/software-templates` (replacing
`__APPS_DOMAIN__` with the cluster's apps domain) and keeps it current while that repo has
only seed commits. Developer Hub discovers `catalog-info.yaml` there.

| Template | Creates |
|---|---|
| `quarkus-service`: *Quarkus Service with ArgoCD and a Tekton Pipeline* | `development/<name>` (Quarkus app) and `development/<name>-gitops`; Argo CD apps `<name>-build`, `-dev`, `-preprod`, `-prod`. Push to `main` → build + dev; tag `v1.0` → preprod; tag `prod-v1.0` → prod |
| `poi-backend`, `poi-gateway`, `poi-map`: the points-of-interest workshop | A Quarkus backend (national parks), a Quarkus gateway (REST + WebSocket) and an Angular map, all three in one workshop space `demo-<space>`; each push to `main` builds and deploys |

How they run on this platform:
- Every `-gitops` repo has `environments/*.yaml`; the Argo CD ApplicationSet `gitops-envs`
  makes one Application per file, in the owner team's project `team-<team>` (GitLab topic).
- The Helm charts come from `_shared/charts` (`app`: Deployment, Service, Route; `build`:
  Tekton pipelines `<repo>-ci` and `<repo>-promote`, first build).
- GitLab's system hook sends pushes and tags to the EventListener in `rhdh-demo-ci`.
- Images go to the cluster registry (ImageStream in `demo-<repo>`) or to Quay, organization
  `development`, with the robot credentials in Secret `quay/quay-ci-push`.

## Origin and license

Ported from Red Hat's demo content, licensed under the Apache License 2.0 (see `LICENSE`):

- `quarkus-service/skeleton`: `scaffolder-templates/quarkus-web-template/skeleton` of
  [rhpds/developer-hub-software-templates](https://github.com/rhpds/developer-hub-software-templates)
  (commit 3f5b296), the templates of the RHDP Developer Hub catalog item.
- `poi-*/skeleton`: `scaffolder-templates/poi-*/skeleton` of
  [redhat-scholars/backstage-workshop](https://github.com/redhat-scholars/backstage-workshop)
  (commit ad13e42), the Red Hat Summit 2023 Backstage workshop.

Changes: new `template.yaml` files (GitLab instead of GitHub, the platform's GitOps and CI
instead of Vault, External Secrets, a separate Argo CD and webhook Jobs), new catalog files,
multi-stage `Dockerfile`s (the Maven build runs in the image build) and `.dockerignore`s,
Dev Spaces image `udi-rhel9`, the gateway's backend address, the map's OpenStreetMap tiles
(Mapbox token removed), and the shared Helm charts in `_shared/charts`.
