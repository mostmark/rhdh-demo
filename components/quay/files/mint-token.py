#!/usr/bin/env python3
"""Create a long-lived Quay API token for the admin user and write it to a file.

Tokens from POST /api/v1/user/initialize expire after 2.5 hours. Tokens issued to an OAuth
application last 10 years, so this signs in with the admin password (session + CSRF),
makes sure an organization and an OAuth application for the automation exist, and
authorizes that application with the scopes the demo layer's Quay hook needs.

Quay marks its session cookie Secure (PREFERRED_URL_SCHEME https), so a cookie jar would
not send it over the in-cluster http Service; the cookie is handled by hand here.

Env: QUAY_API (http://quay:8080), QUAY_HOST (public host name), ADMIN_USER,
ADMIN_PASSWORD, ORG, APP, SCOPES, OUT (file to write the token to). Prints no secret.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ["QUAY_API"].rstrip("/")
cookies = {}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def call(method, path, body=None, form=None, csrf=None):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if csrf:
        headers["X-CSRF-Token"] = csrf
    if cookies:
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        resp = opener.open(req, timeout=60)
        status, hdrs, raw = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        status, hdrs, raw = e.code, e.headers, e.read()
    for c in hdrs.get_all("Set-Cookie") or []:
        name, _, rest = c.partition("=")
        cookies[name.strip()] = rest.split(";", 1)[0]
    return status, hdrs, raw


def csrf_token():
    status, _, raw = call("GET", "/csrf_token")
    if status != 200:
        sys.exit(f"csrf_token: HTTP {status}")
    return json.loads(raw)["csrf_token"]


def main():
    host, org, app = os.environ["QUAY_HOST"], os.environ["ORG"], os.environ["APP"]
    redirect = f"https://{host}/oauth/localapp"  # Quay always accepts its own handler

    csrf = csrf_token()
    status, _, raw = call("POST", "/api/v1/signin", csrf=csrf, body={
        "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASSWORD"]})
    if status != 200:
        sys.exit(f"signin: HTTP {status} {raw[:200]!r}")
    csrf = csrf_token()  # the session changed at sign-in

    status, _, _ = call("GET", f"/api/v1/organization/{org}", csrf=csrf)
    if status == 404:
        status, _, raw = call("POST", "/api/v1/organization/", csrf=csrf,
                              body={"name": org, "email": f"{org}@demo.example"})
        if status not in (200, 201):
            sys.exit(f"create organization {org}: HTTP {status} {raw[:200]!r}")
        print(f"created organization {org}")

    status, _, raw = call("GET", f"/api/v1/organization/{org}/applications", csrf=csrf)
    if status != 200:
        sys.exit(f"list applications: HTTP {status}")
    client_id = next((a["client_id"] for a in json.loads(raw).get("applications", [])
                      if a.get("name") == app), None)
    if not client_id:
        status, _, raw = call("POST", f"/api/v1/organization/{org}/applications", csrf=csrf, body={
            "name": app, "redirect_uri": redirect, "application_uri": f"https://{host}/",
            "description": "rhdh-demo automation (demo layer image sync)"})
        if status not in (200, 201):
            sys.exit(f"create application: HTTP {status} {raw[:200]!r}")
        client_id = json.loads(raw)["client_id"]
        print(f"created OAuth application {app} in {org}")

    status, hdrs, raw = call("POST", "/oauth/authorizeapp", form={
        "client_id": client_id, "redirect_uri": redirect, "response_type": "token",
        "scope": os.environ["SCOPES"], "_csrf_token": csrf})
    location = hdrs.get("Location", "")
    m = re.search(r"[#&]access_token=([^&]+)", location)
    if status not in (301, 302, 303) or not m:
        err = re.search(r"[#&?]error=([^&]+)", location)
        sys.exit(f"authorize: HTTP {status} {err.group(1) if err else raw[:200]!r}")
    with open(os.environ["OUT"], "w") as f:
        f.write(urllib.parse.unquote(m.group(1)))
    print(f"issued a token for {app} (scopes: {os.environ['SCOPES']})")


if __name__ == "__main__":
    main()
