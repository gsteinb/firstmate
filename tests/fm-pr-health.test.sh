#!/usr/bin/env bash
# Behavior tests for the PR-health poll: the shared classifier bin/fm-pr-health-lib.sh
# and the edge-triggered per-task check that bin/fm-pr-check.sh generates.
#
# The old merge poll only ever reported a PR reaching MERGED; it was blind to a
# ready PR that then REGRESSED - went conflicted (mergeStateStatus DIRTY) or had a
# required check turn red. This suite pins the fix:
#   - pure classification (category + is-healthy) over every state combination
#   - the generated check.sh is EDGE-triggered: dirty wakes ONCE, stays quiet while
#     still dirty, and re-fires after recover-then-re-dirty
#   - red check wakes; merged still wakes
#   - transient/unknown states never wake and never poison the stored state
#   - any gh error is silent (keeps firstmate asleep)
#
# Hermetic: a stub `gh` on PATH emits the same 3-line summary real gh's embedded jq
# would (state / mergeStateStatus / first-failing-check), driven by FM_FAKE_PR_*.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-health-lib.sh
. "$ROOT/bin/fm-pr-health-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
LIB="$ROOT/bin/fm-pr-health-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-health)

# A fakebin with a stub gh. It ignores the -q program (real gh applies its embedded
# jq; we can't run gh, so we emit the summary directly) and prints the env-driven
# up-to-3-line health summary for the health-field query, or the fake head sha for
# the headRefOid query used by fm-pr-check's meta recording. FM_FAKE_GH_FAIL=1
# simulates a gh/network error.
make_gh_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = pr ] || exit 0
[ "${2:-}" = view ] || exit 0
json=""
prev=""
for a in "$@"; do
  [ "$prev" = "--json" ] && json=$a
  prev=$a
done
case "$json" in
  *headRefOid*) printf '%s\n' "${FM_FAKE_GH_HEAD:-deadbeefcafe}" ;;
  *statusCheckRollup*|*mergeStateStatus*)
    printf '%s\n' "${FM_FAKE_PR_STATE-OPEN}"
    printf '%s\n' "${FM_FAKE_PR_MERGE-CLEAN}"
    [ -n "${FM_FAKE_PR_FAILED:-}" ] && printf '%s\n' "$FM_FAKE_PR_FAILED" ;;
  *state*) printf '%s\n' "${FM_FAKE_PR_STATE-OPEN}" ;;
esac
exit 0
SH
  chmod +x "$fb/gh"
  printf '%s\n' "$fb"
}

new_case() {  # <name> -> echoes case dir with an empty state/ and a gh fakebin
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  make_gh_fakebin "$d" >/dev/null
  printf '%s\n' "$d"
}

reset_pr_fakes() {
  FM_FAKE_PR_STATE=OPEN
  FM_FAKE_PR_MERGE=CLEAN
  FM_FAKE_PR_FAILED=""
  FM_FAKE_GH_FAIL=0
  FM_FAKE_GH_HEAD=deadbeefcafe
  export FM_FAKE_PR_STATE FM_FAKE_PR_MERGE FM_FAKE_PR_FAILED FM_FAKE_GH_FAIL FM_FAKE_GH_HEAD
}

# Run the generated check for <case> <id> with the case's gh stub on PATH and the
# current FM_FAKE_PR_* exported into it.
run_generated_check() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" bash "$1/state/$2.check.sh"
}

# --- pure classifier: fm_pr_health_category ---------------------------------

test_category_pure() {
  [ "$(fm_pr_health_category MERGED UNKNOWN '')" = merged ]      || fail "MERGED -> merged"
  [ "$(fm_pr_health_category OPEN DIRTY '')" = conflicted ]      || fail "OPEN+DIRTY -> conflicted"
  [ "$(fm_pr_health_category OPEN BLOCKED build)" = red ]        || fail "failing check -> red"
  [ "$(fm_pr_health_category OPEN CLEAN '')" = clean ]           || fail "OPEN+CLEAN -> clean"
  [ "$(fm_pr_health_category OPEN UNSTABLE '')" = clean ]        || fail "OPEN+UNSTABLE(no fail) -> clean"
  # Conflicted takes precedence over a simultaneously-failing check.
  [ "$(fm_pr_health_category OPEN DIRTY build)" = conflicted ]   || fail "DIRTY+failing -> conflicted wins"
  # Merged takes precedence over everything (a merged PR never reports red).
  [ "$(fm_pr_health_category MERGED DIRTY build)" = merged ]     || fail "MERGED wins over dirty/red"
  # Indeterminate: no false conflicted/red and no premature clean.
  [ -z "$(fm_pr_health_category '' '' '')" ]                     || fail "empty state -> indeterminate"
  [ -z "$(fm_pr_health_category UNKNOWN UNKNOWN '')" ]           || fail "UNKNOWN state -> indeterminate"
  [ -z "$(fm_pr_health_category OPEN UNKNOWN '')" ]              || fail "OPEN+UNKNOWN merge, no fail -> indeterminate"
  [ -z "$(fm_pr_health_category OPEN '' '')" ]                   || fail "OPEN+empty merge, no fail -> indeterminate"
  pass "fm_pr_health_category classifies merged/conflicted/red/clean and stays indeterminate on unknown"
}

