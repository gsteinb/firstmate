#!/usr/bin/env bash
# fm-top.test.sh - fleet-chart data tests for the promoted cockpit (fm-top.py).
#
# Covers gather() surfacing beyond live crew: queued backlog items become rows,
# a recent-done tail is parsed, and background workflows (state/<id>.meta with
# kind=workflow) render as rows WITHOUT a crewmate pane or a crew-state probe.
# Drives the real gather() via `fm-top.py --once-json`, so no curses is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOP="$ROOT/fm-top.py"

home=$(fm_test_tmproot fm-top)
mkdir -p "$home/state" "$home/data" "$home/bin"

# A fake crew-state probe that RECORDS every id it is called with, so the test
# can prove a workflow row is never probed.
calls="$home/crew-calls.log"
: > "$calls"
cat > "$home/bin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
echo "\$1" >> "$calls"
echo "state: working · note · crew is doing work"
SH
chmod +x "$home/bin/fm-crew-state.sh"

cat > "$home/data/backlog.md" <<'MD'
## In flight
- [ ] fix-login-k3 - fix the flaky login test (repo: yourapp, since 2026-06-30)

## Queued
- [ ] add-dark-mode-p7 - add dark mode toggle (repo: yourapp) blocked-by: fix-login-k3 - shares theme files
- [ ] audit-deps-z2 - audit dependency licenses (repo: loanova)

## Done
- [x] old-task-a1 - earlier fix - https://github.com/you/yourapp/pull/9 (merged 2026-06-29)
MD

printf 'window=firstmate:fm-fix-login-k3\nkind=ship\nproject=/p/yourapp\n' > "$home/state/fix-login-k3.meta"
printf 'kind=workflow\nproject=/p/loanova\n' > "$home/state/clickup-audit-w1.meta"
printf 'working: scanning 42 clickup tickets\n' > "$home/state/clickup-audit-w1.status"
# a terminal workflow: its status verb should pass through to the row
printf 'kind=workflow\nproject=/p/yourapp\n' > "$home/state/migrate-w2.meta"
printf 'done: migrated 300 rows\n' > "$home/state/migrate-w2.status"

out=$(FM_HOME="$home" python3 "$TOP" --once-json)

# Assert the row set through the real gather() output.
FM_TOP_JSON="$out" python3 - <<'PY'
import json, os, sys

rows = json.loads(os.environ["FM_TOP_JSON"])
by = {r["name"]: r for r in rows}
failed = []

def check(cond, msg):
    if not cond:
        failed.append(msg)

# queued backlog items become rows (status queued), with repo + blocked-by note.
check("add-dark-mode-p7" in by, "queued item add-dark-mode-p7 missing")
check("audit-deps-z2" in by, "queued item audit-deps-z2 missing")
if "add-dark-mode-p7" in by:
    q = by["add-dark-mode-p7"]
    check(q["status"] == "queued", "queued row status wrong: %r" % q["status"])
    check(q["kind"] == "queued", "queued row kind wrong: %r" % q["kind"])
    check(q["project"] == "yourapp", "queued row project wrong: %r" % q["project"])
    check("blocked-by fix-login-k3" in q["note"], "queued blocked-by note wrong: %r" % q["note"])

# a background workflow becomes a row with the distinct 'workflow' status.
check("clickup-audit-w1" in by, "workflow row missing")
if "clickup-audit-w1" in by:
    w = by["clickup-audit-w1"]
    check(w["kind"] == "workflow", "workflow kind wrong: %r" % w["kind"])
    check(w["status"] == "workflow", "workflow status wrong: %r" % w["status"])
    check("scanning 42" in w["note"], "workflow note not from status file: %r" % w["note"])

# a terminal workflow passes its status verb through.
check("migrate-w2" in by, "terminal workflow row missing")
if "migrate-w2" in by:
    check(by["migrate-w2"]["status"] == "done", "terminal workflow status wrong: %r" % by["migrate-w2"]["status"])

# the recent-done tail is parsed.
check("old-task-a1" in by, "recent-done row missing")
if "old-task-a1" in by:
    check(by["old-task-a1"]["kind"] == "done", "recent-done kind wrong")

# live crew is still probed and classified.
check("fix-login-k3" in by, "live crew row missing")
if "fix-login-k3" in by:
    check(by["fix-login-k3"]["status"] == "working", "crew row status wrong: %r" % by["fix-login-k3"]["status"])

if failed:
    for m in failed:
        sys.stderr.write("assert failed: %s\n" % m)
    sys.exit(1)
PY
pass "gather(): queued rows, workflow rows, recent-done tail, and live crew all surface"

# A workflow row must never trigger a crew-state probe (no pane).
assert_grep "fix-login-k3" "$calls" "live crew should be probed"
assert_no_grep "clickup-audit-w1" "$calls" "a workflow must not be crew-state probed"
assert_no_grep "migrate-w2" "$calls" "a terminal workflow must not be crew-state probed"
pass "gather(): background workflows are never crew-state probed"

pass "fm-top.test.sh: all checks passed"
