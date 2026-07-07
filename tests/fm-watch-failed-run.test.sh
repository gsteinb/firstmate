#!/usr/bin/env bash
# tests/fm-watch-failed-run.test.sh - the failed-run reconciliation folded into
# bin/fm-watch.sh's per-task check cadence (scan_failed_runs).
#
# A ship task whose no-mistakes run transitions to a failed/cancelled OUTCOME must
# wake firstmate even when it never wrote a `failed:` status line - fm-crew-state.sh
# (authoritative run-step read) is the source of truth. But a run that is
# failed/cancelled while its PR is already DELIVERED and HEALTHY (merged, or
# open+not-dirty+green) is a benign monitoring-run cancellation - not recovery-
# needed - and must NOT raise a scary failure wake. These cases pin that:
#   - failed run, no PR              -> actionable wake, edge-triggered (fires once)
#   - failed run, already-seen       -> suppressed (no re-fire while still failed)
#   - failed run, healthy delivered PR (merged) -> absorbed (no wake, logged)
#   - failed run, conflicted PR      -> actionable wake (not a healthy PR)
#
# Hermetic: reuses the fake tmux + fake fm-crew-state from wake-helpers, plus a stub
# gh for the PR-health probe. Only ship metas are scanned; the check cadence is the
# only loop that runs it, so tests set FM_CHECK_INTERVAL low and everything else high.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-failed-run)

# Add a stub gh to a case's fakebin for the PR-health probe. Emits the env-driven
# 3-line summary (state / mergeStateStatus / first-failing-check).
add_gh_stub() {  # <fakebin>
  local fb=$1
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = pr ] || exit 0
[ "${2:-}" = view ] || exit 0
printf '%s\n' "${FM_FAKE_PR_STATE-OPEN}"
printf '%s\n' "${FM_FAKE_PR_MERGE-CLEAN}"
[ -n "${FM_FAKE_PR_FAILED:-}" ] && printf '%s\n' "$FM_FAKE_PR_FAILED"
exit 0
SH
  chmod +x "$fb/gh"
}

# Launch the watcher for a case with the check cadence enabled (interval 1) and
# everything else quiet, the fake crew-state wired in, and gh on PATH.
watch_failed_bg() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# 0 if <pid> stays alive <limit> 0.1s ticks; 1 if it died (mirrors fm-watch-triage).
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# --- failed run, no PR: actionable wake -------------------------------------

test_failed_run_no_pr_wakes() {
  local dir state fakebin out drain_out pid
  dir=$(make_case failed-no-pr); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  add_gh_stub "$fakebin"
  # A ship task, no window (so the stale scan skips it), no pr recorded.
  printf 'kind=ship\nworktree=%s\n' "$dir/wt" > "$state/task.meta"
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  watch_failed_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not wake for a failed run with no healthy PR"
  grep -F "check: run-failed task" "$out" >/dev/null || fail "watcher did not print the run-failed wake reason"
  [ "$(cat "$state/task.run-state-seen" 2>/dev/null || true)" = failed ] || fail "failed run did not persist run-state-seen"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the run-failed wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "run-failed-task" >/dev/null || fail "run-failed wake was not queued"
  pass "a failed run with no healthy PR wakes firstmate (actionable)"
}

# --- failed run already seen: edge-triggered, no re-fire --------------------

test_failed_run_already_seen_suppressed() {
  local dir state fakebin out pid
  dir=$(make_case failed-seen); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_gh_stub "$fakebin"
  printf 'kind=ship\nworktree=%s\n' "$dir/wt" > "$state/task.meta"
  printf 'failed' > "$state/task.run-state-seen"   # already surfaced last cadence
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  watch_failed_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "watcher re-fired for an already-seen failed run (should be edge-suppressed): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "already-seen failed run printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "already-seen failed run enqueued a wake"; }
  reap "$pid"
  pass "an already-seen failed run does not re-fire (edge-triggered)"
}

# --- failed run, healthy delivered PR (merged): benign, absorbed ------------

test_failed_run_healthy_pr_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case failed-healthy-pr); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_gh_stub "$fakebin"
  printf 'kind=ship\nworktree=%s\npr=https://example.test/pr/10\n' "$dir/wt" > "$state/task.meta"
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run cancelled'
  export FM_FAKE_PR_STATE=MERGED   # the PR was delivered and merged; the run was a monitoring run
  watch_failed_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "watcher woke for a cancelled run whose PR is delivered+healthy (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "benign cancelled-with-healthy-PR printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign cancelled-with-healthy-PR enqueued a wake"; }
  grep -F "absorbed failed run with healthy delivered PR: task" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "benign absorb was not logged to the triage log"; }
  [ "$(cat "$state/task.run-state-seen" 2>/dev/null || true)" = failed ] || { reap "$pid"; fail "benign absorb did not persist run-state-seen"; }
  reap "$pid"
  pass "a cancelled run whose PR is delivered and healthy is absorbed (no scary failure wake)"
}

# --- failed run, conflicted PR: not healthy -> actionable wake --------------

test_failed_run_conflicted_pr_wakes() {
  local dir state fakebin out drain_out pid
  dir=$(make_case failed-dirty-pr); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  add_gh_stub "$fakebin"
  printf 'kind=ship\nworktree=%s\npr=https://example.test/pr/11\n' "$dir/wt" > "$state/task.meta"
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  export FM_FAKE_PR_STATE=OPEN FM_FAKE_PR_MERGE=DIRTY   # PR went conflicted: not a healthy delivered PR
  watch_failed_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not wake for a failed run whose PR is conflicted"
  grep -F "check: run-failed task" "$out" >/dev/null || fail "watcher did not print the run-failed wake for a conflicted PR"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the conflicted-PR run-failed wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "run-failed-task" >/dev/null || fail "conflicted-PR run-failed wake was not queued"
  pass "a failed run whose PR is conflicted (not healthy) wakes firstmate"
}

# --- a non-failed run does not wake and records its state -------------------

test_working_run_records_and_quiet() {
  local dir state fakebin out pid
  dir=$(make_case working-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_gh_stub "$fakebin"
  printf 'kind=ship\nworktree=%s\n' "$dir/wt" > "$state/task.meta"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_failed_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "watcher woke for a working run (should stay quiet): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a working run printed a wake reason: $(cat "$out")"; }
  [ "$(cat "$state/task.run-state-seen" 2>/dev/null || true)" = working ] || { reap "$pid"; fail "a working run did not record run-state-seen (so a later failure would not be an edge)"; }
  reap "$pid"
  pass "a non-failed run stays quiet and records its state so a later transition into failed is an edge"
}

test_failed_run_no_pr_wakes
test_failed_run_already_seen_suppressed
test_failed_run_healthy_pr_absorbed
test_failed_run_conflicted_pr_wakes
test_working_run_records_and_quiet

echo "all fm-watch-failed-run tests passed"
