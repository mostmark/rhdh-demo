#!/bin/bash
# PostSync: create the first (super) user through Quay's API once, then keep a working
# long-lived API token for it. Both live in Secret quay-admin (namespace quay only); the
# demo layer's Quay hook pushes images with that token.
# The token from /api/v1/user/initialize expires after 2.5 hours, so whenever the stored
# token is rejected, mint-token.py issues a 10-year token through an OAuth application.
set -euo pipefail
ns=quay
api=http://quay:8080
echo "waiting for Quay"
until curl -sf -o /dev/null $api/health/instance; do sleep 10; done
if ! oc get secret quay-admin -n $ns >/dev/null 2>&1; then
  pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  out="$(curl -s -X POST $api/api/v1/user/initialize -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${pw}\",\"email\":\"${ADMIN_USER}@demo.example\",\"access_token\":true}")"
  echo "$out" | grep -q '"access_token"' || { echo "initialize failed: $(echo "$out" | head -c 200)"; exit 1; }
  oc create secret generic quay-admin -n $ns --from-literal=username="${ADMIN_USER}" \
    --from-literal=password="$pw" --from-literal=token=pending
  echo "initialised ${ADMIN_USER}"
fi

token="$(oc get secret quay-admin -n $ns -o jsonpath='{.data.token}' | base64 -d)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${token}" $api/api/v1/user/)
if [ "$code" = 200 ]; then
  echo "stored token valid"
else
  echo "stored token rejected (HTTP $code); issuing a long-lived one"
  ADMIN_PASSWORD="$(oc get secret quay-admin -n $ns -o jsonpath='{.data.password}' | base64 -d)" \
    QUAY_API=$api QUAY_HOST="quay.${APPS_DOMAIN}" OUT=/tmp/token \
    python3 /scripts/mint-token.py
  oc patch secret quay-admin -n $ns --type merge \
    -p "{\"data\":{\"token\":\"$(base64 -w0 < /tmp/token)\"}}" >/dev/null
  rm -f /tmp/token
  token="$(oc get secret quay-admin -n $ns -o jsonpath='{.data.token}' | base64 -d)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${token}" $api/api/v1/user/)
  [ "$code" = 200 ] || { echo "new token rejected (HTTP $code)"; exit 1; }
  echo "stored a new token in quay-admin"
fi
echo "admin ready"

# CI robot for software-template pipelines: Secret quay-ci-push (docker config for the Quay
# host). Pipelines in any namespace may read it (RoleBinding quay-ci-push-readers).
QUAY_TOKEN="$token" QUAY_API=$api QUAY_HOST="quay.${APPS_DOMAIN}" OUT=/tmp/ci-auth.json \
  python3 /scripts/ci-robot.py
if oc get secret quay-ci-push -n $ns >/dev/null 2>&1; then
  oc patch secret quay-ci-push -n $ns --type merge \
    -p "{\"data\":{\".dockerconfigjson\":\"$(base64 -w0 < /tmp/ci-auth.json)\"}}" >/dev/null
else
  oc create secret generic quay-ci-push -n $ns --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/tmp/ci-auth.json >/dev/null
fi
rm -f /tmp/ci-auth.json
echo "CI robot credentials in quay-ci-push"
