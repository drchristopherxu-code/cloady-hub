#!/usr/bin/env bash
# Deploy the Hub to a Cloady FREE region.
#
# IMPORTANT: `cloady deploy` always CREATES A NEW APP (it is not an update).
# Two apps in one workspace = 1.0 vCPU, which breaks the 0.5 vCPU free
# allowance. This script therefore removes the previous app FIRST so there is
# never more than one app. Expect ~2-4 min of downtime and a NEW cloady.io URL.
#
# Secrets live OUTSIDE the repo in ~/.config/cloady/hub.env (mode 0600).
# Missing values are generated once and reused on subsequent deploys.
#
# Usage:  ./deploy.sh [eu1|use1|usw1]        (default eu1)
# Check:  cloady regions

set -euo pipefail

REGION="${1:-eu1}"
case "$REGION" in
  eu1|use1|usw1) ;;
  *) echo "ERROR: '$REGION' is not a FREE region. Choose eu1 | use1 | usw1" >&2
     echo "       Re-check with: cloady regions" >&2; exit 1 ;;
esac

cd "$(dirname "$0")"
command -v cloady >/dev/null 2>&1 || { echo "ERROR: npm install -g cloady" >&2; exit 1; }

WS="${CLOADY_WORKSPACE:-$(cloady workspaces --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["slug"])')}"
ENVP="${HOME}/.config/cloady/hub.env"
mkdir -p "$(dirname "$ENVP")"
touch "$ENVP"
chmod 600 "$ENVP"

rand() { openssl rand -hex 24; }
getvar() { grep -E "^${1}=" "$ENVP" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
setvar() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENVP"; then
    python3 - "$ENVP" "$k" "$v" <<'PY'
import sys, os
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(p).read().splitlines()
out = [(k + "=" + v) if l.startswith(k + "=") else l for l in lines]
open(p, "w").write("\n".join(out) + "\n")
os.chmod(p, 0o600)
PY
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENVP"
    chmod 600 "$ENVP"
  fi
}

for key in HUB_TOKEN GITHUB_WEBHOOK_SECRET BOT_SECRET; do
  [ -n "$(getvar "$key")" ] || setvar "$key" "$(rand)"
done

echo "-> Workspace: $WS   Region: $REGION (FREE)"
echo "-> Secrets:   $ENVP (0600, not in git)"

# Build --value args. Optional GitHub integration values are only sent if set.
ARGS=( deploy . --name my-site --region "$REGION" --env production --port 3000 )
for key in HUB_TOKEN GITHUB_WEBHOOK_SECRET BOT_SECRET GITHUB_TOKEN GITHUB_REPO; do
  v="$(getvar "$key")"
  [ -n "$v" ] && ARGS+=( --value "${key}=${v}" )
done

# Remove the previous app BEFORE creating the new one (free-tier safety).
EXISTING="$(cloady apps "$WS" --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print("\n".join(a["slug"] for a in d if a.get("name") == "my-site" or a.get("slug","").startswith("my-site")))
' || true)"

if [ -n "$EXISTING" ]; then
  for slug in $EXISTING; do
    echo "-> Removing previous app: $slug (keeps workspace within free allowance)"
    cloady delete "$WS" "$slug" --region "$REGION" 2>&1 | tail -3 || {
      echo "ERROR: could not delete $slug — aborting to avoid a second app" >&2; exit 1;
    }
  done
fi

echo "-> Deploying (upload + build, ~2-4 min)"
cloady "${ARGS[@]}"

echo ""
echo "-> Follow up:"
echo "   cloady apps $WS --json"
echo "   curl -s https://<new-url>/api/health"
echo "   Panel: https://<new-url>/panel?key=\$(grep '^HUB_TOKEN=' $ENVP | cut -d= -f2-)"
echo ""
echo "NOTE: github-sourced apps use native autoUpdate instead of this script."
echo "      Free tier pauses after 7 days with no requests -> point GitHub Actions keepalive at /api/health."
