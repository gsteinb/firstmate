#!/usr/bin/env bash
# tests/fm-gate-start.test.sh - behavior tests for bin/fm-gate-start.sh, the
# reliable no-mistakes gate-run starter.
#
# The helper exists because `no-mistakes axi run` spawns its gate push with
# PWD=. in the env, which poisons the gate post-receive hook's $(pwd) on macOS
# /bin/sh, so the daemon rejects the run notification for every fresh branch,
# and the bare-push workaround silently drops the --intent push option. These
# tests pin the whole contract deterministically - no daemon, no network:
# a scratch bare "gate" repo with an instrumented post-receive hook captures
# what the hook actually saw (pwd, refs, push options), and a PATH stub of
# no-mistakes replays canned `runs` output for the confirmation poll.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-start-test)
GATE_START="$ROOT/bin/fm-gate-start.sh"

# --- fixture builders ---------------------------------------------------------

# make_gate <dir> <log>: bare gate repo with push options enabled and a
# post-receive hook that records pwd, every ref update, and every push option.
make_gate() {
  local gate=$1 log=$2
  git init -q --bare "$gate"
  git -C "$gate" config receive.advertisePushOptions true
  cat > "$gate/hooks/post-receive" <<HOOK
#!/bin/sh
{
  echo "pwd=\$(pwd)"
  while read old new ref; do
    echo "ref=\$ref old=\$old new=\$new"
  done
  i=0
  while [ "\$i" -lt "\${GIT_PUSH_OPTION_COUNT:-0}" ]; do
    eval "opt=\\\$GIT_PUSH_OPTION_\$i"
    echo "opt=\$opt"
    i=\$((i+1))
  done
  echo "---"
} >> "$log"
HOOK
  chmod +x "$gate/hooks/post-receive"
}

# make_src <dir> <branch> <gate>: source repo on feature <branch> with the
# gate registered as the no-mistakes remote.
make_src() {
  local src=$1 branch=$2 gate=$3
  fm_git_init_commit "$src"
  git -C "$src" checkout -q -b "$branch"
  git -C "$src" remote add no-mistakes "$gate"
}

# make_nm_stub <fakebin> <runs-line...>: stub no-mistakes whose `runs`
# subcommand replays the given canned lines; everything else exits 0.
make_nm_stub() {
  local fakebin=$1 runs_file=$1/runs-output line
  shift
  : > "$runs_file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$runs_file"
  done
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = runs ]; then cat "$runs_file"; fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# run_gate_start <src> <fakebin> [args...]: run the helper from inside <src>
# with the stub on PATH and a poisoned PWD=. (the axi-run bug environment), so
# every test doubles as the env -u PWD regression check. Echoes output; the
# exit code is left to the caller via $?.
run_gate_start() {
  local src=$1 fakebin=$2
  shift 2
  (cd "$src" && env PWD=. PATH="$fakebin:$PATH" FM_GATE_START_TIMEOUT=0 "$GATE_START" "$@" 2>&1)
}

fm_git_identity fmtest fmtest@example.invalid

# --- happy path: run starts, intent preserved, hook sees an absolute path ----

test_start_preserves_intent_and_survives_poisoned_pwd() {
  local dir="$TMP_ROOT/happy" log branch=fm/task-x1 sha short out rc=0
  local intent expected_b64 fakebin
  mkdir -p "$dir"
  log="$dir/hook.log"
  make_gate "$dir/gate.git" "$log"
  make_src "$dir/src" "$branch" "$dir/gate.git"

  # Multi-line structured intent with quoting hazards; written untracked in the
  # worktree, which must NOT trip the dirty-tree guard.
  intent="$dir/src/.fm-intent.md"
  cat > "$intent" <<'EOF'
### Problem
`axi run` pushes with PWD=. and the hook's "$(pwd)" breaks.

### Solution
- push via env -u PWD with -o no-mistakes.intent=<base64>

### Details
Byte-for-byte fidelity matters, even 'quotes'.
EOF

  sha=$(git -C "$dir/src" rev-parse HEAD)
  short=$(git -C "$dir/src" rev-parse --short HEAD)
  fakebin=$(fm_fakebin "$dir")
  make_nm_stub "$fakebin" "  running   $branch  $short  2026-07-03 10:00"

  out=$(run_gate_start "$dir/src" "$fakebin" --intent-file .fm-intent.md) || rc=$?
  expect_code 0 "$rc" "fm-gate-start happy path"
  assert_contains "$out" "gate run started for $branch ($short)" \
    "helper must confirm the started run with branch and sha"

  # The regression test for the whole bug class: the helper ran under PWD=.,
  # yet the hook must have seen an absolute path, never ".".
  assert_grep "pwd=/" "$log" "gate hook must see an absolute pwd even under PWD=."
  if grep -Fx 'pwd=.' "$log" >/dev/null; then
    fail "gate hook saw the poisoned relative pwd '.'"
  fi

  # The branch ref was updated to HEAD.
  assert_grep "ref=refs/heads/$branch" "$log" "hook must record the branch ref update"
  assert_grep "new=$sha" "$log" "hook must record the pushed HEAD sha"

  # The intent rode along as the base64 push option, byte-for-byte (same
  # encoder pipeline the helper uses; $(cat ...) strips the trailing newline).
  expected_b64=$(printf '%s' "$(cat "$intent")" | base64 | tr -d '\n')
  assert_grep "opt=no-mistakes.intent=$expected_b64" "$log" \
    "hook must receive the intent as a base64 no-mistakes.intent push option"

  pass "fm-gate-start: run starts with intent attached, immune to PWD=. poisoning"
}

