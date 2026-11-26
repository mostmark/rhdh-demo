#!/usr/bin/env bash
# Bootstrap a Red Hat Developer Hub 2.1 demo environment on an OpenShift cluster.
#
#   ./bootstrap.sh                       # uses this repo on GitHub, branch main
#   REVISION=wip ./bootstrap.sh          # test a branch
#   DEMO_PASSWORD='…' ./bootstrap.sh     # choose the demo users' password (else generated)
#
# What it does (idempotent, safe to re-run):
#   1. checks the oc login (cluster admin) and reads the apps domain
#   2. installs the OpenShift GitOps operator and waits for the openshift-gitops Argo CD
#   3. configures that Argo CD: cluster-admin for its controller (it installs operators),
#      health checks for Applications (so sync waves wait), an 'rhdh' API account
#   4. creates namespaces and generates secrets in the cluster (never in Git)
#   5. applies the root Application; Argo CD installs everything else from this repo
# Nothing secret is printed; the script says how to read the demo password.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/mostmark/rhdh-demo.git}"
REVISION="${REVISION:-main}"
GITOPS_CHANNEL="${GITOPS_CHANNEL:-gitops-1.22}"
WAIT_MINUTES="${WAIT_MINUTES:-45}"

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

for cmd in oc openssl; do command -v "$cmd" >/dev/null || die "$cmd is required"; done

# ---------------------------------------------------------------- 1. cluster
say "Cluster"
oc whoami >/dev/null 2>&1 || die "not logged in: run 'oc login' as a cluster admin first"
[ "$(oc auth can-i '*' '*' --all-namespaces)" = "yes" ] || die "$(oc whoami) is not cluster admin"
APPS_DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
[ -n "$APPS_DOMAIN" ] || die "could not read the apps domain"
info "server:  $(oc whoami --show-server)"
info "apps:    $APPS_DOMAIN"
info "repo:    $REPO_URL @ $REVISION"
oc get keycloak keycloak -n keycloak >/dev/null 2>&1 \
  || die "Keycloak CR 'keycloak' in namespace 'keycloak' not found (this cluster type provides it)"
oc get secret keycloak-initial-admin -n keycloak >/dev/null 2>&1 \
  || die "Secret keycloak/keycloak-initial-admin not found"

