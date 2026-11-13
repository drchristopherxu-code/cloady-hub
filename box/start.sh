#!/usr/bin/env bash
# Self-healing supervisor for the Box worker. Mirrors the pattern used by the
# existing freenews / eb5 schedulers: a plain while-true loop that restarts the
# worker if it crashes.
#
# IMPORTANT: launch via ./launch.sh (setsid), NOT plain `nohup ... &`.
# Background processes left in the MCP shell's process group get reaped when
# that session ends; the long-lived schedulers in this Box are all session
# leaders (SID == PID) because they were started with setsid.
#
# Stop:  pkill -f 'cloady-hub/start.sh'; pkill -f 'cloady-hub/worker.py'

set -u
DIR="/workspace/cloady-hub"
mkdir -p "$DIR/runtime"
LOG="$DIR/runtime/supervisor.log"
PIDFILE="$DIR/runtime/supervisor.pid"

# A second copy would claim the same tasks twice. Use a pidfile rather than
# pgrep -f, which also matches the shell that launched us.
if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    CMD="$(tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null || true)"
    case "$CMD" in
      *cloady-hub/start.sh*) echo "[$(date -u +%FT%TZ)] already running ($OLD)" >> "$LOG"; exit 0 ;;
    esac
  fi
fi
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

echo "[$(date -u +%FT%TZ)] supervisor start pid=$$ sid=$(ps -o sid= -p $$ | tr -d ' ')" >> "$LOG"
while true; do
  echo "[$(date -u +%FT%TZ)] worker start" >> "$LOG"
  python3 "$DIR/worker.py" >> "$DIR/runtime/worker.out" 2>&1
  code=$?
  echo "[$(date -u +%FT%TZ)] worker exited $code, restart in 10s" >> "$LOG"
  sleep 10
done