# --- stale gate ref: deletion fires before the update push -------------------

test_stale_gate_ref_is_cleared_first() {
  local dir="$TMP_ROOT/stale" log branch=fm/task-y2 sha short out rc=0 fakebin
  local null_sha=0000000000000000000000000000000000000000
  mkdir -p "$dir"
  log="$dir/hook.log"
  make_gate "$dir/gate.git" "$log"
  make_src "$dir/src" "$branch" "$dir/gate.git"
  sha=$(git -C "$dir/src" rev-parse HEAD)
  short=$(git -C "$dir/src" rev-parse --short HEAD)

  # Simulate the axi-run misfire aftermath: the gate ref already equals HEAD,
  # so a plain retry push would be a no-op and start nothing.
  git -C "$dir/src" push -q no-mistakes "HEAD:refs/heads/$branch"
  : > "$log"

  fakebin=$(fm_fakebin "$dir")
  make_nm_stub "$fakebin" "  running   $branch  $short  2026-07-03 10:00"
  out=$(run_gate_start "$dir/src" "$fakebin" --intent 'restart this wedged branch') || rc=$?
  expect_code 0 "$rc" "fm-gate-start on a stale gate ref"
  assert_contains "$out" "gate run started for $branch" "stale-ref start must still confirm"

  # The hook must have seen the deletion (new=null sha) before the re-push.
  local del_line push_line
  del_line=$(grep -n "new=$null_sha" "$log" | head -1 | cut -d: -f1)
  push_line=$(grep -n "new=$sha" "$log" | head -1 | cut -d: -f1)
  [ -n "$del_line" ] || fail "hook never saw the gate-ref deletion"
  [ -n "$push_line" ] || fail "hook never saw the re-push of HEAD"
  [ "$del_line" -lt "$push_line" ] || fail "deletion must precede the update push (got delete@$del_line, push@$push_line)"

  pass "fm-gate-start: stale gate ref is deleted first so the hook re-fires"
}

# --- refusal paths ------------------------------------------------------------

test_refusals() {
  local dir="$TMP_ROOT/refuse" out rc fakebin default
  mkdir -p "$dir"
  make_gate "$dir/gate.git" "$dir/hook.log"
  make_src "$dir/src" fm/task-z3 "$dir/gate.git"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" no-mistakes

  # Default branch: pin its name to 'main' so the guard is deterministic
  # regardless of the host git's init.defaultBranch.
  default=$(git -C "$dir/src" branch --format='%(refname:short)' | grep -v '^fm/' | head -1)
  [ "$default" = main ] || git -C "$dir/src" branch -m "$default" main
  git -C "$dir/src" checkout -q main
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent x) || rc=$?
  expect_code 1 "$rc" "default-branch refusal"
  assert_contains "$out" "default branch 'main'" "must refuse the default branch by name"

  # Detached HEAD.
  git -C "$dir/src" checkout -q --detach
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent x) || rc=$?
  expect_code 1 "$rc" "detached-HEAD refusal"
  assert_contains "$out" "detached HEAD" "must refuse a detached HEAD"
  git -C "$dir/src" checkout -q fm/task-z3

  # Dirty tracked tree.
  echo dirty >> "$dir/src/README.md"
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent x) || rc=$?
  expect_code 1 "$rc" "dirty-tree refusal"
  assert_contains "$out" "uncommitted tracked changes" "must refuse a dirty tracked tree"
  git -C "$dir/src" checkout -q -- README.md

  # Missing no-mistakes remote.
  git -C "$dir/src" remote remove no-mistakes
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent x) || rc=$?
  expect_code 1 "$rc" "missing-remote refusal"
  assert_contains "$out" "not gate-initialized" "must explain the missing no-mistakes remote"
  git -C "$dir/src" remote add no-mistakes "$dir/gate.git"

  # Empty / whitespace-only intent.
  printf '  \n\t\n' > "$dir/src/.fm-intent.md"
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent-file .fm-intent.md) || rc=$?
  expect_code 1 "$rc" "empty-intent refusal"
  assert_contains "$out" "intent text is empty" "must refuse a whitespace-only intent"

  # No intent at all.
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin") || rc=$?
  expect_code 1 "$rc" "missing-intent refusal"
  assert_contains "$out" "an intent is required" "must require an intent"

  # Both intent forms at once.
  rc=0; out=$(run_gate_start "$dir/src" "$fakebin" --intent x --intent-file .fm-intent.md) || rc=$?
  expect_code 1 "$rc" "double-intent refusal"
  assert_contains "$out" "mutually exclusive" "must refuse --intent plus --intent-file"

  pass "fm-gate-start: refusal paths (default branch, detached, dirty, no remote, bad intent)"
}