# ---------------------------------------------------------------- 2. GitOps operator
say "OpenShift GitOps operator ($GITOPS_CHANNEL)"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: ${GITOPS_CHANNEL}
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
info "waiting for the operator and the openshift-gitops Argo CD (a few minutes)"
for _ in $(seq 1 90); do
  oc get argocd openshift-gitops -n openshift-gitops >/dev/null 2>&1 \
    && [ "$(oc get deploy openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && break
  sleep 10
done
[ "$(oc get deploy openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] \
  || die "openshift-gitops Argo CD did not become ready"
info "openshift-gitops is ready"

# ---------------------------------------------------------------- 3. Argo CD configuration
say "Argo CD configuration"
oc apply -f - <<'EOF'
# The platform Argo CD installs operators and CRDs, so its controller needs cluster-admin.
# Apps created by software templates are confined by the 'demo-apps' AppProject instead.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-controller-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
EOF
# Application health (so sync waves wait for child apps), and an API account for the
# Developer Hub Argo CD plugin, limited to the demo-apps project.
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p "$(cat <<'EOF'
{"spec": {
  "extraConfig": {"accounts.rhdh": "apiKey"},
  "rbac": {"policy": "g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\np, rhdh, applications, *, demo-apps/*, allow\np, rhdh, projects, get, demo-apps, allow\np, rhdh, clusters, get, *, allow\n", "scopes": "[groups]"},
  "resourceHealthChecks": [{"group": "argoproj.io", "kind": "Application", "check": "hs = {}\nhs.status = \"Progressing\"\nhs.message = \"\"\nif obj.status ~= nil then\n  if obj.status.health ~= nil then\n    hs.status = obj.status.health.status\n    if obj.status.health.message ~= nil then hs.message = obj.status.health.message end\n  end\nend\nreturn hs\n"}]
}}
EOF
)" >/dev/null
info "controller has cluster-admin; Application health check and 'rhdh' account configured"

# ---------------------------------------------------------------- 4. namespaces and secrets
say "Namespaces and secrets"
for ns in gitlab rhdh; do
  oc get namespace "$ns" >/dev/null 2>&1 || oc create namespace "$ns" >/dev/null
done
# create a Secret only if it doesn't exist yet, so re-runs never rotate credentials
ensure_secret() { # ns name key=value...
  local ns="$1" name="$2"; shift 2
  if oc get secret "$name" -n "$ns" >/dev/null 2>&1; then info "secret $ns/$name exists"; return; fi
  local args=(); for kv in "$@"; do args+=("--from-literal=$kv"); done
  oc create secret generic "$name" -n "$ns" "${args[@]}" >/dev/null
  info "secret $ns/$name created"
}
if oc get secret demo-credentials -n keycloak >/dev/null 2>&1; then
  DEMO_PW="$(oc get secret demo-credentials -n keycloak -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d)"
else
  DEMO_PW="${DEMO_PASSWORD:-$(rand 16)}"
fi
[ "${#DEMO_PW}" -ge 8 ] || die "DEMO_PASSWORD must be at least 8 characters"
RHDH_CLIENT_SECRET="$(oc get secret demo-credentials -n keycloak -o jsonpath='{.data.RHDH_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)"
GITLAB_CLIENT_SECRET="$(oc get secret demo-credentials -n keycloak -o jsonpath='{.data.GITLAB_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)"
RHDH_CLIENT_SECRET="${RHDH_CLIENT_SECRET:-$(rand 40)}"
GITLAB_CLIENT_SECRET="${GITLAB_CLIENT_SECRET:-$(rand 40)}"

ensure_secret keycloak demo-credentials \
  "DEMO_PASSWORD=$DEMO_PW" "RHDH_CLIENT_SECRET=$RHDH_CLIENT_SECRET" "GITLAB_CLIENT_SECRET=$GITLAB_CLIENT_SECRET"
ensure_secret gitlab gitlab-secrets \
  "GITLAB_ROOT_PASSWORD=$(rand 24)" "GITLAB_OIDC_CLIENT_SECRET=$GITLAB_CLIENT_SECRET"
ensure_secret rhdh rhdh-secrets \
  "SESSION_SECRET=$(rand 48)" "BACKEND_SECRET=$(rand 48)" \
  "KEYCLOAK_BASE_URL=https://sso.${APPS_DOMAIN}" "KEYCLOAK_REALM=sso" "KEYCLOAK_LOGIN_REALM=sso" \
  "KEYCLOAK_CLIENT_ID=rhdh" "KEYCLOAK_CLIENT_SECRET=$RHDH_CLIENT_SECRET"
# filled in by the seed Jobs (GitLab token, Argo CD token); placeholders until then
ensure_secret rhdh rhdh-integrations "GITLAB_TOKEN=pending" "ARGOCD_TOKEN=pending"
unset DEMO_PW RHDH_CLIENT_SECRET GITLAB_CLIENT_SECRET

# ---------------------------------------------------------------- 5. root Application
say "Root Application"
oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhdh-demo
  namespace: openshift-gitops
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  destination: {server: https://kubernetes.default.svc, namespace: openshift-gitops}
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: charts/root
    helm:
      valuesObject:
        appsDomain: ${APPS_DOMAIN}
        repoURL: ${REPO_URL}
        targetRevision: ${REVISION}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    retry: {limit: 10, backoff: {duration: 30s, factor: 2, maxDuration: 5m}}
EOF

say "Waiting for the components (up to ${WAIT_MINUTES} min; GitLab's first start takes ~10 min)"
end=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while :; do
  rows="$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null || true)"
  printf '   %s %s\n' "$(date +%H:%M:%S)" "$rows"
  if [ -n "$rows" ] && ! echo "$rows" | tr ' ' '\n' | grep -v '^$' | grep -qv '=Synced/Healthy'; then
    echo "$rows" | grep -q 'developer-hub=' && break
  fi
  [ "$(date +%s)" -lt "$end" ] || { info "not all components are Synced/Healthy yet; check them in Argo CD"; break; }
  sleep 30
done

say "Done"
info "Developer Hub: https://developer-hub.${APPS_DOMAIN}"
info "GitLab:        https://gitlab.${APPS_DOMAIN}   (sign in with Keycloak)"
info "Argo CD:       https://openshift-gitops-server-openshift-gitops.${APPS_DOMAIN}"
info "Demo users sign in with the demo password:"
info "  oc get secret demo-credentials -n keycloak -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d"
