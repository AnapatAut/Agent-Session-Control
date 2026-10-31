"""asctl: list running agent sessions, favorite them, turn favorites on and off.

  asctl live                       running claudes: pid, session id, tmux, folder, favorite
  asctl list                       favorites and their state
  asctl fav REF [--name N] [--whole-session]
                                   favorite a running claude (REF: its pid, session id or
                                   tmux pane %N), or a past conversation (REF: its session id)
  asctl on ID                      start it: a tmux session NAME-ID in its folder, resumed
  asctl off ID [--force]           end it: claude gets SIGTERM, then its tmux session closes
  asctl rename ID NAME             a new name (the tmux session too, if it runs)
  asctl mode ID auto|manual|skip   permission mode for the next start (skip: no prompts)
  asctl forget ID                  drop the favorite; a running session is left alone
  asctl dash [--socket P] [--idle S]
                                   the dashboard server, on a unix socket (see asc/dash.py)
ID is the 4-digit id or the full NAME-ID. Nothing here starts a tmux server: it would then
belong to asctl's own process (a later phase adds asctl-tmux.service for that).
"""
import glob
import json
import os
import signal
import sys
import time
import uuid

from . import live, registry, tmuxctl
from .registry import RegistryError

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def out(*a):
    print(*a, flush=True)


def exit_file(id4):
    d = os.path.join(registry.state_dir(), "exit")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return os.path.join(d, id4)


def last_exit(id4):
    try:
        with open(exit_file(id4), encoding="utf-8") as f:
            p = f.read().split()
        return int(p[0]), int(p[1])
    except (OSError, ValueError, IndexError):
        return None


def claude_argv(e):
    a = [os.environ.get("ASC_CLAUDE", "claude")]
    a += ["--resume", e["session_id"]] if e.get("started") else ["--session-id", e["session_id"]]
    a += ["--name", e["tmux"], "--permission-mode", registry.MODES[e.get("mode", "auto")]]
    if e.get("rc"):
        a += ["--remote-control", e.get("rc_title") or e["tmux"]]
    return a


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
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 200:
                    break
                try:
                    r = json.loads(line)
                except ValueError:
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
        fav = by_sid.get(s["session_id"], "-")
        out(f"{s['pid']:>8}  {s['session_id']}  {s['status']:<7} fav={fav:<4}  {where:<24} {s['cwd']}")
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
    out(f"favorited {id4} {tmux} ({cwd})")
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
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4):
        e = registry.find(registry.load(), id4)
        server = tmuxctl.server_pid()
        if server is None:
            raise RegistryError("no tmux server is running; asctl does not start one (it would own it)")
        if tmuxctl.has_session(e["tmux"]):
            raise RegistryError(f"tmux session {e['tmux']!r} already exists")
        if live_for(e):
            raise RegistryError(f"a live claude already holds session {e['session_id']}")
        blockers = live.unreadable_blockers(e["session_id"])
        if blockers:
            raise RegistryError(f"session file(s) asctl cannot read or check may belong to a claude holding this "
                                f"session: {', '.join(blockers)}; on refused")
        if not os.path.isdir(e["cwd"]):
            raise RegistryError(f"folder {e['cwd']} does not exist")
        with registry.changing() as data:
            e = registry.find(data, e["id4"])
            e["want_on"], e["last_on"] = True, registry.now()
            argv = claude_argv(e)
            e["started"] = True
        try:
            os.unlink(exit_file(e["id4"]))
        except FileNotFoundError:
            pass
        wrap = os.path.join(HERE, "bin", "asctl-wrap")
        r = tmuxctl.new_session(e["tmux"], e["cwd"], [wrap, exit_file(e["id4"])] + argv)
        if r.returncode != 0:
            raise RegistryError(f"tmux new-session failed: {r.stderr.strip()}")
        if tmuxctl.server_pid() != server:
            # The server ended between the check and new-session, which then started one of its
            # own under asctl. Close that session: the new server, empty, exits with it.
            tmuxctl.kill_session(e["tmux"])
            raise RegistryError("the tmux server ended while starting; nothing was started")
        s = wait_started(e)
        if not s:
            out(f"{e['tmux']}: tmux session started, but no claude came up (see: tmux attach -t ={e['tmux']})")
            return 1
        if s["session_id"] != e["session_id"]:
            with registry.changing() as data:
                x = registry.find(data, e["id4"])
                x["lineage"] = ([x["session_id"]] + x.get("lineage", []))[:5]
                x["session_id"] = s["session_id"]
        out(f"on: {e['tmux']} (claude {s['pid']}, session {s['session_id']})")
    return 0


