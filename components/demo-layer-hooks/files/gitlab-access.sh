#!/bin/bash
# PostSync hook (openshift/cli image, namespace gitlab): reads the demo organisation from
# ConfigMap keycloak/demo-org and runs gitlab-access.rb in the GitLab pod.
set -euo pipefail
org="$(oc get configmap demo-org -n keycloak -o jsonpath='{.data.org\.json}' 2>/dev/null || true)"
[ -n "$org" ] || { echo "no demo organisation (keycloak/demo-org); nothing to do"; exit 0; }
echo "waiting for GitLab"
for _ in $(seq 1 60); do
  oc exec -n gitlab deploy/gitlab -- curl -sf -o /dev/null http://localhost/-/readiness 2>/dev/null && { ready=1; break; }
  sleep 15
done
[ "${ready:-0}" = 1 ] || { echo "GitLab not ready"; exit 1; }
{
  echo "require 'base64'; require 'json'"
  echo "ORG = JSON.parse(Base64.decode64('$(printf %s "$org" | base64 -w0)'))"
  echo "DEV_GROUP = '${DEV_GROUP}'"
  echo "DRY_RUN = ${DRY_RUN:-false}"
  cat /script/gitlab-access.rb
} | oc exec -i -n gitlab deploy/gitlab -- gitlab-rails runner - 2>&1 | grep -E '^access:|Error|error' | head -60
