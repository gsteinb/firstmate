#!/usr/bin/env python3
"""fm-top - a live, navigable htop-style table of the firstmate fleet.

Sortable table of work + decisions. Navigate, Enter for detail, decide from the
UI (routes back to firstmate), and flag a crew for a check. The chart shows live
crewmates plus queued backlog work and background workflows (state/<id>.meta with
kind=workflow, rendered as rows with no pane). Press 'a' for a per-project
Architecture view over each project's ARCHITECTURE.md.

Keys:
  ↑/↓ k/j   move           Enter   detail / choose option
  a         architecture   1-5     sort column (re-press toggles ▲/▼)   r   reverse
  c         flag crew for firstmate to check (maybe stuck)
  d         show/hide recent-done tail   Esc / q   back / quit

Speed: crew-state probes run in PARALLEL on a background thread, so the UI never
blocks (startup is instant; data fills in). Read-only except decisions/checks
you explicitly send.
"""
import os
import re
import sys
import glob
import time
import json
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor

_PR_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")

HOME = os.environ.get("FM_HOME") or os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HOME, "state")
DATA = os.path.join(HOME, "data")
PROJECTS = os.path.join(HOME, "projects")
INBOX = os.path.join(STATE, ".fmtop-inbox")
REFRESH = float(os.environ.get("FM_TOP_REFRESH", "3"))

# The Architecture view shares the exact fm-arch:v1 parser the lint uses, so the
# schema and this renderer cannot drift. The module lives in bin/ next to this
# script (script-relative, not FM_HOME-relative, since it is tracked code).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin"))
try:
    import fm_arch
except Exception:   # degrade gracefully: the fleet cockpit still works without it
    fm_arch = None

STATUS_META = {
    "needs-decision": ("yellow", "⚑"),   # YOUR call (has options)
    "with-firstmate": ("mag",    "⚙"),    # parked on firstmate to process/surface - NOT on you
    "working":        ("cyan",   "●"),
    "workflow":       ("mag",    "⟳"),    # background workflow (no crewmate pane)
    "validating":     ("cyan",   "◐"),
    "PR-ready":       ("green",  "▲"),
    "done":           ("green",  "✓"),
    "at-gate":        ("yellow", "◪"),   # a run parked at a gate - needs action
    "waiting":        ("grey",   "◌"),   # done, waiting for its lane / merge
    "queued":         ("grey",   "·"),
    "blocked":        ("red",    "■"),
    "failed":         ("red",    "✗"),
}
SORT_RANK = {"needs-decision": 0, "blocked": 1, "failed": 2, "at-gate": 3,
             "with-firstmate": 4, "PR-ready": 5, "working": 6, "workflow": 7,
             "validating": 8, "waiting": 9, "queued": 10, "done": 11}


def _next_sort(cur_col, cur_rev, key_col):
    """Return the (column, reversed) sort state after a sort-column key press.

    Re-pressing the column that is already active toggles its direction
    (ascending <-> descending), like clicking a header twice; pressing a
    different column switches to it in the default (ascending) direction.
    """
    if key_col == cur_col:
        return cur_col, not cur_rev
    return key_col, False


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def _meta(path):
    d = {}
    for line in _read(path).splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            d[k.strip()] = v.strip()
    return d


def _crew_state(tid):
    try:
        out = subprocess.run([os.path.join(HOME, "bin", "fm-crew-state.sh"), tid],
                             capture_output=True, text=True, timeout=6).stdout.strip()
    except Exception:
        return ("?", "")
    if out.startswith("state:"):
        p = out.split("·")
        st = p[0].replace("state:", "").strip()
        note = "·".join(p[2:]).strip() if len(p) >= 3 else (p[1].strip() if len(p) == 2 else "")
        return (st, note)
    return ("?", out)


def _backlog_desc():
    out = {}
    for line in _read(os.path.join(DATA, "backlog.md")).splitlines():
        s = line.strip()
        if s.startswith("- [") and "] " in s:
            body = s.split("] ", 1)[1]
            if " - " in body:
                tid, desc = body.split(" - ", 1)
                tid = tid.strip().strip("*")
                desc = desc.split("(repo")[0].split(" blocked-by")[0].strip()
                out[tid] = desc
    return out


def _age_secs(tid):
    newest = 0.0
    for suf in (".status", ".turn-ended", ".meta"):
        p = os.path.join(STATE, tid + suf)
        try:
            m = os.path.getmtime(p)
            if m > newest:
                newest = m
        except OSError:
            pass
    return (time.time() - newest) if newest else None


def _fmt_age(s):
    if s is None:
        return "-"
    s = int(s)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s//60}m"
    if s < 86400:
        return f"{s//3600}h"
    return f"{s//86400}d"


def _classify(state, note):
    n = (note or "").lower()
    if "ask-user" in n or "needs-decision" in n or state == "needs-decision":
        # parked at a gate but NOT (yet) surfaced as a decision row -> it's on
        # firstmate to process/surface. Once surfaced, gather() overrides to needs-decision.
        return "with-firstmate"
    if any(p in n for p in ("pr ready", "ready for review", "checks green",
                            "checks-green", "open and mergeable", "mergeable (clean")):
        return "PR-ready"
    if state in ("blocked", "failed"):
        return state
    if "validating" in n or "validating" in state:
        return "validating"
    if state == "working":
        return "working"
    if state == "done":
        return "waiting"        # done and waiting for its lane / merge - no action needed
    if state == "parked":
        return "at-gate"        # genuinely parked at a gate - needs action
    return state if state in STATUS_META else "working"


