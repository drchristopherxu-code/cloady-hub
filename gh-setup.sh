#!/usr/bin/env bash
# One-shot GitHub wiring for the hub. Run this once, after `gh auth login`.
#
# Creates the repo, pushes the code, sets Actions secrets/variables, and adds a
# signed repo webhook so every push also reaches Cloady -> Box.
#
#   gh auth login --web --scopes 'repo,workflow,admin:repo_hook'
#   ./gh-setup.sh
#
# REPO_VISIBILITY=public by default. Cloady can build a PUBLIC repo without
# any extra OAuth; a PRIVATE repo requires connecting GitHub in Cloady's
# Workspace settings -> Integrations first (see migrate-to-git.sh).

set -euo pipefail
cd "$(dirname "$0")"

REPO="${REPO_NAME:-cloady-hub}"
VISIBILITY="${REPO_VISIBILITY:-public}"
WS="${CLOADY_WORKSPACE:-drchristopherxu-code}"
ENVP="${HOME}/.config/cloady/hub.env"

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI missing (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || {
  echo "ERROR: not logged in. Run: gh auth login --web --scopes 'repo,workflow,admin:repo_hook'" >&2; exit 1;
}
[ -f "$ENVP" ] || { echo "ERROR: $ENVP missing — run ./deploy.sh first" >&2; exit 1; }

getvar() { grep -E "^${1}=" "$ENVP" | tail -1 | cut -d= -f2-; }
APP_URL="${APP_URL:-$(cloady apps "$WS" --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["endpoints"][0]["url"])')}"
APP_URL="${APP_URL%/}"
CL_TOKEN="$(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.config/cloady/config.json")))["token"])')"
OWNER="$(gh api user -q .login)"

echo "-> owner=$OWNER repo=$REPO visibility=$VISIBILITY"
echo "-> app=$APP_URL workspace=$WS"

if gh repo view "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "-> repo exists, reusing"
else
  gh repo create "$REPO" --"$VISIBILITY" --description "Cloady hub: public ingress + GitHub Actions clock + Box worker" >/dev/null
  echo "-> created $OWNER/$REPO"
fi

echo "-> setting Actions secrets + variables"
gh secret set CLOADY_TOKEN            --body "$CL_TOKEN"                   --repo "$OWNER/$REPO"
gh secret set APP_URL                 --body "$APP_URL"                    --repo "$OWNER/$REPO"
gh secret set HUB_TOKEN               --body "$(getvar HUB_TOKEN)"         --repo "$OWNER/$REPO"
# NOTE: GITHUB_WEBHOOK_SECRET is intentionally NOT a GitHub Actions secret.
# GitHub forbids secret names starting with GITHUB_, and it is only consumed by
# the Cloady app itself (server.js verifies webhook signatures against it), where
# deploy.sh already injects it as an app env var. The webhook registration below
# embeds the same value from hub.env into the hook config.
gh secret set BOT_SECRET              --body "$(getvar BOT_SECRET)"        --repo "$OWNER/$REPO"
gh variable set APP_URL               --body "$APP_URL"                    --repo "$OWNER/$REPO"
gh variable set CLOADY_WORKSPACE      --body "$WS"                         --repo "$OWNER/$REPO"

echo "-> committing and pushing"
[ -d .git ] || git init -q
git config user.name "${GIT_AUTHOR_NAME:-$OWNER}"
git config user.email "${GIT_AUTHOR_EMAIL:-$OWNER@users.noreply.github.com}"
git add -A
git commit -q -m "hub: ingress + task queue + panel + actions + box worker" || echo "   (nothing to commit)"
git branch -M main
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/$OWNER/$REPO.git"
else
  git remote add origin "https://github.com/$OWNER/$REPO.git"
fi
git push -u origin main

echo "-> creating signed GitHub webhook"
HOOK_URL="$APP_URL/api/webhook/github"
EXISTING="$(gh api "repos/$OWNER/$REPO/hooks" --paginate 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
try: d = json.loads(raw)
except Exception: d = []
if isinstance(d, dict): d = [d]
print("yes" if any(h.get("config",{}).get("url") == sys.argv[1] for h in d) else "no")
' "$HOOK_URL" || echo no)"
if [ "$EXISTING" = "yes" ]; then
  echo "   webhook already present"
else
  HOOK_JSON="$(mktemp)"
  python3 - "$HOOK_JSON" "$HOOK_URL" "$(getvar GITHUB_WEBHOOK_SECRET)" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({
        "name": "web", "active": True,
        "events": ["push", "issues", "release"],
        "config": {"url": sys.argv[2], "content_type": "json", "secret": sys.argv[3]},
    }, f)
PY
  gh api "repos/$OWNER/$REPO/hooks" --method POST --input "$HOOK_JSON" >/dev/null
  rm -f "$HOOK_JSON"
  echo "   webhook -> $HOOK_URL"
fi

echo ""
echo "DONE. Next:"
echo "  1. Actions tab -> enable workflows if prompted; run 'keepalive' once manually."
echo "  2. Panel: $APP_URL/panel?key=\$(grep '^HUB_TOKEN=' $ENVP | cut -d= -f2-)"
echo "  3. Optional native autoUpdate: ./migrate-to-git.sh (changes the app URL!)"
