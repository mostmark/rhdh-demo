# ${{ values.name }}

${{ values.description }}

- `src/`: the web content, served by Apache httpd (`Containerfile`)
- `deploy/`: Kubernetes manifests, applied by Argo CD to namespace `${{ values.namespace }}`,
  and the Tekton pipeline `${{ values.name }}-ci`

Every push to `main` builds a new image and rolls it out. To edit in the browser, use
the component's **Open in Dev Spaces** link (`devfile.yaml`; run the *preview* command to
see the page).