def _links():
    out = {}
    for line in _read(os.path.join(DATA, "links.md")).splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "::" not in s:
            continue
        parts = [p.strip() for p in s.split("::")]
        d = {}
        for p in parts[1:]:
            if p.startswith("ticket="):
                d["ticket"] = p[7:].strip()
            elif p.startswith("pr="):
                d["pr"] = p[3:].strip()
        out[parts[0]] = d
    return out


def _find_pr(text):
    m = _PR_RE.search(text or "")
    return m.group(0) if m else ""


_PRCACHE = os.path.join(STATE, ".fmtop-prcache")


def _pr_merged(pr_url):
    """Live-check whether a PR is merged, throttled to <=1 GitHub call / 20s / PR
    via a file cache (gather runs in a fresh child each refresh, so cache on disk)."""
    if not pr_url:
        return False
    m = re.search(r"github\.com/([^/]+)/([^/]+)/pull/(\d+)", pr_url)
    if not m:
        return False
    owner, repo, num = m.groups()
    os.makedirs(_PRCACHE, exist_ok=True)
    cf = os.path.join(_PRCACHE, f"{owner}-{repo}-{num}.json")
    try:
        c = json.load(open(cf))
        if time.time() - c["ts"] < 20:
            return c["merged"]
    except Exception:
        pass
    merged = False
    try:
        out = subprocess.run(["gh", "api", f"repos/{owner}/{repo}/pulls/{num}", "-q", ".merged"],
                             capture_output=True, text=True, timeout=6).stdout.strip()
        merged = out == "true"
    except Exception:
        merged = False
    try:
        json.dump({"ts": time.time(), "merged": merged}, open(cf, "w"))
    except Exception:
        pass
    return merged


def _recent_done(links, n=5):
    rows, indone = [], False
    for line in _read(os.path.join(DATA, "backlog.md")).splitlines():
        s = line.strip()
        if s.startswith("## Done"):
            indone = True
            continue
        if indone and s.startswith("## "):
            break
        if indone and s.startswith("- [x]"):
            body = s[5:].strip()
            tid = body.split(" - ")[0].strip().strip("*")
            desc = body.split(" - ", 1)[1] if " - " in body else body
            short = desc.split(" - http")[0].split(" - data/")[0].split(" - local")[0].strip()
            lk = links.get(tid, {})
            rows.append({"kind": "done", "name": tid, "project": "", "desc": short,
                         "overview": desc, "context": "", "note": "", "status": "done",
                         "options": [], "age": None, "ticket": lk.get("ticket", ""),
                         "pr": lk.get("pr") or _find_pr(line)})
    return rows[:n]


def _queued(links):
    """Queued backlog items (## Queued in data/backlog.md) so waiting work is
    visible in the cockpit, not just live crew. blocked-by dependencies become
    the row note; the (repo: …) tag becomes the project."""
    rows, inq = [], False
    for line in _read(os.path.join(DATA, "backlog.md")).splitlines():
        s = line.strip()
        if s.startswith("## Queued"):
            inq = True
            continue
        if inq and s.startswith("## "):
            break
        if inq and s.startswith("- [") and "] " in s:
            body = s.split("] ", 1)[1]
            tid = body.split(" - ")[0].strip().strip("*")
            desc = body.split(" - ", 1)[1] if " - " in body else body
            short = desc.split("(repo")[0].split(" blocked-by")[0].strip()
            proj = desc.split("(repo:", 1)[1].split(")")[0].strip() if "(repo:" in desc else ""
            note = ""
            if "blocked-by:" in line:
                note = "blocked-by " + line.split("blocked-by:", 1)[1].strip()
            lk = links.get(tid, {})
            rows.append({"kind": "queued", "name": tid, "project": proj, "desc": short,
                         "overview": short, "context": "", "note": note, "status": "queued",
                         "options": [], "age": None, "ticket": lk.get("ticket", ""),
                         "pr": lk.get("pr", "")})
    return rows


def _workflow_status(tid):
    """Derive a background workflow's (status, note) from its status file only -
    no crewmate pane and no crew-state probe. Terminal verbs pass through; any
    other running state renders as the distinct 'workflow' status."""
    last = ""
    for line in _read(os.path.join(STATE, tid + ".status")).splitlines():
        if line.strip():
            last = line.strip()
    verb = last.split(":", 1)[0].strip().lower() if ":" in last else last.strip().lower()
    note = last.split(":", 1)[1].strip() if ":" in last else ""
    if verb in ("done", "failed", "blocked", "needs-decision"):
        return verb, note
    return "workflow", (note or last)


