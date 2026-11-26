# ${{ values.name }}

${{ values.description }}

- `src/`: the web content, served by Apache httpd (`Containerfile`)
- `deploy/`: Kubernetes manifests, applied by Argo CD to namespace `${{ values.namespace }}`,
  and the Tekton pipeline `${{ values.name }}-ci`

Every push to `main` builds a new image and rolls it out.
