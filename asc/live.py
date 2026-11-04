"""Running claudes, from Claude Code's own session files, each checked against /proc.

~/.claude/sessions/<pid>.json is Claude Code's undocumented format: a file whose fields are
missing or unexpected gives a session marked unknown, and nothing acts on it. A file only
counts as live when it is named <pid>.json, its pidDomain (if any) is this machine and PID
namespace, and its PID runs, is a claude (is_claude) and started at the recorded procStart (so
a reused PID, a copied file or one left by a SIGKILL is not taken for a live claude).
"""
import glob
import json
import os
import re
import stat
import time

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SHELLS = {"bash", "zsh", "sh", "dash", "fish", "ksh", "tcsh", "csh"}
# Looked through like a shell when checking what a pane runs (a shebang script's process
# name is its file name).
WRAPPERS = SHELLS | {"asctl-wrap"}
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def open_regular(path):
    """A regular file opened for reading (binary), or None: never a FIFO or device (open would
    block or read forever) and never through a symlink."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        return None
    return os.fdopen(fd, "rb")


def read_json(path, limit=1 << 20):
    """A small JSON file's value, or None (unreadable, not a regular file, too big, not JSON,
    or nested deep enough to raise RecursionError)."""
    f = open_regular(path)
    if f is None:
        return None
    with f:
        data = f.read(limit + 1)
    if len(data) > limit:
        return None
    try:
        return json.loads(data.decode("utf-8", "replace"))
    except (ValueError, RecursionError):
        return None


def proc_stat(pid):
    """(name, ppid, starttime, state) of a PID, or None."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as f:
            s = f.read()
    except OSError:
        return None
    i, j = s.find("("), s.rfind(")")
    if i < 0 or j < i:
        return None
    rest = s[j + 2:].split()
    try:
        return s[i + 1:j], int(rest[1]), rest[19], rest[0]
    except (IndexError, ValueError):
        return None


def is_claude(pid, name):
    """Whether a process named name is a claude: `claude`, or one of Claude Code's version
    binaries run as claude (a background job runs ~/.local/share/claude/versions/2.1.316 itself,
    so its name is the version and its argv[0] is claude)."""
    return name == "claude" or (VERSION_RE.fullmatch(name) is not None
                                and _cmdline(pid).split(" ", 1)[0].rsplit("/", 1)[-1] == "claude")


def alive(pid, proc_start):
    st = proc_stat(pid)
    # a zombie has ended: it only waits for its parent (tmux) to collect it
    return (st is not None and is_claude(pid, st[0]) and st[3] not in ("Z", "X")
            and proc_start is not None and st[2] == str(proc_start))


def _pid_domain():
    try:
        with open("/etc/machine-id", encoding="utf-8") as f:
            mid = f.read().strip()
        return f"linux:{mid}:{os.readlink('/proc/self/ns/pid')}"
    except OSError:
        return None


def tty_name(pid):
    """The terminal a process runs on ("pts/27"), or "" for none."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as f:
            nr = int(f.read().rsplit(")", 1)[1].split()[4])
    except (OSError, IndexError, ValueError):
        return ""
    major, minor = (nr >> 8) & 0xfff, (nr & 0xff) | ((nr >> 12) & 0xfff00)
    if 136 <= major <= 143:
        return f"pts/{(major - 136) * 256 + minor}"
    return f"tty{minor}" if major == 4 and minor < 64 else ("" if nr == 0 else f"terminal {major}:{minor}")


def where(s):
    """Where a live claude runs, in words, when it is not in its favorite's tmux session:
    {"how": "background" | "tmux" | "terminal", "text": ...}. background: a Claude Code
    background session (claude --bg, claude agents) in no pane, which `claude stop JOB` ends
    with its conversation kept; tmux: another tmux session's pane; terminal: anything else (a
    terminal window, an IDE's terminal, ssh), named by the program it runs under."""
    if s["kind"] == "bg" and not s.get("pane"):
        return {"how": "background", "text": "a Claude Code background session"
                + (f" (job {s['job']})" if s.get("job") else "")}
    if s.get("pane"):
        return {"how": "tmux", "text": f"tmux session {s['pane']['session']}"}
    app = ""
    for a in ancestors(s["pid"])[1:]:
        name = (proc_stat(a) or ("",))[0]
        if name not in WRAPPERS and not is_claude(a, name):
            app = name
            break
    tty = tty_name(s["pid"])
    if tty:
        return {"how": "terminal", "text": f"a terminal outside tmux ({', '.join(x for x in (app, tty) if x)})"}
    return {"how": "terminal", "text": "a process outside tmux, with no terminal" + (f" (under {app})" if app else "")}


def ancestors(pid, limit=64):
    out = []
    while pid > 1 and len(out) < limit:
        st = proc_stat(pid)
        if not st:
            break
        out.append(pid)
        pid = st[1]
    return out


