"""The event log: what happened to each favorite, kept KEEP_DAYS (plan row 10).

<state>/events.jsonl, mode 0600, one JSON object per line:
  {"t": epoch seconds, "id4": "0421", "tmux": "das-0421", "kind": "on", "by": "cli", "text": "..."}
kind: what happened (KINDS): refused = nothing was changed; failed = it went wrong part way, after
something was changed (the text says what). by: who did it (cli, page, watch, boot; $ASC_BY, set
by the dashboard and the units; anything else counts as cli).
Appended under an flock of its own (events.lock: nothing else is locked while it is held, so it
cannot deadlock with the registry lock), one write per line, to a regular file only (a symlink or
a FIFO in its place is refused, never followed or waited on). Pruned in place when its first line
is older than KEEP_DAYS or the file grows past MAX_BYTES (then the oldest half goes): bounded
however busy the machine is. Logging never fails an action: an error is reported on stderr and
the action goes on.
"""
import contextlib
import fcntl
import glob
import json
import math
import os
import stat
import sys
import tempfile
import time
import unicodedata

from . import registry

KEEP_DAYS = 7
MAX_BYTES = 2 << 20
KINDS = {"fav", "forget", "on", "off", "restart", "rename", "rc", "resurrect", "mode", "refused",
         "failed", "ended", "restarted", "followed", "waiting", "duplicate", "memory", "setting"}
BY = {"cli", "page", "watch", "boot"}


def path(d=None):
    return os.path.join(d or registry.state_dir(), "events.jsonl")


def by():
    b = os.environ.get("ASC_BY", "")
    return b if b in BY else "cli"


def _clean(text, limit=300):
    """One line of plain text: control, format (bidi) and line-separator characters become
    spaces (a title or a folder is anyone's text)."""
    return "".join(" " if unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp", "Cs") else c
                   for c in str(text))[:limit]


def _open_regular(p, flags):
    """An fd of p, a regular file (created 0600 if missing); OSError for anything else."""
    fd = os.open(p, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(f"{p} is not a regular file")
    return fd


@contextlib.contextmanager
def _locked(d):
    fd = _open_regular(os.path.join(d, "events.lock"), os.O_RDWR | os.O_CREAT)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def log(kind, e=None, text="", d=None, **extra):
    """Append one event. e: the entry it is about (its id4 and tmux name), or None."""
    if kind not in KINDS:
        raise ValueError(f"unknown event kind {kind!r}")
    try:
        rec = {"t": int(time.time()), "kind": kind, "by": by(), "text": _clean(text)}
        if e:
            rec["id4"], rec["tmux"] = _clean(e.get("id4", ""), 4), _clean(e.get("tmux", ""), 40)
        for k, v in extra.items():  # small facts only: numbers, booleans, short text
            rec[k] = v if isinstance(v, (bool, int)) or v is None else _clean(v, 120)
        line = (json.dumps(rec, sort_keys=True) + "\n").encode("ascii")
        d = d or registry.state_dir()
        with _locked(d):
            fd = _open_regular(path(d), os.O_RDWR | os.O_APPEND | os.O_CREAT)
            try:
                os.write(fd, line)
                try:
                    _prune(d, fd)
                except Exception as x:  # the event is in; only the trim failed
                    print(f"asctl: event log not trimmed ({x})", file=sys.stderr)
            finally:
                os.close(fd)
    except Exception as x:
        print(f"asctl: event not logged ({x})", file=sys.stderr)


def _prune(d, fd):
    """Drop what is past KEEP_DAYS, and the oldest half past MAX_BYTES. With the lock held."""
    size = os.fstat(fd).st_size
    first = os.pread(fd, 4096, 0).split(b"\n", 1)[0]
    if size <= MAX_BYTES and _time(first) >= time.time() - KEEP_DAYS * 86400:
        return
    data, off = [], 0
    while off < size:
        b = os.pread(fd, min(1 << 20, size - off), off)
        if not b:
            break
        data.append(b)
        off += len(b)
    lines = b"".join(data).splitlines(keepends=True)
    cut = time.time() - KEEP_DAYS * 86400
    keep = [l for l in lines if _time(l) >= cut]
    while keep and sum(map(len, keep)) > MAX_BYTES // 2 and size > MAX_BYTES:
        keep = keep[len(keep) // 2:]
    for old in glob.glob(os.path.join(d, ".events.*")):  # left by a prune that was killed
        with contextlib.suppress(OSError):
            if time.time() - os.lstat(old).st_mtime > 3600:
                os.unlink(old)
    tfd, tmp = tempfile.mkstemp(prefix=".events.", dir=d)
    try:
        with os.fdopen(tfd, "wb") as f:
            f.writelines(keep)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path(d))
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def _time(line):
    """The time of one line, or 0 when broken or not a plausible time (so it is pruned)."""
    try:
        r = json.loads(line)
    except (ValueError, RecursionError):
        return 0
    t = r.get("t") if isinstance(r, dict) else None
    ok = isinstance(t, (int, float)) and not isinstance(t, bool) and math.isfinite(t)
    return t if ok and 0 < t <= time.time() + 86400 else 0


def read(id4=None, limit=200, d=None):
    """The latest events (newest first), of one favorite or all; lines that do not parse or do
    not look like an event are skipped."""
    if limit <= 0:
        return []
    try:
        fd = os.open(path(d), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return []
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return []
        start = max(0, st.st_size - 2 * MAX_BYTES)  # the newest part, if pruning ever failed
        lines = os.pread(fd, st.st_size - start, start).splitlines()
    finally:
        os.close(fd)
    if start:
        lines = lines[1:]  # cut part way
    out = []
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if (not isinstance(r, dict) or not _time(line) or r.get("kind") not in KINDS
                or not all(isinstance(r.get(k, ""), str) for k in ("by", "id4", "tmux", "text"))):
            continue
        if id4 is not None and r.get("id4") != id4:
            continue
        out.append(r)
        if len(out) >= limit:
            break
    return out
