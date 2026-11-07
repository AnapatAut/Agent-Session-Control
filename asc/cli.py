"""asctl: list running agent sessions, favorite them, turn favorites on and off.

  asctl live                       running claudes: pid, session id, tmux, folder, favorite
  asctl list                       favorites and their state
  asctl fav REF [--name N] [--whole-session]
                                   favorite a running claude (REF: its pid, session id or
                                   tmux pane %N), or a past conversation (REF: its session id)
  asctl on ID [--force-memory]     start it: a tmux session NAME-ID in its folder, resumed;
                                   refused when memory is short (asc/memory.py) unless forced
  asctl off ID [--force]           end it: claude gets SIGTERM, then its tmux session closes
  asctl rename ID NAME [--restart] a new name (the tmux session too, if it runs); a running
                                   claude, when idle, gets /rename NAME, also its claude.ai title
                                   (--restart: restart it instead)
  asctl restart ID [--outside]     off and on again on the same conversation, only when its
                                   claude is idle and runs no command or subagent; one that runs
                                   outside its tmux session (a terminal, a Claude Code background
                                   session) is moved into it (--outside: only that, the page's)
  asctl mode ID auto|manual|skip   permission mode when its transcript names none; a start
                                   follows the mode the conversation last ran in, whichever it
                                   is (shift+tab carries over)
  asctl rc ID on|off [--title T] [--next-start]
                                   remote control (and its title); a running claude also
                                   now, when idle (asc/rclive.py), unless --next-start
  asctl resurrect ID on|off        bring it back after a reboot; on turns rc on too, and a
                                   resurrect start always has rc
  asctl note ID TEXT               a note shown with it ("" clears it)
  asctl forget ID                  drop the favorite; a running session is left alone
  asctl events [ID] [--limit N]    what happened, oldest first (a favorite's last 200; asc/events.py)
  asctl watch                      one watcher run (asctl-watch.timer, every 30 s; asc/watch.py)
  asctl auto-restart on|off        whether the watcher starts again a claude ended by a signal
                                   under memory pressure (off: it only logs; the default)
  asctl boot [--wait S] [--net-wait S]
                                   bring back the favorites with resurrect on that were on, one
                                   at a time past the memory gates (asctl-boot.service; asc/boot.py)
  asctl dash [--socket P] [--idle S]
                                   the dashboard server, on a unix socket (see asc/dash.py)
  asctl tmux-server                asctl-tmux.service's start (only that unit runs it)
  asctl setup [--remove] [--yes]   turn asctl's units on for this user (once, no sudo), or off
                                   again; shows what it will do and asks first (asc/setup.py)
ID is the 4-digit id or the full NAME-ID. With no tmux server running, On starts
asctl-tmux.service, which owns the server: asctl never starts one from its own process (the
server would then be that process's, and restarting the dashboard would end every session).
"""
import contextlib
import datetime
import glob
import json
import os
import signal
import subprocess
import sys
import time
import uuid

from . import events, live, memory, rclive, registry, tmuxctl
from .registry import RegistryError

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def out(*a):
    print(*a, flush=True)


def say(kind, e, msg, **extra):
    """Print what was done and log it as an event of the entry e."""
    out(msg)
    events.log(kind, e, msg, **extra)


class ActionFailed(RegistryError):
    """An action that went wrong after it had changed something (logged as failed, not refused)."""


@contextlib.contextmanager
def refusals(e, what):
    """Log an action on e that was refused or failed (the error still goes to the caller)."""
    try:
        yield
    except ActionFailed as x:
        events.log("failed", e, f"{what}: {x}")
        raise
    except RegistryError as x:
        events.log("refused", e, f"{what}: {x}")
        raise
    except Exception as x:
        events.log("failed", e, f"{what}: {type(x).__name__}: {x}")
        raise


# Commands that change something: each is logged when refused or failed (main).
ACTIONS = {"fav", "on", "off", "rename", "restart", "mode", "rc", "resurrect", "forget"}


def exit_file(id4):
    d = os.path.join(registry.state_dir(), "exit")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return os.path.join(d, id4)


def last_exit(id4):
    x = last_exit_full(id4)
    return x[:2] if x else None


def last_exit_full(id4):
    """(exit code, time, boot id, pane PID or None) asctl-wrap recorded when the entry's claude
    last ended, or None."""
    p = registry.read_private_text(exit_file(id4))
    try:
        f = p.split()
        pid = int(f[3]) if len(f) > 3 and f[3].isdigit() else None
        return int(f[0]), int(f[1]), f[2] if len(f) > 2 else "", pid
    except (AttributeError, ValueError, IndexError):
        return None


def started_exit(e):
    """The exit record of the claude this start ran: written by the asctl-wrap of a pane of the
    entry's session (the pane PID it records, which it keeps), else None. A wrap of the session
    before (a restart's off) may write its record late, after the start removed the old one."""
    ex = last_exit_full(e["id4"])
    if ex and ex[3] is not None and any(p["pane_pid"] == ex[3] for p in tmuxctl.panes(e["tmux"])):
        return ex
    return None


TYPING_S = 120  # a client with a key this recent: someone may be typing in that pane


