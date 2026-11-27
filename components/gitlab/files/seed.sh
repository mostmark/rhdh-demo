#!/bin/bash
# Seed Job entrypoint (openshift/cli image). Builds the Ruby input for seed.rb and runs it
# in the GitLab pod; stores the Developer Hub token in rhdh/rhdh-integrations.
set -euo pipefail

echo "waiting for GitLab to be ready"
for _ in $(seq 1 90); do
  if oc exec -n gitlab deploy/gitlab -- curl -sf -o /dev/null http://localhost/-/readiness 2>/dev/null; then
    ready=1; break
  fi
  sleep 20
done
[ "${ready:-0}" = 1 ] || { echo "GitLab did not become ready"; exit 1; }

ds_exists=false
if [ -n "${DEVSPACES_URL:-}" ] && oc get secret devspaces-gitlab-oauth -n openshift-devspaces >/dev/null 2>&1; then
  ds_exists=true
fi

# The platform software templates: fetch the synced platform commit inside the GitLab pod
# (it has git and reaches the internet); seed.rb copies TEMPLATES_PATH from there.
templates_src=""
if [ -n "${PLATFORM_REPO:-}" ] && [ -n "${PLATFORM_REVISION:-}" ]; then
  if oc exec -n gitlab deploy/gitlab -- bash -c "rm -rf /tmp/rhdh-demo-platform && git init -q /tmp/rhdh-demo-platform && cd /tmp/rhdh-demo-platform && git fetch -q --depth 1 '${PLATFORM_REPO}' '${PLATFORM_REVISION}' && git checkout -q FETCH_HEAD && test -d '${TEMPLATES_PATH}'"; then
    templates_src="/tmp/rhdh-demo-platform/${TEMPLATES_PATH}"
    echo "fetched ${PLATFORM_REVISION} of the platform repo for the software templates"
  else
    echo "WARNING: could not fetch ${PLATFORM_REPO} @ ${PLATFORM_REVISION}; software templates not updated"
  fi
fi

current="$(oc get secret rhdh-integrations -n rhdh -o jsonpath='{.data.GITLAB_TOKEN}' | base64 -d)"
hooks_token="$(oc get secret gitlab-hooks-token -n rhdh-demo-ci -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
[ "$current" = pending ] && current=""

out="$({
  echo "require 'base64'"
  echo "APPS = '${APPS_DOMAIN}'"
  echo "DEMO_GROUP = '${DEMO_GROUP}'"
  echo "DEMO_REPO = '${DEMO_REPO}'"
  echo "DEV_GROUP = '${DEV_GROUP}'"
  echo "SYSTEM_HOOK_URL = '${SYSTEM_HOOK_URL:-}'"
  echo "DEVSPACES_URL = '${DEVSPACES_URL:-}'"
  echo "DEVSPACES_SECRET_EXISTS = ${ds_exists}"
  echo "CURRENT_TOKEN = Base64.decode64('$(printf %s "$current" | base64 -w0)')"
  echo "TEMPLATES_SRC = '${templates_src}'"
  echo "TEMPLATES_GROUP = '${TEMPLATES_GROUP:-platform}'"
  echo "TEMPLATES_REPO = '${TEMPLATES_REPO:-software-templates}'"
  echo "TEMPLATES_REVISION = '${PLATFORM_REVISION:-}'"
  echo "CURRENT_HOOKS_TOKEN = Base64.decode64('$(printf %s "$hooks_token" | base64 -w0)')"
  echo "FILES = {}"
  for f in /seed-files/*; do
    key="$(basename "$f")"
    echo "FILES['${key//__//}'] = Base64.decode64('$(base64 -w0 < "$f")')"
  done
  cat /seed/seed.rb
} | oc exec -i -n gitlab deploy/gitlab -- gitlab-rails runner -)"

echo "$out" | grep '^seed:' || true
token="$(echo "$out" | sed -n 's/^RHDH_GITLAB_TOKEN=//p' | tail -1)"
if [ -n "$token" ]; then
  oc patch secret rhdh-integrations -n rhdh --type merge \
    -p "{\"stringData\":{\"GITLAB_TOKEN\":\"${token}\"}}" >/dev/null
  echo "stored the new token in rhdh/rhdh-integrations"
fi
htoken="$(echo "$out" | sed -n 's/^CI_HOOKS_TOKEN=//p' | tail -1)"
if [ -n "$htoken" ]; then
  # the EventListener's webhook task (namespace rhdh-demo-ci) adds release webhooks to new repos
  for _ in $(seq 1 30); do oc get namespace rhdh-demo-ci >/dev/null 2>&1 && break; sleep 10; done
  if oc get secret gitlab-hooks-token -n rhdh-demo-ci >/dev/null 2>&1; then
    oc patch secret gitlab-hooks-token -n rhdh-demo-ci --type merge -p "{\"stringData\":{\"token\":\"${htoken}\"}}" >/dev/null
  else
    oc create secret generic gitlab-hooks-token -n rhdh-demo-ci --from-literal=token="${htoken}" >/dev/null
  fi
  echo "stored the CI webhook token in rhdh-demo-ci/gitlab-hooks-token"
fi
oauth="$(echo "$out" | sed -n 's/^DEVSPACES_OAUTH=//p' | tail -1)"
if [ -n "$oauth" ]; then
  # Dev Spaces SCM OAuth configuration (the secret is shown by GitLab only once)
  oc delete secret devspaces-gitlab-oauth -n openshift-devspaces --ignore-not-found >/dev/null || true
  if oc apply -f - >/dev/null <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: devspaces-gitlab-oauth
  namespace: openshift-devspaces
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: oauth-scm-configuration
  annotations:
    che.eclipse.org/oauth-scm-server: gitlab
    che.eclipse.org/scm-server-endpoint: https://gitlab.${APPS_DOMAIN}
type: Opaque
stringData:
  id: "${oauth%%:*}"
  secret: "${oauth#*:}"
SECRET
  then echo "stored the Dev Spaces GitLab OAuth Secret"
  else echo "WARNING: could not write openshift-devspaces/devspaces-gitlab-oauth"
  fi
fi
echo "seed complete"
