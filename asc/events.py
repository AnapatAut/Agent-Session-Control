"""The event log: what happened to each favorite, its last KEEP_PER events (plan row 10).

<state>/events.jsonl, mode 0600, one JSON object per line:
  {"t": epoch seconds, "id4": "0421", "tmux": "das-0421", "kind": "on", "by": "cli", "text": "..."}
kind: what happened (KINDS): refused = nothing was changed; failed = it went wrong part way, after
something was changed (the text says what). by: who did it (cli, page, watch, boot; $ASC_BY, set
by the dashboard and the units; anything else counts as cli).
Appended under an flock of its own (events.lock: nothing else is locked while it is held, so it
cannot deadlock with the registry lock), one write per line, to a regular file only (a symlink or
a FIFO in its place is refused, never followed or waited on). Pruned in place: a favorite keeps
its last KEEP_PER events however old (cut back to that once it has KEEP_SLACK more, so the file
is not rewritten on every event); anything else (an event of no favorite, of one forgotten since,
or from before its id was forgotten and drawn again) goes after KEEP_DAYS. Past MAX_BYTES it is
cut to half that: the oldest of those other events first, then each favorite's oldest, as evenly
as halving how many each keeps allows: bounded however busy the machine is. Logging never fails
an action: an error is reported on stderr and the action goes on.
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

KEEP_PER = 200
KEEP_SLACK = 50
KEEP_DAYS = 7
MAX_BYTES = 2 << 20
CHECK_BYTES = 16000  # a favorite's line is over 80 bytes: under this none can have KEEP_PER
KINDS = {"fav", "new", "forget", "on", "off", "restart", "rename", "rc", "resurrect", "mode", "refused",
         "failed", "ended", "restarted", "followed", "waiting", "duplicate", "memory", "setting",
         "setup", "trusted", "untrusted", "mcp", "prompt"}
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


def _favorites(d):
    """The id4s of the favorites now, or None when the registry does not read (then every id4
    counts as one: nothing of a favorite is dropped for its age)."""
    try:
        return set(registry.load(d)["entries"])
    except Exception:
        return None


def _prune(d, fd):
    """Keep each favorite's last KEEP_PER events, anything else for KEEP_DAYS, and past
    MAX_BYTES only half that (see the top). With the lock held; the file is rewritten only when
    a line has to go."""
    size = os.fstat(fd).st_size
    first = os.pread(fd, 4096, 0).split(b"\n", 1)[0]
    cut = time.time() - KEEP_DAYS * 86400
    if size <= CHECK_BYTES and _time(first) >= cut:
        return
    data, off = [], 0
    while off < size:
        b = os.pread(fd, min(1 << 20, size - off), off)
        if not b:
            break
        data.append(b)
        off += len(b)
    lines = b"".join(data).splitlines(keepends=True)
    # newest first: each favorite's lines ranked back to its forget; the rest, if not too old
    favs, rank, gone, mine, other, drop = _favorites(d), {}, set(), [], [], False
    for i in range(len(lines) - 1, -1, -1):
        t, id4, kind = _meta(lines[i])
        if not t:
            drop = True  # broken
            continue
        fav = bool(id4) and id4 not in gone and (favs is None or id4 in favs)
        if fav and kind == "forget":  # it and what came before belong to an earlier favorite
            gone.add(id4)
            fav = False
        if fav:
            rank[id4] = rank.get(id4, -1) + 1
            mine.append((rank[id4], i))
            drop |= rank[id4] + 1 >= KEEP_PER + KEEP_SLACK
        elif t >= cut:
            other.append(i)
        else:
            drop = True  # too old
    per, n_other = KEEP_PER, len(other)
    total = lambda: sum(len(lines[i]) for r, i in mine if r < per) + sum(len(lines[i]) for i in other[:n_other])
    if size > MAX_BYTES:
        drop = True
        while n_other and total() > MAX_BYTES // 2:
            n_other //= 2
        while per > 1 and total() > MAX_BYTES // 2:
            per //= 2
    if not drop:
        return
    kept = sorted([i for r, i in mine if r < per] + other[:n_other])
    keep = [lines[i] for i in kept]
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
    return _meta(line)[0]


def _meta(line):
    """(time, id4, kind) of one line; time 0 when broken or not a plausible time."""
    try:
        r = json.loads(line)
    except (ValueError, RecursionError):
        return 0, "", ""
    if not isinstance(r, dict):
        return 0, "", ""
    t, id4, kind = r.get("t"), r.get("id4"), r.get("kind")
    return (t if _plausible(t) else 0, id4 if isinstance(id4, str) else "", kind if isinstance(kind, str) else "")


def _plausible(t):
    ok = isinstance(t, (int, float)) and not isinstance(t, bool) and math.isfinite(t)
    return ok and 0 < t <= time.time() + 86400


def read(id4=None, limit=KEEP_PER, d=None):
    """The latest events (newest first), of all or of one favorite: back to its id's last forget,
    which ended an earlier favorite of that id. Lines that do not parse or do not look like an
    event are skipped."""
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
        if (not isinstance(r, dict) or not _plausible(r.get("t")) or r.get("kind") not in KINDS
                or not all(isinstance(r.get(k, ""), str) for k in ("by", "id4", "tmux", "text"))):
            continue
        if id4 is not None and r.get("id4") != id4:
            continue
        if id4 is not None and r["kind"] == "forget":
            break
        out.append(r)
        if len(out) >= limit:
            break
    return out