def pane_free(e, pane, pane_pid):
    """"" when pane %N of the entry's session is the shell asctl-wrap left after claude ended
    (the same PID, which it keeps through exec), running nothing, not scrolled back, with no
    one typing in the session; else why not. Checked before claude runs there again."""
    ps = tmuxctl.panes(e["tmux"], strict=True)
    if ps is None:
        return "tmux did not list its panes"
    p = next((p for p in ps if p["pane_id"] == pane), None)
    if p is None or len(ps) != 1:
        return f"its tmux session is not that one pane any more"
    if p["pane_pid"] != pane_pid:
        return "its pane runs another process than the one asctl started (respawned or swapped)"
    st = live.proc_stat(pane_pid)
    if not st or st[0] not in live.SHELLS:
        return "its pane does not run a shell"
    if live.children_map().get(pane_pid):
        return "its pane's shell runs something"
    if p["in_mode"]:
        return "its pane is in copy mode (someone is reading it)"
    acts = tmuxctl.client_activity(e["tmux"])
    if acts is None:
        return "tmux did not list its clients"
    if any(time.time() - a < TYPING_S for a in acts):
        return f"someone typed in it in the last {TYPING_S // 60} min"
    return ""


def has_transcript(sid):
    """True when claude has written the conversation's transcript, which it does at its first
    message: only then can --resume take it up (claude exits 1 on one it cannot find), and
    --session-id would no longer start it."""
    pattern = os.path.expanduser(f"~/.claude/projects/*/{glob.escape(sid)}.jsonl")
    return any(os.path.isfile(p) for p in glob.glob(pattern))


def claude_argv(e, resurrect=False):
    a = [os.environ.get("ASC_CLAUDE", "claude")]  # isolation: no mutant may change this line
    # by its transcript, not by "started": a claude started (or favorited) before its first
    # message has none, and is started again as new, on the same session id
    a += ["--resume", e["session_id"]] if has_transcript(e["session_id"]) else ["--session-id", e["session_id"]]
    a += ["--name", e["tmux"], "--permission-mode", start_mode(e)]
    if e.get("rc") or (resurrect and e.get("resurrect")):
        a += ["--remote-control", e.get("rc_title") or e["tmux"]]
    return a


# Modes followed from the transcript as claude takes them, every one --permission-mode takes
# ("default" was manual's old name).
FOLLOW = {"auto": "auto", "manual": "manual", "default": "manual", "acceptEdits": "acceptEdits",
          "dontAsk": "dontAsk", "plan": "plan", "bypassPermissions": "bypassPermissions"}
_modes = {}  # transcript path -> ((size, mtime), (mode, time)): the dashboard asks every 5 s


def last_mode_at(sid, tail=2 << 20):
    """(mode, time) the conversation last ran in: the last permissionMode at the end of its
    transcript (claude writes it with each message and on each change), and the time of that
    record or the last timestamped one before it (None if none in the tail); (None, None) when
    none is found."""
    for path in glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl")):
        f = live.open_regular(path)
        if f is None:
            continue
        with f:
            st = os.fstat(f.fileno())
            key = (st.st_size, st.st_mtime_ns)
            if path in _modes and _modes[path][0] == key:
                return _modes[path][1]
            f.seek(max(0, st.st_size - tail))
            lines = f.read(tail).split(b"\n")
        found, mode, at = False, None, None
        for line in reversed(lines[1:] if st.st_size > tail else lines):  # the first may be cut
            if b'"permissionMode"' not in line and not (found and b'"timestamp"' in line):
                continue
            try:
                r = json.loads(line.decode("utf-8", "replace"))
            except (ValueError, RecursionError):
                continue
            if not isinstance(r, dict):
                continue
            if not found:
                if not isinstance(r.get("permissionMode"), str):
                    continue
                found, mode = True, r["permissionMode"][:40]
            if isinstance(r.get("timestamp"), str):  # a message carries its own
                at = iso_time(r["timestamp"])
                if at is not None:
                    break
        _modes[path] = (key, (mode, at))
        return mode, at
    return None, None


def last_mode(sid):
    return last_mode_at(sid)[0]


