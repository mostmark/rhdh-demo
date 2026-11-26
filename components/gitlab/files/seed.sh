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

current="$(oc get secret rhdh-integrations -n rhdh -o jsonpath='{.data.GITLAB_TOKEN}' | base64 -d)"
[ "$current" = pending ] && current=""

out="$({
  echo "require 'base64'"
  echo "APPS = '${APPS_DOMAIN}'"
  echo "DEMO_GROUP = '${DEMO_GROUP}'"
  echo "DEMO_REPO = '${DEMO_REPO}'"
  echo "DEV_GROUP = '${DEV_GROUP}'"
  echo "CURRENT_TOKEN = Base64.decode64('$(printf %s "$current" | base64 -w0)')"
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
echo "seed complete"
