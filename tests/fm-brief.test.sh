#!/usr/bin/env bash
# tests/fm-brief.test.sh - behavior tests for the fm-brief.sh scaffold contract.
#
# Covers the structured --intent contract in the no-mistakes ship brief: the
# crewmate must write the run's --intent itself in the Problem/Solution/Details
# shape (never leaving it to transcript inference, whose third-person narrative
# becomes the PR's Intent section verbatim). Briefs that never start a pipeline
# run (direct-PR, local-only, scout) must not carry the contract.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-test)

# --- no-mistakes ship brief carries the structured --intent contract --------

test_ship_brief_has_intent_contract() {
  local home brief
  home="$TMP_ROOT/nm-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" intent-shape-a1 alpha >/dev/null 2>&1
  brief="$home/data/intent-shape-a1/brief.md"
  assert_present "$brief" "ship brief was not scaffolded"
  assert_grep "--intent" "$brief" \
    "no-mistakes ship brief must tell the crewmate to write --intent itself"
  assert_grep "### Problem" "$brief" "brief is missing the Problem section of the intent shape"
  assert_grep "### Solution" "$brief" "brief is missing the Solution section of the intent shape"
  assert_grep "### Details" "$brief" "brief is missing the Details section of the intent shape"
  assert_grep 'verbatim' "$brief" \
    "brief must explain the --intent text becomes the PR Intent section verbatim"
  assert_grep '"the developer"' "$brief" \
    "brief must ban third-person developer/agent narration in the intent"
  assert_grep "fm-gate-start.sh --intent-file" "$brief" \
    "no-mistakes ship brief must start the run via the gate-start helper with the intent file"
  pass "fm-brief: no-mistakes ship brief pins the structured --intent shape and gate-start helper"
}

# --- briefs that never start a pipeline run stay free of it ------------------

test_non_pipeline_briefs_skip_intent_contract() {
  local home brief
  home="$TMP_ROOT/other-home"
  mkdir -p "$home/data"
  printf -- '- alpha [direct-PR] - test project (added 2026-07-01)\n- beta [local-only] - test project (added 2026-07-01)\n' \
    > "$home/data/projects.md"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" direct-b2 alpha >/dev/null 2>&1
  brief="$home/data/direct-b2/brief.md"
  assert_present "$brief" "direct-PR brief was not scaffolded"
  assert_no_grep "### Problem" "$brief" "direct-PR brief must not carry the pipeline intent shape"
  assert_no_grep "fm-gate-start.sh" "$brief" "direct-PR brief must not reference the gate-start helper"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" local-c3 beta >/dev/null 2>&1
  brief="$home/data/local-c3/brief.md"
  assert_present "$brief" "local-only brief was not scaffolded"
  assert_no_grep "### Problem" "$brief" "local-only brief must not carry the pipeline intent shape"
  assert_no_grep "fm-gate-start.sh" "$brief" "local-only brief must not reference the gate-start helper"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout-d4 alpha --scout >/dev/null 2>&1
  brief="$home/data/scout-d4/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_no_grep "### Problem" "$brief" "scout brief must not carry the pipeline intent shape"
  assert_no_grep "fm-gate-start.sh" "$brief" "scout brief must not reference the gate-start helper"

  pass "fm-brief: direct-PR, local-only, and scout briefs skip the intent shape and gate-start helper"
}

test_ship_brief_has_intent_contract
test_non_pipeline_briefs_skip_intent_contract