def iso_time(t):
    try:
        return int(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def mode_now(s):
    """The mode a running claude s is in: the transcript's, unless that was written before this
    claude started (claude writes its mode only with a message), then the one it was started
    with (its --permission-mode)."""
    m, at = last_mode_at(s["session_id"])
    if m is None or (at is not None and s.get("started_at") and at < s["started_at"]):
        a = live._cmdline(s["pid"]).split(" ")
        if "--permission-mode" in a[:-1]:
            return a[a.index("--permission-mode") + 1][:40]
    return m


def start_mode(e):
    """--permission-mode for a start: the mode the conversation last ran in, whichever it is
    (skip and plan too), so a change made inside claude carries over; a mode not known here or
    none found: the favorite's own mode."""
    own = registry.MODES[e.get("mode", "auto")]
    m = last_mode(e["session_id"]) if e.get("started") and e.get("session_id") else None
    return FOLLOW.get(m) or own


def live_in(e, lv=None):
    """The live claude in the entry's own tmux session (holding its session id first)."""
    lv = live.live() if lv is None else lv
    mine = [s for s in lv if s["pane"] and s["pane"]["session"] == e["tmux"]]
    return next((s for s in mine if s["session_id"] == e.get("session_id")), mine[0] if mine else None)


def live_for(e, lv=None):
    """Any live claude of an entry: in its tmux session, else holding its session id anywhere.
    Only for refusing a duplicate start or showing state: never for signalling."""
    lv = live.live() if lv is None else lv
    return live_in(e, lv) or next((s for s in lv if s["session_id"] == e.get("session_id")), None)


def past_conversation(sid):
    """Folder and title of a past conversation, from its transcript (first lines only)."""
    for path in glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl")):
        cwd = title = None
        f = live.open_regular(path)
        if f is None:
            continue
        with f:
            for i, line in enumerate(f):
                if i > 200:
                    break
                try:
                    r = json.loads(line.decode("utf-8", "replace"))
                except (ValueError, RecursionError):
                    continue
                if not isinstance(r, dict):
                    continue
                cwd = cwd or (r.get("cwd") if isinstance(r.get("cwd"), str) else None)
                if r.get("type") in ("custom-title", "agent-name"):
                    title = r.get("customTitle") or r.get("agentName") or title
        if cwd:
            return cwd, title
    return None


# --- commands ---------------------------------------------------------------------------

def cmd_live(args):
    data = registry.load()
    by_sid = {e.get("session_id"): e["id4"] for e in data["entries"].values()}
    lv = live.live()
    if not lv:
        out("no live claude")
    for s in lv:
        where = f"{s['pane']['session']} {s['pane']['pane_id']}" if s["pane"] else "(not in tmux)"
        h = s["host"] or {}  # a background job shown in a claude's pane: that claude's favorite
        fav = by_sid.get(s["session_id"]) or by_sid.get(h.get("session_id")) or "-"
        job = f"  (a background job, shown by claude {h['pid']})" if h else ""
        out(f"{s['pid']:>8}  {s['session_id']}  {s['status']:<7} fav={fav:<4}  {where:<24} {s['cwd']}{job}")
    unknown = [s for s in live.read_sessions() if not s["ok"]]
    if unknown:
        out(f"{len(unknown)} session file(s) in an unknown format: shown nowhere, never acted on")
    return 0


def state_of(e, lv, up_sessions=None):
    s = live_for(e, lv)
    up = tmuxctl.has_session(e["tmux"]) if up_sessions is None else e["tmux"] in up_sessions
    if s and up:
        return "on", s
    if s:
        return "on (outside its tmux session)", s
    ex = last_exit(e["id4"])
    if up:
        if ex and ex[0] in (137, 143):
            return f"ended by a signal ({ex[0]}), tmux up", None
        return ("tmux up, claude ended" + (f" ({ex[0]})" if ex else "")), None
    return ("off" if not e.get("want_on") else "off (wanted on)"), None


def cmd_list(args):
    data = registry.load()
    if not data["entries"]:
        out("no favorites (asctl live, then asctl fav)")
    lv = live.live()
    for e in sorted(data["entries"].values(), key=lambda e: e["tmux"]):
        st, _ = state_of(e, lv)
        flags = ",".join(f for f, on in (("rc", e.get("rc")), ("resurrect", e.get("resurrect"))) if on) or "-"
        out(f"{e['id4']}  {e['tmux']:<24} {st:<34} mode={e.get('mode', 'auto'):<6} {flags:<12} {e['cwd']}")
    return 0


def cmd_fav(args):
    ref, name, whole = args.ref, args.name, args.whole_session
    lv = live.live()
    s = next((x for x in lv if ref in (str(x["pid"]), x["session_id"], (x["pane"] or {}).get("pane_id"))), None)
    with registry.changing() as data:
        sid = s["session_id"] if s else ref
        if any(e.get("session_id") == sid for e in data["entries"].values()):
            raise RegistryError(f"session {sid} is already a favorite")
        if s:
            cwd, title, started = s["cwd"], s["name"], True
        else:
            if not live.UUID_RE.fullmatch(ref):
                raise RegistryError(f"no live claude {ref!r}, and it is not a session id")
            past = past_conversation(ref)
            if not past:
                raise RegistryError(f"no conversation {ref} under ~/.claude/projects")
            (cwd, title), started = past, True
        name = registry.check_name(name) if name else registry.slug(title or os.path.basename(cwd))
        taken = tmuxctl.sessions()
        id4 = registry.new_id4(data, taken)
        tmux = f"{name}-{id4}"
        if s and s["pane"]:
            owner = next((e for e in data["entries"].values() if e["tmux"] == s["pane"]["session"]), None)
            if owner:
                raise RegistryError(f"this claude runs in {owner['tmux']!r}, the tmux session of favorite "
                                    f"{owner['id4']}; move it to a session of its own first")
            others = [p for p in tmuxctl.panes(s["pane"]["session"]) if p["pane_id"] != s["pane"]["pane_id"]]
            if others and not whole:
                raise RegistryError(f"this claude shares tmux session {s['pane']['session']!r} with {len(others)} "
                                    "other pane(s): Off would close them all. Use --whole-session to accept that, "
                                    "or move the claude to a session of its own")
            if tmuxctl.run("rename-session", "-t", "=" + s["pane"]["session"], tmux).returncode != 0:
                raise RegistryError(f"could not rename tmux session {s['pane']['session']!r} to {tmux!r}")
            out(f"tmux session {s['pane']['session']!r} renamed to {tmux!r}")
        elif tmux in taken:
            raise RegistryError(f"tmux session {tmux!r} exists")
        t = registry.now()
        data["entries"][id4] = {
            "id4": id4, "name": name, "tmux": tmux, "cwd": cwd, "session_id": sid, "lineage": [],
            "started": started, "rc": bool(s and s["rc"]), "rc_title": tmux, "mode": "auto",
            "resurrect": False, "want_on": bool(s), "note": "", "created": t,
            "last_on": t if s else None, "last_off": None,
        }
    say("fav", data["entries"][id4], f"favorited {id4} {tmux} ({cwd})", session=sid)
    return 0


def trust_prompt(screen, cwd):
    """True only for Claude Code's own trust prompt for this folder: its fixed lines, in
    order, as the last lines on screen (a transcript that quotes them does not count)."""
    lines = [l.strip() for l in screen.splitlines() if l.strip()]
    tail = lines[-12:]
    try:
        i = next(k for k, l in enumerate(tail) if l.startswith("Quick safety check:"))
    except StopIteration:
        return False
    rest = tail[i:]
    return (any(l.endswith("No, exit") for l in rest) and any(l.endswith("Yes, I trust this folder") for l in rest)
            and rest[-1].startswith("Enter to confirm") and cwd in "".join(lines))


def wait_started(e, timeout=40):
    """Wait for the claude of a just-started session; answer the trust prompt only for the
    entry's own folder (Claude Code selects "No, exit" by default: press Down, check, Enter),
    and only while no claude in the session has its session file yet."""
    end = time.time() + timeout
    while time.time() < end:
        time.sleep(0.5)
        if not tmuxctl.has_session(e["tmux"]):
            return None
        s = live_in(e)
        if s:
            return s
        if started_exit(e):  # claude ended already
            return None
        screen = tmuxctl.capture(e["tmux"])
        if trust_prompt(screen, e["cwd"]):
            if "❯ Yes, I trust this folder" not in screen:
                tmuxctl.send_key(e["tmux"], "Down")
                time.sleep(0.5)
            screen = tmuxctl.capture(e["tmux"])
            if trust_prompt(screen, e["cwd"]) and "❯ Yes, I trust this folder" in screen and not live_in(e):
                tmuxctl.send_key(e["tmux"], "Enter")
    return None


def cmd_on(args):
    e = registry.find(registry.load(), args.id)
    with registry.entry_lock(e["id4"]):
        return _on(e["id4"], args.force_memory)


SYSTEMCTL_S = 30  # systemctl --user start asctl-tmux.service: a start takes a second or two


def ensure_server():
    """The tmux server's PID; with none running, asctl-tmux.service is started first (the
    server-owner rule: the server is that unit's, never this process's)."""
    pid = tmuxctl.server_pid()
    if pid is not None:
        return pid
    cmd = [os.environ.get("ASC_SYSTEMCTL", "systemctl"), "--user", "start", "asctl-tmux.service"]  # isolation: no mutant may change this line
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=SYSTEMCTL_S, stdin=subprocess.DEVNULL)
        why = (r.stderr or r.stdout).strip() if r.returncode != 0 else ""
    except subprocess.TimeoutExpired:
        why = f"no answer in {SYSTEMCTL_S} s"
    except OSError as x:
        why = str(x)
    pid = tmuxctl.server_pid()
    if pid is None:
        raise RegistryError("no tmux server is running, and asctl-tmux.service did not start one"
                            + (f": {why}" if why else ""))
    return pid