def cmd_off(args):
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4):
        e = registry.find(registry.load(), id4)
        lv = live.live()
        s = live_in(e, lv)
        up = tmuxctl.has_session(e["tmux"])
        away = None if s else live_for(e, lv)
        if away:
            where = away["pane"]["session"] if away["pane"] else "no tmux"
            raise RegistryError(f"its claude ({away['pid']}) runs outside its tmux session {e['tmux']!r} "
                                f"(in {where}); off ends only what runs in {e['tmux']!r}, so nothing was done")
        if up and not args.force:
            why = live.busy_reason(e["tmux"], lv)
            if why:
                raise RegistryError(f"busy: {why} (asctl off {e['id4']} --force ends it anyway)")
        with registry.changing() as data:
            x = registry.find(data, e["id4"])
            x["want_on"], x["last_off"] = False, registry.now()
        if s:
            # Checked again just before the signal: the claude may have been moved out meanwhile.
            panes = {p["pane_pid"] for p in tmuxctl.panes(e["tmux"])}
            if not live.alive(s["pid"], s["proc_start"]) or not panes.intersection(live.ancestors(s["pid"])):
                raise RegistryError(f"claude {s['pid']} changed or left {e['tmux']!r} while checking; nothing signalled")
            os.kill(s["pid"], signal.SIGTERM)
            for _ in range(100):
                if not live.alive(s["pid"], s["proc_start"]):
                    break
                time.sleep(0.1)
            else:
                out(f"claude {s['pid']} still runs 10 s after SIGTERM; closing its tmux session anyway")
        if up:
            tmuxctl.kill_session(e["tmux"])
        out(f"off: {e['tmux']}")
    return 0


def cmd_rename(args):
    name = registry.check_name(args.name)
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4, wait=True), registry.changing() as data:
        e = registry.find(data, args.id)
        new = f"{name}-{e['id4']}"
        if new != e["tmux"] and tmuxctl.has_session(new):
            raise RegistryError(f"tmux session {new!r} exists")
        if tmuxctl.has_session(e["tmux"]):
            if tmuxctl.run("rename-session", "-t", "=" + e["tmux"], new).returncode != 0:
                raise RegistryError(f"could not rename tmux session {e['tmux']!r}")
        if e.get("rc_title") == e["tmux"]:
            e["rc_title"] = new
        e["name"], e["tmux"] = name, new
    out(f"renamed: {new} (claude's own name changes at its next start)")
    return 0


def cmd_mode(args):
    if args.mode not in registry.MODES:
        raise RegistryError(f"mode must be one of: {', '.join(registry.MODES)}")
    with registry.changing() as data:
        e = registry.find(data, args.id)
        e["mode"] = args.mode
    out(f"{e['tmux']}: mode {args.mode} from its next start")
    return 0


def cmd_forget(args):
    id4 = registry.find(registry.load(), args.id)["id4"]
    with registry.entry_lock(id4, wait=True), registry.changing() as data:
        e = registry.find(data, args.id)
        del data["entries"][e["id4"]]
    out(f"forgot {e['id4']} {e['tmux']} (anything running was left alone)")
    return 0


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
    for c, f in (("on", cmd_on), ("forget", cmd_forget)):
        a = sub.add_parser(c)
        a.add_argument("id")
        a.set_defaults(f=f)
    a = sub.add_parser("off")
    a.add_argument("id")
    a.add_argument("--force", action="store_true")
    a.set_defaults(f=cmd_off)
    a = sub.add_parser("rename")
    a.add_argument("id")
    a.add_argument("name")
    a.set_defaults(f=cmd_rename)
    a = sub.add_parser("mode")
    a.add_argument("id")
    a.add_argument("mode")
    a.set_defaults(f=cmd_mode)
    a = sub.add_parser("dash")
    a.add_argument("--socket")
    a.add_argument("--idle", type=int, default=600, help="exit after this many idle seconds (0: never)")
    a.set_defaults(f=cmd_dash)
    args = p.parse_args(argv)
    try:
        return args.f(args)
    except RegistryError as e:
        print(f"asctl: {e}", file=sys.stderr)
        return 1
