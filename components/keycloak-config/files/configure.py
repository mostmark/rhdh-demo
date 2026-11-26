"""Configure realm `sso` for the demo through the Keycloak admin REST API.

Idempotent. Creates or updates:
  - client `rhdh` (Developer Hub sign-in + Keycloak org import; its service account
    gets realm-management query-users, query-groups, view-users)
  - client `gitlab` (GitLab sign-in)
  - the demo organisation from /config/org.json: groups (a company group with team
    subgroups) and users with the demo password (permanent, no forced change)
Never touches the realm import or the existing client `idp-4-ocp`.
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

KC = os.environ["KEYCLOAK_URL"].rstrip("/")
REALM = os.environ.get("REALM", "sso")
APPS = os.environ["APPS_DOMAIN"]
CTX = ssl.create_default_context()


def req(method, path, token=None, body=None, form=None, ok=(200, 201, 204)):
    url = path if path.startswith("http") else f"{KC}{path}"
    data, headers = None, {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, None
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read()[:300]!r}")


def admin_token():
    for attempt in range(60):
        try:
            _, t = req("POST", "/realms/master/protocol/openid-connect/token", form={
                "grant_type": "password", "client_id": "admin-cli",
                "username": os.environ["KC_ADMIN_USER"], "password": os.environ["KC_ADMIN_PASSWORD"]})
            return t["access_token"]
        except (urllib.error.URLError, SystemExit) as e:
            print(f"waiting for Keycloak ({e})", flush=True)
            time.sleep(10)
    raise SystemExit("Keycloak admin login failed")


def ensure_client(tok, client_id, secret, redirect_uris, web_origins, service_account=False):
    base = f"/admin/realms/{REALM}/clients"
    _, found = req("GET", f"{base}?clientId={urllib.parse.quote(client_id)}", tok)
    rep = {
        "clientId": client_id, "enabled": True, "protocol": "openid-connect",
        "publicClient": False, "clientAuthenticatorType": "client-secret", "secret": secret,
        "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": service_account,
        "redirectUris": redirect_uris, "webOrigins": web_origins,
        "attributes": {"post.logout.redirect.uris": "+"},
    }
    if found:
        cid = found[0]["id"]
        req("PUT", f"{base}/{cid}", tok, {**found[0], **rep})
        print(f"client {client_id}: updated")
    else:
        req("POST", base, tok, rep)
        _, found = req("GET", f"{base}?clientId={urllib.parse.quote(client_id)}", tok)
        cid = found[0]["id"]
        print(f"client {client_id}: created")
    return cid


def grant_realm_management(tok, client_uuid, roles):
    base = f"/admin/realms/{REALM}"
    _, sa = req("GET", f"{base}/clients/{client_uuid}/service-account-user", tok)
    _, rm = req("GET", f"{base}/clients?clientId=realm-management", tok)
    rm_id = rm[0]["id"]
    wanted = []
    for name in roles:
        _, role = req("GET", f"{base}/clients/{rm_id}/roles/{name}", tok)
        wanted.append({"id": role["id"], "name": role["name"]})
    req("POST", f"{base}/users/{sa['id']}/role-mappings/clients/{rm_id}", tok, wanted)
    print(f"service account of {client_uuid[:8]}…: {', '.join(roles)}")


def find_group(tok, name, parent=None):
    base = f"/admin/realms/{REALM}"
    if parent:
        _, kids = req("GET", f"{base}/groups/{parent}/children?max=500", tok)
        return next((g for g in kids or [] if g["name"] == name), None)
    _, top = req("GET", f"{base}/groups?search={urllib.parse.quote(name)}&exact=true&max=100", tok)
    return next((g for g in top or [] if g["name"] == name), None)


def ensure_group(tok, name, parent=None):
    g = find_group(tok, name, parent)
    if g:
        return g["id"]
    base = f"/admin/realms/{REALM}"
    path = f"{base}/groups/{parent}/children" if parent else f"{base}/groups"
    req("POST", path, tok, {"name": name})
    print(f"group {name}: created")
    return find_group(tok, name, parent)["id"]


def ensure_user(tok, user, password, group_ids):
    base = f"/admin/realms/{REALM}/users"
    _, found = req("GET", f"{base}?username={urllib.parse.quote(user['username'])}&exact=true", tok)
    rep = {"username": user["username"], "email": user["email"], "firstName": user["firstName"],
           "lastName": user["lastName"], "enabled": True, "emailVerified": True}
    if found:
        uid = found[0]["id"]
        req("PUT", f"{base}/{uid}", tok, {**found[0], **rep})
    else:
        req("POST", f"{base}", tok, rep)
        _, found = req("GET", f"{base}?username={urllib.parse.quote(user['username'])}&exact=true", tok)
        uid = found[0]["id"]
        print(f"user {user['username']}: created")
    req("PUT", f"{base}/{uid}/reset-password", tok,
        {"type": "password", "value": password, "temporary": False})
    for gid in group_ids:
        req("PUT", f"{base}/{uid}/groups/{gid}", tok)


def main():
    tok = admin_token()
    rhdh_host = f"developer-hub.{APPS}"
    gitlab_host = f"gitlab.{APPS}"
    rhdh = ensure_client(tok, "rhdh", os.environ["RHDH_CLIENT_SECRET"],
                         [f"https://{rhdh_host}/api/auth/keycloak/handler/frame"],
                         [f"https://{rhdh_host}"], service_account=True)
    grant_realm_management(tok, rhdh, ["query-users", "query-groups", "view-users"])
    ensure_client(tok, "gitlab", os.environ["GITLAB_CLIENT_SECRET"],
                  [f"https://{gitlab_host}/users/auth/openid_connect/callback"],
                  [f"https://{gitlab_host}"])

    with open("/config/org.json") as f:
        org = json.load(f)
    company = ensure_group(tok, org["company"])
    teams = {t["name"]: ensure_group(tok, t["name"], company) for t in org["teams"]}
    for t in org["teams"]:
        for u in t["members"]:
            ensure_user(tok, u, os.environ["DEMO_PASSWORD"], [teams[t["name"]]])
    print(f"organisation {org['company']}: {len(org['teams'])} teams, "
          f"{sum(len(t['members']) for t in org['teams'])} users")


if __name__ == "__main__":
    sys.exit(main())