# --- pure classifier: fm_pr_is_healthy --------------------------------------

test_is_healthy_pure() {
  fm_pr_is_healthy MERGED UNKNOWN '' || fail "merged PR is healthy"
  fm_pr_is_healthy OPEN CLEAN ''     || fail "open+clean is healthy"
  fm_pr_is_healthy OPEN UNSTABLE ''  || fail "open+unstable(no fail) is a delivered non-dirty PR -> healthy"
  fm_pr_is_healthy OPEN BLOCKED ''   || fail "open+blocked(no fail) is not dirty -> healthy"
  ! fm_pr_is_healthy OPEN DIRTY ''   || fail "open+dirty is NOT healthy"
  ! fm_pr_is_healthy OPEN CLEAN build || fail "open with a failing check is NOT healthy"
  ! fm_pr_is_healthy OPEN UNKNOWN '' || fail "open+unknown merge is not confidently healthy"
  ! fm_pr_is_healthy OPEN '' ''      || fail "open+empty merge is not confidently healthy"
  ! fm_pr_is_healthy CLOSED CLEAN '' || fail "closed(unmerged) is not a healthy delivered PR"
  pass "fm_pr_is_healthy: merged or open+not-dirty+green; conservative on unknown/closed"
}

# --- the generated check is armed and delegates to the lib -------------------

test_check_is_generated() {
  reset_pr_fakes
  local d; d=$(new_case armed)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" mytask https://example.test/pr/1 >/dev/null 2>&1
  assert_present "$d/state/mytask.check.sh" "fm-pr-check writes the check script"
  assert_grep "$LIB" "$d/state/mytask.check.sh" "generated check sources the shared health lib"
  assert_grep "fm_pr_health_emit" "$d/state/mytask.check.sh" "generated check delegates to fm_pr_health_emit"
  assert_grep "https://example.test/pr/1" "$d/state/mytask.check.sh" "generated check bakes in the PR url"
  pass "fm-pr-check generates a lib-backed PR-health check"
}

# --- merged still wakes ------------------------------------------------------

test_merged_wakes() {
  reset_pr_fakes
  local d out; d=$(new_case merged)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/2 >/dev/null 2>&1
  FM_FAKE_PR_STATE=MERGED; export FM_FAKE_PR_STATE
  out=$(run_generated_check "$d" t)
  [ "$out" = "merged" ] || fail "a merged PR must still print 'merged' (got: '$out')"
  pass "merged PR still wakes firstmate"
}

# --- dirty -> wake ONCE, quiet while still dirty, re-fire after recover ------

test_dirty_edge_triggered() {
  reset_pr_fakes
  local d out; d=$(new_case dirty-edge)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/3 >/dev/null 2>&1

  # First poll while dirty: wakes once.
  FM_FAKE_PR_MERGE=DIRTY; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ "$out" = "conflicted: PR needs rebase" ] || fail "first dirty poll must wake conflicted (got: '$out')"
  [ "$(cat "$d/state/t.pr-health")" = conflicted ] || fail "dirty poll must persist the conflicted health"

  # Second poll, still dirty: silent (edge-triggered, no churn).
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "still-dirty poll must stay quiet (got: '$out')"

  # Recover: mergeable again. Silent, but the stored state resets.
  FM_FAKE_PR_MERGE=CLEAN; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "recovery poll must be silent (got: '$out')"
  [ "$(cat "$d/state/t.pr-health")" = clean ] || fail "recovery must reset stored health to clean"

  # Re-regress: dirty again -> wakes AGAIN.
  FM_FAKE_PR_MERGE=DIRTY; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ "$out" = "conflicted: PR needs rebase" ] || fail "re-regression must wake conflicted again (got: '$out')"
  pass "dirty is edge-triggered: wakes once, quiet while dirty, re-fires after recovery"
}

