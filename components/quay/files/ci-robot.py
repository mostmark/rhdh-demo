"""Make sure the CI robot for software-template builds exists and print its credentials.

Organization CI_ORG (e.g. development, like the GitLab group) with a team CI_TEAM in role
'creator' and the robot CI_ORG+CI_ROBOT in that team: pipelines push images with it, and
new repositories are created on push (public, CREATE_PRIVATE_REPO_ON_PUSH: false).
Writes a docker config.json for the Quay host to OUT. Needs the admin token (QUAY_TOKEN).
"""
import base64
import json
import os
import urllib.error
import urllib.request

API = os.environ.get("QUAY_API", "http://quay:8080").rstrip("/")
HOST = os.environ["QUAY_HOST"]
ORG = os.environ.get("CI_ORG", "development")
TEAM = os.environ.get("CI_TEAM", "ci")
ROBOT = os.environ.get("CI_ROBOT", "ci")
TOKEN = os.environ["QUAY_TOKEN"]


def call(method, path, body=None, ok=(200, 201, 204)):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{API}/api/v1{path}", data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, None
        return e.code, e.read()[:300]


code, _ = call("GET", f"/organization/{ORG}")
if code == 404:
    code, out = call("POST", "/organization/", {"name": ORG, "email": f"{ORG}@demo.example"})
    if code not in (200, 201):
        raise SystemExit(f"create organization {ORG}: HTTP {code} {out!r}")
    print(f"ci-robot: created organization {ORG}")
code, out = call("PUT", f"/organization/{ORG}/team/{TEAM}",
                 {"role": "creator", "description": "CI robots: push images, create repositories"})
if code not in (200, 201):
    raise SystemExit(f"team {TEAM}: HTTP {code} {out!r}")
code, robot = call("GET", f"/organization/{ORG}/robots/{ROBOT}")
if code == 400 or code == 404 or not isinstance(robot, dict):
    code, robot = call("PUT", f"/organization/{ORG}/robots/{ROBOT}",
                       {"description": "Tekton pipelines of software-template services"})
    if code not in (200, 201) or not isinstance(robot, dict):
        raise SystemExit(f"robot {ROBOT}: HTTP {code} {robot!r}")
    print(f"ci-robot: created robot {robot['name']}")
code, out = call("PUT", f"/organization/{ORG}/team/{TEAM}/members/{robot['name']}", {})
if code == 400 and b"already a member" in (out or b""):
    code = 200
if code not in (200, 201):
    raise SystemExit(f"add {robot['name']} to {TEAM}: HTTP {code} {out!r}")
auth = base64.b64encode(f"{robot['name']}:{robot['token']}".encode()).decode()
with open(os.environ["OUT"], "w") as f:
    json.dump({"auths": {HOST: {"auth": auth}}}, f)
print(f"ci-robot: {robot['name']} is in team {TEAM} (creator) of {ORG}")