def _awaiting_merge(links):
    """PRs that are green and waiting on the captain's merge, even after their
    crew was torn down to free the gate slot. Shown (not hidden) - they need action."""
    rows, ina = [], False
    for line in _read(os.path.join(DATA, "backlog.md")).splitlines():
        s = line.strip()
        if s.startswith("## Awaiting merge"):
            ina = True
            continue
        if ina and s.startswith("## "):
            break
        if ina and s.startswith("- ") and " - " in s:
            body = s.split("] ", 1)[1] if "] " in s else s[2:]
            tid = body.split(" - ")[0].strip().strip("*")
            desc = body.split(" - ", 1)[1] if " - " in body else body
            short = desc.split(" - http")[0].strip()
            lk = links.get(tid, {})
            pr = lk.get("pr") or _find_pr(line)
            if _pr_merged(pr):   # live-check: flip to merged the moment it's merged
                rows.append({"kind": "done", "name": tid, "project": "", "desc": short + " (merged)",
                             "overview": desc, "context": "", "note": "merged ✓", "status": "done",
                             "options": [], "age": None, "ticket": lk.get("ticket", ""), "pr": pr})
            else:
                rows.append({"kind": "pr-ready", "name": tid, "project": "", "desc": short,
                             "overview": desc, "context": "", "note": "awaiting your merge",
                             "status": "PR-ready", "options": [], "age": None,
                             "ticket": lk.get("ticket", ""), "pr": pr})
    return rows


def _decisions():
    blocks, cur = [], None
    for line in _read(os.path.join(DATA, "decisions.md")).splitlines():
        if line.startswith("#") and not line.startswith("## "):
            continue
        if line.startswith("## "):
            if cur:
                blocks.append(cur)
            parts = [p.strip() for p in line[3:].split("::")]
            task = ""
            for p in parts[3:]:
                if p.startswith("task="):
                    task = p[5:].strip()
            cur = {"id": parts[0] if parts else "?",
                   "project": parts[1] if len(parts) > 1 else "",
                   "title": parts[2] if len(parts) > 2 else "",
                   "task": task, "context": [], "options": []}
        elif cur is not None:
            s = line.strip()
            if s.startswith("* "):
                cur["options"].append(s[2:].strip())
            elif s:
                cur["context"].append(s)
    if cur:
        blocks.append(cur)
    return blocks


def gather():
    rows = []
    dmtime = None
    try:
        dmtime = time.time() - os.path.getmtime(os.path.join(DATA, "decisions.md"))
    except OSError:
        pass
    decs = _decisions()
    links = _links()
    linked = {d["task"]: d for d in decs if d.get("task")}
    # standalone decisions (not tied to an in-flight task) get their own row
    for d in decs:
        if not d.get("task"):
            rows.append({"kind": "decision", "name": d["id"], "project": d["project"],
                         "desc": d["title"], "overview": d["title"],
                         "context": " ".join(d["context"]), "note": "",
                         "status": "needs-decision", "options": d["options"], "age": dmtime,
                         "ticket": "", "pr": ""})
    bd = _backlog_desc()
    metas = sorted(glob.glob(os.path.join(STATE, "*.meta")))
    meta_by_tid = {os.path.basename(mp)[:-5]: _meta(mp) for mp in metas}
    tids = list(meta_by_tid.keys())
    # Background workflows have no crewmate pane, so they never hit the crew-state
    # probe fan-out; only real crew tids are probed.
    crew_tids = [t for t in tids if meta_by_tid[t].get("kind") != "workflow"]
    states = {}
    if crew_tids:
        with ThreadPoolExecutor(max_workers=min(8, len(crew_tids))) as ex:
            for tid, res in zip(crew_tids, ex.map(_crew_state, crew_tids)):
                states[tid] = res
    for tid in tids:
        m = meta_by_tid[tid]
        proj = os.path.basename(m.get("project", m.get("home", "?")) or "?")
        if m.get("kind") == "workflow":
            wf_state, wf_note = _workflow_status(tid)
            rows.append({"kind": "workflow", "name": tid,
                         "project": os.path.basename(m.get("project", "") or "") or "workflow",
                         "desc": bd.get(tid, wf_note[:60] or "background workflow"),
                         "overview": bd.get(tid, "background workflow"),
                         "context": "", "note": wf_note, "status": wf_state,
                         "options": [], "age": _age_secs(tid),
                         "ticket": links.get(tid, {}).get("ticket", ""),
                         "pr": links.get(tid, {}).get("pr", "") or _find_pr(wf_note)})
            continue
        state, note = states.get(tid, ("?", ""))
        lk = links.get(tid, {})
        ticket = lk.get("ticket", "")
        pr = lk.get("pr") or _find_pr(note) or _find_pr(_read(os.path.join(STATE, tid + ".status")))
        dec = linked.get(tid)
        if dec:   # this crew is parked on a decision -> ONE merged row, decidable here
            rows.append({"kind": "task", "name": tid, "project": proj,
                         "desc": dec["title"],
                         "overview": bd.get(tid, m.get("kind", "")),
                         "context": " ".join(dec["context"]), "note": note,
                         "status": "needs-decision", "options": dec["options"],
                         "age": _age_secs(tid), "ticket": ticket, "pr": pr})
        else:
            rows.append({"kind": "task", "name": tid, "project": proj,
                         "desc": bd.get(tid, note[:60] or m.get("kind", "")),
                         "overview": bd.get(tid, m.get("kind", "")),
                         "context": "", "note": note,
                         "status": _classify(state, note), "options": [],
                         "age": _age_secs(tid), "ticket": ticket, "pr": pr})
    existing = {r["name"] for r in rows}
    # PRs awaiting your merge (crew torn down to free the gate slot) - always shown
    for ar in _awaiting_merge(links):
        if ar["name"] not in existing:
            rows.append(ar)
            existing.add(ar["name"])
    # queued backlog work waiting to be dispatched - always shown
    for qr in _queued(links):
        if qr["name"] not in existing:
            rows.append(qr)
            existing.add(qr["name"])
    # last few completed tasks (hidden by default via the 'd' toggle)
    for dr in _recent_done(links, 5):
        if dr["name"] not in existing:
            rows.append(dr)
    return rows


