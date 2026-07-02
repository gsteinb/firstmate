#!/usr/bin/env bash
# fm-seed-lib.sh - per-project worktree seeding.
#
# Firstmate clones each project fresh from origin and dispatches crewmates into
# isolated git worktrees. Git worktrees never carry untracked/gitignored files,
# so a project's local-only files (e.g. .env.local, backend/.env) that are needed
# to build, run, or test the app never reach a crewmate's worktree. This closes
# that gap generically: a per-project seed store laid out at the exact relative
# paths the files should occupy inside the worktree, copied in at spawn time.
#
# Convention (see AGENTS.md section 2): the store lives at
#   $FM_HOME/config/worktree-seed/<project-name>/
# laid out mirroring the worktree, so e.g.
#   config/worktree-seed/loanova/.env.local    -> <worktree>/.env.local
#   config/worktree-seed/loanova/backend/.env  -> <worktree>/backend/.env
#
# Sourced by bin/fm-spawn.sh and the tests. No side effects on source.
# set -u / set -e safe.

# seed_exclude_path <worktree> <rel>: register <rel> in the worktree's local
# .git/info/exclude so a firstmate-placed file never shows up as untracked -
# regardless of the project's own .gitignore. That keeps a seeded secret out of
# accidental commits and keeps fm-teardown's dirty-worktree check clean. A
# non-git <worktree> is a silent no-op (plain-directory callers); a failed
# append warns to stderr and continues. Always returns 0.
seed_exclude_path() {  # <worktree> <rel>
  local wt=$1 rel=$2 excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$excl" ] || return 0
  case "$excl" in
    /*) ;;
    *) excl="$wt/$excl" ;;
  esac
  grep -qxF "$rel" "$excl" 2>/dev/null && return 0
  if ! { mkdir -p "$(dirname "$excl")" && echo "$rel" >> "$excl"; }; then
    echo "fm-seed: failed to exclude '$rel' in worktree git exclude; continuing" >&2
  fi
  return 0
}

# seed_worktree <seed_dir> <worktree>: copy every file under <seed_dir> to the
# same relative path inside <worktree>, creating intermediate directories as
# needed. Symlinked store entries are followed to their targets, so a captain may
# symlink the real local file into the store. Each seeded path is registered in
# the worktree's local git exclude (seed_exclude_path) so it never appears
# untracked even when the project's .gitignore does not cover it. A missing or
# empty <seed_dir> is a silent, clean no-op (the common case). Best-effort by
# design: a copy failure warns to stderr and continues so a seed hiccup never
# blocks dispatch. Always returns 0.
seed_worktree() {  # <seed_dir> <worktree>
  local seed_dir=$1 wt=$2 src rel dest
  seed_dir=${seed_dir%/}
  [ -d "$seed_dir" ] || return 0
  if [ ! -d "$wt" ]; then
    echo "fm-seed: worktree '$wt' is not a directory; skipping seed" >&2
    return 0
  fi
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    rel=${src#"$seed_dir"/}
    dest="$wt/$rel"
    if { mkdir -p "$(dirname "$dest")" && cp -p "$src" "$dest"; }; then
      seed_exclude_path "$wt" "$rel"
    else
      echo "fm-seed: failed to seed '$rel' into worktree; continuing" >&2
    fi
  done < <(find -L "$seed_dir" -type f)
  return 0
}
