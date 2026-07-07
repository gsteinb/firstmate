#!/usr/bin/env bash
# Unit tests for bin/fm-treehouse-lib.sh - the robust `treehouse return` helpers
# that keep teardown from false-failing on a case-only worktree-path drift or a
# stale git index.lock.
#
# Coverage:
#   - fm_treehouse_registered_path: exact match (no drift), case-only drift match,
#     and no-match fallback to the input path.
#   - fm_clear_stale_index_lock: no lock -> refuse; stale lock -> clear; a lock a
#     live process holds -> refuse and keep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-return-tests)

# Write a fixture pool state recording one worktree at <path>. Args: home path
seed_state() {
  local home=$1 path=$2
  mkdir -p "$home/.treehouse/pool"
  cat > "$home/.treehouse/pool/treehouse-state.json" <<JSON
{ "worktrees": [ { "name": "1", "path": "$path" } ] }
JSON
}

test_registered_path_exact_match_returns_input() {
  local home wt got
  home="$TMP_ROOT/exact"
  wt="$home/pool/1/myapp"
  seed_state "$home" "$wt"
  got=$(TREEHOUSE_DIR="$home" fm_treehouse_registered_path "$wt")
  [ "$got" = "$wt" ] || fail "exact: expected input path back, got '$got'"
  pass "registered-path returns the input unchanged when it matches exactly (no drift)"
}

test_registered_path_case_drift_returns_recorded() {
  local home wt recorded got
  home="$TMP_ROOT/drift"
  # We recorded the worktree lowercase; treehouse recorded a capitalized variant.
  wt="$home/pool/1/myapp"
  recorded="$home/pool/1/MyApp"
  seed_state "$home" "$recorded"
  got=$(TREEHOUSE_DIR="$home" fm_treehouse_registered_path "$wt")
  [ "$got" = "$recorded" ] \
    || fail "drift: expected treehouse's recorded string '$recorded', got '$got'"
  pass "registered-path returns treehouse's own case-variant string on a case-only drift"
}

test_registered_path_case_drift_existing_dir_returns_recorded() {
  local home wt recorded got
  home="$TMP_ROOT/drift-live"
  # The worktree exists on disk; treehouse recorded a case-variant spelling. On a
  # case-insensitive filesystem both spellings alias one directory (same inode);
  # on a case-sensitive one the recorded spelling does not resolve. Either way the
  # recorded string must come back so `treehouse return` matches it.
  wt="$home/pool/1/myapp"
  recorded="$home/pool/1/MyApp"
  mkdir -p "$wt"
  seed_state "$home" "$recorded"
  got=$(TREEHOUSE_DIR="$home" fm_treehouse_registered_path "$wt")
  [ "$got" = "$recorded" ] \
    || fail "drift-live: expected treehouse's recorded string '$recorded', got '$got'"
  pass "registered-path reconciles a case-variant spelling of an existing worktree"
}

test_registered_path_no_match_falls_back() {
  local home wt got
  home="$TMP_ROOT/nomatch"
  wt="$home/pool/1/myapp"
  seed_state "$home" "$home/pool/1/entirely-different"
  got=$(TREEHOUSE_DIR="$home" fm_treehouse_registered_path "$wt")
  [ "$got" = "$wt" ] || fail "no-match: expected fallback to input '$wt', got '$got'"
  pass "registered-path falls back to the input path when nothing matches"
}

test_registered_path_case_equal_distinct_dir_not_matched() {
  local home wt other got
  home="$TMP_ROOT/distinct"
  mkdir -p "$home/probe_a"
  if [ -e "$home/PROBE_A" ]; then
    pass "distinct-dir test skipped (case-insensitive filesystem)"
    return 0
  fi
  # Case-sensitive filesystem: a case-variant sibling is a genuinely different
  # directory; the ci fallback must never hand it to `treehouse return --force`.
  wt="$home/pool/1/myapp"
  other="$home/pool/1/MyApp"
  mkdir -p "$wt" "$other"
  seed_state "$home" "$other"
  got=$(TREEHOUSE_DIR="$home" fm_treehouse_registered_path "$wt")
  [ "$got" = "$wt" ] \
    || fail "distinct-dir: expected fallback to input '$wt', got '$got'"
  pass "registered-path never latches onto a case-equal but distinct real directory"
}