def gather_child():
    """Gather in a SEPARATE PROCESS so the heavy crew-state probes never
    contend the UI thread's GIL (the real cause of the escape lag)."""
    out = subprocess.run([sys.executable, os.path.abspath(__file__), "--once-json"],
                         capture_output=True, text=True, timeout=20)
    return json.loads(out.stdout) if out.stdout.strip() else []


class Store:
    def __init__(self):
        self.rows, self.ts, self.lock = [], 0.0, threading.Lock()

    def snapshot(self):
        with self.lock:
            return list(self.rows), self.ts


def worker(store, stop):
    while not stop.is_set():
        try:
            rows = gather_child()
            with store.lock:
                store.rows, store.ts = rows, time.time()
        except Exception:
            pass
        stop.wait(REFRESH)


def _send(kind, name, project, text, prompt):
    os.makedirs(INBOX, exist_ok=True)
    payload = {"kind": kind, "id": name, "project": project, "choice": text, "prompt": prompt}
    with open(os.path.join(INBOX, f"{name}-{int(time.time())}.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f)


def send_decision(row, option_text):
    _send("decision", row["name"], row["project"], option_text,
          f"Decision on {row['name']} ({row['project']}): {option_text}")


def send_check(row):
    age = _fmt_age(row.get("age"))
    _send("check", row["name"], row["project"], "check",
          f"Please check on crew '{row['name']}' ({row['project']}) - it may be stuck "
          f"(status {row['status']}, last activity {age} ago). Peek it and report.")


def once():
    rows = gather()
    print(f"{'NAME':<20}{'PROJECT':<11}{'STATUS':<16}{'AGE':<6}DESCRIPTION")
    for r in sorted(rows, key=lambda x: (SORT_RANK.get(x["status"], 9), x["name"])):
        print(f"{r['name']:<20}{r['project']:<11}{r['status']:<16}{_fmt_age(r['age']):<6}{r['desc'][:46]}")


def _arch_projects():
    """Every dir under projects/, each tagged with whether it has a valid
    ARCHITECTURE.md and its top-level component count. Parsing is cheap and
    memoized in fm_arch, so this is safe to call on the UI thread."""
    out = []
    for d in sorted(glob.glob(os.path.join(PROJECTS, "*"))):
        if not os.path.isdir(d):
            continue
        name = os.path.basename(d)
        doc = os.path.join(d, "ARCHITECTURE.md")
        entry = {"name": name, "path": doc, "has_doc": os.path.isfile(doc),
                 "count": None, "valid": False}
        if entry["has_doc"] and fm_arch is not None:
            try:
                tree = fm_arch.parse_architecture(doc)
                entry["count"] = len(tree.children)
                entry["valid"] = True
            except Exception:
                entry["valid"] = False   # present but unparseable -> flagged in the picker
        out.append(entry)
    return out


def _arch_node(tree, arch_path):
    """Walk the breadcrumb index path from the root to the current node."""
    node = tree
    for i in arch_path:
        if 0 <= i < len(node.children):
            node = node.children[i]
        else:
            break
    return node


def _arch_breadcrumb(proj, tree, arch_path):
    """`proj > name1 > name2 …` built from the breadcrumb index path."""
    parts = [proj]
    node = tree
    for i in arch_path:
        if 0 <= i < len(node.children):
            node = node.children[i]
            parts.append(node.name)
        else:
            break
    return " › ".join(parts)


def _wrap(text, width):
    words, lines, cur = text.split(), [], ""
    for wd in words:
        if len(cur) + len(wd) + 1 > max(8, width):
            lines.append(cur)
            cur = wd
        else:
            cur = (cur + " " + wd).strip()
    if cur:
        lines.append(cur)
    return lines or [""]


def read_line(stdscr, y, x, prompt, w):
    """Blocking single-line text input. Returns text, or None on Esc."""
    import curses
    curses.curs_set(1)
    stdscr.timeout(-1)
    buf = ""
    try:
        while True:
            stdscr.addnstr(y, x, (prompt + buf).ljust(w - x - 1), w - x - 1)
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (10, 13):
                break
            if ch == 27:
                buf = None
                break
            if ch in (curses.KEY_BACKSPACE, 127, 8):
                buf = buf[:-1]
            elif 32 <= ch < 127:
                buf += chr(ch)
    finally:
        curses.curs_set(0)
        stdscr.timeout(100)
    return buf.strip() if buf else None


def tui(stdscr):
    import curses
    try:
        curses.set_escdelay(25)   # kill the ~1s Esc lag (default ESCDELAY)
    except Exception:
        pass
    curses.curs_set(0)
    curses.use_default_colors()
    cmap = {"cyan": curses.COLOR_CYAN, "green": curses.COLOR_GREEN,
            "yellow": curses.COLOR_YELLOW, "red": curses.COLOR_RED,
            "grey": curses.COLOR_CYAN, "mag": curses.COLOR_MAGENTA}
    pair = {}
    for i, (k, c) in enumerate(cmap.items(), 1):
        curses.init_pair(i, c, -1)
        pair[k] = curses.color_pair(i)
    pair["white"] = 0

    store = Store()
    stop = threading.Event()
    threading.Thread(target=worker, args=(store, stop), daemon=True).start()

    stdscr.timeout(100)
    mode, sel, sort_col, sort_rev, opt_sel = "list", 0, 0, False, 0
    flash, flash_t = "", 0.0
    show_done = False   # hidden by default; toggle with 'd'
    # Architecture view state (separate screen off the fleet chart; enter with 'a')
    arch_projects, arch_proj, arch_tree = [], "", None
    arch_path, arch_sel, arch_scroll = [], 0, 0
    cols = [("NAME", "name", 19), ("PROJECT", "project", 10),
            ("STATUS", "status", 15), ("AGE", "age", 6), ("DESCRIPTION", "desc", 0)]

    try:
        while True:
            rows, ts = store.snapshot()
            if not show_done:
                rows = [r for r in rows if r.get("kind") != "done"]
            if sort_col == 2:
                rows.sort(key=lambda x: (SORT_RANK.get(x["status"], 9), x["name"]), reverse=sort_rev)
            elif sort_col == 3:
                rows.sort(key=lambda x: (x["age"] is None, x["age"] or 0), reverse=sort_rev)
            else:
                k = cols[sort_col][1]
                rows.sort(key=lambda x: str(x.get(k, "")).lower(), reverse=sort_rev)
            if rows:
                sel = max(0, min(sel, len(rows) - 1))
            h, w = stdscr.getmaxyx()
            stdscr.erase()

            if ts == 0.0:
                stdscr.addnstr(0, 0, " ⚓ FIRSTMATE  loading fleet…", w - 1, pair["cyan"] | curses.A_BOLD)
            elif mode == "list":
                title = (f" ⚓ FIRSTMATE   {len(rows)} rows   sort:{cols[sort_col][0]}"
                         f"{'▼' if sort_rev else '▲'}   {time.strftime('%H:%M:%S')} ")
                stdscr.addnstr(0, 0, title.ljust(w - 1), w - 1, pair["cyan"] | curses.A_BOLD)
                x, hdr = 0, ""
                arrow = "▼" if sort_rev else "▲"
                for i, (label, _k, wd) in enumerate(cols):
                    width = wd if wd else max(10, w - 1 - x)
                    marker = arrow if i == sort_col else " "
                    hdr += f"{marker}{label:<{width-1}}"
                    x += width
                stdscr.addnstr(1, 0, hdr.ljust(w - 1), w - 1, curses.A_UNDERLINE | curses.A_BOLD)
                body = h - 3
                top = max(0, sel - body + 1) if sel >= body else 0
                for ri in range(body):
                    idx = top + ri
                    if idx >= len(rows):
                        break
                    r = rows[idx]
                    ckey, glyph = STATUS_META.get(r["status"], ("white", " "))
                    base = curses.A_REVERSE if idx == sel else 0
                    x = 0
                    for i, (_l, k, wd) in enumerate(cols):
                        width = wd if wd else max(10, w - 1 - x)
                        if k == "status":
                            cell, attr = f"{glyph} {r['status']}", base | pair[ckey] | (0 if base else curses.A_BOLD)
                        elif k == "age":
                            cell, attr = _fmt_age(r["age"]), base | (pair["grey"] | curses.A_DIM if not base else 0)
                        else:
                            cell, attr = str(r.get(k, "")), base
                        try:
                            stdscr.addnstr(2 + ri, x, cell[:width-1].ljust(width-1), width-1, attr)
                        except curses.error:
                            pass
                        x += width
                bar = (f" ↑↓ move · Enter detail · a arch · c check · 1-5 sort (re-press toggles ▲▼) · r rev · "
                       f"d {'hide' if show_done else 'show'} done · q quit ")
                if flash and time.time() - flash_t < 5:
                    bar = f" ✓ {flash} "
                stdscr.addnstr(h - 1, 0, bar.ljust(w - 1), w - 1, curses.A_REVERSE)
            elif mode == "arch-pick":
                title = f" ⚓ FIRSTMATE · ARCHITECTURE      {time.strftime('%H:%M:%S')} "
                stdscr.addnstr(0, 0, title.ljust(w - 1), w - 1, pair["cyan"] | curses.A_BOLD)
                hdr = f" {'PROJECT':<18}{'COMPONENTS':<13}DOC"
                stdscr.addnstr(1, 0, hdr.ljust(w - 1), w - 1, curses.A_UNDERLINE | curses.A_BOLD)
                body = h - 3
                if arch_projects:
                    arch_sel = max(0, min(arch_sel, len(arch_projects) - 1))
                top = max(0, arch_sel - body + 1) if arch_sel >= body else 0
                for ri in range(body):
                    idx = top + ri
                    if idx >= len(arch_projects):
                        break
                    p = arch_projects[idx]
                    base = curses.A_REVERSE if idx == arch_sel else 0
                    if p["valid"]:
                        comp, doc, rattr = str(p["count"]), "✓ up to date", base or pair["green"]
                    elif p["has_doc"]:
                        comp, doc, rattr = "–", "⚠ invalid doc", base or pair["red"]
                    else:
                        comp, doc, rattr = "–", "(no architecture doc)", base or (pair["grey"] | curses.A_DIM)
                    row = f" {p['name']:<18}{comp:<13}{doc}"
                    try:
                        stdscr.addnstr(2 + ri, 0, row[:w-1].ljust(w - 1), w - 1, rattr)
                    except curses.error:
                        pass
                if not arch_projects:
                    stdscr.addnstr(3, 2, "no projects under projects/", w - 3, curses.A_DIM)
                bar = " ↑↓ move · Enter open · Esc back to fleet · q quit "
                if flash and time.time() - flash_t < 5:
                    bar = f" ✓ {flash} "
                stdscr.addnstr(h - 1, 0, bar.ljust(w - 1), w - 1, curses.A_REVERSE)
            elif mode == "arch-node":
                if arch_tree is None:
                    mode = "arch-pick"
                else:
                    node = _arch_node(arch_tree, arch_path)
                    crumb = _arch_breadcrumb(arch_proj, arch_tree, arch_path)
                    if len(crumb) > w - 2:
                        crumb = crumb[:w - 3] + "…"
                    stdscr.addnstr(0, 0, f" {crumb} ".ljust(w - 1), w - 1, curses.A_BOLD | pair["cyan"])
                    ln = 2
                    kids = node.children
                    desc_lines = _wrap(node.description(), w - 6) if node.desc else []
                    desc_budget = min(len(desc_lines), 4)
                    comp_budget = (len(kids) + 1) if kids else 2
                    diag_budget = max(3, (h - ln - 2) - desc_budget - comp_budget - 2)
                    diagram = node.diagram
                    total = len(diagram)
                    arch_scroll = max(0, min(arch_scroll, max(0, total - diag_budget)))
                    more = f"  (↕ {total - diag_budget} more · [ ] scroll)" if total > diag_budget else ""
                    stdscr.addnstr(ln, 0, f" DIAGRAM{more} ".ljust(w - 1), w - 1,
                                   curses.A_BOLD | curses.A_UNDERLINE)
                    ln += 1
                    if not diagram:
                        stdscr.addnstr(ln, 2, "(no diagram)", w - 3, curses.A_DIM)
                        ln += 1
                    else:
                        for dl in diagram[arch_scroll:arch_scroll + diag_budget]:
                            if ln >= h - 2:
                                break
                            clipped = "  " + dl
                            try:
                                stdscr.addnstr(ln, 0, clipped[:w-2], w - 2)
                                if len(clipped) > w - 2:
                                    stdscr.addnstr(ln, w - 2, "›", 1, pair["grey"] | curses.A_DIM)
                            except curses.error:
                                pass
                            ln += 1
                    if node.desc and ln < h - 3:
                        stdscr.addnstr(ln, 0, " DESCRIPTION ".ljust(w - 1), w - 1,
                                       curses.A_BOLD | curses.A_UNDERLINE | curses.A_DIM)
                        ln += 1
                        for wl in desc_lines[:desc_budget]:
                            if ln >= h - 2:
                                break
                            stdscr.addnstr(ln, 2, wl, w - 3, curses.A_DIM)
                            ln += 1
                    if ln < h - 2:
                        stdscr.addnstr(ln, 0, " COMPONENTS ".ljust(w - 1), w - 1,
                                       curses.A_BOLD | curses.A_UNDERLINE)
                        ln += 1
                    if not kids:
                        if ln < h - 1:
                            stdscr.addnstr(ln, 2, "(leaf component - no children)", w - 3, curses.A_DIM)
                    else:
                        arch_sel = max(0, min(arch_sel, len(kids) - 1))
                        avail = max(1, h - 1 - ln)
                        ctop = max(0, arch_sel - avail + 1) if arch_sel >= avail else 0
                        for ci in range(avail):
                            kidx = ctop + ci
                            if kidx >= len(kids):
                                break
                            selected = kidx == arch_sel
                            bullet = "▶" if selected else "○"
                            tail = "" if kids[kidx].children else "  (leaf)"
                            txt = f" {bullet}  {kids[kidx].name}{tail}"
                            attr = curses.A_REVERSE if selected else 0
                            try:
                                stdscr.addnstr(ln, 1, txt[:w-3].ljust(w - 4), w - 4, attr)
                            except curses.error:
                                pass
                            ln += 1
                    bar = " ↑↓ pick · Enter open · [ ] scroll · Esc up · q fleet · r reload "
                    if flash and time.time() - flash_t < 5:
                        bar = f" ✓ {flash} "
                    stdscr.addnstr(h - 1, 0, bar.ljust(w - 1), w - 1, curses.A_REVERSE)
            else:
                r = rows[sel] if rows else None
                if not r:
                    mode = "list"
                else:
                    ckey, glyph = STATUS_META.get(r["status"], ("white", " "))
                    stdscr.addnstr(0, 0, f" {r['name']} ".ljust(w - 1), w - 1, curses.A_BOLD | pair["cyan"])
                    stdscr.addnstr(2, 2, f"{glyph} {r['status']}", w - 3, pair[ckey] | curses.A_BOLD)
                    stdscr.addnstr(2, 26, f"project: {r['project']}    last activity: {_fmt_age(r['age'])} ago",
                                   w - 27, curses.A_DIM)
                    ln = 4
                    # high-level: what this task IS
                    stdscr.addnstr(ln, 2, "TASK", w - 3, curses.A_BOLD | curses.A_UNDERLINE)
                    ln += 1
                    for wl in _wrap(r.get("overview") or r["desc"], w - 6):
                        if ln >= h - 2:
                            break
                        stdscr.addnstr(ln, 4, wl, w - 5)
                        ln += 1
                    # latest crew activity (why it's where it is)
                    if r.get("note"):
                        ln += 1
                        stdscr.addnstr(ln, 2, "LATEST ACTIVITY", w - 3,
                                       curses.A_BOLD | curses.A_UNDERLINE | curses.A_DIM)
                        ln += 1
                        for wl in _wrap(r["note"], w - 6):
                            if ln >= h - 2:
                                break
                            stdscr.addnstr(ln, 4, wl, w - 5, curses.A_DIM)
                            ln += 1
                    # links: ticket and/or PR (most terminals make these clickable)
                    if r.get("ticket") or r.get("pr"):
                        ln += 1
                        stdscr.addnstr(ln, 2, "LINKS", w - 3, curses.A_BOLD | curses.A_UNDERLINE)
                        ln += 1
                        if r.get("ticket") and ln < h - 2:
                            stdscr.addnstr(ln, 4, f"🎫 ticket   {r['ticket']}", w - 5, pair["cyan"])
                            ln += 1
                        if r.get("pr") and ln < h - 2:
                            stdscr.addnstr(ln, 4, f"🔗 PR       {r['pr']}", w - 5, pair["cyan"])
                            ln += 1
                    # the decision + actions
                    if r["options"]:
                        ln += 1
                        stdscr.addnstr(ln, 2, "DECISION — ↑↓ pick · Enter send · last = write your own",
                                       w - 3, curses.A_BOLD | curses.A_UNDERLINE | pair["yellow"])
                        ln += 1
                        if r.get("context"):
                            for wl in _wrap(r["context"], w - 6):
                                if ln >= h - 2:
                                    break
                                stdscr.addnstr(ln, 4, wl, w - 5, pair["grey"])
                                ln += 1
                            ln += 1
                        disp = r["options"] + ["✎ Write your own response…"]
                        for oi, opt in enumerate(disp):
                            custom = oi == len(r["options"])
                            rec = "[recommended]" in opt
                            txt = opt.replace("[recommended]", "").strip() + ("   ★ recommended" if rec else "")
                            selected = oi == opt_sel
                            bullet = "▶" if selected else ("✎" if custom else "○")
                            attr = (curses.A_REVERSE if selected else 0) | \
                                   (pair["green"] if rec else (pair["cyan"] if custom else 0))
                            for j, wl in enumerate(_wrap(txt, w - 9)):
                                if ln >= h - 2:
                                    break
                                pre = f" {bullet}  " if j == 0 else "    "
                                stdscr.addnstr(ln, 3, (pre + wl).ljust(w - 5), w - 5, attr)
                                ln += 1
                            ln += 1
                    elif r["status"] == "with-firstmate":
                        ln += 1
                        stdscr.addnstr(ln, 2, "⚙ WITH FIRSTMATE — no action needed from you",
                                       w - 3, pair["mag"] | curses.A_BOLD)
                        ln += 1
                        stdscr.addnstr(ln, 4, "Parked at a gate; firstmate is reviewing it and will "
                                       "surface a decision here only if your call is needed.",
                                       w - 5, pair["mag"])
                    bar = (" ↑↓ pick · Enter send · c flag-check · Esc back "
                           if r["options"] else " c flag-check · Esc back · q quit ")
                    stdscr.addnstr(h - 1, 0, bar.ljust(w - 1), w - 1, curses.A_REVERSE)

            stdscr.refresh()
            ch = stdscr.getch()
            if ch == -1:
                continue
            r = rows[sel] if rows else None
            if mode == "list":
                if ch in (ord("q"), 27):
                    break
                elif ch in (curses.KEY_DOWN, ord("j")):
                    sel += 1
                elif ch in (curses.KEY_UP, ord("k")):
                    sel -= 1
                elif ch in (curses.KEY_ENTER, 10, 13) and rows:
                    opt_sel, mode = 0, "detail"
                elif ch == ord("a"):
                    arch_projects = _arch_projects()
                    arch_sel, mode = 0, "arch-pick"
                elif ch == ord("c") and r:
                    send_check(r)
                    flash, flash_t = f"flagged {r['name']} for a check", time.time()
                elif ch in (ord("1"), ord("2"), ord("3"), ord("4"), ord("5")):
                    nc = ch - ord("1")
                    if nc < len(cols):
                        sort_col, sort_rev = _next_sort(sort_col, sort_rev, nc)
                elif ch == ord("r"):
                    sort_rev = not sort_rev
                elif ch == ord("d"):
                    show_done = not show_done
            elif mode == "arch-pick":
                if ch in (27, ord("q")):
                    mode = "list"
                elif ch in (curses.KEY_DOWN, ord("j")):
                    arch_sel += 1
                elif ch in (curses.KEY_UP, ord("k")):
                    arch_sel -= 1
                elif ch in (curses.KEY_ENTER, 10, 13) and arch_projects:
                    p = arch_projects[max(0, min(arch_sel, len(arch_projects) - 1))]
                    if p["valid"] and fm_arch is not None:
                        try:
                            arch_tree = fm_arch.parse_architecture(p["path"])
                            arch_proj, arch_path, arch_sel, arch_scroll = p["name"], [], 0, 0
                            mode = "arch-node"
                        except Exception as exc:
                            flash, flash_t = f"cannot parse {p['name']}: {exc}", time.time()
                    elif p["has_doc"]:
                        flash, flash_t = f"{p['name']}: architecture doc is invalid (run fm-arch-lint)", time.time()
                    else:
                        flash, flash_t = f"{p['name']}: no architecture doc - add one via a PR", time.time()
            elif mode == "arch-node":
                node = _arch_node(arch_tree, arch_path) if arch_tree is not None else None
                if ch == ord("q"):
                    mode = "list"
                elif ch == 27:   # Esc: up one level, or back to the picker at the top
                    if arch_path:
                        arch_sel, arch_scroll = arch_path.pop(), 0
                    else:
                        arch_sel, mode = 0, "arch-pick"
                elif node is None:
                    mode = "arch-pick"
                elif ch in (curses.KEY_DOWN, ord("j")) and node.children:
                    arch_sel = (arch_sel + 1) % len(node.children)
                elif ch in (curses.KEY_UP, ord("k")) and node.children:
                    arch_sel = (arch_sel - 1) % len(node.children)
                elif ch in (curses.KEY_ENTER, 10, 13):
                    if node.children:
                        arch_path.append(max(0, min(arch_sel, len(node.children) - 1)))
                        arch_sel, arch_scroll = 0, 0
                    else:
                        flash, flash_t = "leaf component - no children", time.time()
                elif ch == ord("["):
                    arch_scroll = max(0, arch_scroll - 1)
                elif ch == ord("]"):
                    arch_scroll += 1
                elif ch == ord("r") and fm_arch is not None and arch_proj:
                    path = os.path.join(PROJECTS, arch_proj, "ARCHITECTURE.md")
                    fm_arch.invalidate(path)
                    try:
                        arch_tree = fm_arch.parse_architecture(path)
                        valid_path, cursor = [], arch_tree   # clamp breadcrumb to the reloaded tree
                        for i in arch_path:
                            if 0 <= i < len(cursor.children):
                                valid_path.append(i)
                                cursor = cursor.children[i]
                            else:
                                break
                        arch_path, arch_sel, arch_scroll = valid_path, 0, 0
                        flash, flash_t = f"reloaded {arch_proj}", time.time()
                    except Exception as exc:
                        flash, flash_t = f"reload failed: {exc}", time.time()
                        mode = "arch-pick"
            else:
                if ch in (27, ord("q")):
                    mode = "list"
                elif ch == ord("c") and r:
                    send_check(r)
                    flash, flash_t = f"flagged {r['name']} for a check", time.time()
                    mode = "list"
                elif r and r["options"]:
                    n = len(r["options"]) + 1   # +1 for "write your own"
                    if ch in (curses.KEY_DOWN, ord("j")):
                        opt_sel = (opt_sel + 1) % n
                    elif ch in (curses.KEY_UP, ord("k")):
                        opt_sel = (opt_sel - 1) % n
                    elif ch in (curses.KEY_ENTER, 10, 13):
                        if opt_sel == len(r["options"]):   # write-your-own
                            txt = read_line(stdscr, h - 2, 2, "Your decision → ", w)
                            if txt:
                                send_decision(r, "(your own) " + txt)
                                flash, flash_t = f"sent: {r['name']} → {txt[:40]}", time.time()
                                mode = "list"
                        else:
                            choice = r["options"][opt_sel].replace("[recommended]", "").strip()
                            send_decision(r, choice)
                            flash, flash_t = f"sent: {r['name']} → {choice[:40]}", time.time()
                            mode = "list"
    finally:
        stop.set()


def main():
    if "--once-json" in sys.argv:
        sys.stdout.write(json.dumps(gather()))
        return
    if "--once" in sys.argv:
        once()
        return
    import curses
    curses.wrapper(tui)


if __name__ == "__main__":
    main()
