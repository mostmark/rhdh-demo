"""Create the Argo CD API token for the Developer Hub Argo CD plugin.

Logs in to the openshift-gitops Argo CD as admin (password from the operator-generated
Secret, passed in as ARGOCD_ADMIN_PASSWORD), checks the token currently stored in
rhdh/rhdh-integrations, and only if it is missing or rejected generates a new token for
the 'rhdh' account (apiKey, RBAC limited to the demo-apps project by bootstrap.sh) and
patches it into that Secret through the Kubernetes API.
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

ARGO = "https://openshift-gitops-server.openshift-gitops.svc"
K8S = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
INSECURE = ssl._create_unverified_context()          # Argo CD's in-cluster service cert
K8S_CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def call(url, method="GET", body=None, headers=None, ctx=INSECURE):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, context=ctx, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def k8s(method, path, body=None, content_type="application/json"):
    token = open(f"{SA}/token").read()
    return call(f"{K8S}{path}", method, body,
                {"Authorization": f"Bearer {token}", "Content-Type": content_type}, K8S_CTX)


def main():
    secret_path = "/api/v1/namespaces/rhdh/secrets/rhdh-integrations"
    current = base64.b64decode(k8s("GET", secret_path)["data"].get("ARGOCD_TOKEN", "")).decode()
    if current and current != "pending":
        try:
            call(f"{ARGO}/api/v1/projects/demo-apps", headers={"Authorization": f"Bearer {current}"})
            print("Argo CD token still valid")
            return 0
        except urllib.error.HTTPError as e:
            print(f"stored token rejected (HTTP {e.code}); creating a new one")

    for _ in range(60):
        try:
            session = call(f"{ARGO}/api/v1/session", "POST",
                           {"username": "admin", "password": os.environ["ARGOCD_ADMIN_PASSWORD"]})
            break
        except (urllib.error.URLError, ConnectionError) as e:
            print(f"waiting for Argo CD ({e})", flush=True)
            time.sleep(10)
    else:
        raise SystemExit("Argo CD admin login failed")
    auth = {"Authorization": f"Bearer {session['token']}"}
    token = call(f"{ARGO}/api/v1/account/rhdh/token", "POST", {"name": "developer-hub"}, auth)["token"]
    k8s("PATCH", secret_path, {"stringData": {"ARGOCD_TOKEN": token}},
        "application/merge-patch+json")
    print("stored a new Argo CD token in rhdh/rhdh-integrations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
