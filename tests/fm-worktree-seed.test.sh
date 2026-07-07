#!/usr/bin/env bash
# Behavior tests for per-project worktree seeding.
#
# A fresh git worktree never carries the project's untracked/gitignored local
# files (env, secrets, local config), yet a crewmate may need them to build, run,
# or test the app. seed_worktree copies a per-project seed store into the worktree
# at the matching relative paths. These cases pin: nested paths land correctly, an
# absent store is a clean no-op, intermediate dirs are created in a fresh worktree,
# symlinked store entries are followed to their targets, every seeded path is
# registered in the worktree's local git exclude (idempotently, and as a silent
# no-op for a non-git directory), a seed path the project already tracks is
# skipped with a warning and left unmodified, and fm-spawn wires the seed in for
# a ship spawn (and never for a secondmate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-seed-lib.sh
. "$ROOT/bin/fm-seed-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-seed)
fm_git_identity fmtest fmtest@example.invalid

# --- helper: nested + top-level files land at the right relative paths ------

test_seed_lands_nested_and_toplevel() {
  local seed wt
  seed="$TMP_ROOT/seed-nested/loanova"
  wt="$TMP_ROOT/wt-nested"
  mkdir -p "$seed/backend" "$wt"
  printf 'TOP=1\n' > "$seed/.env.local"
  printf 'DB=secret\n' > "$seed/backend/.env"

  seed_worktree "$seed" "$wt"

  assert_present "$wt/.env.local" "top-level seed file did not land"
  assert_present "$wt/backend/.env" "nested seed file did not land"
  assert_grep "TOP=1" "$wt/.env.local" "top-level seed content mismatch"
  assert_grep "DB=secret" "$wt/backend/.env" "nested seed content mismatch"
  pass "seed_worktree: top-level and nested files land at the correct relative paths"
}

# --- helper: absent (and empty) store is a clean no-op ----------------------

test_seed_absent_is_noop() {
  local wt out status
  wt="$TMP_ROOT/wt-absent"
  mkdir -p "$wt"

  out=$(seed_worktree "$TMP_ROOT/does-not-exist/loanova" "$wt" 2>&1); status=$?
  expect_code 0 "$status" "absent seed dir should be a clean no-op"
  [ -z "$out" ] || fail "absent seed dir produced output: $out"
  [ -z "$(ls -A "$wt")" ] || fail "absent seed dir wrongly wrote into the worktree"

  # An existing but empty store is likewise a silent no-op.
  mkdir -p "$TMP_ROOT/seed-empty/loanova"
  out=$(seed_worktree "$TMP_ROOT/seed-empty/loanova" "$wt" 2>&1); status=$?
  expect_code 0 "$status" "empty seed dir should be a clean no-op"
  [ -z "$out" ] || fail "empty seed dir produced output: $out"
  [ -z "$(ls -A "$wt")" ] || fail "empty seed dir wrongly wrote into the worktree"
  pass "seed_worktree: an absent or empty store is a silent, clean no-op"
}

# --- helper: a copy into a fresh worktree creates intermediate dirs ---------

test_seed_creates_intermediate_dirs() {
  local seed wt
  seed="$TMP_ROOT/seed-deep/loanova"
  wt="$TMP_ROOT/wt-deep"
  mkdir -p "$seed/a/b/c" "$wt"
  printf 'deep\n' > "$seed/a/b/c/secret.env"

  seed_worktree "$seed" "$wt"

  assert_present "$wt/a/b/c" "intermediate directories were not created"
  assert_present "$wt/a/b/c/secret.env" "deeply nested seed file did not land"
  assert_grep "deep" "$wt/a/b/c/secret.env" "deeply nested seed content mismatch"
  pass "seed_worktree: copying into a fresh worktree creates intermediate directories"
}

# --- helper: symlinked store entries are followed to their targets ----------

test_seed_follows_symlinked_sources() {
  local seed wt
  seed="$TMP_ROOT/seed-symlink/loanova"
  wt="$TMP_ROOT/wt-symlink"
  mkdir -p "$seed" "$wt" "$TMP_ROOT/real-files"
  printf 'REAL=1\n' > "$TMP_ROOT/real-files/.env.local"
  ln -s "$TMP_ROOT/real-files/.env.local" "$seed/.env.local"

  seed_worktree "$seed" "$wt"

  assert_present "$wt/.env.local" "symlinked seed source did not land"
  [ ! -L "$wt/.env.local" ] || fail "seeded file is a symlink instead of a regular copy"
  assert_grep "REAL=1" "$wt/.env.local" "symlinked seed content mismatch"
  pass "seed_worktree: a symlinked store entry is followed and its target content lands"
}

# --- helper: seeded paths are registered in the worktree's git exclude ------

