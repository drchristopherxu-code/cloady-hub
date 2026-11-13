#!/usr/bin/env bash
# Start (or revive) the Box hub worker as its own session leader.
# Safe to run repeatedly: start.sh refuses to run a duplicate.
#
#   bash /workspace/cloady-hub/launch.sh
#
# Re-run this after a Box hibernate/wake cycle, or call it from any existing
# scheduler's self-heal hook. It never modifies other scripts.

set -u
DIR="/workspace/cloady-hub"
PIDFILE="$DIR/runtime/supervisor.pid"
LOG="$DIR/runtime/supervisor.log"
mkdir -p "$DIR/runtime"

if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && \
     tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null | grep -q "cloady-hub/start.sh"; then
    echo "already running (pid $OLD)"
    exit 0
  fi
fi

setsid bash "$DIR/start.sh" </dev/null >/dev/null 2>&1 &
echo "launched supervisor pid $!"
echo "[$(date -u +%FT%TZ)] launch.sh invoked" >> "$LOG"
