# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.
The optional `fm-top` cockpit lives at the repo root (`fm-top.py`, `fm-top-poll.sh`); see [fm-top.md](fm-top.md) for its keys, the Architecture view, and the `fm-arch:v1` schema.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain and version problems, optional capability facts, primary-checkout `TANGLE:` problems, and actionable clone refresh outcomes; refresh project clones best-effort; locally sync live secondmate homes; install tools only after consent |
| `fm-fleet-sync.sh`       | Fetch clones, fast-forward safe default-branch states, self-heal clean detached ancestor drift, report unsafe drift as `STUCK:`, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                 |
| `fm-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion (no-mistakes briefs also pin the structured Problem/Solution/Details `--intent` contract), a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate` |
| `fm-gate-start.sh`       | Crewmate-run reliable no-mistakes gate-run starter: clear the stale gate ref, push `HEAD` with the base64 `--intent` push option under `env -u PWD` (immune to the `axi run` `PWD=.` hook poisoning), then confirm the run exists before `no-mistakes axi run` reattaches |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing watcher needs a prominent banner |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`; ship/scout spawns require an isolated treehouse worktree, install per-harness turn-end signaling, and secondmate spawns locally sync the home before launch |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-marker-lib.sh`       | Shared from-firstmate request marker and detector sourced by `fm-send.sh`, `fm-brief.sh`, and tests                 |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe always-on watcher; absorbs no-verb signal and stale wakes only when the crew is provably working, queues and exits for actionable wakes, and reverts to daemon-owned one-shot behavior while `state/.afk` exists |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, uses the shared wake classifier, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-crew-state.sh`       | Print one stable current-state line for a crew by reconciling its matching no-mistakes run-step, even when the pane has closed, with pane and status-log fallback |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls and no-fetch local secondmate syncs         |
| `fm-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and teardown                                            |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work, then run the watcher-liveness guard         |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `fm-classify-lib.sh`     | Shared captain-relevant wake classifier sourced by the watcher and daemon, plus the watcher's provably-working predicate |
| `fm-send.sh`             | Send one verified literal line (or `--key Escape`) to a direct-report window; exits non-zero on confirmed swallowed Enter; bare `kind=secondmate` targets are marked as from-firstmate; slash commands and codex `$...` skill invocations get popup-settle before Enter; text sends pause `FM_SEND_SETTLE` seconds after success |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record `pr=` and a verified `pr_head=` when available for a PR-ready task, then arm the watcher's merge poll        |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return a clean, landed ship worktree or retire/release a secondmate home; requires scout reports, checks child work, removes firstmate-owned hook artifacts, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate harness                                                  |
| `fm-lock.sh`             | Per-home firstmate session lock                                                                                     |
| `fm-arch-lint.sh`        | Validate a project's `ARCHITECTURE.md` against `fm-arch:v1` (Tier-1 structural lint, absent doc passes; optional Tier-2 advisory staleness nudge) using the shared `fm_arch.py` parser |
| `fm_arch.py`             | The single `fm-arch:v1` `ARCHITECTURE.md` parser and structural lint, imported by both `fm-arch-lint.sh` and `fm-top.py` so the schema and renderer cannot drift |
| `fm-top.py`              | Optional local curses cockpit (repo root): a live fleet table plus a per-project Architecture view over each `ARCHITECTURE.md`; read-only bar the decisions/checks you send |
| `fm-top-poll.sh`         | Companion background poll (repo root): block until `fm-top` writes a decision to its inbox, print it, and exit so the decision routes back to firstmate |
