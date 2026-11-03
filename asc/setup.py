"""asctl setup: turn asctl on for this user, once, without sudo (asctl setup --remove: off again).
It runs as that user, in a session of theirs: never as root, and it refuses when the user's
systemd manager does not answer (sudo -u or su without XDG_RUNTIME_DIR).

Setup refuses, changing nothing, while:
- asctl's units are not installed (sudo ./install.sh puts them in /etc/systemd/user for every
  user; tools/install-units.sh puts a checkout's own in ~/.config/systemd/user);
- an earlier tmux-claude-restore install is there (its own install.sh --uninstall removes it);
- tmux-continuum's restore or boot is on, in a tmux config (or a file it sources) or the
  running server: a continuum restore brings every saved session back at once, past boot's
  memory gates, and its boot turns its tmux.service on again at every server start.
Then it shows what it will do and asks (--yes: it does not ask; with no terminal and no --yes it
changes nothing):
- the drop-in tmux-spawn-.scope.d/asctl.conf in the user's unit folder: the kernel's OOM kill
  of one claude then does not end its tmux session (OOMPolicy=continue);
- every other enabled user unit that runs tmux is disabled, never stopped (a stop ends every
  session; the running server stays that unit's until the next boot). Each is recorded in
  setup.json first, and --remove enables it again;
- asctl-tmux.service, asctl-boot.service, asctl-watch.timer and asctl-dash.socket enabled, the
  timer and the socket started.
It says when linger is off (the units start at boot only with it: loginctl enable-linger, which
it does not run) and when the dashboard has no config yet. A second run does only what is
missing.
--remove disables asctl's units: the watcher and the dashboard stop; the tmux server unit is not
stopped (that would end every session) and keeps the server until the next boot. It removes the
drop-in when it is unchanged and enables again what setup disabled. Favorites, the event log and
the settings stay.
"""
import glob
import json
import os
import pwd
import re
import subprocess
import sys
import time

from . import cli, events, registry, tmuxctl
from .registry import RegistryError

UNITS = ["asctl-tmux.service", "asctl-boot.service", "asctl-watch.timer", "asctl-dash.socket"]
STARTED = ["asctl-watch.timer", "asctl-dash.socket"]
DROPIN = os.path.join("tmux-spawn-.scope.d", "asctl.conf")
SYSTEMCTL_S = 60
OLD_MARK = "# >>> tmux-claude-restore >>>"
# set -g @continuum-restore 'on' (set-option, other flags, either quote, a comment after it)
CONTINUUM = re.compile(r"""^\s*set(?:-option)?\s+(?:-[A-Za-z]+\s+)*@continuum-(restore|boot)\s+(['"]?)on\2\s*(?:#.*)?$""")


def _sc(*args, timeout=SYSTEMCTL_S):
    cmd = [os.environ.get("ASC_SYSTEMCTL", "systemctl"), "--user", *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"systemctl {args[0]}: no answer in {timeout} s")
    except OSError as x:
        return subprocess.CompletedProcess(cmd, 127, "", f"systemctl: {x}")


def _must(*args, timeout=SYSTEMCTL_S):
    r = _sc(*args, timeout=timeout)
    if r.returncode != 0:
        raise cli.ActionFailed(f"systemctl --user {' '.join(args)}: {(r.stderr or r.stdout).strip() or f'exit {r.returncode}'}")
    return r


def _prop(unit, p):
    return _sc("show", "-p", p, "--value", unit).stdout.strip()


def _enabled(unit):
    return _sc("is-enabled", unit).stdout.strip() == "enabled"


def _config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")


_manager = {}


def manager_env():
    """The user manager's environment (systemctl --user show-environment), read once; a manager
    that does not answer is refused (sudo -u or su without XDG_RUNTIME_DIR, for one)."""
    if "env" not in _manager:
        r = _sc("show-environment")
        if r.returncode != 0:  # the manager did not answer
            raise RegistryError("cannot reach your systemd user manager (systemctl --user: "
                                f"{(r.stderr or r.stdout).strip() or f'exit {r.returncode}'}): run it in a login "
                                f"session of your own, not through sudo -u or su")
        _manager["env"] = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
    return _manager["env"]


def unit_dir():
    """Where the user manager reads this user's units: XDG_CONFIG_HOME as the manager has it
    (usually unset there, whatever the shell says), else ~/.config."""
    base = manager_env().get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "systemd", "user")


def _record_path():
    return os.path.join(registry.state_dir(), "setup.json")


