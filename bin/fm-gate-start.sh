#!/usr/bin/env bash
# Reliably start a no-mistakes gate run for a branch, with the explicit
# --intent attached. Run by a CREWMATE inside its own worktree, on its
# committed feature branch, before driving the run with `no-mistakes axi run`.
#
# Why this exists: `no-mistakes axi run` (observed at v1.31.2) spawns its gate
# push with the literal environment variable PWD=. in the child env. Git's
# local-transport push runs git-receive-pack as a child of that process, so the
# gate bare repo's post-receive hook inherits PWD=.; macOS /bin/sh (bash 3.2)
# adopts an inherited relative PWD, the hook's "$(pwd)" evaluates to ".", and
# `no-mistakes daemon notify-push --gate .` is rejected by the daemon. No run is
# created, and axi run's rerun fallback fails on any fresh branch ("no previous
# run for branch ..."), so every first-time run start misfires. Worse, the
# failed start still updated the gate ref, so a retry push is a no-op and fires
# no hook, and the bare-push workaround silently drops the intent push option,
# leaving the PR's Intent section to transcript inference.
#
# This helper performs the reliable start: clear the (possibly stale) gate ref,
# then push HEAD with `-o no-mistakes.intent=<base64>` - the exact push option
# axi run itself sends (captured empirically at v1.31.2) - both via
# `env -u PWD` so the whole PWD-poisoning failure class is impossible even from
# a polluted caller env. It then confirms the daemon actually created a
# running/pending run for the branch at the current HEAD before declaring
# success. Once the run exists, `no-mistakes axi run --intent "..."` reattaches
# and drives the gates normally.
#
# The root fix belongs upstream at github.com/kunchenguid/no-mistakes (stop
# setting PWD=. on the spawned push, or absolutize a relative --gate in
# notify-push); this helper stays valid on a fixed tool too, where the
# deletion step is simply an extra benign hook fire.
#
# Intentionally does NOT call fm-guard.sh: it runs in crew worktrees, outside
# any firstmate home, and must work with FM_HOME unset.
#
# Usage: fm-gate-start.sh --intent-file <path> [--branch <name>]
#        fm-gate-start.sh --intent '<text>'   [--branch <name>]
# Env:   FM_GATE_START_TIMEOUT  seconds to wait for the run to appear (default 15)
#        FM_GATE_START_POLL     seconds between run-list polls (default 1)
set -eu

