#!/usr/bin/env bash
# Turn on the durable GitHub Issue queue. Cloady opens one Issue per inbound
# task and comments the result when Box finishes it.
#
# Without this, tasks live only in Cloady memory (fast path) and are lost on a
# redeploy. With this, GitHub holds an audit trail of every task and result.
#
# Token choice (most to least safe):
#   1. GitHub fine-grained PAT, one repo, "Issues: read & write" -> export GITHUB_TOKEN=...
#   2. Fallback to `gh auth token` (broad OAuth token) -> only for personal use
#
# Usage: GITHUB_TOKEN=github_pat_... ./enable-issue-mirror.sh

set -euo pipefail
cd "$(dirname "$0")"

WS="${CLOADY_WORKSPACE:-drchristopherxu-code}"
REGION="${CLOADY_REGION:-eu1}"
REPO="${REPO_NAME:-cloady-hub}"

GH_TOKEN_VALUE="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}" || true
[ -n "$GH_TOKEN_VALUE" ] || { echo "ERROR: no GitHub token. Set GITHUB_TOKEN or run gh auth login" >&2; exit 1; }
OWNER="$(gh api user -q .login 2>/dev/null)" || { echo "ERROR: gh not authed" >&2; exit 1; }

CT="$(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.config/cloady/config.json")))["token"])')"
APP_SLUG="$(cloady apps "$WS" --json | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["slug"])')"

echo "-> app=$APP_SLUG workspace=$WS region=$REGION repo=$OWNER/$REPO"
GITHUB_TOKEN_VALUE="$GH_TOKEN_VALUE" CLOADY_TOKEN="$CT" \
python3 - "$WS" "$APP_SLUG" "$REGION" "$OWNER/$REPO" <<'PY'
import json, os, sys, urllib.request, urllib.error

ws, app, region, repo = sys.argv[1:5]
base = f"https://cloady.com/api/workspaces/{ws}/apps/{app}/vars"
query = "?env=production&region=" + region
headers = {"Authorization": "Bearer " + os.environ["CLOADY_TOKEN"],
           "Content-Type": "application/json"}

def call(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

status, listing = call("GET", base + query)
print("   GET vars:", status)
if status != 200:
    sys.exit("   cannot list vars: " + str(listing))
existing = {v["key"]: v["id"] for v in listing.get("vars", [])}

for key, value, secret in [
    ("GITHUB_TOKEN", os.environ["GITHUB_TOKEN_VALUE"], True),
    ("GITHUB_REPO", repo, False),
]:
    if key in existing:
        code, out = call("PUT", base + "/" + existing[key] + query,
                         {"key": key, "value": value, "isSecret": secret})
        print(f"   update {key}: {code}")
    else:
        code, out = call("POST", base + query,
                         {"key": key, "value": value, "isSecret": secret})
        print(f"   create {key}: {code}")
    if code not in (200, 201):
        print("   ", str(out)[:200]); sys.exit(1)
PY

echo "-> rolling the app so the new env is picked up"
cloady redeploy "$WS" "$APP_SLUG" --region "$REGION" 2>&1 | head -3 || true
echo "   check in ~60s: curl -s https://<app>/api/health | grep githubIssueMirror"
