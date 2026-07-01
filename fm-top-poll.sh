#!/usr/bin/env bash
# fm-top-poll.sh - block until fm-top writes a decision to its inbox, then print
# it, consume it, and exit. Run as a harness-tracked background task so a decision
# the captain makes inside fm-top routes straight back to firstmate. Tracked
# companion tooling to fm-top.py.
set -euo pipefail
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
INBOX="$FM_HOME/state/.fmtop-inbox"
MAX="${FM_TOP_POLL_MAX:-3600}"   # safety cap (s)
mkdir -p "$INBOX"
elapsed=0
while [ "$elapsed" -lt "$MAX" ]; do
  f=$(ls -1 "$INBOX"/*.json 2>/dev/null | head -1 || true)
  if [ -n "$f" ]; then
    echo "fmtop-decision: $f"
    cat "$f" 2>/dev/null || true
    echo
    rm -f "$f"
    exit 0
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
echo "fmtop-poll: no decision within ${MAX}s (re-arm)"
exit 0
