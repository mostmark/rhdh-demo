#!/bin/bash
# PostSync: create the first (super) user through Quay's API once and keep its
# password and API token in Secret quay-admin (namespace quay only). Developer Hub reads
# the public repositories anonymously and gets no Quay token.
set -euo pipefail
ns=quay
api=http://quay:8080
echo "waiting for Quay"
until curl -sf -o /dev/null $api/health/instance; do sleep 10; done
if ! oc get secret quay-admin -n $ns >/dev/null 2>&1; then
  pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  out="$(curl -s -X POST $api/api/v1/user/initialize -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${pw}\",\"email\":\"${ADMIN_USER}@demo.example\",\"access_token\":true}")"
  token="$(echo "$out" | sed -n 's/.*"access_token": *"\([^"]*\)".*/\1/p')"
  [ -n "$token" ] || { echo "initialize failed: $(echo "$out" | head -c 200)"; exit 1; }
  oc create secret generic quay-admin -n $ns --from-literal=username="${ADMIN_USER}" \
    --from-literal=password="$pw" --from-literal=token="$token"
  echo "initialised ${ADMIN_USER}"
fi
echo "admin ready"
