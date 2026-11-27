#!/bin/bash
# Sync hook (wave -1): create the Quay secrets once (never rotated): database password and
# config.yaml (it embeds the DB password and the Quay secret keys). On later syncs only the
# security scanner settings are brought up to date (then Quay is restarted once).
set -euo pipefail
ns=quay

# Scanning is on and points at the Clair address (SCANNER_ENDPOINT). Until Clair runs
# there, the Quay tab shows "Queued" per tag: with the scanner off, Quay has no security
# endpoint at all and Developer Hub's Quay tab fails with an error.
ensure_scanner() {
  local cfg new
  cfg="$(oc get secret quay-config -n $ns -o jsonpath='{.data.config\.yaml}' | base64 -d)"
  new="$(printf '%s\n' "$cfg" | grep -v -E '^(FEATURE_SECURITY_SCANNER|SECURITY_SCANNER_V4_ENDPOINT):')"
  new="$(printf '%s\nFEATURE_SECURITY_SCANNER: true\nSECURITY_SCANNER_V4_ENDPOINT: %s\n' "$new" "$SCANNER_ENDPOINT")"
  if [ "$(printf '%s\n' "$cfg" | grep -E '^(FEATURE_SECURITY_SCANNER|SECURITY_SCANNER_V4_ENDPOINT):' | sort)" = \
       "$(printf '%s\n' "$new" | grep -E '^(FEATURE_SECURITY_SCANNER|SECURITY_SCANNER_V4_ENDPOINT):' | sort)" ]; then
    echo "scanner settings up to date"; return
  fi
  oc patch secret quay-config -n $ns --type merge \
    -p "{\"data\":{\"config.yaml\":\"$(printf '%s\n' "$new" | base64 -w0)\"}}" >/dev/null
  echo "updated scanner settings"
  if oc get deployment quay -n $ns >/dev/null 2>&1; then
    oc rollout restart deployment/quay -n $ns && echo "restarted Quay"
  fi
}

if oc get secret quay-config -n $ns >/dev/null 2>&1; then echo "secrets exist"; ensure_scanner; exit 0; fi
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
db_pw="$(rand 32)"
cat > /tmp/config.yaml <<CONF
SERVER_HOSTNAME: quay.${APPS_DOMAIN}
PREFERRED_URL_SCHEME: https
EXTERNAL_TLS_TERMINATION: true
SETUP_COMPLETE: true
DB_URI: postgresql://quay:${db_pw}@quay-postgres:5432/quay
DB_CONNECTION_ARGS: {}
BUILDLOGS_REDIS: {host: quay-redis, port: 6379}
USER_EVENTS_REDIS: {host: quay-redis, port: 6379}
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - LocalStorage
    - storage_path: /datastorage/registry
DISTRIBUTED_STORAGE_PREFERENCE: [default]
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS: [default]
SECRET_KEY: $(rand 48)
DATABASE_SECRET_KEY: $(rand 48)
AUTHENTICATION_TYPE: Database
SUPER_USERS: [${ADMIN_USER}]
FEATURE_USER_INITIALIZE: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_ANONYMOUS_ACCESS: true
CREATE_PRIVATE_REPO_ON_PUSH: false
CREATE_NAMESPACE_ON_PUSH: false
FEATURE_USER_CREATION: true
FEATURE_MAILING: false
FEATURE_SECURITY_SCANNER: true
SECURITY_SCANNER_V4_ENDPOINT: ${SCANNER_ENDPOINT}
FEATURE_BUILD_SUPPORT: false
FEATURE_REPO_MIRROR: false
FEATURE_PROXY_CACHE: false
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS: [0s, 1d, 1w, 2w, 4w]
REGISTRY_TITLE: Quay (demo)
REGISTRY_TITLE_SHORT: Quay
CONF
oc create secret generic quay-db -n $ns --from-literal=POSTGRESQL_USER=quay \
  --from-literal=POSTGRESQL_PASSWORD="$db_pw" --from-literal=POSTGRESQL_DATABASE=quay \
  --from-literal=POSTGRESQL_ADMIN_PASSWORD="$(rand 32)"
oc create secret generic quay-config -n $ns --from-file=config.yaml=/tmp/config.yaml
rm -f /tmp/config.yaml
echo "created secrets quay-db and quay-config"
