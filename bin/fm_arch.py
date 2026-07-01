#!/usr/bin/env python3
"""fm_arch.py - the single fm-arch:v1 ARCHITECTURE.md parser and structural lint.

One parser, imported by BOTH consumers so the schema and the renderer cannot
drift:
  - fm-top.py's Architecture view (parse -> navigable component tree), and
  - bin/fm-arch-lint.sh (Tier-1 structural gate check).

`fm-arch:v1` schema (see docs/fm-top.md for the authoring contract):
  - Line 1 is the H1 title `# <Project> Architecture`.
  - Line 2 is the exact marker `<!-- fm-arch:v1 -->`.
  - Every heading at level >= 2 is a component node; depth = (# count) - 1, so
    the H1 is the implicit root (depth 0), `##` a top-level component (depth 1).
  - A node's diagram is the FIRST fenced code block in its body whose info
    string's last word is `fm-diagram`; a node has zero or one.
  - A node's description is the remaining prose in its body.
  - An optional `> code: pathA, pathB` blockquote lists implementing paths.
  - Parent assignment is by depth (nearest preceding shallower node).
  - Sibling names must be unique under one parent.
  - Diagrams are pre-formatted art, preserved byte-for-byte.

CLI:
  fm_arch.py lint <path>   structural lint; prints findings, exit 1 on any error
  fm_arch.py tree <path>   print `depth<TAB>name<TAB>diagram=<n>` per node
  fm_arch.py codepaths <path>   print every `> code:` path, one per line
"""
import os
import re
import sys

V1_MARKER = "<!-- fm-arch:v1 -->"
DIAGRAM_MARKER = "fm-diagram"

_HEADING_RE = re.compile(r"^(#{2,})\s+(.*)$")
_FENCE_RE = re.compile(r"^```")
# C0 control characters that curses cannot render (tab is allowed in art).
_UNPRINTABLE_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


class ArchError(Exception):
    """Raised on a fatal structural problem that makes the tree meaningless
    (missing H1/marker, unbalanced fence, unreadable file)."""


class Node:
    """One component in the architecture tree. The H1 is the root (depth 0)."""

    __slots__ = ("name", "depth", "diagram", "desc", "code", "children")

    def __init__(self, name, depth):
        self.name = name
        self.depth = depth
        self.diagram = []      # list[str]: verbatim diagram lines (no fences)
        self.desc = []         # list[str]: prose lines
        self.code = []         # list[str]: repo-relative paths from `> code:`
        self.children = []     # list[Node]

    def description(self):
        """Prose joined into a single string (blank lines preserved as spaces)."""
        return "\n".join(self.desc).strip()


def _build(lines):
    """Core single-pass parse.

    Returns (root, findings) where findings is a list of (level, message) with
    level in {"error", "warn"}. Raises ArchError only on the fatal problems that
    make the tree meaningless, so the linter can still report them as errors.
    """
    if len(lines) < 2:
        raise ArchError("file is too short: need an H1 title and the fm-arch:v1 marker")
    if not (lines[0].startswith("# ") and lines[0].rstrip().endswith("Architecture")):
        raise ArchError("line 1 must be an H1 title ending in 'Architecture'")
    if lines[1].strip() != V1_MARKER:
        raise ArchError("line 2 must be the exact marker '%s'" % V1_MARKER)

    name = lines[0][2:].strip()
    if name.endswith("Architecture"):
        name = name[:-len("Architecture")].strip()
    root = Node(name or "<project>", 0)

    findings = []
    stack = [root]
    cur = root
    diagram_count = {id(root): 0}
    in_fence = False
    fence_is_diagram = False
    buf = []

    for ln in lines[2:]:
        if not in_fence:
            m = _HEADING_RE.match(ln)
            if m:
                depth = len(m.group(1)) - 1
                nm = m.group(2).strip()
                node = Node(nm, depth)
                while stack[-1].depth >= depth:
                    stack.pop()
                parent = stack[-1]
                if depth - parent.depth > 1:
                    findings.append(("warn",
                        "heading level jumps to depth %d under '%s' (depth %d) at "
                        "'%s'; attached to the nearest shallower ancestor"
                        % (depth, parent.name, parent.depth, nm)))
                if any(c.name == nm for c in parent.children):
                    findings.append(("error",
                        "duplicate sibling component name '%s' under '%s'"
                        % (nm, parent.name)))
                parent.children.append(node)
                stack.append(node)
                cur = node
                diagram_count[id(node)] = 0
                continue

        if _FENCE_RE.match(ln) and not in_fence:
            in_fence = True
            info = ln[3:].strip()
            is_diagram = bool(info) and info.split()[-1] == DIAGRAM_MARKER
            if is_diagram:
                diagram_count[id(cur)] += 1
                fence_is_diagram = diagram_count[id(cur)] == 1   # keep the first only
                if diagram_count[id(cur)] > 1:
                    findings.append(("error",
                        "component '%s' has more than one %s block"
                        % (cur.name, DIAGRAM_MARKER)))
            else:
                fence_is_diagram = False
            buf = []
            continue

        if in_fence and _FENCE_RE.match(ln):
            if fence_is_diagram:
                cur.diagram = buf
            in_fence = False
            fence_is_diagram = False
            continue

        if in_fence:
            buf.append(ln)
            continue

        stripped = ln.strip()
        if stripped.startswith("> code:"):
            cur.code = [p.strip() for p in stripped.split("code:", 1)[1].split(",") if p.strip()]
            continue
        if stripped:
            cur.desc.append(ln)

    if in_fence:
        raise ArchError("unbalanced code fence: a ``` block was opened but never closed")
    return root, findings


