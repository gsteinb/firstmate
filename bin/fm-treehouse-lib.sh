# shellcheck shell=bash
# Robust `treehouse return` for teardown. Usage: . bin/fm-treehouse-lib.sh
#
# Two macOS-flavored failure modes have repeatedly broken teardown's worktree
# return, forcing manual de-tracking:
#
#   1. Case-only path drift. On a case-insensitive filesystem treehouse can record
#      one worktree under differently-cased path strings across acquisitions - e.g.
#      the on-disk pool dir is `.treehouse/MyApp-<hash>/N/MyApp` but the state
#      records `.../myapp-<hash>/N/myapp`. `treehouse return` string-matches the
#      path we hand it against its recorded strings, so a case difference between the
#      path we stored (from the pane cwd) and the path treehouse stored yields
#      "worktree <path> is not managed by treehouse" even though both name the same
#      directory. We reconcile by handing treehouse back its OWN recorded string.
#
#   2. A stale git index.lock. A killed git process can leave an index.lock behind;
#      treehouse's reset then fails. If - and only if - no live process holds the
#      lock, we clear it and retry once.
#
# Neither path weakens any caller safety check: the recorded worktree path is still
# what the dirty/landed checks inspect, and a lock a live process holds is never
# yanked. On anything unexpected we fall back to the original path and today's
# behavior.

# Idempotent source guard.
if [ -n "${FM_TREEHOUSE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TREEHOUSE_LIB_SOURCED=1

# Echo each recorded worktree path in a treehouse-state.json file, one per line.
# Deliberately dependency-light (no jq): the state schema is a flat list of
# {"path": "..."} objects and worktree paths never contain a double quote. Always
# succeeds so it is safe inside a heredoc under `set -e`.
fm_treehouse_state_paths() {
  local state=$1
  [ -f "$state" ] || return 0
  grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$state" 2>/dev/null \
    | sed -E 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/' || true
  return 0
}

# Case-insensitive whole-string path equality. Returns 0 when the two paths differ
# only by letter case - the drift signature - and 1 otherwise.
fm_paths_equal_ci() {
  local a b
  a=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  [ "$a" = "$b" ]
}

# Given a worktree path we recorded, echo the path string treehouse actually has
# recorded for that same worktree (so `treehouse return` matches it), or the input
# unchanged when no better match is found. Prefers an exact match (the healthy,
# no-drift case), then an entry naming the same directory - compared by device and
# inode (`-ef`), because case-insensitive filesystems alias both spellings to one
# inode while resolved-path strings do not reliably canonicalize case - then a
# case-only string match taken only when the entry can no longer be resolved (the
# drift with the aliased directory gone). An entry that resolves to a DIFFERENT
# directory - a genuinely distinct worktree on a case-sensitive filesystem - is
# never matched. Never fails.
fm_treehouse_registered_path() {
  local wt=${1:-} root state entry ci_match=
  [ -n "$wt" ] || { printf '%s\n' "$wt"; return 0; }
  root="${TREEHOUSE_DIR:-$HOME}/.treehouse"
  [ -d "$root" ] || { printf '%s\n' "$wt"; return 0; }
  for state in "$root"/*/treehouse-state.json; do
    [ -f "$state" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if [ "$entry" = "$wt" ]; then
        printf '%s\n' "$entry"
        return 0
      fi
      if [ -d "$entry" ]; then
        if [ -d "$wt" ] && [ "$entry" -ef "$wt" ]; then
          printf '%s\n' "$entry"
          return 0
        fi
      elif [ -z "$ci_match" ] && fm_paths_equal_ci "$entry" "$wt"; then
        ci_match=$entry
      fi
    done <<EOF
$(fm_treehouse_state_paths "$state")
EOF
  done
  if [ -n "$ci_match" ]; then
    printf '%s\n' "$ci_match"
    return 0
  fi
  printf '%s\n' "$wt"
}

# Remove the worktree's git index.lock IFF it is stale - no live process holds it.
# Returns 0 when a stale lock was cleared (caller should retry), 1 otherwise: no
# lock present, or a lock a live process still holds (which must never be yanked).
fm_clear_stale_index_lock() {
  local wt=${1:-} lock holders now mtime age
  [ -n "$wt" ] || return 1
  [ -d "$wt" ] || return 1
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) : ;;
    *) lock="$wt/$lock" ;;
  esac
  [ -f "$lock" ] || return 1
  if command -v lsof >/dev/null 2>&1; then
    # A live holder means the lock is NOT stale: refuse to touch it.
    holders=$(lsof -t -- "$lock" 2>/dev/null || true)
    [ -z "$holders" ] || return 1
  else
    # No lsof: fall back to an age heuristic, clearing only clearly-old locks.
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    { [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ] && [ "$age" -ge "${FM_STALE_LOCK_SECS:-120}" ]; } || return 1
  fi
  rm -f -- "$lock" || return 1
  return 0
}

# Return a worktree to its treehouse pool, robust to a case-only path drift and a
# stale index.lock. Runs treehouse from <proj> so it resolves the right pool.
# Reconciles the path to treehouse's own recorded string, and on a first-attempt
# failure clears a provably stale index.lock and retries once. Returns treehouse's
# exit status.
fm_treehouse_return() {
  local proj=$1 wt=$2 target
  target=$(fm_treehouse_registered_path "$wt")
  if ( cd "$proj" && treehouse return --force "$target" ); then
    return 0
  fi
  if fm_clear_stale_index_lock "$wt"; then
    ( cd "$proj" && treehouse return --force "$target" )
    return $?
  fi
  return 1
}