def _recorded():
    """The units setup disabled (setup.json); a broken file counts as none."""
    try:
        with open(_record_path(), encoding="utf-8") as f:
            d = json.load(f)
        xs = d.get("disabled") if isinstance(d, dict) else None
        return [u for u in xs if isinstance(u, str) and _unit_name(u)] if isinstance(xs, list) else []
    except (OSError, ValueError):
        return []


def _unit_name(u):
    return re.fullmatch(r"[A-Za-z0-9:_.\\@-]+\.service", u) is not None


SOURCE = re.compile(r"""^\s*source(?:-file)?\s+(?:-[A-Za-z]+\s+)*(['"]?)([^'"#\s]+)\1""")


def tmux_configs():
    """The tmux config files there are (tmux reads both the XDG one and ~/.tmux.conf), and the
    ones they source-file by a literal path (~ and $HOME expanded, globs), a few levels deep."""
    todo = [os.path.expanduser("~/.tmux.conf"), os.path.join(_config_home(), "tmux", "tmux.conf"),
            os.path.expanduser("~/.config/tmux/tmux.conf")]
    seen = []
    depth = 0
    while todo and depth < 5:
        nxt = []
        for p in todo:
            if p in seen or not os.path.isfile(p):
                continue
            seen.append(p)
            for line in _read(p).splitlines():
                m = SOURCE.match(line)
                if not m or "#{" in m.group(2):
                    continue
                q = os.path.expanduser(m.group(2).replace("$HOME", os.path.expanduser("~")).replace("${HOME}", os.path.expanduser("~")))
                if os.path.isabs(q):
                    nxt.extend(sorted(glob.glob(q)))
        todo, depth = nxt, depth + 1
    return seen


def _read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def old_install():
    """What shows an earlier tmux-claude-restore install ("" when none)."""
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    manifest = os.path.join(state, "tmux-claude-restore", "manifest.json")
    if os.path.lexists(manifest):
        return f"its manifest {manifest}"
    for d in dict.fromkeys([unit_dir(), os.path.expanduser("~/.config/systemd/user")]):
        timer = os.path.join(d, "tmux-claude-autosave.timer")
        if os.path.lexists(timer):
            return f"its unit {timer}"
    for p in tmux_configs():
        for line in _read(p).splitlines():
            if line.startswith(OLD_MARK):
                m = re.search(r"managed by (/\S+/install\.sh)", line)
                return f"its block in {p}" + (f" (installed by {m.group(1)})" if m else "")
    return ""


def continuum_on():
    """Where tmux-continuum's restore or boot is on: ["~/.tmux.conf: @continuum-restore", ...]."""
    found = []
    for p in tmux_configs():
        for n, line in enumerate(_read(p).splitlines(), 1):
            m = CONTINUUM.match(line)
            if m:
                found.append(f"{p}:{n}: @continuum-{m.group(1)} 'on'")
    if tmuxctl.server_pid() is not None:
        for o in ("restore", "boot"):
            r = tmuxctl.run("show", "-gqv", f"@continuum-{o}")
            if r.returncode == 0 and r.stdout.strip() == "on":
                found.append(f"the running tmux server: @continuum-{o} on")
    return found


def runs_tmux(execstart):
    """Whether an ExecStart property ("{ path=/usr/bin/tmux ; argv[]=/usr/bin/tmux new -d ; … }",
    one per command) runs tmux: its program, the program env runs (/usr/bin/env tmux …), or a word
    of a shell's -c command (sh -c "tmux new -d"). A script that runs tmux is not seen."""
    for m in re.finditer(r"path=(\S+) ; argv\[\]=([^;]*)", execstart):
        prog, argv = os.path.basename(m.group(1)), m.group(2).split()
        if prog == "tmux":
            return True
        if prog == "env" and next((os.path.basename(a) for a in argv[1:] if "=" not in a and not a.startswith("-")), "") == "tmux":
            return True
        if prog in ("sh", "bash", "dash", "zsh") and "-c" in argv and any(
                os.path.basename(w.strip("'\"();&|")) == "tmux" for w in argv[argv.index("-c") + 1:]):
            return True
    return False


def tmux_units():
    """Enabled user services, other than asctl's, that run tmux."""
    r = _sc("list-unit-files", "--state=enabled", "--type=service", "--no-legend")
    if r.returncode != 0:
        raise RegistryError(f"systemctl --user list-unit-files: {(r.stderr or r.stdout).strip()}")
    names = []
    for line in r.stdout.splitlines():
        u = (line.split() or [""])[0]
        if not _unit_name(u) or u.startswith("asctl-"):
            continue
        if u.endswith("@.service"):  # a template: its instances, by the links that enable them
            pre = u[:-len(".service")]
            for d in dict.fromkeys([unit_dir(), os.path.expanduser("~/.config/systemd/user")]):
                names += sorted(os.path.basename(x) for x in glob.glob(os.path.join(glob.escape(d), "*.wants", glob.escape(pre) + "?*.service")))
        else:
            names.append(u)
    found = []
    for u in dict.fromkeys(names):
        if _unit_name(u) and _enabled(u) and runs_tmux(_prop(u, "ExecStart")):
            found.append(u)
    return found