def walk(node):
    """Yield every node in the tree, root first, depth-first."""
    yield node
    for child in node.children:
        yield from walk(child)


# --- rendering entry point (memoized by (path, mtime)) ----------------------

_CACHE = {}


def parse_architecture(path):
    """Parse an ARCHITECTURE.md into its root Node, memoized by (path, mtime).

    Cheap (single local-file read + one pass) - safe to call on fm-top's UI
    thread. Raises ArchError on a fatal structural problem.
    """
    try:
        mtime = os.path.getmtime(path)
    except OSError as exc:
        raise ArchError("cannot read %s: %s" % (path, exc))
    cached = _CACHE.get(path)
    if cached and cached[0] == mtime:
        return cached[1]
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise ArchError("cannot read %s: %s" % (path, exc))
    root, _ = _build(text.splitlines())
    _CACHE[path] = (mtime, root)
    return root


def invalidate(path):
    """Drop the memoized tree for a path so the next parse re-reads from disk."""
    _CACHE.pop(path, None)


# --- structural lint (Tier 1) -----------------------------------------------

def lint_text(text):
    """Return a list of (level, message) for a doc's text. level in
    {"error", "warn"}. A caller treats any "error" as a hard failure."""
    findings = []
    try:
        root, structural = _build(text.splitlines())
    except ArchError as exc:
        return [("error", str(exc))]
    findings.extend(structural)
    for node in walk(root):
        for i, line in enumerate(node.diagram, 1):
            if _UNPRINTABLE_RE.search(line):
                findings.append(("error",
                    "component '%s' diagram line %d contains a non-printable "
                    "control character (not preservable as text)" % (node.name, i)))
    return findings


def lint(path):
    """Lint a single ARCHITECTURE.md file. An absent file returns no findings
    (the doc is optional). Returns a list of (level, message)."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return []
    except OSError as exc:
        return [("error", "cannot read %s: %s" % (path, exc))]
    return lint_text(text)


def code_paths(path):
    """Every `> code:` path across the tree, for the Tier-2 staleness check."""
    try:
        root = parse_architecture(path)
    except ArchError:
        return []
    paths = []
    for node in walk(root):
        paths.extend(node.code)
    return paths


# --- CLI --------------------------------------------------------------------

def _cmd_lint(path):
    findings = lint(path)
    errors = 0
    for level, msg in findings:
        if level == "error":
            errors += 1
        sys.stderr.write("%s: %s\n" % (level, msg))
    if not findings:
        sys.stdout.write("ok: %s is valid fm-arch:v1\n" % path)
    return 1 if errors else 0


def _cmd_tree(path):
    try:
        root = parse_architecture(path)
    except ArchError as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 1
    for node in walk(root):
        sys.stdout.write("%d\t%s\tdiagram=%d\n" % (node.depth, node.name, len(node.diagram)))
    return 0


def _cmd_codepaths(path):
    for p in code_paths(path):
        sys.stdout.write("%s\n" % p)
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("lint", "tree", "codepaths"):
        sys.stderr.write(
            "usage: fm_arch.py {lint|tree|codepaths} <path>\n")
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "lint":
        return _cmd_lint(path)
    if cmd == "tree":
        return _cmd_tree(path)
    return _cmd_codepaths(path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