def _on(id4, force_memory, loud=True, pane=None, pane_pid=None, starting=None, resurrect=False):
    """On, with the entry's lock held. pane, pane_pid: a pane %N of the entry's own tmux session
    whose claude ended, and the PID asctl-wrap left there (the watcher's restart): claude runs
    there again in place of its shell (the session and anyone attached stay), after the same
    checks and pane_free just before. starting: called once nothing can refuse any more.
    resurrect: asctl boot's start (with rc when resurrect is on, as claude_argv says)."""
    e = registry.find(registry.load(), id4)
    if pane is not None:
        server = tmuxctl.server_pid()  # a pane to start in: its server, never a new one
        if server is None:
            raise RegistryError("no tmux server is running")
    else:
        server = ensure_server()
    if pane is None and tmuxctl.has_session(e["tmux"]):
        raise RegistryError(f"tmux session {e['tmux']!r} already exists")
    if pane is not None:
        why = pane_free(e, pane, pane_pid)
        if why:
            raise RegistryError(why)
    if live_for(e):
        raise RegistryError(f"a live claude already holds session {e['session_id']}")
    blockers = live.unreadable_blockers(e["session_id"])
    if blockers:
        raise RegistryError(f"session file(s) asctl cannot read or check may belong to a claude holding this "
                            f"session: {', '.join(blockers)}; on refused")
    if not os.path.isdir(e["cwd"]):
        raise RegistryError(f"folder {e['cwd']} does not exist")
    if not force_memory:
        why = memory.gate(e.get("rss_kb"))
        if why:
            raise RegistryError(f"{why} (asctl on {e['id4']} --force-memory starts it anyway)")
    with registry.changing() as data:
        e = registry.find(data, e["id4"])
        e["want_on"], e["last_on"] = True, registry.now()
        argv = claude_argv(e, resurrect)
        e["started"] = True
    try:
        os.unlink(exit_file(e["id4"]))
    except FileNotFoundError:
        pass
    wrap = os.path.join(HERE, "bin", "asctl-wrap")
    if starting:
        starting()
    if pane is not None and (tmuxctl.server_pid() != server or pane_free(e, pane, pane_pid)):
        raise ActionFailed(f"its pane changed just before claude would start there; nothing was started "
                           f"(it is marked on)")
    if pane is None:
        r = tmuxctl.new_session(e["tmux"], e["cwd"], [wrap, exit_file(e["id4"])] + argv)
    else:
        r = tmuxctl.respawn(pane, e["cwd"], [wrap, exit_file(e["id4"])] + argv)
    if r.returncode != 0:
        raise ActionFailed(f"tmux {'new-session' if pane is None else 'respawn-pane'} failed: {r.stderr.strip()} "
                           f"(it is marked on)")
    if tmuxctl.server_pid() != server:
        # The server ended between the check and new-session, which then started one of its
        # own under asctl. Close that session: the new server, empty, exits with it. (A respawn
        # never starts a server; a pane %N names nothing on another one: nothing to close.)
        if pane is None:
            tmuxctl.kill_session(e["tmux"])
        raise ActionFailed("the tmux server ended while starting; nothing was started (it is marked on)")
    s = wait_started(e)
    if not s:
        ex = started_exit(e)
        why = f"claude exited {ex[0]} {max(0, ex[1] - e['last_on'])} s after it started" if ex else "no claude came up"
        msg = f"{e['tmux']}: tmux session started, but {why} (see: tmux attach -t ={e['tmux']})"
        # on stderr, as every failure: the page shows it (stdout is for what was done)
        print(f"asctl: {msg}", file=sys.stderr, flush=True)
        events.log("failed", e, msg)
        return 1
    events.log("on", e, f"claude {s['pid']}, session {s['session_id']}" + (" (past the memory gate)" if force_memory else ""),
               mode=argv[argv.index("--permission-mode") + 1], rc="--remote-control" in argv)
    if s["session_id"] != e["session_id"]:
        with registry.changing() as data:
            x = registry.find(data, e["id4"])
            x["lineage"] = ([x["session_id"]] + x.get("lineage", []))[:5]
            x["session_id"] = s["session_id"]
        events.log("followed", e, f"session {e['session_id']} is now {s['session_id']} (claude chose it at start)")
    if "--remote-control" in argv and (e.get("rc_title") or e["tmux"]) == e["tmux"]:
        why = send_title(s, e["tmux"])
        if why:  # claude has the name (--name), its claude.ai session not yet: owed to it
            pending(e["id4"], e["tmux"], title=True)
            say("rc", e, f"{e['tmux']}: its name not sent to claude.ai: {why}")
    if loud:
        out(f"on: {e['tmux']} (claude {s['pid']}, session {s['session_id']})")
    return 0


