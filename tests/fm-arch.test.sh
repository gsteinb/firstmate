#!/usr/bin/env bash
# fm-arch.test.sh - unit tests for the shared fm-arch:v1 parser (bin/fm_arch.py)
# and the structural lint (bin/fm-arch-lint.sh).
#
# Covers: heading-depth = tree-depth, diagram extraction (byte-for-byte, first
# block only), the mandatory v1 marker, a malformed (unbalanced-fence) doc,
# duplicate sibling detection, and lint pass/fail on the tracked fixtures.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX="$ROOT/tests/fixtures/arch"
VALID="$FIX/valid/ARCHITECTURE.md"

# --- parser unit tests (drive the real module via a Python assertions block) --

python3 - "$ROOT" "$VALID" <<'PY'
import os
import sys

root, valid = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "bin"))
import fm_arch

failed = []

def check(cond, msg):
    if not cond:
        failed.append(msg)

tree = fm_arch.parse_architecture(valid)

# heading depth = tree depth: root is depth 0, its children depth 1, etc.
check(tree.depth == 0, "root depth should be 0")
check(tree.name == "Loanova", "root name should be 'Loanova', got %r" % tree.name)
names = [c.name for c in tree.children]
check(names == ["Backend API", "Frontends", "Data & Infrastructure"],
      "top-level components wrong: %r" % names)
for child in tree.children:
    check(child.depth == 1, "top-level '%s' should be depth 1" % child.name)

backend = tree.children[0]
backend_kids = [c.name for c in backend.children]
check(backend_kids == ["Auth", "Underwriting", "Marketplace"],
      "Backend API children wrong: %r" % backend_kids)
for gc in backend.children:
    check(gc.depth == 2, "grandchild '%s' should be depth 2" % gc.name)

# diagram extraction: byte-for-byte, correct line count, first block only.
check(len(tree.diagram) == 6, "root diagram should be 6 lines, got %d" % len(tree.diagram))
check(tree.diagram[0].startswith("        borrower SPA"),
      "root diagram line 1 not preserved: %r" % tree.diagram[0])
check("Chi HTTP API" in tree.diagram[1],
      "root diagram should preserve the Chi HTTP API art verbatim")

# a container node with no diagram parses cleanly with an empty diagram.
data_infra = tree.children[2]
check(data_infra.diagram == [], "container node should have an empty diagram")
check(data_infra.children == [], "container node should have no children")

# `> code:` paths are captured on the node.
check(backend.code == ["backend/main.go", "backend/internal/", "backend/cmd/"],
      "Backend API code paths wrong: %r" % backend.code)

# the mandatory v1 marker: a doc missing line-2 marker raises ArchError.
try:
    fm_arch._build(["# Acme Architecture", "", "prose"])
    failed.append("missing v1 marker should raise ArchError")
except fm_arch.ArchError:
    pass

# a valid two-line minimal doc parses.
root_min, findings_min = fm_arch._build(["# Acme Architecture", fm_arch.V1_MARKER])
check(root_min.name == "Acme", "minimal doc root name wrong: %r" % root_min.name)
check(findings_min == [], "minimal doc should have no findings")

# malformed: an unbalanced fence raises ArchError.
try:
    fm_arch._build(["# Acme Architecture", fm_arch.V1_MARKER, "", "```text fm-diagram", " art"])
    failed.append("unbalanced fence should raise ArchError")
except fm_arch.ArchError:
    pass

# malformed: a node with two fm-diagram blocks is a lint error.
two_diagrams = "\n".join([
    "# Acme Architecture", fm_arch.V1_MARKER, "",
    "## CLI", "",
    "```text fm-diagram", " a", "```", "",
    "```text fm-diagram", " b", "```", "",
])
errs = [m for lvl, m in fm_arch.lint_text(two_diagrams) if lvl == "error"]
check(any("more than one" in m for m in errs),
      "two diagrams should produce a 'more than one' error: %r" % errs)

# heading-level jump (## then ####) warns but does not hard-error.
jump = "\n".join([
    "# Acme Architecture", fm_arch.V1_MARKER, "",
    "## A", "", "#### B", "",
])
report = fm_arch.lint_text(jump)
check(any(lvl == "warn" for lvl, _ in report), "level jump should warn: %r" % report)
check(all(lvl != "error" for lvl, _ in report), "level jump should not error: %r" % report)

if failed:
    for m in failed:
        sys.stderr.write("assert failed: %s\n" % m)
    sys.exit(1)
PY
pass "parser: heading-depth=tree-depth, diagram extraction, v1 marker, malformed doc"

# --- lint script integration tests ------------------------------------------

# Tier 1 passes on the valid fixture.
if "$ROOT/bin/fm-arch-lint.sh" "$FIX/valid" >/dev/null 2>&1; then
  pass "fm-arch-lint.sh: passes on the valid fixture"
else
  fail "fm-arch-lint.sh should pass on the valid fixture"
fi

# Tier 1 fails on each broken fixture.
for broken in broken-marker broken-dup broken-fence; do
  rc=0
  "$ROOT/bin/fm-arch-lint.sh" "$FIX/$broken" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-arch-lint.sh should fail on $broken"
done
pass "fm-arch-lint.sh: fails on broken-marker, broken-dup, broken-fence"

# An absent doc is a clean pass (the doc is optional).
tmp=$(fm_test_tmproot fm-arch)
mkdir -p "$tmp"
rc=0
"$ROOT/bin/fm-arch-lint.sh" "$tmp" >/dev/null 2>&1 || rc=$?
expect_code 0 "$rc" "fm-arch-lint.sh on a dir with no ARCHITECTURE.md"
pass "fm-arch-lint.sh: absent doc exits 0"

# Tier 2 staleness nudge: a source change without an ARCHITECTURE.md edit warns,
# and never changes the exit code.
git -C "$tmp" init -q
cp "$VALID" "$tmp/ARCHITECTURE.md"
mkdir -p "$tmp/backend"
printf 'package main\n' > "$tmp/backend/main.go"
git -C "$tmp" -c user.name=t -c user.email=t@e.invalid add -A
git -C "$tmp" -c user.name=t -c user.email=t@e.invalid commit -qm base
printf 'package main // changed\n' > "$tmp/backend/main.go"
git -C "$tmp" -c user.name=t -c user.email=t@e.invalid add -A
git -C "$tmp" -c user.name=t -c user.email=t@e.invalid commit -qm change
out=$("$ROOT/bin/fm-arch-lint.sh" "$tmp" --diff-base HEAD~1 2>&1)
rc=$?
expect_code 0 "$rc" "Tier 2 advisory must not change the exit code"
assert_contains "$out" "ARCHITECTURE.md not updated" "Tier 2 should nudge on a mapped source change"
pass "fm-arch-lint.sh: Tier 2 advisory nudges without failing"

# fm-top imports the shared parser cleanly (smoke check; no curses needed).
FM_HOME="$ROOT" python3 -c "
import os, sys
sys.path.insert(0, os.path.join('$ROOT', 'bin'))
import importlib.util
spec = importlib.util.spec_from_file_location('fmtop', os.path.join('$ROOT', 'fm-top.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.fm_arch is not None, 'fm-top should import the shared fm_arch parser'
assert hasattr(mod, '_arch_projects'), 'fm-top should define _arch_projects'
assert hasattr(mod, '_arch_node'), 'fm-top should define _arch_node'
" || fail "fm-top.py should import fm_arch and define the arch helpers"
pass "fm-top.py: imports the shared parser and defines the Architecture helpers"

pass "fm-arch.test.sh: all checks passed"