def read_sessions(home=None):
    """Every session file, as dicts; ok=False when a field is missing or odd."""
    home = home or os.path.expanduser("~")
    domain = _pid_domain()
    out = []
    for path in sorted(glob.glob(os.path.join(home, ".claude", "sessions", "*.json"))):
        base = os.path.basename(path)[:-5]
        raw = read_json(path)
        if not isinstance(raw, dict):
            # Unreadable (a partial write, a new format): never live, but on must see it.
            out.append({"file": path, "ok": False, "pid": int(base) if base.isdigit() else None,
                        "session_id": None, "live": False, "text": _text(path)})
            continue
        pid, sid = raw.get("pid"), raw.get("sessionId")
        ok = (isinstance(pid, int) and pid > 1 and base == str(pid) and isinstance(sid, str)
              and UUID_RE.fullmatch(sid) and isinstance(raw.get("cwd"), str) and raw.get("procStart") is not None
              and (raw.get("pidDomain") is None or raw.get("pidDomain") == domain))
        s = {"file": path, "ok": bool(ok), "pid": pid, "session_id": sid, "cwd": raw.get("cwd"),
             "name": raw.get("name") if isinstance(raw.get("name"), str) else "",
             "derived": raw.get("nameSource") == "derived",  # a made-up name (folder-NN), not one given
             # a name claude took over --name: from its own record of an old background job
             # (~/.claude/jobs/<id>/state.json), applied again at every start
             "peer_name": raw.get("nameSource") == "peer",
             "status": raw.get("status") if raw.get("status") in ("busy", "idle", "shell", "waiting") else "unknown",
             "rc": bool(raw.get("bridgeSessionId")), "kind": raw.get("kind"),
             # why claude waits ("dialog open", "input needed", ...), and when its status last changed
             "waiting_for": raw.get("waitingFor")[:40] if isinstance(raw.get("waitingFor"), str) else "",
             "status_at": raw.get("statusUpdatedAt") // 1000 if type(raw.get("statusUpdatedAt")) is int else None,
             "proc_start": raw.get("procStart"),
             # a background job's id; an interactive claude that handed its conversation to a
             # background job and now shows that job in its pane names the job here
             "job": raw.get("jobId") if isinstance(raw.get("jobId"), str) else None,
             "parked": raw.get("parkedJobId") if isinstance(raw.get("parkedJobId"), str) else None,
             "started_at": raw.get("startedAt") // 1000 if type(raw.get("startedAt")) is int else None}
        s["live"] = bool(ok) and alive(pid, s["proc_start"])
        s["text"] = "" if ok else _text(path)
        out.append(s)
    return out


def _text(path):
    f = open_regular(path)
    if f is None:
        return ""
    with f:
        return f.read(65536).decode("utf-8", "replace")


def unreadable_blockers(session_id, home=None):
    """Session files asctl cannot trust that might belong to a running claude holding this
    session: the file's PID is a running `claude`, or the file mentions the session id. A file
    that reads well but does not check out against a running claude of its PID counts too (if
    Claude Code changed how it writes procStart, no claude would look live)."""
    out = []
    for s in read_sessions(home):
        if s["live"]:
            continue
        pid = s["pid"] if isinstance(s["pid"], int) else None
        st = proc_stat(pid) if pid else None
        if (st and is_claude(pid, st[0])) or (session_id and session_id in s.get("text", "")):
            out.append(s["file"])
    return out


def live(home=None, pane_list=None):
    """Live claudes, each with the tmux pane it runs in (or None). A claude whose pane shows a
    background job it handed its conversation to (parkedJobId) is replaced by that job: what the
    pane shows and what typed keys reach is the job, so the job takes the pane, and the claude
    in the pane is kept as its "host" (the process in the pane, the one Off signals)."""
    from . import tmuxctl
    pane_list = tmuxctl.panes() if pane_list is None else pane_list
    by_pid = {p["pane_pid"]: p for p in pane_list}
    out = []
    for s in read_sessions(home):
        if not s["live"]:
            continue
        # a background job runs under Claude Code's daemon, which may be a child of whichever
        # claude started it, so in that claude's pane: it is in a pane only when a claude shows it
        s["pane"] = None if s["kind"] == "bg" else next((by_pid[a] for a in ancestors(s["pid"]) if a in by_pid), None)
        s["host"] = None
        out.append(s)
    jobs = {s["job"]: s for s in out if s["kind"] == "bg" and s["job"] and not s["pane"]}
    for h in [s for s in out if s["pane"] and s["parked"] in jobs]:
        j = jobs.pop(h["parked"])
        j["pane"], j["host"] = h["pane"], h
        out.remove(h)
    return out


def children_map():
    """PID -> [(child pid, name)] for every process."""
    kids = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            st = proc_stat(int(d))
            if st:
                kids.setdefault(st[1], []).append((int(d), st[0]))
    return kids


def rss_kb(pid):
    try:
        with open(f"/proc/{pid}/statm", encoding="ascii") as f:
            return int(f.read().split()[1]) * (os.sysconf("SC_PAGE_SIZE") // 1024)
    except (OSError, ValueError, IndexError):
        return 0


def pss_kb(pid):
    """A process's fair share of memory (PSS: a page shared by n processes counts 1/n in each,
    so the claude binary's code, shared by every claude, is not counted again per session);
    RSS when it cannot be read (another user's process)."""
    try:
        with open(f"/proc/{pid}/smaps_rollup", encoding="ascii") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return rss_kb(pid)


def tree_mem_kb(pid, kids):
    """PSS of a process and all its descendants (a pane: claude, its MCP servers, a browser)."""
    total, todo, seen = 0, [pid], set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        total += pss_kb(p)
        todo += [c for c, _ in kids.get(p, [])]
    return total


AGENT_FRESH = 600  # a subagent transcript untouched this long is left over (its claude ended), not running


def _cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read(4096).replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        return ""


def _last_record(path, chunk=65536):
    f = open_regular(path)
    if f is None:
        return None
    with f:
        size = os.fstat(f.fileno()).st_size
        f.seek(max(0, size - chunk))
        lines = [l for l in f.read(chunk).split(b"\n") if l.strip()]
    try:
        r = json.loads(lines[-1]) if lines else None
    except (ValueError, RecursionError):
        return None
    return r if isinstance(r, dict) else None


def claude_tasks(s, kids, home=None):
    """What an idle claude still runs, or "": a shell command (claude runs each, also a background
    one, as a child bash that sources its shell snapshot), or a subagent (its transcript recent, not
    marked finished, and not ending in a final answer). MCP servers, also children, do not count."""
    home = home or os.path.expanduser("~")
    snap = os.path.join(home, ".claude", "shell-snapshots") + "/"
    for pid, name in kids.get(s["pid"], []):
        if name in SHELLS and snap in _cmdline(pid):
            return "runs a command"
    now = time.time()
    for path in glob.glob(os.path.join(home, ".claude", "projects", "*", s["session_id"], "subagents", "agent-*.jsonl")):
        try:
            if now - os.lstat(path).st_mtime > AGENT_FRESH:
                continue
        except OSError:
            continue
        meta = read_json(path[:-6] + ".meta.json")
        if isinstance(meta, dict) and meta.get("finished") is True:
            continue
        r = _last_record(path)
        m = r.get("message") if r else None
        if r and r.get("type") == "assistant" and isinstance(m, dict) and m.get("stop_reason") == "end_turn":
            continue
        what = meta.get("description") if isinstance(meta, dict) and isinstance(meta.get("description"), str) else ""
        return "runs a subagent" + (f": {what[:60]}" if what else "")
    return ""


def busy_reason(session_name, lv, kids=None, pane_list=None, own_sid=None):
    """Why a tmux session is busy, or "" when it is not. Each pane's process tree is walked
    (tmux's pane_current_command names the process group, which for a claude under asctl-wrap
    is the wrapper's bash): shells are looked through; a claude counts by its session file
    (busy if working; one with no trusted file is unknown, so busy); anything else running
    (a dev server, a build, an editor) makes the session busy. lv: the live claudes (live());
    kids, pane_list: children_map() and that session's panes, when the caller has them.
    own_sid: the favorite's session id; any other claude in the session counts as busy too
    (Off would end it as well)."""
    from . import tmuxctl
    known = {s["pid"]: s for s in lv}
    known.update({s["host"]["pid"]: s for s in lv if s.get("host")})  # the claude showing a job
    kids = children_map() if kids is None else kids
    pane_list = tmuxctl.panes(session_name, strict=True) if pane_list is None else pane_list
    if pane_list is None:
        return "tmux did not list its panes"
    for p in pane_list:
        todo = [(p["pane_pid"], (proc_stat(p["pane_pid"]) or ("?",))[0])]
        while todo:
            pid, name = todo.pop()
            if name == "claude":
                s = known.get(pid)
                if s is None:
                    return f"it runs a claude asctl cannot read (pid {pid})"
                if s["status"] == "busy":
                    return "claude is working"
                t = claude_tasks(s, kids)
                if t:
                    return f"claude {t}"
                if own_sid and own_sid not in (s["session_id"], (s.get("host") or {}).get("session_id")):
                    return f"another claude runs in it (pid {pid}, session {s['session_id']})"
                continue
            if name in WRAPPERS:
                todo += kids.get(pid, [])
                continue
            return f"it runs {name}"
    return ""
