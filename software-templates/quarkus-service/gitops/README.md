# ${{ values.component }}-gitops

Deployment resources of [${{ values.component }}](${{ values.gitUrl | replace('.git', '') }}), read by Argo CD.

| Path | What |
|---|---|
| `environments/*.yaml` | One Argo CD application per file (ApplicationSet `gitops-envs`): its namespace, chart and values |
| `helm/build` | Tekton pipelines in `${{ values.buildNamespace }}`: `${{ values.repo }}-ci` (every push to `main`), `${{ values.repo }}-promote` (Git tags, GitLab releases) |
| `helm/app` | Deployment, Service and Route of one environment |

Promotion: create a tag (e.g. `v1.0`) in the application repository to copy the dev
image to **preprod**; create a GitLab release of that tag to promote the same version to
**prod**. preprod and prod have no pods until their first promotion.