def send_title(s, name, wait=20):
    """/rename NAME once claude's remote control is up: a resumed conversation reconnects to its
    claude.ai session, which keeps its old title, and an old background-job record of claude's
    own can put an old name back at each start; only /rename sends a name to claude.ai."""
    if not rclive.wait_for(lambda: (rclive.session(s["pid"]) or {}).get("rc"), wait):
        return "its remote control did not come up"
    if not rclive.wait_for(lambda: rclive.guard(s) is None, 10):
        return rclive.guard(s) or "claude was not ready"
    return rclive.rename(s, name)


def pending(id4, name, title=False):
    """A name claude has not taken yet: the watcher types /rename once claude is idle. title: one
    its claude.ai session has not taken, although claude has (a restart gives claude its name
    with --name, but --resume reconnects to the claude.ai session, which keeps its title): sent
    all the same."""
    with registry.changing() as data:
        x = data["entries"].get(id4)
        if x and x["tmux"] == name:
            x["rename_pending"] = name
            x["rename_title"] = True if title else None


def cmd_off(args):
    e = registry.find(registry.load(), args.id)
    with registry.entry_lock(e["id4"]):
        return _off(e["id4"], args.force)


def _off(id4, force, loud=True):
    """Off, with the entry's lock held."""
    e = registry.find(registry.load(), id4)
    lv = live.live()
    s = live_in(e, lv)
    up = tmuxctl.has_session(e["tmux"])
    away = None if s else live_for(e, lv)
    if away and live.where(away)["how"] == "background" and away["job"] and not up:
        # Claude Code's own stop: the background session ends, its conversation is kept
        why = outside_busy(away)
        if why:
            raise RegistryError(f"busy: {why} (its claude runs as {live.where(away)['text']})")
        with registry.changing() as data:
            x = registry.find(data, e["id4"])
            x["want_on"], x["last_off"] = False, registry.now()
        events.log("off", e, end_outside(e, away))
        if loud:
            out(f"off: {e['tmux']} (its background session stopped; the conversation is kept)")
        return 0
    if away:
        raise RegistryError(f"its claude ({away['pid']}) runs outside its tmux session {e['tmux']!r}, in "
                            f"{live.where(away)['text']}; off ends only what runs in {e['tmux']!r}, so nothing "
                            f"was done (end it there, or asctl restart {e['id4']} moves it into "
                            f"{e['tmux']!r} once it is idle)")
    if up and not force:
        why = live.busy_reason(e["tmux"], lv, own_sid=e.get("session_id"))
        if why:
            raise RegistryError(f"busy: {why} (asctl off {e['id4']} --force ends it anyway)")
    with registry.changing() as data:
        x = registry.find(data, e["id4"])
        x["want_on"], x["last_off"] = False, registry.now()
    if s:
        job, s = (s, s["host"]) if s.get("host") else (None, s)  # the claude in the pane, not its job
        # Checked again just before the signal: the claude may have been moved out meanwhile.
        panes = {p["pane_pid"] for p in tmuxctl.panes(e["tmux"])}
        if not live.alive(s["pid"], s["proc_start"]) or not panes.intersection(live.ancestors(s["pid"])):
            raise ActionFailed(f"claude {s['pid']} changed or left {e['tmux']!r} while checking; nothing signalled "
                               f"(it is marked off)")
        os.kill(s["pid"], signal.SIGTERM)
        for _ in range(100):
            if not live.alive(s["pid"], s["proc_start"]):
                break
            time.sleep(0.1)
        else:
            out(f"claude {s['pid']} still runs 10 s after SIGTERM; closing its tmux session anyway")
        ended = f"claude {s['pid']} " + ("ended" if not live.alive(s["pid"], s["proc_start"]) else "still ran after SIGTERM")
        if job and live.alive(job["pid"], job["proc_start"]):
            ended += f"; its background job (claude {job['pid']}, session {job['session_id']}) runs on in Claude Code"
            out(ended)
    if up:
        tmuxctl.kill_session(e["tmux"])
    events.log("off", e, (ended if s else "no claude ran") + (", forced" if force else ""))
    if loud:
        out(f"off: {e['tmux']}")
    return 0


