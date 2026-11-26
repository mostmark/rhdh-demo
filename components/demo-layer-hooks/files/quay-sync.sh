#!/bin/bash
# Init container (cli image): create the demo's Quay organisation and public
# repositories from /quay/repos.json, and write the copy plan for the skopeo container.
#   {"organization": "acme", "source": "registry.access.redhat.com/ubi9/httpd-24:latest",
#    "repositories": [{"name": "web", "description": "...", "tags": ["1.0.0", "latest"]}]}
set -euo pipefail
f=/quay/repos.json
: > /work/plan
if [ ! -f "$f" ]; then echo "no demo-quay ConfigMap: nothing to do"; exit 0; fi
api=http://quay.quay.svc:8080/api/v1
auth="Authorization: Bearer ${QUAY_TOKEN}"
python3 - "$f" > /work/repos.tsv <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
src = d.get("source", "registry.access.redhat.com/ubi9/httpd-24:latest")
for r in d["repositories"]:
    print("\t".join([d["organization"], r["name"], r.get("description", ""), src, " ".join(r.get("tags", ["latest"]))]))
PY
org="$(head -1 /work/repos.tsv | cut -f1)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "$auth" "$api/organization/$org")
if [ "$code" != 200 ]; then
  curl -sf -X POST -H "$auth" -H 'Content-Type: application/json' "$api/organization/" \
    -d "{\"name\":\"$org\",\"email\":\"$org@demo.example\"}" >/dev/null
  echo "created organisation $org"
fi
while IFS=$'\t' read -r o name desc src tags; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "$auth" "$api/repository/$o/$name")
  if [ "$code" != 200 ]; then
    body=$(python3 -c 'import json,sys; print(json.dumps({"namespace":sys.argv[1],"repository":sys.argv[2],"visibility":"public","description":sys.argv[3],"repo_kind":"image"}))' "$o" "$name" "$desc")
    curl -sf -X POST -H "$auth" -H 'Content-Type: application/json' "$api/repository" -d "$body" >/dev/null
    echo "created repository $o/$name"
  fi
  for t in $tags; do
    have=$(curl -s -H "$auth" "$api/repository/$o/$name/tag/?specificTag=$t&onlyActiveTags=true" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tags",[])))')
    [ "$have" = 0 ] && printf '%s\t%s\n' "$src" "quay.${APPS_DOMAIN}/$o/$name:$t" >> /work/plan
  done
done < /work/repos.tsv
echo "$(wc -l < /work/plan) image tags to copy"