test_registered_path_no_state_root_falls_back() {
  local wt got
  wt="$TMP_ROOT/noroot/pool/1/myapp"
  got=$(TREEHOUSE_DIR="$TMP_ROOT/noroot" fm_treehouse_registered_path "$wt")
  [ "$got" = "$wt" ] || fail "no-root: expected fallback to input '$wt', got '$got'"
  pass "registered-path falls back cleanly when no pool state exists"
}

# Build a git worktree and place a fake index.lock in its git dir. Echoes the lock
# path. Args: dir
make_worktree_with_lock() {
  local dir=$1 repo="$1/repo" wt="$1/wt" lock
  mkdir -p "$dir"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$wt" 2>/dev/null
  lock=$(git -C "$wt" rev-parse --git-path index.lock)
  case "$lock" in /*) : ;; *) lock="$wt/$lock" ;; esac
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  printf '%s\n' "$wt" "$lock"
}

test_clear_stale_index_lock_no_lock_refuses() {
  local dir wt
  dir="$TMP_ROOT/lock-none"
  mkdir -p "$dir"
  git init -q "$dir/repo"
  git -C "$dir/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$dir/repo" worktree add -q "$dir/wt" 2>/dev/null
  wt="$dir/wt"
  set +e
  fm_clear_stale_index_lock "$wt"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-lock: helper should refuse (nothing to clear)"
  pass "stale-lock helper refuses when there is no index.lock"
}

test_clear_stale_index_lock_stale_cleared() {
  local dir out wt lock rc
  dir="$TMP_ROOT/lock-stale"
  out=$(make_worktree_with_lock "$dir")
  wt=$(printf '%s\n' "$out" | sed -n 1p)
  lock=$(printf '%s\n' "$out" | sed -n 2p)
  [ -f "$lock" ] || fail "stale-lock: fixture lock was not created"
  set +e
  FM_STALE_LOCK_SECS=0 fm_clear_stale_index_lock "$wt"
  rc=$?
  set -e
  expect_code 0 "$rc" "stale-lock: helper should clear a lock with no live holder"
  [ ! -e "$lock" ] || fail "stale-lock: index.lock was not removed"
  pass "stale-lock helper clears a lock that no live process holds"
}

test_clear_index_lock_live_holder_kept() {
  local dir out wt lock rc holder
  command -v lsof >/dev/null 2>&1 || { pass "live-holder test skipped (no lsof)"; return 0; }
  dir="$TMP_ROOT/lock-held"
  out=$(make_worktree_with_lock "$dir")
  wt=$(printf '%s\n' "$out" | sed -n 1p)
  lock=$(printf '%s\n' "$out" | sed -n 2p)
  # Hold the lock open with a live background process, then wait until lsof can see
  # the open fd before asserting, so the check is deterministic rather than timing.
  ( exec 9>"$lock"; sleep 30 ) &
  holder=$!
  local waited=0
  while [ "$waited" -lt 30 ]; do
    [ -n "$(lsof -t -- "$lock" 2>/dev/null || true)" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  set +e
  fm_clear_stale_index_lock "$wt"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "live-holder: helper should refuse to clear a held lock"
  [ -f "$lock" ] || fail "live-holder: a lock held by a live process was wrongly removed"
  pass "stale-lock helper keeps a lock a live process still holds (no safety regression)"
}

test_registered_path_exact_match_returns_input
test_registered_path_case_drift_returns_recorded
test_registered_path_case_drift_existing_dir_returns_recorded
test_registered_path_no_match_falls_back
test_registered_path_case_equal_distinct_dir_not_matched
test_registered_path_no_state_root_falls_back
test_clear_stale_index_lock_no_lock_refuses
test_clear_stale_index_lock_stale_cleared
test_clear_index_lock_live_holder_kept