usage() {
  cat <<'EOF'
Usage: fm-gate-start.sh --intent-file <path> [--branch <name>]
       fm-gate-start.sh --intent '<text>'   [--branch <name>]

Reliably start a no-mistakes gate run for the current (or named) branch with
the explicit intent attached, then confirm the run actually started.

Why not `no-mistakes axi run` directly? Its starter spawns the gate push with
PWD=. in the env, which poisons the gate hook's $(pwd) on macOS /bin/sh, so the
daemon rejects the notification and every fresh-branch start fails ("no
previous run for branch ..."). A bare `git push no-mistakes HEAD:...` retry
also silently drops the --intent push option. This helper does the start that
works - clear the stale gate ref, push with `-o no-mistakes.intent=<base64>`,
both under `env -u PWD` - and polls until the run is visible. After it prints
success, drive the run as usual with `no-mistakes axi run --intent "..."`,
which reattaches to the active run.

Prefer --intent-file: it preserves the multi-line Problem/Solution/Details
intent shape without shell-quoting hazards. The intent text must be non-empty.

Options:
  --intent-file <path>  read the intent text from <path>
  --intent '<text>'     take the intent text inline
  --branch <name>       gate branch ref to start (default: current branch)
  -h, --help            show this help

Refuses to run on the repo's default branch, on a detached HEAD, without the
`no-mistakes` remote (project not gate-initialized), with uncommitted tracked
changes, or with an empty intent. Untracked files (e.g. your intent file) are
fine.

Exit status: 0 once a running/pending run for the branch at the current HEAD
is confirmed; non-zero on any refusal, push failure, or confirmation timeout
(FM_GATE_START_TIMEOUT seconds, default 15).

The root fix for the starter misfire lives upstream at
github.com/kunchenguid/no-mistakes; this helper remains a valid start path on
a fixed tool as well.
EOF
}

fatal() {
  echo "error: $1" >&2
  exit 1
}

BRANCH=""
INTENT_INLINE=""
INTENT_FILE=""
INTENT_INLINE_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --intent-file)
      [ $# -ge 2 ] || fatal "--intent-file requires a path"
      INTENT_FILE=$2; shift 2 ;;
    --intent)
      [ $# -ge 2 ] || fatal "--intent requires the intent text"
      INTENT_INLINE=$2; INTENT_INLINE_SET=1; shift 2 ;;
    --branch)
      [ $# -ge 2 ] || fatal "--branch requires a branch name"
      BRANCH=$2; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage >&2
      fatal "unknown argument: $1" ;;
  esac
done

# --- resolve and guard the intent -------------------------------------------

if [ -n "$INTENT_FILE" ] && [ "$INTENT_INLINE_SET" = 1 ]; then
  fatal "--intent-file and --intent are mutually exclusive; pass one"
fi
if [ -n "$INTENT_FILE" ]; then
  [ -f "$INTENT_FILE" ] || fatal "intent file not found: $INTENT_FILE"
  INTENT_TEXT=$(cat "$INTENT_FILE")
elif [ "$INTENT_INLINE_SET" = 1 ]; then
  INTENT_TEXT=$INTENT_INLINE
else
  usage >&2
  fatal "an intent is required: pass --intent-file <path> (preferred) or --intent '<text>'"
fi
[ -n "$(printf '%s' "$INTENT_TEXT" | tr -d '[:space:]')" ] || fatal "intent text is empty"

# --- resolve and guard the branch and repo state -----------------------------

git rev-parse --git-dir >/dev/null 2>&1 || fatal "not inside a git repository"
command -v no-mistakes >/dev/null 2>&1 || fatal "no-mistakes binary not found on PATH"

CURRENT=$(git symbolic-ref --quiet --short HEAD || true)
if [ -z "$BRANCH" ]; then
  [ -n "$CURRENT" ] || fatal "detached HEAD: check out your feature branch (or pass --branch) before starting a gate run"
  BRANCH=$CURRENT
fi
[ -n "$CURRENT" ] || fatal "detached HEAD: check out your feature branch before starting a gate run"

# Refuse the default branch: gate runs validate feature branches, and a crew
# push of the default branch is never intended.
default_branch() {
  local ref b
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then
      echo "$b"
      return 0
    fi
  done
  return 1
}
DEFAULT=$(default_branch || true)
if [ -n "$DEFAULT" ] && [ "$BRANCH" = "$DEFAULT" ]; then
  fatal "refusing to start a gate run for the default branch '$DEFAULT'; work on a feature branch"
fi

git remote get-url no-mistakes >/dev/null 2>&1 \
  || fatal "no 'no-mistakes' remote here: the project is not gate-initialized (run 'no-mistakes init' from the project checkout)"

# Tracked modifications only: the untracked intent file (and other scratch
# files) must not block the start of a run for the committed work.
if [ -n "$(git status --porcelain --untracked-files=no | head -1)" ]; then
  fatal "working tree has uncommitted tracked changes; commit them before starting a gate run"
fi

# --- start the run ------------------------------------------------------------

B64=$(printf '%s' "$INTENT_TEXT" | base64 | tr -d '\n')

# Clear a stale gate ref first: after an axi-run misfire the gate ref already
# equals HEAD, so a plain push would be a no-op and fire no hook. A missing
# remote ref is the normal first-run case and is ignored; any other failure is
# fatal. `env -u PWD` on both pushes makes the PWD=. hook poisoning impossible
# regardless of the caller's environment.
if ! DEL_OUT=$(env -u PWD git push no-mistakes ":refs/heads/$BRANCH" 2>&1); then
  case "$DEL_OUT" in
    *"remote ref does not exist"*) : ;;
    *)
      printf '%s\n' "$DEL_OUT" >&2
      fatal "failed to clear the gate ref refs/heads/$BRANCH" ;;
  esac
fi

if ! PUSH_OUT=$(env -u PWD git push -o "no-mistakes.intent=$B64" no-mistakes "HEAD:refs/heads/$BRANCH" 2>&1); then
  printf '%s\n' "$PUSH_OUT" >&2
  fatal "gate push failed for $BRANCH"
fi

# --- confirm the daemon created the run ---------------------------------------
#
# The push succeeding only proves git accepted it; the run exists only once the
# hook's notify-push reached the daemon. Poll the run list for a
# running/pending row for this branch whose SHA matches HEAD, and never report
# a silent half-start.

SHA=$(git rev-parse HEAD)
SHORT=$(git rev-parse --short HEAD)
TIMEOUT=${FM_GATE_START_TIMEOUT:-15}
POLL=${FM_GATE_START_POLL:-1}
case "$TIMEOUT$POLL" in
  *[!0-9]*) fatal "FM_GATE_START_TIMEOUT and FM_GATE_START_POLL must be whole seconds" ;;
esac

ELAPSED=0
while :; do
  LINE=$(no-mistakes runs 2>/dev/null \
    | awk -v b="$BRANCH" '($1 == "running" || $1 == "pending") && $2 == b { print; exit }' \
    || true)
  if [ -n "$LINE" ]; then
    RUN_SHA=$(printf '%s\n' "$LINE" | awk '{ print $3 }')
    case "$SHA" in
      "$RUN_SHA"*)
        echo "gate run started for $BRANCH ($SHORT)"
        exit 0 ;;
    esac
  fi
  [ "$ELAPSED" -lt "$TIMEOUT" ] || break
  sleep "$POLL"
  ELAPSED=$((ELAPSED + POLL))
done

GATE_URL=$(git remote get-url no-mistakes 2>/dev/null || echo '<gate repo>')
{
  echo "error: the gate push for $BRANCH succeeded, but no running/pending run appeared at $SHORT within ${TIMEOUT}s."
  echo "The hand-off from the gate hook to the daemon likely failed. Check:"
  echo "  - the gate hook log: $GATE_URL/notify-push.log"
  echo "  - the daemon log: ~/.no-mistakes/logs/daemon.log"
  echo "  - 'no-mistakes runs' and 'no-mistakes axi status' for $BRANCH"
} >&2
exit 1