def _restart(id4, outside=False):
    """Off and on again, on the same conversation (its session id), so claude takes
    up a new name and rc title. Only when its claude is idle and runs nothing: no command, also
    none in the background, and no subagent (live.busy_reason). A claude of the entry that runs
    outside its tmux session is moved into it (_move_in); outside: only that. The entry's lock
    held."""
    e = registry.find(registry.load(), id4)
    lv = live.live()
    s = live_in(e, lv)
    away = None if s else live_for(e, lv)
    if away and not away.get("host"):
        return _move_in(e, away)
    if outside:
        raise RegistryError(f"its claude runs in {e['tmux']!r}, not outside it: nothing to move in" if s
                            else f"no claude of it runs outside {e['tmux']!r}")
    if not s and not away:
        raise RegistryError(f"no claude runs in {e['tmux']!r}")
    s = s or away
    if s.get("host"):
        raise RegistryError(f"its pane shows a background job of claude's (session {s['session_id']}); "
                            f"a restart would not bring it back")
    if s["status"] != "idle":
        raise RegistryError(f"its claude is {'working' if s['status'] == 'busy' else s['status']}")
    why = live.busy_reason(e["tmux"], lv, own_sid=e.get("session_id"))
    if why:
        raise RegistryError(f"busy: {why}")
    _off(id4, False, loud=False)
    try:
        # it was just running, so its memory is there: no memory gate
        return _on(id4, True, loud=False)
    except RegistryError as x:
        raise ActionFailed(f"it is off now, and turning it on again failed: {x}")


def outside_busy(s, kids=None):
    """Why a claude outside its tmux session is not idle, or "": working, waiting, or running a
    command or a subagent (as busy_reason has it for a pane)."""
    if s["status"] != "idle":
        return f"its claude is {'working' if s['status'] == 'busy' else s['status']}"
    t = live.claude_tasks(s, live.children_map() if kids is None else kids)
    return f"claude {t}" if t else ""


def end_outside(e, s, wait_s=15):
    """End the entry's claude that runs outside its tmux session (s, checked idle): a background
    session by Claude Code's own `claude stop JOB` (its conversation kept), anything else by
    SIGTERM, as off does in a pane. It is checked again first (the same process, still holding
    the entry's conversation, still idle, still outside), then waited for until it has ended.
    What happened, in words; RegistryError when nothing was done, ActionFailed after."""
    now = next((x for x in live.live() if x["pid"] == s["pid"]), None)
    if (now is None or now["proc_start"] != s["proc_start"] or now["session_id"] != e.get("session_id")
            or (now["pane"] and now["pane"]["session"] == e["tmux"]) or now.get("host")):
        raise RegistryError(f"claude {s['pid']} changed while checking; nothing was done")
    why = outside_busy(now)
    if why:
        raise RegistryError(f"busy: {why}")
    w = live.where(now)
    if w["how"] == "background" and now["job"]:
        try:
            r = subprocess.run([os.environ.get("ASC_CLAUDE", "claude"), "stop", now["job"]], capture_output=True,  # isolation: no mutant may change this line
                               text=True, timeout=30, stdin=subprocess.DEVNULL)
        except OSError as x:  # no claude to run: nothing done
            raise RegistryError(f"claude stop {now['job']}: {x}")
        except subprocess.TimeoutExpired as x:
            raise ActionFailed(f"claude stop {now['job']}: {x}")
        if r.returncode != 0:
            raise ActionFailed(f"claude stop {now['job']}: {(r.stderr or r.stdout).strip()[:200] or 'failed'}")
        how = f"its background session (job {now['job']}) stopped with claude stop"
    else:
        os.kill(now["pid"], signal.SIGTERM)
        how = f"claude {now['pid']} in {w['text']} ended"
    for _ in range(wait_s * 10):
        if not live.alive(now["pid"], now["proc_start"]):
            return how
        time.sleep(0.1)
    raise ActionFailed(f"claude {now['pid']} in {w['text']} still runs {wait_s} s later; nothing was started")


