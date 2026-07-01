#!/usr/bin/env bash
# fm-arch-lint.sh - validate a project's ARCHITECTURE.md against the fm-arch:v1
# schema, using the shared parser in bin/fm_arch.py so the lint and fm-top's
# renderer cannot diverge.
#
# Tier 1 (hard, deterministic): structural lint. If <dir>/ARCHITECTURE.md is
# absent, exit 0 (the doc is optional). If present, parse it and exit non-zero on
# any structural error (missing/wrong H1 or fm-arch:v1 marker, unbalanced fences,
# a node with more than one fm-diagram block, duplicate sibling names, or a
# diagram line that is not preservable as text). A heading-level jump deeper than
# +1 warns but does not fail.
#
# Tier 2 (soft, advisory): when a git diff shows source files changed but
# ARCHITECTURE.md did not, print a staleness nudge. Never changes the exit code.
# With `> code:` paths present, the nudge fires only when a touched path falls
# under a mapped component. Enable by passing --diff-base <ref>.
#
# Usage: fm-arch-lint.sh <dir> [--diff-base <ref>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-arch-lint.sh <dir> [--diff-base <ref>]" >&2
}

dir=""
diff_base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --diff-base)
      shift
      [ $# -gt 0 ] || { usage; exit 2; }
      diff_base="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      if [ -z "$dir" ]; then
        dir="$1"
      else
        usage
        exit 2
      fi
      ;;
  esac
  shift
done

[ -n "$dir" ] || dir="."
doc="$dir/ARCHITECTURE.md"

# Tier 1: the doc is optional; an absent one is a clean pass.
if [ ! -f "$doc" ]; then
  exit 0
fi

rc=0
python3 "$SCRIPT_DIR/fm_arch.py" lint "$doc" || rc=$?

# Tier 2: advisory staleness nudge (best-effort; never changes the exit code).
if [ "$rc" -eq 0 ] && [ -n "$diff_base" ] && command -v git >/dev/null 2>&1; then
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    changed=$(git -C "$dir" diff --name-only "$diff_base" 2>/dev/null || true)
    if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -qx "ARCHITECTURE.md"; then
      # Sharpen with mapped `> code:` paths when present: warn only if a touched
      # path falls under a mapped component. With no mapped paths, warn broadly.
      mapped=$(python3 "$SCRIPT_DIR/fm_arch.py" codepaths "$doc" 2>/dev/null || true)
      nudge=1
      if [ -n "$mapped" ]; then
        nudge=0
        while IFS= read -r code_path; do
          [ -n "$code_path" ] || continue
          code_path="${code_path%/}"
          if printf '%s\n' "$changed" | awk -v p="$code_path" '$0==p || index($0, p"/")==1 {found=1} END{exit !found}'; then
            nudge=1
            break
          fi
        done <<EOF
$mapped
EOF
      fi
      if [ "$nudge" -eq 1 ]; then
        echo "advisory: ARCHITECTURE.md not updated - confirm this change alters no component structure." >&2
      fi
    fi
  fi
fi

exit "$rc"
