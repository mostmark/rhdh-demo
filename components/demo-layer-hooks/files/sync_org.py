"""Apply the demo organisation from the demo layer to a Keycloak realm (admin REST API).

Input: ORG_FILE (JSON), written by the demo layer as ConfigMap keycloak/demo-org:
  {"company": {"name": "acme", "displayName": "Acme", "description": "..."},
   "teams": [{"name": "platform-team", "displayName": "...", "description": "...",
              "members": [{"username": "...", "firstName": "...", "lastName": "...",
                           "email": "..."}]}]}
("company" may also be a plain name.) Missing file: nothing to do.

Groups this script creates carry the attribute rhdh-demo-managed=true. On each run it
  - creates/updates the company group, its team subgroups and the users (demo password,
    permanent, no forced change), and sets each user's team memberships;
  - deletes managed company groups and team subgroups that are no longer in the org, and
    users who were in a managed group but are no longer in the org.
Never touches unmanaged groups (e.g. the realm's own admins/users), the user 'admin',
service-account users or clients.
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
BASE = f"/admin/realms/{REALM}"
MARK = "rhdh-demo-managed"
PROTECTED_USERS = {"admin"}
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
    for _ in range(60):
        try:
            _, t = req("POST", "/realms/master/protocol/openid-connect/token", form={
                "grant_type": "password", "client_id": "admin-cli",
                "username": os.environ["KC_ADMIN_USER"], "password": os.environ["KC_ADMIN_PASSWORD"]})
            return t["access_token"]
        except (urllib.error.URLError, SystemExit) as e:
            print(f"waiting for Keycloak ({e})", flush=True)
            time.sleep(10)
    raise SystemExit("Keycloak admin login failed")


def q(s):
    return urllib.parse.quote(s, safe="")


def top_groups(tok):
    _, gs = req("GET", f"{BASE}/groups?briefRepresentation=false&max=1000", tok)
    return gs or []


def children(tok, gid):
    _, kids = req("GET", f"{BASE}/groups/{gid}/children?briefRepresentation=false&max=1000", tok)
    return kids or []


def members(tok, gid):
    _, ms = req("GET", f"{BASE}/groups/{gid}/members?briefRepresentation=true&max=5000", tok)
    return ms or []


def is_managed(g):
    return (g.get("attributes") or {}).get(MARK) == ["true"]


def group_rep(name, display, desc):
    attrs = {MARK: ["true"]}
    if display:
        attrs["displayName"] = [display]
    if desc:
        attrs["description"] = [desc[:250]]
    return {"name": name, "attributes": attrs}


def ensure_group(tok, existing, name, display, desc, parent=None):
    rep = group_rep(name, display, desc)
    g = next((x for x in existing if x["name"] == name), None)
    if g:
        req("PUT", f"{BASE}/groups/{g['id']}", tok, {**g, **rep, "subGroups": None})
        return g["id"]
    path = f"{BASE}/groups/{parent}/children" if parent else f"{BASE}/groups"
    req("POST", path, tok, rep)
    print(f"group {name}: created")
    pool = children(tok, parent) if parent else top_groups(tok)
    return next(x for x in pool if x["name"] == name)["id"]


def find_user(tok, username):
    _, found = req("GET", f"{BASE}/users?username={q(username)}&exact=true", tok)
    return found[0] if found else None


def ensure_user(tok, u, password):
    rep = {"username": u["username"], "email": u.get("email"), "firstName": u.get("firstName"),
           "lastName": u.get("lastName"), "enabled": True, "emailVerified": True}
    found = find_user(tok, u["username"])
    if found:
        req("PUT", f"{BASE}/users/{found['id']}", tok, {**found, **rep})
        uid = found["id"]
    else:
        req("POST", f"{BASE}/users", tok, rep)
        uid = find_user(tok, u["username"])["id"]
        print(f"user {u['username']}: created")
    req("PUT", f"{BASE}/users/{uid}/reset-password", tok,
        {"type": "password", "value": password, "temporary": False})
    return uid


def main():
    path = os.environ.get("ORG_FILE", "/org/org.json")
    if not os.path.exists(path):
        print(f"{path} not found: the demo layer defines no organisation; nothing to do")
        return 0
    with open(path) as f:
        org = json.load(f)
    company = org["company"] if isinstance(org["company"], dict) else {"name": org["company"]}
    teams = org.get("teams", [])
    wanted_users = {m["username"] for t in teams for m in t.get("members", [])}
    wanted_teams = {t["name"] for t in teams}
    password = os.environ["DEMO_PASSWORD"]
    tok = admin_token()

    # What this script manages today: managed company groups, their subgroups and members.
    managed_before, managed_members = [], {}
    for g in top_groups(tok):
        if not is_managed(g):
            continue
        managed_before.append(g)
        for sub in [g] + children(tok, g["id"]):
            for m in members(tok, sub["id"]):
                managed_members[m["username"]] = m["id"]

    # Company group and teams.
    cid = ensure_group(tok, top_groups(tok), company["name"], company.get("displayName"),
                       company.get("description"))
    kids = children(tok, cid)
    team_ids = {t["name"]: ensure_group(tok, kids, t["name"], t.get("displayName"),
                                        t.get("description"), cid) for t in teams}
    for k in children(tok, cid):
        if k["name"] not in wanted_teams and is_managed(k):
            req("DELETE", f"{BASE}/groups/{k['id']}", tok)
            print(f"group {k['name']}: deleted (no longer in the org)")

    # Users and memberships.
    team_group_ids = set(team_ids.values())
    for t in teams:
        for m in t.get("members", []):
            if m["username"] in PROTECTED_USERS:
                raise SystemExit(f"user name {m['username']} is reserved")
            uid = ensure_user(tok, m, password)
            _, current = req("GET", f"{BASE}/users/{uid}/groups?max=1000", tok)
            for g in current or []:
                if g["id"] in team_group_ids and g["id"] != team_ids[t["name"]]:
                    req("DELETE", f"{BASE}/users/{uid}/groups/{g['id']}", tok)
            req("PUT", f"{BASE}/users/{uid}/groups/{team_ids[t['name']]}", tok)

    # Remove what left the org: other managed companies and their former members.
    for g in managed_before:
        if g["name"] != company["name"]:
            req("DELETE", f"{BASE}/groups/{g['id']}", tok)
            print(f"group {g['name']}: deleted (replaced by {company['name']})")
    for username, uid in sorted(managed_members.items()):
        if username in wanted_users or username in PROTECTED_USERS or username.startswith("service-account-"):
            continue
        req("DELETE", f"{BASE}/users/{uid}", tok)
        print(f"user {username}: deleted (no longer in the org)")

    print(f"organisation {company['name']}: {len(teams)} teams, {len(wanted_users)} users")
    return 0


if __name__ == "__main__":
    sys.exit(main())
