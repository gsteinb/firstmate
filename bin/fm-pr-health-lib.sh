#!/usr/bin/env bash
# Shared PR-health probe + classifier. Sourced by BOTH the generated per-task PR
# poll (bin/fm-pr-check.sh writes state/<id>.check.sh, which sources this) and the
# watcher's failed-run reconciliation (bin/fm-watch.sh), so the "is this PR bad?"
# policy lives in one place instead of two copies that can drift.
#
# The problem this solves: the old merge poll only ever reported a PR reaching
# MERGED. It was blind to a PR that was green-and-ready then REGRESSED - went
# `mergeStateStatus=DIRTY` (a real merge conflict on shared files, the classic
# parallel-PR collision) or had a required check turn red - so firstmate reported
# such a PR "ready" and never learned it had gone bad. This library adds those two
# regressions to the merge signal, edge-triggered so a bad PR wakes firstmate ONCE
# per transition, not on every poll.
#
# One gh call per probe; gh embeds gojq so the -q program below does the JSON work.
# Classification (fm_pr_health_category, fm_pr_is_healthy) is pure and unit-testable
# without gh. Everything fails safe: any gh/network/parse error yields no output, so
# the watcher stays asleep rather than waking on a spurious signal.

# The -q program. Emits up to three lines from one PR view:
#   line 1: PR state              - OPEN / CLOSED / MERGED
#   line 2: mergeStateStatus      - CLEAN / DIRTY / UNSTABLE / BLOCKED / BEHIND /
#                                   HAS_HOOKS / DRAFT / UNKNOWN
#   line 3: first FAILING check   - the name of the first status check whose
#                                   conclusion is a TERMINAL failure; absent when
#                                   none fail (a pending/queued/neutral/skipped
#                                   check is NOT a failure and emits nothing).
# `failing` upcases whichever of .conclusion (CheckRun) or .state (StatusContext)
# is present, so it is robust to both shapes and to casing. `.[0] // empty` yields
# nothing (not a stray "check") when no check has failed.
# shellcheck disable=SC2016  # single quotes are deliberate: $c is a jq variable, not shell.
FM_PR_HEALTH_JQ='
  def failing: ((.conclusion // .state) // "" | ascii_upcase) as $c
    | ($c == "FAILURE" or $c == "TIMED_OUT" or $c == "ERROR" or $c == "STARTUP_FAILURE");
  .state, .mergeStateStatus,
  ((.statusCheckRollup // []) | map(select(failing)) | .[0] // empty | (.name // .context // "check"))
'

# Probe a PR once. Echoes the raw up-to-3-line summary on stdout, or nothing (and
# returns non-zero) on any gh/network/parse error - the fail-safe silence contract.
fm_pr_health_probe() {  # <url>
  local url=$1
  [ -n "$url" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  gh pr view "$url" --json state,mergeStateStatus,statusCheckRollup -q "$FM_PR_HEALTH_JQ" 2>/dev/null || return 1
}

# Classify a probe summary into a single health category. PURE (no gh). Echoes one
# of: merged | conflicted | red | clean | "" (empty = INDETERMINATE - GitHub is
# still recomputing mergeability, so no conclusion can be drawn and callers must
# leave any stored state untouched rather than treating it as clean).
#
# Precedence: MERGED wins (terminal-good); then a definitive DIRTY is conflicted;
# then a definitively failed check is red; then a known non-dirty merge state is
# clean. An empty/UNKNOWN state or (for a non-merged, non-dirty, no-failed-check PR)
# an empty/UNKNOWN merge state is indeterminate - never a false conflicted/red, and
# never a premature clean that would suppress a later real regression.
fm_pr_health_category() {  # <state> <merge> <failed>
  local state=$1 merge=$2 failed=$3
  case "$state" in
    MERGED) printf 'merged'; return ;;
    ''|UNKNOWN) return ;;
  esac
  if [ "$merge" = DIRTY ]; then printf 'conflicted'; return; fi
  if [ -n "$failed" ]; then printf 'red'; return; fi
  case "$merge" in
    ''|UNKNOWN) return ;;
    *) printf 'clean' ;;
  esac
}

# 0 iff the PR is a healthy DELIVERED PR: merged, or open with no failing check and
# a definitively non-dirty merge state. PURE (no gh). Used by the watcher to tell a
# benign cancelled monitoring run (delivered+healthy PR -> no scary failure wake)
# from a real failure (no healthy PR -> wake). Deliberately conservative: an
# UNKNOWN/empty merge state is NOT confidently healthy, so it returns non-zero and
# the failure is treated as actionable - suppressing a real failure is worse than
# an occasional extra wake on a PR that turns out fine.
fm_pr_is_healthy() {  # <state> <merge> <failed>
  local state=$1 merge=$2 failed=$3
  [ "$state" = MERGED ] && return 0
  [ "$state" = OPEN ] || return 1
  [ -n "$failed" ] && return 1
  case "$merge" in
    DIRTY|UNKNOWN|'') return 1 ;;
    *) return 0 ;;
  esac
}

# Edge-triggered emit for the generated per-task poll. Probes <url>, classifies,
# and prints a wake line ONLY when the health category TRANSITIONED away from the
# value stored in <health-file>. Updates the stored category on every determinate
# read (including clean/recovered) so a later re-regression fires again. Prints
# nothing - and leaves the stored state untouched - on error, transient/unknown
# states, or an unchanged category. This is the whole body of state/<id>.check.sh.
fm_pr_health_emit() {  # <url> <health-file>
  local url=$1 hf=$2 out state merge failed category prev
  out=$(fm_pr_health_probe "$url") || return 0
  [ -n "$out" ] || return 0
  state=$(printf '%s\n' "$out" | sed -n '1p')
  merge=$(printf '%s\n' "$out" | sed -n '2p')
  failed=$(printf '%s\n' "$out" | sed -n '3p')
  category=$(fm_pr_health_category "$state" "$merge" "$failed")
  [ -n "$category" ] || return 0
  prev=$(cat "$hf" 2>/dev/null || true)
  [ "$category" = "$prev" ] && return 0
  printf '%s' "$category" > "$hf" 2>/dev/null || true
  case "$category" in
    merged)     printf 'merged\n' ;;
    conflicted) printf 'conflicted: PR needs rebase\n' ;;
    red)        printf 'checks-red: %s\n' "$failed" ;;
  esac
}