# --- red check wakes, named; and is edge-triggered --------------------------

test_red_check_wakes() {
  reset_pr_fakes
  local d out; d=$(new_case red)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/4 >/dev/null 2>&1
  FM_FAKE_PR_MERGE=BLOCKED; FM_FAKE_PR_FAILED="unit-tests"; export FM_FAKE_PR_MERGE FM_FAKE_PR_FAILED
  out=$(run_generated_check "$d" t)
  [ "$out" = "checks-red: unit-tests" ] || fail "a failing required check must wake checks-red with its name (got: '$out')"
  [ "$(cat "$d/state/t.pr-health")" = red ] || fail "red poll must persist the red health"
  # Still red -> quiet.
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "still-red poll must stay quiet (got: '$out')"
  pass "a red required check wakes checks-red once, named"
}

# --- transient / unknown states never wake and never poison stored state ----

test_transient_unknown_no_wake() {
  reset_pr_fakes
  local d out; d=$(new_case transient)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/5 >/dev/null 2>&1

  # mergeStateStatus UNKNOWN while GitHub recomputes: no wake, no stored state.
  FM_FAKE_PR_MERGE=UNKNOWN; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "UNKNOWN merge state must not wake (got: '$out')"
  assert_absent "$d/state/t.pr-health" "indeterminate poll must not write a stored health"

  # A genuine DIRTY that follows must still fire (the transient did not suppress it).
  FM_FAKE_PR_MERGE=DIRTY; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ "$out" = "conflicted: PR needs rebase" ] || fail "a real dirty after a transient unknown must still wake (got: '$out')"
  pass "transient/unknown states never wake and never suppress a later real regression"
}

# UNSTABLE (CI still running) and BLOCKED (awaiting review) are normal, not bad.
test_normal_pending_states_no_wake() {
  reset_pr_fakes
  local d out; d=$(new_case pending)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/6 >/dev/null 2>&1
  FM_FAKE_PR_MERGE=UNSTABLE; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "UNSTABLE (CI running) must not wake (got: '$out')"
  FM_FAKE_PR_MERGE=BLOCKED; export FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "BLOCKED (awaiting review) must not wake (got: '$out')"
  pass "normal pending states (UNSTABLE, BLOCKED) do not wake"
}

# A pending/queued check is not red.
test_pending_check_not_red() {
  reset_pr_fakes
  local d out; d=$(new_case pending-check)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/7 >/dev/null 2>&1
  # No failing check name emitted (the -q only emits terminal failures); merge OK.
  FM_FAKE_PR_MERGE=UNSTABLE; FM_FAKE_PR_FAILED=""; export FM_FAKE_PR_MERGE FM_FAKE_PR_FAILED
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "a PR with only pending checks must not wake checks-red (got: '$out')"
  pass "a pending check is not treated as red"
}

# --- any gh error is silent (keeps firstmate asleep) ------------------------

test_gh_error_silent() {
  reset_pr_fakes
  local d out; d=$(new_case gh-error)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/8 >/dev/null 2>&1
  # Prime a stored conflicted state, then a gh failure must NOT change it or emit.
  printf 'conflicted' > "$d/state/t.pr-health"
  FM_FAKE_GH_FAIL=1; export FM_FAKE_GH_FAIL
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "a gh error must print nothing (got: '$out')"
  [ "$(cat "$d/state/t.pr-health")" = conflicted ] || fail "a gh error must leave stored health untouched"
  pass "a gh/network error is silent and leaves stored state untouched"
}

# Empty gh output (succeeded but returned nothing) is also treated as an error.
test_empty_output_silent() {
  reset_pr_fakes
  local d out; d=$(new_case empty-out)
  FM_STATE_OVERRIDE="$d/state" "$PR_CHECK" t https://example.test/pr/9 >/dev/null 2>&1
  FM_FAKE_PR_STATE=""; FM_FAKE_PR_MERGE=""; export FM_FAKE_PR_STATE FM_FAKE_PR_MERGE
  out=$(run_generated_check "$d" t)
  [ -z "$out" ] || fail "empty gh output must print nothing (got: '$out')"
  assert_absent "$d/state/t.pr-health" "empty gh output must not write a stored health"
  pass "empty gh output is silent"
}

test_category_pure
test_is_healthy_pure
test_check_is_generated
test_merged_wakes
test_dirty_edge_triggered
test_red_check_wakes
test_transient_unknown_no_wake
test_normal_pending_states_no_wake
test_pending_check_not_red
test_gh_error_silent
test_empty_output_silent

echo "all fm-pr-health tests passed"
