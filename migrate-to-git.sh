#!/usr/bin/env bash
# Switch the Cloady app from "upload" source to "git" source, which enables
# Cloady's native autoUpdate: every push to main rebuilds the site on the
# platform, with the Mac off and GitHub Actions doing nothing but verifying.
#
# DESTRUCTIVE: `cloady deploy` cannot update an app, it always creates a new
# one. So this removes the old app first (never 2 apps = never over free tier),
# which means a NEW cloady.io URL and a few minutes of downtime.
#
# For a PRIVATE repo, first connect GitHub in Cloady:
#   Workspace settings -> Integrations -> GitHub.
# A PUBLIC repo needs no extra OAuth.
#
# Usage: ./migrate-to-git.sh [eu1|use1|usw1]

set -euo pipefail
cd "$(dirname "$0")"

REGION="${1:-eu1}"
case "$REGION" in eu1|use1|usw1) ;; *) echo "ERROR: FREE regions are eu1|use1|usw1" >&2; exit 1 ;; esac

REPO="${REPO_NAME:-cloady-hub}"
WS="${CLOADY_WORKSPACE:-drchristopherxu-code}"
ENVP="${HOME}/.config/cloady/hub.env"
[ -f "$ENVP" ] || { echo "ERROR: $ENVP missing" >&2; exit 1; }
getvar() { grep -E "^${1}=" "$ENVP" | tail -1 | cut -d= -f2-; }

OWNER="$(gh api user -q .login 2>/dev/null)" || { echo "ERROR: gh not authed" >&2; exit 1; }
REPO_URL="https://github.com/$OWNER/$REPO.git"
echo "-> source: $REPO_URL (branch main)"
echo "-> target: $WS / $REGION (FREE)"

EXISTING="$(cloady apps "$WS" --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print("\n".join(a["slug"] for a in d))
' || true)"
for slug in $EXISTING; do
  echo "-> removing upload-sourced app: $slug"
  cloady delete "$WS" "$slug" --region "$REGION" >/dev/null
done

ARGS=( deploy "$REPO_URL" --type git --branch main --name my-site \
       --region "$REGION" --env production --port 3000 )
for key in HUB_TOKEN GITHUB_WEBHOOK_SECRET BOT_SECRET GITHUB_TOKEN GITHUB_REPO; do
  v="$(getvar "$key")"
  [ -n "$v" ] && ARGS+=( --value "${key}=${v}" )
done
cloady "${ARGS[@]}"

sleep 20
NEW_URL="$(cloady apps "$WS" --json | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["endpoints"][0]["url"])')"
NEW_URL="${NEW_URL%/}"
echo "-> new app URL: $NEW_URL"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh secret set APP_URL --body "$NEW_URL" --repo "$OWNER/$REPO" >/dev/null
  gh variable set APP_URL --body "$NEW_URL" --repo "$OWNER/$REPO" >/dev/null
  HOOK_JSON="$(mktemp)"
  python3 - "$HOOK_JSON" "$NEW_URL/api/webhook/github" "$(getvar GITHUB_WEBHOOK_SECRET)" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"name": "web", "active": True, "events": ["push", "issues", "release"],
               "config": {"url": sys.argv[2], "content_type": "json", "secret": sys.argv[3]}}, f)
PY
  gh api "repos/$OWNER/$REPO/hooks" --method POST --input "$HOOK_JSON" >/dev/null
  rm -f "$HOOK_JSON"
  echo "-> updated Actions APP_URL + added new webhook"
fi

echo ""
echo "MANUAL: on Box, update /workspace/cloady-hub/.env -> APP_URL=$NEW_URL"
echo "        then:  pkill -f cloady-hub/start.sh; pkill -f cloady-hub/worker.py"
echo "              nohup bash /workspace/cloady-hub/start.sh >/dev/null 2>&1 &"
echo "MANUAL: remove the OLD webhook pointing at the previous cloady.io URL in"
echo "        https://github.com/$OWNER/$REPO/settings/hooks"
echo "MANUAL: open the new panel: $NEW_URL/panel?key=\$(grep '^HUB_TOKEN=' $ENVP | cut -d= -f2-)"