# --- confirmation: timeout and wrong-sha runs never count --------------------

test_timeout_prints_diagnostic() {
  local dir="$TMP_ROOT/timeout" branch=fm/task-t4 out rc=0 fakebin
  mkdir -p "$dir"
  make_gate "$dir/gate.git" "$dir/hook.log"
  make_src "$dir/src" "$branch" "$dir/gate.git"
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" no-mistakes   # `runs` shows nothing, ever

  out=$(run_gate_start "$dir/src" "$fakebin" --intent 'never confirmed') || rc=$?
  expect_code 1 "$rc" "confirmation timeout must exit non-zero"
  assert_contains "$out" "no running/pending run appeared" "timeout must say the run never appeared"
  assert_contains "$out" "notify-push.log" "timeout diagnostic must point at the gate hook log"

  pass "fm-gate-start: silent half-start is impossible - timeout exits non-zero with a diagnostic"
}

test_wrong_sha_run_is_not_confirmed() {
  local dir="$TMP_ROOT/wrongsha" branch=fm/task-w5 out rc=0 fakebin
  mkdir -p "$dir"
  make_gate "$dir/gate.git" "$dir/hook.log"
  make_src "$dir/src" "$branch" "$dir/gate.git"
  fakebin=$(fm_fakebin "$dir")
  # A stale run row for the same branch at a different sha must not count.
  make_nm_stub "$fakebin" "  running   $branch  deadbeef  2026-07-03 10:00"

  out=$(run_gate_start "$dir/src" "$fakebin" --intent 'stale row must not satisfy confirmation') || rc=$?
  expect_code 1 "$rc" "wrong-sha run row must not confirm the start"
  assert_contains "$out" "no running/pending run appeared" "wrong-sha timeout must report no run"

  pass "fm-gate-start: a run row at a different sha never confirms the start"
}

# --- scratch intent file is excluded so it never trips teardown --------------

# fm-teardown refuses on any untracked worktree file that is not one of
# firstmate's own hook files. The scratch intent file (.fm-intent.md) is never
# committed, so before this fix it lingered as `?? .fm-intent.md` and forced a
# manual `rm` on every gate-started teardown. The helper now registers it in
# .git/info/exclude, so it stays untracked-but-ignored.
test_intent_file_is_excluded_from_worktree() {
  local dir="$TMP_ROOT/exclude" log branch=fm/task-e6 short out rc=0 fakebin
  local dirty excl
  mkdir -p "$dir"
  log="$dir/hook.log"
  make_gate "$dir/gate.git" "$log"
  make_src "$dir/src" "$branch" "$dir/gate.git"
  printf '### Problem\nx\n### Solution\n- y\n### Details\nz\n' > "$dir/src/.fm-intent.md"
  short=$(git -C "$dir/src" rev-parse --short HEAD)
  fakebin=$(fm_fakebin "$dir")
  make_nm_stub "$fakebin" "  running   $branch  $short  2026-07-03 10:00"

  out=$(run_gate_start "$dir/src" "$fakebin" --intent-file .fm-intent.md) || rc=$?
  expect_code 0 "$rc" "fm-gate-start must succeed when excluding the intent file"

  # The intent file must be gone from git's view entirely: no `?? .fm-intent.md`.
  assert_not_contains "$(git -C "$dir/src" status --porcelain)" ".fm-intent.md" \
    "the scratch intent file must be untracked-but-ignored, not visible to git status"

  # Prove it directly against teardown's exact cleanliness check: the same grep
  # fm-teardown.sh uses to detect a dirty worktree must now find nothing.
  dirty=$(git -C "$dir/src" status --porcelain 2>/dev/null \
    | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)
  [ -z "$dirty" ] || fail "teardown's dirty check still trips on: $dirty"

  # The exclude entry is anchored to the worktree root and idempotent: a second
  # start must not append a duplicate line.
  excl="$dir/src/.git/info/exclude"
  assert_grep "/.fm-intent.md" "$excl" "intent file must be anchored in .git/info/exclude"
  out=$(run_gate_start "$dir/src" "$fakebin" --intent-file .fm-intent.md) || rc=$?
  [ "$(grep -cxF '/.fm-intent.md' "$excl")" -eq 1 ] \
    || fail "exclude registration must be idempotent (found duplicate lines)"

  pass "fm-gate-start: scratch intent file is excluded, so teardown stays clean"
}

test_start_preserves_intent_and_survives_poisoned_pwd
test_stale_gate_ref_is_cleared_first
test_refusals
test_timeout_prints_diagnostic
test_wrong_sha_run_is_not_confirmed
test_intent_file_is_excluded_from_worktree
