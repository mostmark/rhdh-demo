# ${{ values.name }}

${{ values.description }}

## How it is built and deployed

1. A push to `main` in GitLab starts the Tekton pipeline `${{ values.name }}-ci` in
   namespace `${{ values.namespace }}`: clone, build the image with buildah, push it to
   the cluster registry, roll out the Deployment.
2. Argo CD keeps the manifests in `deploy/` in sync with the cluster.

Edit `src/index.html`, commit and push, and watch the pipeline on the **Deployment**
tab in Developer Hub.
