"""Derive team access from the demo organisation (ConfigMap keycloak/demo-org).

Runs as a Sync hook of the demo-layer Application (wave -1: after the demo layer's
ConfigMaps in wave -2, before the workload Applications), with the Kubernetes API and
the Job's service account. On each run it

  - writes ConfigMap rhdh/rbac-policies (rbac-policy.csv, conditional-policies.yaml), the
    Developer Hub RBAC policy: the roles from ConfigMap rhdh/rbac-roles if the demo layer
    has one, else the platform defaults in /script, plus one binding per team: the
    platform team(s) -> role:default/platform-admin, every other team ->
    role:default/developer. If the demo layer's rbac-roles.csv has its own 'g' lines,
    no bindings are generated. Developer Hub reloads the file without a restart.
  - makes one OpenShift Group per team (same name, the team's people as users) and the
    group PLATFORM_GROUP with the platform team's people. Argo CD (Dex, OpenShift login)
    sees these groups.
  - makes one Argo CD AppProject team-<team> per team, with the destinations and source
    repos of project demo-apps and a read-only role for the team's group.

Platform team: the teams with "platform": true in org.json, else the team named
platform-team. Everything this script creates has the label LABEL; it only changes or
deletes objects with that label, and it keeps a team project that Applications still use.
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

API = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
LABEL = "rhdh-demo/team-access"
GITOPS_NS = os.environ.get("GITOPS_NAMESPACE", "openshift-gitops")
RHDH_NS = os.environ.get("RHDH_NAMESPACE", "rhdh")
PLATFORM_GROUP = os.environ.get("PLATFORM_GROUP", "rhdh-demo-platform-admins")
TEMPLATE_PROJECT = os.environ.get("TEMPLATE_PROJECT", "demo-apps")
DEFAULTS = os.environ.get("DEFAULTS_DIR", "/script")

TOKEN = open(f"{SA}/token").read().strip()
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")
GROUPS = "/apis/user.openshift.io/v1/groups"
PROJECTS = f"/apis/argoproj.io/v1alpha1/namespaces/{GITOPS_NS}/appprojects"
APPS = f"/apis/argoproj.io/v1alpha1/namespaces/{GITOPS_NS}/applications"


def log(msg):
    print(f"team-access: {msg}", flush=True)


def k8s(method, path, body=None, patch=False):
    data = json.dumps(body).encode() if body is not None else None
    ctype = "application/merge-patch+json" if patch else "application/json"
    r = urllib.request.Request(f"{API}{path}", data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Content-Type": ctype, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code == 404 and method == "GET":
            return None
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read()[:300]!r}")


def managed(obj):
    return (obj.get("metadata", {}).get("labels") or {}).get(LABEL) == "true"


def upsert(collection, name, desired, what):
    """Create or merge-patch an object we own; never take over an unlabelled one."""
    cur = k8s("GET", f"{collection}/{name}")
    if cur is None:
        k8s("POST", collection, desired)
        log(f"{what} {name}: created")
        return True
    if not managed(cur):
        log(f"{what} {name}: exists without label {LABEL}; left alone")
        return False
    k8s("PATCH", f"{collection}/{name}", desired, patch=True)
    return True


def cm_data(ns, name):
    cm = k8s("GET", f"/api/v1/namespaces/{ns}/configmaps/{name}")
    return (cm or {}).get("data") or {}


def main():
    raw = cm_data("keycloak", "demo-org").get("org.json")
    if not raw:
        log("no demo organisation (ConfigMap keycloak/demo-org); nothing to do")
        return
    org = json.loads(raw)
    teams = [t for t in org.get("teams", []) if t.get("name")]
    platform = [t["name"] for t in teams if t.get("platform") is True] or \
               [t["name"] for t in teams if t["name"] == "platform-team"]
    if not platform:
        log("warning: no platform team (\"platform\": true or a team named platform-team); "
            "nobody gets role platform-admin")
    members = {t["name"]: sorted({m["username"] for m in t.get("members", []) if m.get("username")})
               for t in teams}

    # ---- Developer Hub RBAC policy
    override = cm_data(RHDH_NS, "rbac-roles")
    if override.get("rbac-roles.csv"):
        roles, source = override["rbac-roles.csv"], "ConfigMap rhdh/rbac-roles"
        conditional = override.get("conditional-policies.yaml", "")
    else:
        roles, source = open(f"{DEFAULTS}/rbac-roles.csv").read(), "platform defaults"
        conditional = open(f"{DEFAULTS}/conditional-policies.yaml").read()
    own_bindings = any(l.strip().startswith("g,") for l in roles.splitlines())
    lines = [roles.rstrip("\n"), ""]
    if own_bindings:
        log(f"RBAC roles and bindings from {source}")
    else:
        lines.append("# ---- generated by the team-access hook from the demo organisation")
        for t in teams:
            role = "platform-admin" if t["name"] in platform else "developer"
            lines.append(f"g, group:default/{t['name']}, role:default/{role}")
        log(f"RBAC roles from {source}; bindings: " + ", ".join(
            f"{t['name']}={'platform-admin' if t['name'] in platform else 'developer'}" for t in teams))
    cm = {"apiVersion": "v1", "kind": "ConfigMap",
          "metadata": {"name": "rbac-policies", "namespace": RHDH_NS, "labels": {LABEL: "true"}},
          "data": {"rbac-policy.csv": "\n".join(lines) + "\n", "conditional-policies.yaml": conditional}}
    upsert(f"/api/v1/namespaces/{RHDH_NS}/configmaps", "rbac-policies", cm, "ConfigMap")

    # ---- OpenShift groups (Argo CD reads them through its OpenShift login)
    want_groups = dict(members)
    want_groups[PLATFORM_GROUP] = sorted({u for p in platform for u in members.get(p, [])})
    for name, users in want_groups.items():
        upsert(GROUPS, name, {"apiVersion": "user.openshift.io/v1", "kind": "Group",
                              "metadata": {"name": name, "labels": {LABEL: "true"}}, "users": users}, "Group")
    for g in k8s("GET", f"{GROUPS}?labelSelector={LABEL}%3Dtrue")["items"]:
        if g["metadata"]["name"] not in want_groups:
            k8s("DELETE", f"{GROUPS}/{g['metadata']['name']}")
            log(f"Group {g['metadata']['name']}: deleted (team no longer in the organisation)")
    log(f"groups: {len(teams)} teams, {PLATFORM_GROUP} = {', '.join(want_groups[PLATFORM_GROUP]) or '-'}")

    # ---- Argo CD: one project per team, read-only for the team's group
    base = k8s("GET", f"{PROJECTS}/{TEMPLATE_PROJECT}")
    if base is None:
        raise SystemExit(f"AppProject {TEMPLATE_PROJECT} not found (gitops-config component)")
    want_projects = set()
    for t in teams:
        proj = f"team-{t['name']}"
        want_projects.add(proj)
        spec = {k: base["spec"][k] for k in ("destinations", "sourceRepos", "clusterResourceWhitelist") if k in base["spec"]}
        spec["description"] = f"Applications of {t.get('displayName') or t['name']} (demo)"
        spec["roles"] = [{"name": "team", "description": f"{t['name']}: read-only",
                          "groups": [t["name"]],
                          "policies": [f"p, proj:{proj}:team, applications, get, {proj}/*, allow",
                                       f"p, proj:{proj}:team, logs, get, {proj}/*, allow"]}]
        upsert(PROJECTS, proj, {"apiVersion": "argoproj.io/v1alpha1", "kind": "AppProject",
                                "metadata": {"name": proj, "namespace": GITOPS_NS, "labels": {LABEL: "true"}},
                                "spec": spec}, "AppProject")
    used = {a["spec"].get("project") for a in k8s("GET", APPS)["items"]}
    for p in k8s("GET", f"{PROJECTS}?labelSelector={LABEL}%3Dtrue")["items"]:
        name = p["metadata"]["name"]
        if name in want_projects:
            continue
        if name in used:
            log(f"AppProject {name}: team gone, kept because Applications still use it")
            continue
        k8s("DELETE", f"{PROJECTS}/{name}")
        log(f"AppProject {name}: deleted (team no longer in the organisation)")
    log(f"Argo CD projects: {', '.join(sorted(want_projects)) or '-'}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if e.code not in (None, 0):
            print(f"team-access: ERROR {e.code}", file=sys.stderr)
        raise