def _template():
    with open(os.path.join(cli.HERE, "systemd", DROPIN), encoding="utf-8") as f:
        return f.read()


def _write_dropin(path, text):
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _dropin_state():
    """("missing" | "same" | "differs" | "not a file", its path)."""
    p = os.path.join(unit_dir(), DROPIN)
    if os.path.islink(p) or (os.path.lexists(p) and not os.path.isfile(p)):
        return "not a file", p
    if not os.path.lexists(p):
        return "missing", p
    return ("same" if _read(p) == _template() else "differs"), p


def _linger():
    user = pwd.getpwuid(os.getuid()).pw_name
    return os.path.exists(os.path.join(os.environ.get("ASC_LINGER_DIR", "/var/lib/systemd/linger"), user))


def _server_unit():
    """The service the running tmux server belongs to ("" with no server, or none)."""
    pid = tmuxctl.server_pid()
    if pid is None:
        return ""
    try:
        with open(f"/proc/{pid}/cgroup", encoding="utf-8") as f:
            cg = f.read().strip().splitlines()[-1].rpartition("/")[2]
    except (OSError, IndexError):
        return ""
    return cg if re.fullmatch(r"[A-Za-z0-9:_.\\@-]+\.service", cg) else ""  # a shell's scope: not a unit to warn about


def _ask(yes, what):
    if yes:
        return True
    if not sys.stdin.isatty():
        cli.out(f"Nothing changed: run asctl {what} --yes to do it.")
        return False
    try:
        a = input("Go ahead? [y/N] ")
    except EOFError:
        a = ""
    if a.strip().lower() not in ("y", "yes"):
        cli.out("Nothing changed.")
        return False
    return True


def _notes():
    from . import dash
    xs = []
    if not _linger():
        xs.append("linger is off: the units start only once you log in, so a reboot brings nothing "
                  "back until then (sudo loginctl enable-linger, or ask an admin)")
    if not os.path.lexists(dash.config_path()):
        xs.append(f"the dashboard has no config yet: {dash.config_path()} (see the README)")
    return xs


def _not_root():
    if os.getuid() == 0:
        raise RegistryError("run it as the user who wants asctl, not as root (it sets up that user's own units)")


