# fm-top - the fleet cockpit

`fm-top.py` is an optional, local curses TUI: a live, navigable htop-style table of the firstmate fleet, plus a per-project **Architecture view** that browses each project's `ARCHITECTURE.md` component tree.
It is read-only over your projects; the only things it ever writes are the decisions and check-flags you explicitly send from inside it, which route back to firstmate through its inbox.

Launch it from the repo root:

```sh
python3 fm-top.py
```

`fm-top-poll.sh` is its companion: run as a background task, it blocks until fm-top writes a decision to its inbox, prints it, and exits, so a decision you make inside the TUI reaches firstmate.

Both honor `FM_HOME`, so they operate on whichever firstmate home that variable selects (the repo root when it is unset).

## Fleet view (home chart)

The default screen is a sortable table of the whole fleet, not just live crew:

- **live crewmates** (each `state/<id>.meta`), with their reconciled crew-state,
- **queued backlog work** parsed from `## Queued` in `data/backlog.md` (shown with a `·` glyph and its `blocked-by` dependency as the note),
- a **recent-done tail** from `## Done` (hidden by default; toggle with `d`), and
- **background workflows** - any `state/<id>.meta` with `kind=workflow` - rendered as rows with a distinct `⟳` glyph and **no pane** (their status comes from their status file, never a crew-state probe), so a running audit or migration workflow stays visible in the cockpit.

| Key         | Action                                             |
| ----------- | -------------------------------------------------- |
| `↑ ↓` `k j` | move the selection                                 |
| `Enter`     | open the detail view / choose a decision option    |
| `a`         | open the **Architecture view**                     |
| `c`         | flag the selected crew for firstmate to check on   |
| `1`-`5`     | sort by column; re-press the active column to toggle `▲`/`▼` |
| `r`         | reverse the sort direction                         |
| `d`         | show / hide recently-done tasks                    |
| `Esc` `q`   | back / quit                                        |

Crew-state probes run in parallel on a background thread, so the UI never blocks: startup is instant and the table fills in.

## Architecture view

A separate screen off the fleet chart, reached with `a`, that renders each project's committed `ARCHITECTURE.md` as a navigable component tree.
It reads local files only (parsed cheaply on demand and memoized), so it never touches the live fleet probing.

**Screen A - project picker.** Every directory under `projects/` is listed with its top-level component count and doc status (`✓ up to date`, `⚠ invalid doc`, or a dimmed `(no architecture doc)`).
`Enter` opens a project that has a valid doc; a project without one flashes a hint that the doc is added through a PR.

**Screen B - component browser.** The core screen. Top to bottom:

- a **breadcrumb** (`project › component › child …`),
- the node's **diagram** rendered verbatim (pre-formatted ASCII art, clipped to width; scroll with `[` / `]` when it overflows),
- the node's **description** (wrapped prose), and
- its child **components** as a navigable list.

| Key         | Action                                             |
| ----------- | -------------------------------------------------- |
| `↑ ↓` `k j` | move between child components                      |
| `Enter`     | descend into the selected component                |
| `[` `]`     | scroll the diagram pane when it overflows          |
| `Esc`       | go up one level (or back to the picker at the top) |
| `q`         | leave the Architecture view for the fleet chart    |
| `r`         | reload the doc from disk (pick up a merged edit)   |

## The `fm-arch:v1` schema

`projects/<name>/ARCHITECTURE.md` is project-intrinsic knowledge that travels with the code, exactly like `AGENTS.md`: one committed file at the project root, created lazily on the first architecturally-significant change and maintained by crewmates through the delivery pipeline.
It is **not** the same as [`docs/architecture.md`](architecture.md), which documents the firstmate orchestrator itself.

The architecture is a tree, and **heading depth encodes tree depth**.
The shared parser (`bin/fm_arch.py`) and `bin/fm-arch-lint.sh` enforce the contract so a committed doc can never rot into an unrenderable state.

````markdown
# <Project Name> Architecture
<!-- fm-arch:v1 -->

<root prose: 1-3 paragraphs describing the whole system>

```text fm-diagram
<ASCII context diagram of the whole system>
```

## <Top-level component name>

> code: <comma-separated repo-relative paths>

```text fm-diagram
<ASCII diagram for this component>
```

<prose description of this component>

### <Child component name>

<prose>  ← a node may omit the diagram; it renders "(no diagram)"
````

Rules the author and parser both obey:

1. **Line 1** is the H1 title `# <…> Architecture`; **line 2** is the exact marker `<!-- fm-arch:v1 -->`. Both are mandatory - their absence means "not an architecture doc".
2. **Every heading at level ≥ 2 is a component node.** Node depth = (number of `#`) − 1, so `##` is a top-level component (depth 1) and the H1 is the implicit root (depth 0). Do not use headings for anything that is not a component.
3. **A node's diagram** is the first fenced code block in its body whose info string's last word is `fm-diagram` (write `text fm-diagram` so editors show monospace and the parser matches the marker). A node has zero or one; zero renders a `(no diagram)` placeholder. Diagrams are preserved byte-for-byte.
4. **A node's description** is the remaining prose in its body.
5. An optional `> code: pathA, pathB` blockquote line under a heading lists the repo-relative paths that implement the component (machine-readable; used by the staleness nudge).
6. **Parent assignment is by depth** (the nearest preceding shallower node). A skipped level attaches to the nearest shallower ancestor but the lint warns.
7. **Sibling names must be unique** under one parent.

## Linting - `bin/fm-arch-lint.sh`

`bin/fm-arch-lint.sh <dir>` validates `<dir>/ARCHITECTURE.md` against the schema:

- **Tier 1 (hard):** if the doc is present, parse it and exit non-zero on any structural error - a missing or wrong H1/marker, unbalanced fences, more than one `fm-diagram` block in a node, duplicate sibling names, or a non-preservable diagram line. An absent doc is a clean pass (the doc is optional). A heading-level jump deeper than +1 warns but does not fail.
- **Tier 2 (soft, advisory):** with `--diff-base <ref>`, when the diff touches source files but `ARCHITECTURE.md` is unchanged, it prints a staleness nudge. When `> code:` paths are present it fires only for a touched mapped path. This never changes the exit code.

Both the lint and fm-top import the one parser in `bin/fm_arch.py`, so the schema and the renderer cannot drift.
