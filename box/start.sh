#!/usr/bin/env bash
# Self-healing supervisor for the Box worker. Mirrors the pattern used by the
# existing freenews / eb5 schedulers: a plain while-true loop that restarts the
# worker if it crashes. Box hibernation kills user processes, so re-run this
# launcher (or your box wake hook) whenever the box comes back.
#
# Start once:  nohup bash /workspace/cloady-hub/start.sh >/dev/null 2>&1 &
# Stop:        pkill -f 'cloady-hub/start.sh'; pkill -f 'cloady-hub/worker.py'

set -u
DIR="/workspace/cloady-hub"
mkdir -p "$DIR/runtime"
LOG="$DIR/runtime/supervisor.log"

# A second copy would claim the same tasks twice.
if pgrep -f "cloady-hub/start.sh" | grep -qv "^$$\$"; then
  echo "[$(date -u +%FT%TZ)] another supervisor is already running" >> "$LOG"
  exit 0
fi

while true; do
  echo "[$(date -u +%FT%TZ)] worker start" >> "$LOG"
  python3 "$DIR/worker.py" >> "$DIR/runtime/worker.out" 2>&1
  code=$?
  echo "[$(date -u +%FT%TZ)] worker exited $code, restart in 10s" >> "$LOG"
  sleep 10
done
