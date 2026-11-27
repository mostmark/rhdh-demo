# ${{ values.component }}-gitops

Deployment resources of [${{ values.component }}](${{ values.gitUrl | replace('.git', '') }}), read by Argo CD.

| Path | What |
|---|---|
| `environments/*.yaml` | One Argo CD application per file (ApplicationSet `gitops-envs`): its namespace, chart and values |
| `helm/build` | Tekton pipelines in `${{ values.buildNamespace }}`: `${{ values.repo }}-ci` (every push to `main`), `${{ values.repo }}-promote` (Git tags) |
| `helm/app` | Deployment, Service and Route of one environment |

Promotion: push a tag `v1.0` to the application repository to copy the dev image to
**preprod**; push `prod-v1.0` to copy the preprod image to **prod**.
