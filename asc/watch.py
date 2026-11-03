"""The watcher: one short run every 30 s (asctl-watch.timer runs `asctl watch`).

Each run, one at a time (watch.lock; a run that finds another still going does nothing):
 1. a memory sample (asc/memory.py), kept for the steady check and as evidence; a warning (an
    event and a tmux message) when available memory falls under WARN_PCT, and when it is back;
 2. two live claudes holding one session id: logged once (nothing is done about it);
 3. for each favorite whose claude runs in its own tmux session (and no other claude does):
    - its memory (PSS of its pane tree) kept as rss_kb, the size the memory gate expects;
    - followed: a new session id (a branch, a rewind, /resume inside claude) into lineage, a
      new folder (/cd);
    - a rename asctl could not send because claude was busy (rename_pending) sent once idle;
    - an exit record older than that claude dropped (it ended before this claude was started);
 4. a favorite that is wanted on whose claude ended while its tmux session stayed: logged once
    with its exit code and the memory evidence. Started again (in its own pane, which keeps the
    session and anyone attached) only when every one holds (plan row 7): auto-restart is on
    (asctl auto-restart on; off by default), it ended by a signal (143 SIGTERM, 137 SIGKILL) in
    this boot under an hour ago, memory pressure was seen around then, memory has been steady at
    START_PCT for 5 min and has room for it, it was not started again in the last 30 min, its
    session is that one pane, still the shell asctl-wrap left (the PID in the exit record),
    running nothing, not scrolled back and with no one typing in the last 2 min (cli.pane_free,
    checked again just before), and no other restart in this run.
 5. the length of each favorite's conversation counted on (asc/past.py, lengths.json).
watch.json keeps what a run tells the next, and "at", when the last run began (the dashboard
warns when that is old: the timer stopped). Every entry is handled under its own lock, taken
without waiting: one that an asctl action holds is left to the next run. An error with one entry
is logged and the others go on. A favorite's want_on is never changed here (plan row 16: only
On, Off and Forget change it).
"""
import fcntl
import os
import re
import sys
import time

from . import cli, events, live, memory, past, rclive, registry, tmuxctl

RESTART_EVERY = 1800   # at most one automatic restart of a favorite per 30 min
RESTART_WITHIN = 3600  # and only for an end at most this old
RENAME_TRIES = 3       # a pending rename that fails after typing this often is dropped
SIZE_CHANGE = 0.10     # rss_kb is rewritten only when it moved by more than this


def _state(d):
    """watch.json, with every part checked (a broken file starts afresh, it decides nothing)."""
    s = registry.read_private(os.path.join(d, "watch.json"))
    s = s if isinstance(s, dict) else {}
    d = lambda k: s.get(k) if isinstance(s.get(k), dict) else {}
    ok = lambda x: (isinstance(x, dict) and isinstance(x.get("key"), str) and isinstance(x.get("reason"), str)
                    and x.get("has") in (True, False, None) and (x.get("proof") is None or isinstance(x.get("proof"), str)))
    return {"warned": s.get("warned") is True,
            "dups": [x for x in s.get("dups", []) if isinstance(x, str)] if isinstance(s.get("dups"), list) else [],
            "ended": {k: x for k, x in d("ended").items() if ok(x)},
            "rename_tries": {k: v for k, v in d("rename_tries").items() if type(v) is int},
            "failed": {k: v for k, v in d("failed").items() if isinstance(v, str)}}


