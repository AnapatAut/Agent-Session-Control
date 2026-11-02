"""The registry: favorited sessions, one JSON file, changed only under a lock.

~/.local/state/agent-session-control/registry.json (or $XDG_STATE_HOME/...), mode 0600.
Every change is read-modify-write under an exclusive flock on registry.lock, written to a
temp file, fsynced and renamed into place, so a crash leaves the old or the new file.
Fields this version does not know are kept on rewrite.
"""
import contextlib
import fcntl
import json
import os
import re
import secrets
import tempfile
import time

VERSION = 1
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,30}")
ID4_RE = re.compile(r"[0-9]{4}")
MODES = {"auto": "auto", "manual": "manual", "skip": "bypassPermissions"}


class RegistryError(Exception):
    pass


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    d = os.path.join(base, "agent-session-control")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _path(d):
    return os.path.join(d, "registry.json")


def load(d=None):
    d = d or state_dir()
    try:
        with open(_path(d), encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"version": VERSION, "entries": {}}
    except ValueError as e:
        raise RegistryError(f"{_path(d)} is not valid JSON ({e}); fix or move it, nothing changed")
    if not isinstance(data, dict) or not isinstance(data.get("entries"), dict):
        raise RegistryError(f"{_path(d)} has no 'entries' object; nothing changed")
    if data.get("version", VERSION) > VERSION:
        raise RegistryError(f"{_path(d)} is version {data['version']}, newer than this asctl ({VERSION})")
    return data


def save(data, d=None):
    d = d or state_dir()
    data["version"] = max(VERSION, data.get("version", VERSION))
    fd, tmp = tempfile.mkstemp(prefix=".registry.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, _path(d))
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


@contextlib.contextmanager
def changing(d=None):
    """Yield the loaded registry under the lock; save it if the block ends without an error."""
    d = d or state_dir()
    fd = os.open(os.path.join(d, "registry.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        data = load(d)
        yield data
        save(data, d)
    finally:
        os.close(fd)


@contextlib.contextmanager
def entry_lock(id4, d=None, wait=False):
    """Hold a lock for one entry while it is started or stopped (a double click, the timer)."""
    d = d or state_dir()
    os.makedirs(os.path.join(d, "locks"), mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(d, "locks", id4), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            raise RegistryError(f"{id4} is being started or stopped by another asctl; try again")
        yield
    finally:
        os.close(fd)


def check_name(name):
    if not NAME_RE.fullmatch(name or ""):
        raise RegistryError(f"bad name {name!r}: 1-31 of a-z 0-9 -, starting with a letter or digit")
    return name


def _plain(text, what, limit):
    if not isinstance(text, str) or len(text) > limit or any(ord(c) < 32 or 0x7f <= ord(c) < 0xa0 for c in text):
        raise RegistryError(f"bad {what}: at most {limit} characters, no control characters")
    return text


def check_title(title):
    """An rc title: shown on claude.ai, passed to claude as one argument (never starting with
    "-", which claude would read as an option)."""
    t = _plain(title, "title", 80).strip()
    if not t or t.startswith("-"):
        raise RegistryError("bad title: empty, or starts with -")
    if t.endswith(";"):  # tmux reads a final ";" as the end of its command and drops it
        raise RegistryError("bad title: ends with ;")
    return t


def check_note(note):
    return _plain(note, "note", 500)


def slug(text):
    """A name from free text (a session name, a folder): lower case, a-z 0-9 -."""
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")[:31].strip("-")
    return s or "session"


def new_id4(data, taken_tmux=()):
    used = {e.get("id4") for e in data["entries"].values()}
    for _ in range(200):
        id4 = f"{secrets.randbelow(10000):04d}"
        if id4 not in used and not any(t.endswith("-" + id4) for t in taken_tmux):
            return id4
    raise RegistryError("no free 4-digit id after 200 tries")


def find(data, ref):
    """An entry by its id4 or its full tmux name."""
    e = data["entries"].get(ref)
    if e:
        return e
    for e in data["entries"].values():
        if e.get("tmux") == ref:
            return e
    raise RegistryError(f"no favorite {ref!r} (see: asctl list)")


def now():
    return int(time.time())