def _move_in(e, s):
    """Restart of a claude that runs outside the entry's tmux session: once it is idle, end it
    there (end_outside) and start it again in its tmux session, on the same conversation. The
    entry's lock held."""
    w = live.where(s)
    why = outside_busy(s)
    if why:
        raise RegistryError(f"busy: {why} (its claude runs in {w['text']})")
    if tmuxctl.has_session(e["tmux"]):
        raise RegistryError(f"its claude runs in {w['text']}, and tmux session {e['tmux']!r} is up "
                            f"without it: close that session first")
    how = end_outside(e, s)
    events.log("off", e, how + ", to start again in its tmux session")
    try:
        # it was just running, so its memory is there: no memory gate
        return _on(e["id4"], True, loud=False)
    except RegistryError as x:
        raise ActionFailed(f"{how}, and starting it in {e['tmux']!r} failed: {x}")


def cmd_restart(args):
    e = registry.find(registry.load(), args.id)
    with registry.entry_lock(e["id4"], wait=True):
        r = _restart(e["id4"], args.outside)
    if r == 0:
        say("restart", e, f"restarted: {e['tmux']} (same conversation)")
    return r


def cmd_rename(args):
    name = registry.check_name(args.name)
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4, wait=True):
        with registry.changing() as data:
            e = registry.find(data, args.id)
            new = f"{name}-{e['id4']}"
            if new != e["tmux"] and tmuxctl.has_session(new):
                raise RegistryError(f"tmux session {new!r} exists")
            if tmuxctl.has_session(e["tmux"]):
                if tmuxctl.run("rename-session", "-t", "=" + e["tmux"], new).returncode != 0:
                    raise RegistryError(f"could not rename tmux session {e['tmux']!r}")
            if e.get("rc_title") == e["tmux"]:
                e["rc_title"] = new
            old = e["tmux"]
            e["name"], e["tmux"], e["rename_pending"], e["rename_title"] = name, new, None, None
        s = live_in(e)
        if not s or s["name"] == new:
            say("rename", e, f"renamed: {new}", old=old)
        elif not args.restart:
            # /rename: claude takes the name at once and sends it to its claude.ai session (a
            # restart would not: --resume reconnects to that session, which keeps its title)
            why = rclive.rename(s, new)
            if why:
                pending(id4, new)
                say("rename", e, f"renamed to {new}; claude's own name not changed now: {why}. "
                                 f"The watcher sends it once claude is idle", old=old)
            else:
                say("rename", e, f"renamed to {new}, claude and its claude.ai title too", old=old)
        else:
            try:
                if _restart(id4) != 0:
                    events.log("rename", e, f"renamed to {new}; the restart did not bring claude back", old=old)
                    return 1
                say("rename", e, f"renamed to {new} and restarted (same conversation)", old=old)
            except RegistryError as x:
                say("rename", e, f"renamed to {new}; not restarted now: {x}. Restart it once idle (asctl restart {id4})", old=old)
    return 0


def cmd_mode(args):
    if args.mode not in registry.MODES:
        raise RegistryError(f"mode must be one of: {', '.join(registry.MODES)}")
    with registry.changing() as data:
        e = registry.find(data, args.id)
        e["mode"] = args.mode
    say("mode", e, f"{e['tmux']}: mode {args.mode} (used when its transcript names none)")
    return 0


def cmd_rc(args):
    if args.state not in ("on", "off"):
        raise RegistryError("rc is on or off")
    title = registry.check_title(args.title) if args.title is not None else None
    on = args.state == "on"
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4, wait=True):  # after a start or stop that is running
        with registry.changing() as data:
            e = registry.find(data, id4)
            e["rc"] = on
            if title is not None:
                e["rc_title"] = title
        head = f"{e['tmux']}: rc {args.state}" + (f", title {e.get('rc_title') or e['tmux']!r}" if on else "")
        s = None if args.next_start else live_in(e)
        if not s:
            say("rc", e, head + " from its next start")
        elif s["rc"] == on:
            say("rc", e, head + (" (live already)" if on else " (not live already)"))
        else:
            why = rclive.switch(s, on, e.get("rc_title") or e["tmux"])
            say("rc", e, head + (f" from its next start; not changed now: {why}" if why else (", live now" if on else ", off now")))
    return 0


def cmd_resurrect(args):
    if args.state not in ("on", "off"):
        raise RegistryError("resurrect is on or off")
    with registry.changing() as data:
        e = registry.find(data, args.id)
        e["resurrect"] = args.state == "on"
        if e["resurrect"]:
            e["rc"] = True
    say("resurrect", e, f"{e['tmux']}: resurrect {args.state}" + (" (rc on)" if e["resurrect"] else ""))
    return 0


def cmd_note(args):
    note = registry.check_note(args.text)
    with registry.changing() as data:
        e = registry.find(data, args.id)
        e["note"] = note
    out(f"{e['tmux']}: note " + ("cleared" if not note else "set"))
    return 0


def cmd_forget(args):
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4, wait=True), registry.changing() as data:
        e = registry.find(data, args.id)
        del data["entries"][e["id4"]]
    say("forget", e, f"forgot {e['id4']} {e['tmux']} (anything running was left alone)")
    return 0


def cmd_events(args):
    id4 = registry.find(registry.load(), args.id)["id4"] if args.id else None
    evs = events.read(id4, args.limit)
    if not evs:
        out("no events" + (f" for {id4}" if id4 else ""))
    for r in reversed(evs):
        when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["t"]))
        out(f"{when}  {r.get('by', '?'):<5} {r['kind']:<9} {r.get('tmux') or '-':<24} {r.get('text', '')}")
    return 0