def run():
    d = registry.state_dir()
    fd = os.open(os.path.join(d, "watch.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        st = _state(d)
        st["at"] = int(time.time())
        try:
            _run(st)
        finally:
            registry.write_private(os.path.join(d, "watch.json"), st)
        _lengths(d)
        return 0
    finally:
        os.close(fd)


def _run(st):
    samples = memory.add_sample(memory.sample())
    _memory_warning(st, samples[-1])
    data = registry.load()
    for k in ("ended", "rename_tries", "failed"):  # forgotten favorites
        st[k] = {i: v for i, v in st[k].items() if i in data["entries"]}
    if not tmuxctl.server_running():
        return
    lv = live.live()
    _duplicates(st, lv, data)
    up = set(tmuxctl.sessions())
    kids = live.children_map()
    run = {"restarted": False}  # one restart per run: set the moment one is attempted
    for e in sorted(data["entries"].values(), key=lambda e: e["id4"]):
        before = run["restarted"]
        try:
            with registry.entry_lock(e["id4"]):
                e = registry.find(registry.load(), e["id4"])  # as it is now, under its lock
                s = cli.live_in(e, lv)
                if s:
                    _running(st, e, s, lv, kids)
                elif e.get("want_on") and e["tmux"] in up:
                    _ended(st, e, samples, run)
                else:
                    st["ended"].pop(e["id4"], None)
            st["failed"].pop(e["id4"], None)
        except registry.RegistryError:
            continue  # an action holds it (or it was forgotten): the next run looks again
        except Exception as x:
            msg = f"watch: {type(x).__name__}: {x}"
            if st["failed"].get(e["id4"]) != msg:  # the same error each run is said once
                events.log("failed", e, msg)
            st["failed"][e["id4"]] = msg
        if run["restarted"] and not before:  # a restart takes a while: what was read is old
            lv, up, kids = live.live(), set(tmuxctl.sessions()), live.children_map()


def _lengths(d):
    """Count on the favorites' conversation lengths: last, as it reads the most; an error only
    makes the count late (nothing else depends on it)."""
    try:
        past.update_lengths([e.get("session_id") for e in registry.load()["entries"].values()], d)
    except Exception as x:
        print(f"asctl watch: conversation lengths not counted ({type(x).__name__}: {x})", file=sys.stderr)


def _set(e, expect, changes):
    """Change an entry (its lock held) if it still has the expected values; True when changed."""
    with registry.changing() as data:
        x = data["entries"].get(e["id4"])
        if not x or any(x.get(k) != v for k, v in expect.items()):
            return False
        x.update(changes)
    e.update(changes)
    return True


def _memory_warning(st, s):
    pct = s["avail_pct"]
    if pct < memory.WARN_PCT and not st["warned"]:
        st["warned"] = True
        msg = f"memory low: {pct}% available (under {memory.WARN_PCT}%); starts wait for {memory.START_PCT}%"
        events.log("memory", None, msg)
        _tell_tmux("asctl: " + msg)
    elif pct >= memory.WARN_PCT + 1 and st["warned"]:  # 1 point over, so it does not flap
        st["warned"] = False
        events.log("memory", None, f"memory back: {pct}% available")


def _tell_tmux(msg):
    """The message on every attached tmux client, for 10 s (a status-line note, nothing typed)."""
    r = tmuxctl.run("list-clients", "-F", "#{client_name}")
    for c in r.stdout.split() if r.returncode == 0 else []:
        tmuxctl.run("display-message", "-c", c, "-d", "10000", msg.replace("#", "##"))


def _duplicates(st, lv, data):
    count = {}
    for s in lv:
        count.setdefault(s["session_id"], []).append(s["pid"])
    dups = sorted(sid for sid, pids in count.items() if len(pids) > 1)
    entries = {e.get("session_id"): e for e in data["entries"].values()}
    for sid in sorted(set(dups) - set(st["dups"])):
        events.log("duplicate", entries.get(sid), f"{len(count[sid])} live claudes hold session {sid} "
                   f"(pids {', '.join(map(str, count[sid]))}); asctl acts on none of them by itself")
    st["dups"] = dups


def _running(st, e, s, lv, kids):
    st["ended"].pop(e["id4"], None)
    if sum(1 for x in lv if x["pane"] and x["pane"]["session"] == e["tmux"]) != 1:
        return  # not only its own claude in the session: nothing here is sure to be about it
    panes = tmuxctl.panes(e["tmux"], strict=True)
    kb = sum(live.tree_mem_kb(p["pane_pid"], kids) for p in panes or [])
    kb += live.tree_mem_kb(s["pid"], kids) if s.get("host") else 0
    old = e.get("rss_kb")
    if panes and kb and (type(old) is not int or old <= 0 or abs(kb - old) / old > SIZE_CHANGE):
        _set(e, {"rss_kb": old}, {"rss_kb": kb})
    sid = s["session_id"]
    if sid != e.get("session_id"):
        held = any(x.get("session_id") == sid for x in registry.load()["entries"].values())
        was = e.get("session_id")
        lineage = [x for x in e.get("lineage", []) if isinstance(x, str)] if isinstance(e.get("lineage"), list) else []
        if not held and _set(e, {"session_id": was}, {"session_id": sid, "lineage": ([was] + lineage)[:5]}):
            events.log("followed", e, f"its claude now holds session {sid} (was {was}): a branch, a rewind "
                       f"or a /resume inside claude")
    if s["cwd"] != e.get("cwd") and os.path.isdir(s["cwd"]):
        was = e.get("cwd")
        if _set(e, {"cwd": was}, {"cwd": s["cwd"]}):
            events.log("followed", e, f"its claude moved to {s['cwd']} (was {was})")
    ex = cli.last_exit_full(e["id4"])
    if ex and s.get("started_at") and s["started_at"] >= ex[1]:
        # it ended before this claude was started (by hand in the pane): never act on it again
        try:
            os.unlink(cli.exit_file(e["id4"]))
        except FileNotFoundError:
            pass
    if s["session_id"] == e.get("session_id"):
        _pending_rename(st, e, s)


def _pending_rename(st, e, s):
    tries = st["rename_tries"]
    pend = e.get("rename_pending")
    if not pend:
        tries.pop(e["id4"], None)
        return
    if pend != e["tmux"] or s["name"] == pend:  # renamed again since, or claude has it now
        _set(e, {"rename_pending": pend}, {"rename_pending": None})
        tries.pop(e["id4"], None)
        return
    if rclive.guard(s) is not None:  # busy, waiting, typing: the next run
        return
    why = rclive.rename(s, pend)
    if not why:
        _set(e, {"rename_pending": pend}, {"rename_pending": None})
        tries.pop(e["id4"], None)
        events.log("rename", e, f"claude took the name {pend} now that it is idle, its claude.ai title too")
        return
    tries[e["id4"]] = tries.get(e["id4"], 0) + 1
    if tries[e["id4"]] >= RENAME_TRIES:
        _set(e, {"rename_pending": pend}, {"rename_pending": None})
        tries.pop(e["id4"], None)
        events.log("failed", e, f"rename: claude did not take the name {pend} after {RENAME_TRIES} tries ({why}); "
                   f"rename it again by hand")


def _ended(st, e, samples, run):
    """A favorite wanted on whose claude is gone and whose tmux session is up (its lock held)."""
    ex = cli.last_exit_full(e["id4"])
    key = f"{ex[0]}:{ex[1]}" if ex else "none"
    prev = st["ended"].get(e["id4"], {})
    same = prev.get("key") == key
    if ex is None:
        has, proof = None, None
        why = "no exit record (claude was not started by asctl, or the record is gone)"
    else:
        # the evidence as first found: the samples around the end are dropped after KEEP_S
        # (found means True or False; None, not yet told, is asked again while samples come in)
        has, proof = ((prev["has"], prev["proof"]) if same and prev.get("has") is not None
                      else memory.evidence(samples, ex[1]))
        why = _why_not(e, ex, has, proof, run["restarted"], samples)
    reason = re.sub(r"[0-9][0-9.]*", "N", why)  # the same reason with other numbers is not news
    if not same:
        how = "no exit record" if ex is None else f"exit {ex[0]}" + (" (a signal)" if ex[0] in (137, 143) else "")
        events.log("ended", e, f"claude ended, {how}, its tmux session up" + (f"; memory: {proof}" if proof else "")
                   + (f"; not started again: {why}" if why else ""), code=ex[0] if ex else None)
    elif why and reason != prev.get("reason") and not why.startswith("another restart"):
        events.log("waiting", e, f"not started again yet: {why}")
    st["ended"][e["id4"]] = {"key": key, "reason": reason, "has": has, "proof": proof}
    if why:
        return
    why = _restart(e, ex, proof, run)
    if not why:
        return
    reason = re.sub(r"[0-9][0-9.]*", "N", why)  # On refused it: nothing was changed
    if reason != st["ended"][e["id4"]]["reason"]:
        events.log("waiting", e, f"not started again yet: {why}")
    st["ended"][e["id4"]]["reason"] = reason


def _why_not(e, ex, has, proof, busy_run, samples):
    code, t, boot, pid = ex
    settings = registry.load().get("settings")
    if not isinstance(settings, dict) or settings.get("auto_restart") is not True:
        return "auto-restart is off (asctl auto-restart on)"
    if code not in (137, 143):
        return "it did not end by a signal"
    if not boot or boot != memory.boot_id():
        return "it ended before this boot"
    if time.time() - t > RESTART_WITHIN:
        return f"it ended over {RESTART_WITHIN // 60} min ago"
    if has is not True:  # None: no sample after the end yet, the next run tells
        return proof or "no memory evidence"
    if pid is None:
        return "its exit record names no pane (an asctl-wrap from before this check)"
    last = e.get("auto_restarted") if type(e.get("auto_restarted")) is int else 0
    if abs(time.time() - last) < RESTART_EVERY:  # abs: a stamp from a clock that ran ahead
        return f"it was started again under {RESTART_EVERY // 60} min ago"
    if busy_run:
        return "another restart in this run (one at a time)"
    panes = tmuxctl.panes(e["tmux"], strict=True)
    if panes is None:
        return "tmux did not list its panes"
    if len(panes) != 1:
        return f"its tmux session has {len(panes)} panes (started again only in a session of one)"
    why = cli.pane_free(e, panes[0]["pane_id"], pid)
    if why:
        return why
    return memory.steady(samples)  # the gate (room for its size) is On's own


def _restart(e, ex, proof, run):
    """Claude again in the entry's one pane, through On's own checks (its lock held): "" when
    it was started or attempted (stamped, and counted for this run, the moment nothing can refuse
    it any more, whatever happens after), else why On refused (nothing changed)."""
    panes = tmuxctl.panes(e["tmux"], strict=True)
    if not panes or len(panes) != 1:
        return "its tmux session changed"
    def starting():
        run["restarted"] = True
        _set(e, {}, {"auto_restarted": int(time.time())})
    try:
        r = cli._on(e["id4"], False, loud=False, pane=panes[0]["pane_id"], pane_pid=ex[3], starting=starting)
    except registry.RegistryError as x:
        if not run["restarted"]:
            return str(x)
        events.log("failed", e, f"start again after exit {ex[0]}: {x}")
        return ""
    if r == 0:
        events.log("restarted", e, f"started again after exit {ex[0]} ({proof})")
    return ""
