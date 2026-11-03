"""Past conversations: ~/.claude/projects/<folder>/<session id>.jsonl, newest first.

Each transcript is read once per change (cached by mtime and size), and only its first and
last 64 KB: the folder from the first record that has `cwd`, the title from the last
`custom-title` or `agent-name` record seen, else the last `ai-title` (claude's own summary, also the
name the Claude apps list). Search looks at titles and folders, never content.

The length of a favorite's conversation (its transcript's lines and bytes) is counted by the
watcher into lengths.json in the state folder: only what was added since the last count is read
(a transcript only grows; one that shrank or was replaced is counted again), at most READ_PER_RUN
bytes per run and dropped from the page cache after (a first count of a large one goes on over
a few runs, and is not shown until it is done). Claude Code does not send a conversation of
over 100,000 lines to claude.ai (no history, no new title), so the dashboard shows the count.
"""
import contextlib
import glob
import json
import os
import stat
import threading

from . import live, registry
from .live import UUID_RE

CHUNK = 65536
LENGTHS = "lengths.json"
READ_PER_RUN = 64 << 20
_cache = {}
_lock = threading.Lock()


def _records(path, size):
    f = live.open_regular(path)
    if f is None:
        return
    with f:
        head = f.read(CHUNK)
        tail = b""
        if size > CHUNK:
            f.seek(max(CHUNK, size - CHUNK))
            tail = f.read(CHUNK)
    for chunk, first in ((head, True), (tail, False)):
        lines = chunk.split(b"\n")
        # A chunk cut mid-line: drop the cut ends (the head's last line, the tail's first).
        if first and size > CHUNK:
            lines = lines[:-1]
        elif not first:
            lines = lines[1:]
        for line in lines:
            try:
                r = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if isinstance(r, dict):
                yield r


def _read(path, size):
    cwd = title = ai = None
    for r in _records(path, size):
        if cwd is None and isinstance(r.get("cwd"), str):
            cwd = r["cwd"]
        if r.get("type") in ("custom-title", "agent-name"):
            t = r.get("customTitle") or r.get("agentName")
            if isinstance(t, str):
                title = t
        elif r.get("type") == "ai-title" and isinstance(r.get("aiTitle"), str):
            ai = r["aiTitle"]
    return {"cwd": cwd or "", "title": (title or ai or "")[:200]}


def _info(path):
    """The transcript's {cwd, title}, read again only when it changed; None if no regular file."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return None  # a symlink, FIFO or device: never opened
    key = (st.st_mtime_ns, st.st_size)
    with _lock:
        hit = _cache.get(path)
    if hit and hit[0] == key:
        return dict(hit[1], mtime=int(st.st_mtime))
    try:
        info = _read(path, st.st_size)
    except OSError:
        return None
    with _lock:
        _cache[path] = (key, info)
    return dict(info, mtime=int(st.st_mtime))


def title(sid, home=None):
    """The title of a running conversation, or ""."""
    home = home or os.path.expanduser("~")
    for path in glob.glob(os.path.join(home, ".claude", "projects", "*", f"{sid}.jsonl")):
        info = _info(path)
        if info and info["title"]:
            return info["title"]
    return ""


def conversations(home=None):
    """Every past conversation as {session_id, cwd, title, mtime}, newest first."""
    home = home or os.path.expanduser("~")
    out, seen = [], set()
    for path in glob.glob(os.path.join(home, ".claude", "projects", "*", "*.jsonl")):
        sid = os.path.basename(path)[:-6]
        if not UUID_RE.fullmatch(sid):
            continue
        info = _info(path)
        if info is None:
            continue
        seen.add(path)
        out.append({"session_id": sid, "cwd": info["cwd"], "title": info["title"], "mtime": info["mtime"]})
    with _lock:
        for p in [p for p in _cache if p not in seen]:
            del _cache[p]
    out.sort(key=lambda c: c["mtime"], reverse=True)
    return out


def search(q, exclude=(), limit=50, home=None):
    q = (q or "").strip().lower()
    hits = [c for c in conversations(home) if c["session_id"] not in exclude
            and (not q or q in c["title"].lower() or q in c["cwd"].lower())]
    return hits[:limit]


def _transcript(sid, home):
    """The transcript of a conversation: the one written last when a folder move left two."""
    def mtime(p):
        try:
            return os.lstat(p).st_mtime
        except OSError:
            return 0
    paths = glob.glob(os.path.join(home, ".claude", "projects", "*", f"{sid}.jsonl"))
    return max(sorted(paths), key=mtime) if paths else None


def _entry(x):
    """A lengths.json entry, or None: ino, size (read so far), lines (in that), seen (the file's
    size when last looked at)."""
    ok = isinstance(x, dict) and all(type(x.get(k)) is int and x[k] >= 0 for k in ("ino", "size", "lines", "seen"))
    return x if ok and x["size"] <= x["seen"] else None


def lengths(d):
    """{session id: {"lines": n, "bytes": n}} of each transcript counted to its end when last
    looked at (one still being counted for the first time is left out)."""
    got = registry.read_private(os.path.join(d, LENGTHS), limit=4 << 20)
    return {k: {"lines": v["lines"], "bytes": v["size"]} for k, v in (got.items() if isinstance(got, dict) else [])
            if isinstance(k, str) and _entry(v) and v["size"] == v["seen"]}


def update_lengths(sids, d, home=None, budget=READ_PER_RUN):
    """Count on the lines of each of these conversations' transcripts (the watcher, every run);
    the others are dropped from lengths.json."""
    home = home or os.path.expanduser("~")
    path = os.path.join(d, LENGTHS)
    got = registry.read_private(path, limit=4 << 20)
    old = got if isinstance(got, dict) else {}
    new = {}
    for sid in sorted(s for s in set(sids) if isinstance(s, str) and UUID_RE.fullmatch(s)):
        c = _entry(old.get(sid))
        p = _transcript(sid, home)
        f = live.open_regular(p) if p else None
        if f is None:
            continue
        with f:
            st = os.fstat(f.fileno())
            if c is None or c["ino"] != st.st_ino or c["size"] > st.st_size:
                c = {"ino": st.st_ino, "size": 0, "lines": 0}  # new, replaced or shrunk: from the start
            start = c["size"]
            f.seek(start)
            while c["size"] < st.st_size and budget > 0:
                b = f.read(min(1 << 20, st.st_size - c["size"], budget))
                if not b:
                    break
                c = dict(c, size=c["size"] + len(b), lines=c["lines"] + b.count(b"\n"))
                budget -= len(b)
            if c["size"] - start > 1 << 20:  # a large read: not kept in memory for this
                with contextlib.suppress(OSError, AttributeError):
                    os.posix_fadvise(f.fileno(), start, c["size"] - start, os.POSIX_FADV_DONTNEED)
        new[sid] = dict(c, seen=st.st_size)
    if new != old:
        registry.write_private(path, new)
    return new