def setup(yes=False):
    _not_root()
    manager_env()
    missing = [u for u in UNITS if _prop(u, "LoadState") != "loaded"]
    if missing:
        raise RegistryError(f"asctl's units are not installed ({', '.join(missing)}): sudo ./install.sh "
                            f"in a checkout of it (every user), or tools/install-units.sh (yours only)")
    old = old_install()
    if old:
        raise RegistryError(f"an earlier tmux-claude-restore install is here ({old}): remove it first with "
                            f"its own installer, install.sh --uninstall (this repo has it up to commit dd28b57)")
    cont = continuum_on()
    if cont:
        raise RegistryError("tmux-continuum's restore or boot is on (" + "; ".join(cont) + "): set "
                            "@continuum-restore and @continuum-boot to 'off' in your tmux config first (a "
                            "continuum restore brings every saved session back at once, and its boot turns "
                            "its tmux.service on again)")
    state, dropin = _dropin_state()
    if state == "not a file":
        raise RegistryError(f"{dropin} is not a plain file: left as it is")
    old_units = tmux_units()
    to_enable = [u for u in UNITS if not _enabled(u)]
    to_start = [u for u in STARTED if _prop(u, "ActiveState") != "active"]
    plan = []
    if state == "missing":
        plan.append(f"write {dropin} (a kernel OOM kill of one claude does not end its tmux session)")
    for u in old_units:
        plan.append(f"disable {u}, which runs tmux (not stopped: a stop would end every session; "
                    f"asctl setup --remove enables it again)")
    if to_enable:
        plan.append("enable " + ", ".join(to_enable))
    if to_start:
        plan.append("start " + ", ".join(to_start))
    notes = _notes()
    if state == "differs":
        notes.append(f"{dropin} is not the one asctl ships: left as it is")
    srv = _server_unit()
    if srv and srv != "asctl-tmux.service" and (old_units or to_enable):
        notes.append(f"the running tmux server is {srv}'s and stays so until the next boot; do not stop or "
                     f"restart {srv}: that ends every session")
    if not plan:
        cli.out("asctl is set up already: nothing to do")
        for n in notes:
            cli.out(f"  note: {n}")
        return 0
    cli.out("asctl setup will:")
    for p in plan:
        cli.out(f"  - {p}")
    for n in notes:
        cli.out(f"  note: {n}")
    if not _ask(yes, "setup"):
        return 1
    done = []
    try:
        if old_units:  # recorded before any is disabled: --remove can always undo it
            registry.write_private(_record_path(), {"disabled": sorted(set(_recorded()) | set(old_units)),
                                                    "t": int(time.time())})
        if state == "missing":
            _write_dropin(dropin, _template())
            done.append(f"wrote {dropin}")
        _must("daemon-reload")
        for u in old_units:
            _must("disable", u)
            if _enabled(u):  # not this user's to disable: not recorded either
                registry.write_private(_record_path(), {"disabled": [x for x in _recorded() if x != u],
                                                        "t": int(time.time())})
                raise cli.ActionFailed(f"{u} is still enabled (enabled for every user? an admin's "
                                       f"systemctl --global disable {u})")
            done.append(f"disabled {u}")
        if to_enable:
            _must("enable", *to_enable)
            done.append("enabled " + ", ".join(to_enable))
        if to_start:
            _must("start", *to_start)
            done.append("started " + ", ".join(to_start))
    except (RegistryError, OSError) as x:
        msg = f"setup stopped part way ({'; '.join(done) or 'nothing done'}): {x}; run asctl setup again to finish"
        events.log("failed", None, msg)
        raise cli.ActionFailed(msg)
    events.log("setup", None, "setup: " + "; ".join(done))
    for d in done:
        cli.out(d)
    cli.out("asctl is set up: favorites with resurrect on come back at the next boot")
    return 0


def remove(yes=False):
    _not_root()
    manager_env()
    state, dropin = _dropin_state()
    on = [u for u in UNITS if _enabled(u)]
    stop = [u for u in ("asctl-watch.timer", "asctl-dash.socket", "asctl-dash.service")
            if _prop(u, "ActiveState") in ("active", "activating", "reloading")]
    back = [u for u in _recorded() if _prop(u, "LoadState") == "loaded" and not _enabled(u)]
    plan = []
    if on:
        plan.append("disable " + ", ".join(on))
    if stop:
        plan.append("stop " + ", ".join(stop))
    if state == "same":
        plan.append(f"remove {dropin}")
    for u in back:
        plan.append(f"enable {u} again (setup disabled it)")
    notes = []
    if state == "differs":
        notes.append(f"{dropin} is not the one asctl ships: left as it is")
    if _server_unit() == "asctl-tmux.service":
        notes.append("the running tmux server stays asctl-tmux.service's until the next boot (a stop "
                     "would end every session)")
    if back:
        notes.append("tmux-continuum's restore and boot stay as your tmux config has them")
    if not plan:
        cli.out("asctl is not set up: nothing to do")
        for n in notes:
            cli.out(f"  note: {n}")
        if os.path.lexists(_record_path()) and not _recorded():
            os.unlink(_record_path())
        return 0
    cli.out("asctl setup --remove will:")
    for p in plan:
        cli.out(f"  - {p}")
    for n in notes:
        cli.out(f"  note: {n}")
    if not _ask(yes, "setup --remove"):
        return 1
    done = []
    try:
        if on:
            _must("disable", *on)
            done.append("disabled " + ", ".join(on))
        if stop:  # the dashboard waits up to 100 s for running actions (its TimeoutStopSec 120)
            _must("stop", *stop, timeout=150)
            done.append("stopped " + ", ".join(stop))
        if state == "same":
            os.unlink(dropin)
            done.append(f"removed {dropin}")
        _must("daemon-reload")
        if back:
            _must("enable", *back)
            done.append("enabled " + ", ".join(back) + " again")
        if os.path.lexists(_record_path()):
            os.unlink(_record_path())
    except (RegistryError, OSError) as x:
        msg = f"setup --remove stopped part way ({'; '.join(done) or 'nothing done'}): {x}; run it again to finish"
        events.log("failed", None, msg)
        raise cli.ActionFailed(msg)
    events.log("setup", None, "setup --remove: " + "; ".join(done))
    for d in done:
        cli.out(d)
    cli.out("asctl is off for you: favorites, the event log and the settings are kept")
    return 0
