#!/bin/bash
# Sync hook (wave -1): create the Quay and Clair secrets once (never rotated): database
# passwords, Quay's config.yaml (it embeds the DB password and the Quay secret keys), Clair's
# config.yaml and the key Quay and Clair sign their requests with (PSK). On later syncs
# only the scanner settings in Quay's config and Clair's config are brought up to date
# (then Quay or Clair is restarted once).
set -euo pipefail
ns=quay
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
sec() { oc get secret "$1" -n $ns -o jsonpath="{.data.$2}" | base64 -d; }

# Clair (vulnerability scanner, combo mode): its database secret holds the PSK too.
ensure_clair() {
  if ! oc get secret clair-db -n $ns >/dev/null 2>&1; then
    oc create secret generic clair-db -n $ns --from-literal=POSTGRESQL_USER=clair \
      --from-literal=POSTGRESQL_PASSWORD="$(rand 32)" --from-literal=POSTGRESQL_DATABASE=clair \
      --from-literal=POSTGRESQL_ADMIN_PASSWORD="$(rand 32)" \
      --from-literal=PSK="$(head -c 32 /dev/urandom | base64 -w0)" >/dev/null
    echo "created secret clair-db"
  fi
  local pw psk conn sets new old
  pw="$(sec clair-db POSTGRESQL_PASSWORD)"; psk="$(sec clair-db PSK)"
  conn="host=clair-postgres port=5432 dbname=clair user=clair password=${pw} sslmode=disable"
  sets="$(printf '%s' "$CLAIR_UPDATERS" | sed 's/[^ ][^ ]*/"&"/g; s/ /, /g')"
  new="$(cat <<CONF
http_listen_addr: :8080
introspection_addr: :8089
log_level: info
indexer:
  connstring: ${conn}
  scanlock_retry: 10
  layer_scan_concurrency: 5
  migrations: true
matcher:
  connstring: ${conn}
  max_conn_pool: 50
  migrations: true
matchers: {}
updaters:
  sets: [${sets}]
notifier:
  connstring: ${conn}
  delivery_interval: 1m
  poll_interval: 5m
  migrations: true
  webhook:
    target: http://quay:8080/secscan/notification
    callback: http://clair:8080/notifier/api/v1/notifications
auth:
  psk:
    key: ${psk}
    iss: [quay, clairctl]
metrics:
  name: prometheus
CONF
)"
  if ! oc get secret clair-config -n $ns >/dev/null 2>&1; then
    printf '%s\n' "$new" > /tmp/clair.yaml
    oc create secret generic clair-config -n $ns --from-file=config.yaml=/tmp/clair.yaml >/dev/null
    rm -f /tmp/clair.yaml
    echo "created secret clair-config"; return
  fi
  old="$(sec clair-config 'config\.yaml')"
  [ "$old" = "$new" ] && { echo "Clair config up to date"; return; }
  oc patch secret clair-config -n $ns --type merge \
    -p "{\"data\":{\"config.yaml\":\"$(printf '%s\n' "$new" | base64 -w0)\"}}" >/dev/null
  echo "updated Clair config"
  if oc get deployment clair -n $ns >/dev/null 2>&1; then
    oc rollout restart deployment/clair -n $ns && echo "restarted Clair"
  fi
}

# Quay's scanner settings: on, Clair's address (SCANNER_ENDPOINT) and the shared PSK. (With
# the scanner off, Quay has no security endpoint and Developer Hub's Quay tab fails.)
KEYS='^(FEATURE_SECURITY_SCANNER|SECURITY_SCANNER_V4_ENDPOINT|SECURITY_SCANNER_V4_PSK):'
scanner_lines() {
  printf 'FEATURE_SECURITY_SCANNER: true\nSECURITY_SCANNER_V4_ENDPOINT: %s\nSECURITY_SCANNER_V4_PSK: %s\n' \
    "$SCANNER_ENDPOINT" "$(sec clair-db PSK)"
}
ensure_scanner() {
  local cfg new
  cfg="$(sec quay-config 'config\.yaml')"
  new="$(printf '%s\n' "$cfg" | grep -v -E "$KEYS")"
  new="$(printf '%s\n%s\n' "$new" "$(scanner_lines)")"
  if [ "$(printf '%s\n' "$cfg" | grep -E "$KEYS" | sort)" = "$(printf '%s\n' "$new" | grep -E "$KEYS" | sort)" ]; then
    echo "scanner settings up to date"; return
  fi
  oc patch secret quay-config -n $ns --type merge \
    -p "{\"data\":{\"config.yaml\":\"$(printf '%s\n' "$new" | base64 -w0)\"}}" >/dev/null
  echo "updated scanner settings"
  if oc get deployment quay -n $ns >/dev/null 2>&1; then
    oc rollout restart deployment/quay -n $ns && echo "restarted Quay"
  fi
}

ensure_clair
if oc get secret quay-config -n $ns >/dev/null 2>&1; then echo "secrets exist"; ensure_scanner; exit 0; fi
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
$(scanner_lines)
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
