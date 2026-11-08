"""asctl boot (asctl-boot.service, once per boot): the favorites with resurrect on that were on
start again, one at a time.

want_on changes only by the user's On, Off and Forget, so after a reboot it still says which were
on. Each start needs the memory gates: memory at 20% steady for 5 min (asctl boot takes a sample
every 30 s itself, as the watcher does, so the first start comes 5 min after the boot at the
earliest) and room for that claude's size. Before the first start it waits up to 2 min for
claude.ai to answer (a resurrect start has remote control), then starts anyway: a remote control
that does not come up shows on the dashboard. A favorite whose tmux session is up already, or
whose conversation a live claude holds, is left alone (the watcher looks after the first). What
waits is logged once per reason; after --wait seconds the rest are left, each with a "refused"
event (Start them by hand). After a tmux server that ended without a reboot, run it again:
systemctl --user start asctl-boot.service. While it runs, boot.json in the state folder says
what it still brings back and what it waits for (the dashboard shows it, while boot.lock is
held); "done" once it ends, also when stopped (SIGTERM ends it as an exit, not a kill).
"""
import fcntl
import os
import re
import signal
import socket
import sys
import time

from . import cli, events, memory, registry, tmuxctl
from .registry import RegistryError

TICK_S = 30   # while waiting: a sample and another look this often (the watcher's timer too)
PAUSE_S = 30  # after a start, before the next: the next sample shows what the last one took
NET = "claude.ai:443"  # $ASC_NET: what must answer before the first start
NET_TRY_S = 5
STATUS = "boot.json"


def run(wait=3600, net_wait=120):
    d = registry.state_dir()
    fd = os.open(os.path.join(d, "boot.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RegistryError("another asctl boot is running")
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # stopped: its finally still runs
        try:
            return _run(time.time() + max(wait, 0), max(wait, 0), net_wait)
        finally:
            _status([], "", done=True)
    finally:
        os.close(fd)


def _status(todo, why, done=False):
    """boot.json: the id4s still to bring back (the next first; one turned off, resurrect off or
    forgotten since is left out) and why the next waits ("" when it does not); read by the
    dashboard, so a failure to write it changes nothing here."""
    try:
        if todo:
            es = registry.load()["entries"]
            todo = [i for i in todo if es.get(i, {}).get("resurrect") is True and es[i].get("want_on") is True]
        registry.write_private(os.path.join(registry.state_dir(), STATUS),
                               {"boot": memory.boot_id(), "at": int(time.time()), "todo": list(todo), "why": why, "done": done})
    except (OSError, RegistryError):
        pass


def _todo():
    """The id4s to bring back, the one turned on last first."""
    xs = [e for e in registry.load()["entries"].values() if e.get("resurrect") is True and e.get("want_on") is True]
    return [e["id4"] for e in sorted(xs, key=lambda e: (-(e.get("last_on") if type(e.get("last_on")) is int else 0), e["id4"]))]


def _run(deadline, wait, net_wait):
    todo = _todo()
    if not todo:
        cli.out("boot: no favorite with resurrect on was on")
        return 0
    try:
        cli.ensure_server()
    except RegistryError as x:
        events.log("failed", None, f"boot: {x}")
        raise
    _status(todo, "network: waiting for claude.ai to answer")
    _network(net_wait)
    said, started = {}, []
    while todo:
        e = registry.load()["entries"].get(todo[0])
        try:
            why = _skip(e)
        except tmuxctl.NoAnswer as x:  # what runs is not known: nothing more is started
            events.log("failed", e, f"boot: {x}; nothing more started")
            raise
        if why is not None:
            if why:
                cli.out(f"boot: {e['tmux']}: {why}")
            todo.pop(0)
            continue
        _status(todo, "")
        samples = memory.add_sample(memory.sample())
        why = memory.steady(samples) or memory.gate(e.get("rss_kb")) or _start(e, started)
        if why is None:  # started, or tried and said why not (On logged it): the next one
            todo.pop(0)
            if todo:
                _status(todo, "pause: the last start settles first")
                time.sleep(PAUSE_S)
            continue
        _status(todo, why)
        reason = re.sub(r"[0-9][0-9.]*", "N", why)  # the same reason with other numbers is not news
        if said.get(e["id4"]) != reason:
            events.log("waiting", e, f"boot: not started yet: {why}")
            said[e["id4"]] = reason
        if time.time() >= deadline:
            took = f"{wait // 60} min" if wait >= 60 else f"{wait} s"
            for id4 in todo:
                x = registry.load()["entries"].get(id4)
                if _skip(x) is None:
                    behind = why if id4 == e["id4"] else f"waiting behind {e['tmux']}, which waits: {why}"
                    events.log("refused", x, f"boot: not started in {took} ({behind}); start it by hand")
            return 1
        time.sleep(max(0.0, min(TICK_S, deadline - time.time())))
    cli.out(f"boot: {len(started)} started" + (f" ({', '.join(started)})" if started else ""))
    return 0


def _skip(e):
    """None when e is to be started now; else why not ("" when it needs no word: forgotten, or
    turned off or resurrect off since)."""
    if not e or e.get("resurrect") is not True or e.get("want_on") is not True:
        return ""
    if tmuxctl.has_session(e["tmux"]):
        return "its tmux session is up already: left as it is (the watcher looks after it)"
    if cli.live_for(e):
        return "a live claude holds its conversation: left as it is"
    return None


def _start(e, started):
    """None once On ran (it logged a start, a refusal or a failure itself; a start is added to
    started); else why it waits."""
    locked = False
    try:
        with registry.entry_lock(e["id4"]):
            locked = True
            if cli._on(e["id4"], False, loud=False, resurrect=True) == 0:
                started.append(e["tmux"])
    except cli.ActionFailed as x:
        events.log("failed", e, f"boot: {x}")
    except RegistryError as x:
        if not locked:  # an action holds it: the next look
            return str(x)
        why = memory.gate(e.get("rss_kb"))
        if why:  # memory went down between the look and On's own gate: wait as before
            return why
        events.log("refused", e, f"boot: {x}")
    return None


def _network(wait):
    """True once $ASC_NET (claude.ai:443) takes a connection, trying for wait seconds."""
    target = os.environ.get("ASC_NET", NET)
    host, _, port = target.rpartition(":")
    host = host.strip("[]")  # [::1]:443
    end = time.time() + max(wait, 0)
    while True:
        try:
            socket.create_connection((host, int(port)), timeout=NET_TRY_S).close()
            return True
        except (OSError, ValueError):
            pass
        if time.time() >= end:
            break
        time.sleep(min(2.0, max(0.0, end - time.time())))
    events.log("waiting", None, f"boot: {target} did not answer in {wait} s; starting anyway (a remote "
                                f"control that does not come up shows on the dashboard)")
    return False
