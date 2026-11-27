# ${{ values.component }}-gitops

Deployment resources of ${{ values.component }} (workshop space `${{ values.space }}`), read by Argo CD.

| Path | What |
|---|---|
| `environments/*.yaml` | One Argo CD application per file (ApplicationSet `gitops-envs`): its namespace, chart and values |
| `helm/build` | Tekton pipeline `${{ values.repo }}-ci` in `${{ values.buildNamespace }}`, started by every push to `main` |
| `helm/app` | Deployment, Service and Route in namespace `demo-${{ values.space }}` |
