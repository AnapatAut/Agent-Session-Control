"""Past conversations: ~/.claude/projects/<folder>/<session id>.jsonl, newest first.

Each transcript is read once per change (cached by mtime and size), and only its first and
last 64 KB: the folder from the first record that has `cwd`, the title from the last
`custom-title` or `agent-name` record seen. Search looks at titles and folders, never content.
"""
import glob
import json
import os
import threading

from .live import UUID_RE

CHUNK = 65536
_cache = {}
_lock = threading.Lock()


def _records(path, size):
    with open(path, "rb") as f:
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
            except ValueError:
                continue
            if isinstance(r, dict):
                yield r


def _read(path, size):
    cwd = title = None
    for r in _records(path, size):
        if cwd is None and isinstance(r.get("cwd"), str):
            cwd = r["cwd"]
        if r.get("type") in ("custom-title", "agent-name"):
            t = r.get("customTitle") or r.get("agentName")
            if isinstance(t, str):
                title = t
    return {"cwd": cwd or "", "title": title or ""}


def conversations(home=None):
    """Every past conversation as {session_id, cwd, title, mtime}, newest first."""
    home = home or os.path.expanduser("~")
    out, seen = [], set()
    for path in glob.glob(os.path.join(home, ".claude", "projects", "*", "*.jsonl")):
        sid = os.path.basename(path)[:-6]
        if not UUID_RE.fullmatch(sid):
            continue
        try:
            st = os.stat(path)
        except OSError:
            continue
        key = (st.st_mtime_ns, st.st_size)
        with _lock:
            hit = _cache.get(path)
        if hit and hit[0] == key:
            info = hit[1]
        else:
            try:
                info = _read(path, st.st_size)
            except OSError:
                continue
            with _lock:
                _cache[path] = (key, info)
        seen.add(path)
        out.append({"session_id": sid, "cwd": info["cwd"], "title": info["title"], "mtime": int(st.st_mtime)})
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
