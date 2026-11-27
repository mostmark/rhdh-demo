#!/bin/bash
# Main container (skopeo image): copy the planned tags into Quay.
set -euo pipefail
n=0
while IFS=$'\t' read -r src dst; do
  [ -n "$src" ] || continue
  skopeo copy --retry-times 3 --remove-signatures --dest-creds "\$oauthtoken:${QUAY_TOKEN}" "docker://$src" "docker://$dst" >/dev/null
  echo "copied $dst"; n=$((n+1))
done < /work/plan
echo "quay sync done ($n tags copied)"
