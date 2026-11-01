"""Running claudes, from Claude Code's own session files, each checked against /proc.

~/.claude/sessions/<pid>.json is Claude Code's undocumented format: a file whose fields are
missing or unexpected gives a session marked unknown, and nothing acts on it. A file only
counts as live when it is named <pid>.json, its pidDomain (if any) is this machine and PID
namespace, and its PID runs, is named `claude` and started at the recorded procStart (so a
reused PID, a copied file or one left by a SIGKILL is not taken for a live claude).
"""
import glob
import json
import os
import re
import stat

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SHELLS = {"bash", "zsh", "sh", "dash", "fish", "ksh", "tcsh", "csh"}
# Looked through like a shell when checking what a pane runs (a shebang script's process
# name is its file name).
WRAPPERS = SHELLS | {"asctl-wrap"}


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
    """(name, ppid, starttime) of a PID, or None."""
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
        return s[i + 1:j], int(rest[1]), rest[19]
    except (IndexError, ValueError):
        return None


def alive(pid, proc_start):
    st = proc_stat(pid)
    return st is not None and st[0] == "claude" and proc_start is not None and st[2] == str(proc_start)


def _pid_domain():
    try:
        with open("/etc/machine-id", encoding="utf-8") as f:
            mid = f.read().strip()
        return f"linux:{mid}:{os.readlink('/proc/self/ns/pid')}"
    except OSError:
        return None


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
             "status": raw.get("status") if raw.get("status") in ("busy", "idle", "shell", "waiting") else "unknown",
             "rc": bool(raw.get("bridgeSessionId")), "kind": raw.get("kind"),
             "proc_start": raw.get("procStart")}
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
        if (st and st[0] == "claude") or (session_id and session_id in s.get("text", "")):
            out.append(s["file"])
    return out


def live(home=None, pane_list=None):
    """Live interactive claudes, each with the tmux pane it runs in (or None)."""
    from . import tmuxctl
    pane_list = tmuxctl.panes() if pane_list is None else pane_list
    by_pid = {p["pane_pid"]: p for p in pane_list}
    out = []
    for s in read_sessions(home):
        if not s["live"]:
            continue
        s["pane"] = next((by_pid[a] for a in ancestors(s["pid"]) if a in by_pid), None)
        out.append(s)
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


def tree_rss_kb(pid, kids):
    """RSS of a process and all its descendants (a pane: claude, its MCP servers, a browser)."""
    total, todo, seen = 0, [pid], set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        total += rss_kb(p)
        todo += [c for c, _ in kids.get(p, [])]
    return total


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
    kids = children_map() if kids is None else kids
    for p in tmuxctl.panes(session_name) if pane_list is None else pane_list:
        todo = [(p["pane_pid"], (proc_stat(p["pane_pid"]) or ("?",))[0])]
        while todo:
            pid, name = todo.pop()
            if name == "claude":
                s = known.get(pid)
                if s is None:
                    return f"pane {p['pane_id']} runs a claude asctl cannot read ({pid})"
                if s["status"] == "busy":
                    return f"the claude in pane {p['pane_id']} is working"
                if own_sid and s["session_id"] != own_sid:
                    return f"pane {p['pane_id']} runs another claude ({pid}, session {s['session_id']})"
                continue
            if name in WRAPPERS:
                todo += kids.get(pid, [])
                continue
            return f"pane {p['pane_id']} runs {name}"
    return ""