def cmd_watch(args):
    from . import watch
    return watch.run()


def cmd_auto_restart(args):
    if args.state not in ("on", "off"):
        raise RegistryError("auto-restart is on or off")
    with registry.changing() as data:
        data.setdefault("settings", {})["auto_restart"] = args.state == "on"
    events.log("setting", None, f"auto-restart {args.state}")
    out(f"auto-restart {args.state}: " + ("a favorite whose claude was ended by a signal under memory pressure is "
                                          "started again by the watcher, past the memory gates" if args.state == "on"
                                          else "the watcher only logs what it would do"))
    return 0


def cmd_boot(args):
    from . import boot
    return boot.run(args.wait, args.net_wait)


def cmd_tmux_server(args):
    """asctl-tmux.service's start (Type=forking): a tmux server kept up with no session, left in
    that unit when this exits. A server already running (the one the old tmux unit started, on
    the day of the switch) is left as it is: the start succeeds and starts no second one."""
    running = tmuxctl.server_pid()
    if running is not None:
        out(f"a tmux server already runs (pid {running}): left as it is, nothing started")
        return 0
    r = tmuxctl.start_server()
    pid = tmuxctl.server_pid()
    if pid is None:
        raise RegistryError(f"tmux start-server failed: {r.stderr.strip() or 'no server came up'}")
    out(f"tmux server {pid} started, kept up with no session (exit-empty off)")
    return 0


def cmd_setup(args):
    from . import setup
    return setup.remove(args.yes) if args.remove else setup.setup(args.yes)


def cmd_dash(args):
    from . import dash
    return dash.serve(args.socket, args.idle)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(prog="asctl", description=__doc__.split("\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("live").set_defaults(f=cmd_live)
    sub.add_parser("list").set_defaults(f=cmd_list)
    a = sub.add_parser("fav")
    a.add_argument("ref")
    a.add_argument("--name")
    a.add_argument("--whole-session", action="store_true")
    a.set_defaults(f=cmd_fav)
    a = sub.add_parser("on")
    a.add_argument("id")
    a.add_argument("--force-memory", action="store_true")
    a.set_defaults(f=cmd_on)
    a = sub.add_parser("forget")
    a.add_argument("id")
    a.set_defaults(f=cmd_forget)
    a = sub.add_parser("rc")
    a.add_argument("id")
    a.add_argument("state")
    a.add_argument("--title")
    a.add_argument("--next-start", action="store_true", help="only the setting: never type into a running claude")
    a.set_defaults(f=cmd_rc)
    a = sub.add_parser("resurrect")
    a.add_argument("id")
    a.add_argument("state")
    a.set_defaults(f=cmd_resurrect)
    a = sub.add_parser("note")
    a.add_argument("id")
    a.add_argument("text")
    a.set_defaults(f=cmd_note)
    a = sub.add_parser("off")
    a.add_argument("id")
    a.add_argument("--force", action="store_true")
    a.set_defaults(f=cmd_off)
    a = sub.add_parser("rename")
    a.add_argument("id")
    a.add_argument("name")
    a.add_argument("--restart", action="store_true", help="restart its claude instead of /rename (a resumed claude.ai session keeps its title)")
    a.set_defaults(f=cmd_rename)
    a = sub.add_parser("restart")
    a.add_argument("id")
    a.add_argument("--outside", action="store_true", help="only a claude outside its tmux session, moved into it")
    a.set_defaults(f=cmd_restart)
    a = sub.add_parser("mode")
    a.add_argument("id")
    a.add_argument("mode")
    a.set_defaults(f=cmd_mode)
    a = sub.add_parser("events")
    a.add_argument("id", nargs="?")
    a.add_argument("--limit", type=int, default=50)
    a.set_defaults(f=cmd_events)
    sub.add_parser("watch").set_defaults(f=cmd_watch)
    a = sub.add_parser("auto-restart")
    a.add_argument("state")
    a.set_defaults(f=cmd_auto_restart)
    a = sub.add_parser("boot")
    a.add_argument("--wait", type=int, default=3600, help="give up on memory after this many seconds")
    a.add_argument("--net-wait", type=int, default=120, help="wait this long for claude.ai before the first start")
    a.set_defaults(f=cmd_boot)
    sub.add_parser("tmux-server").set_defaults(f=cmd_tmux_server)
    a = sub.add_parser("setup")
    a.add_argument("--remove", action="store_true", help="turn it off again (favorites and the log are kept)")
    a.add_argument("--yes", action="store_true", help="do not ask")
    a.set_defaults(f=cmd_setup)
    a = sub.add_parser("dash")
    a.add_argument("--socket")
    a.add_argument("--idle", type=int, default=600, help="exit after this many idle seconds (0: never)")
    a.set_defaults(f=cmd_dash)
    args = p.parse_args(argv)
    try:
        if args.cmd not in ACTIONS:
            return args.f(args)
        try:
            e = registry.find(registry.load(), args.id) if args.cmd != "fav" else None
        except RegistryError:
            e = None
        with refusals(e, args.cmd + ("" if e or args.cmd == "fav" else f" {args.id}")):
            return args.f(args)
    except RegistryError as e:
        print(f"asctl: {e}", file=sys.stderr)
        return 1