test_seed_registers_git_exclude() {
  local seed wt excl
  seed="$TMP_ROOT/seed-exclude/loanova"
  wt="$TMP_ROOT/wt-exclude"
  mkdir -p "$seed/backend"
  printf 'TOP=1\n' > "$seed/.env.local"
  printf 'DB=secret\n' > "$seed/backend/.env"
  git init -q -b main "$wt"

  seed_worktree "$seed" "$wt"

  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  case "$excl" in /*) ;; *) excl="$wt/$excl" ;; esac
  assert_present "$excl" "seeding did not create the worktree git exclude file"
  grep -qxF '/.env.local' "$excl" || fail "top-level seeded path not registered in git exclude"
  grep -qxF '/backend/.env' "$excl" || fail "nested seeded path not registered in git exclude"
  [ -z "$(git -C "$wt" status --porcelain)" ] || \
    fail "seeded files still show up in git status: $(git -C "$wt" status --porcelain)"

  # Re-seeding is idempotent: no duplicate exclude entries.
  seed_worktree "$seed" "$wt"
  [ "$(grep -cxF '/.env.local' "$excl")" = 1 ] || \
    fail "re-seeding duplicated the git exclude entry for .env.local"
  pass "seed_worktree: seeded paths are excluded from git status, idempotently"
}

# --- helper: a seed path the project already tracks is skipped --------------

test_seed_skips_tracked_path() {
  local seed wt excl out
  seed="$TMP_ROOT/seed-tracked/loanova"
  wt="$TMP_ROOT/wt-tracked"
  mkdir -p "$seed"
  printf 'SEED=secret\n' > "$seed/config.yml"
  git init -q -b main "$wt"
  git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  printf 'TRACKED=original\n' > "$wt/config.yml"
  git -C "$wt" add config.yml
  git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m "track config.yml"

  out=$(seed_worktree "$seed" "$wt" 2>&1)

  assert_grep "TRACKED=original" "$wt/config.yml" "tracked file content was overwritten by the seed"
  assert_no_grep "SEED=secret" "$wt/config.yml" "seed content leaked into the tracked file"
  assert_contains "$out" "config.yml" "tracked-path skip did not warn"
  assert_contains "$out" "tracked" "tracked-path skip warning did not mention it is tracked"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  case "$excl" in /*) ;; *) excl="$wt/$excl" ;; esac
  assert_no_grep '/config.yml' "$excl" "tracked path was wrongly registered in git exclude"
  [ -z "$(git -C "$wt" status --porcelain)" ] || \
    fail "seeding over a tracked path dirtied the worktree: $(git -C "$wt" status --porcelain)"
  pass "seed_worktree: a project-tracked seed path is skipped with a warning and left unmodified"
}

# --- fm-spawn wiring: a ship spawn seeds; a secondmate spawn does not -------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd,
# names the session on '#S', and swallows window ops (mirrors the tangle-guard
# suite's spawn fakebin). Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_seeds_ship_worktree() {
  local home proj fakebin wt name out status excl
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  # A real project repo + a genuine isolated worktree the fake pane resolves to.
  proj="$TMP_ROOT/spawn-proj"
  git init -q -b main "$proj"
  git -C "$proj" commit -q --allow-empty -m init
  wt="$TMP_ROOT/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")

  # Seed store keyed by the project's basename, with a nested file.
  name=$(basename "$proj")
  mkdir -p "$home/config/worktree-seed/$name/backend"
  printf 'TOP=1\n' > "$home/config/worktree-seed/$name/.env.local"
  printf 'DB=secret\n' > "$home/config/worktree-seed/$name/backend/.env"

  out=$(run_spawn "$home" seed-ship-gg7 "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "ship spawn into an isolated worktree should succeed"
  assert_contains "$out" "spawned seed-ship-gg7" "ship spawn did not report success"
  assert_present "$wt/.env.local" "ship spawn did not seed the top-level local file"
  assert_present "$wt/backend/.env" "ship spawn did not seed the nested local file"
  assert_grep "DB=secret" "$wt/backend/.env" "seeded nested file content mismatch"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  case "$excl" in /*) ;; *) excl="$wt/$excl" ;; esac
  grep -qxF '/.env.local' "$excl" || fail "spawn did not register the seeded top-level path in git exclude"
  grep -qxF '/backend/.env' "$excl" || fail "spawn did not register the seeded nested path in git exclude"
  pass "fm-spawn: a ship spawn seeds config/worktree-seed/<project>/ into the worktree"
}

test_spawn_without_store_is_unchanged() {
  local home proj fakebin wt out status
  home="$TMP_ROOT/spawn-home-nostore"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/spawn-proj-nostore"
  git init -q -b main "$proj"
  git -C "$proj" commit -q --allow-empty -m init
  wt="$TMP_ROOT/spawn-wt-nostore"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake-nostore")

  out=$(run_spawn "$home" seed-none-hh8 "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "ship spawn without a seed store should still succeed"
  assert_contains "$out" "spawned seed-none-hh8" "spawn without a store did not report success"
  assert_absent "$wt/.env.local" "spawn without a store wrongly created a seed file"
  pass "fm-spawn: no seed store present leaves the worktree exactly as before"
}

test_seed_lands_nested_and_toplevel
test_seed_absent_is_noop
test_seed_creates_intermediate_dirs
test_seed_follows_symlinked_sources
test_seed_registers_git_exclude
test_seed_skips_tracked_path
test_spawn_seeds_ship_worktree
test_spawn_without_store_is_unchanged
