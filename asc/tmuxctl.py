"""Every tmux call, as an argument list (never through a shell).

Targets: `=NAME` for a session, `=NAME:` for its panes (a bare NAME, or NAME: without `=`,
also matches a longer name that starts with it). $ASC_TMUX_SOCKET picks a `tmux -L` socket
(the tests use their own server).
"""
import os
import subprocess


def _base():
    sock = os.environ.get("ASC_TMUX_SOCKET")
    return ["tmux", "-L", sock] if sock else ["tmux"]


def run(*args, check=False, timeout=5):
    """A tmux call; one that does not answer in time (a stopped server) counts as failed."""
    try:
        return subprocess.run(_base() + list(args), capture_output=True, text=True, check=check,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "tmux did not answer in time")
    except OSError as e:  # no tmux on PATH
        return subprocess.CompletedProcess(args, 127, "", f"tmux: {e}")


def server_pid():
    """The tmux server's PID, or None when none runs."""
    r = run("display-message", "-p", "#{pid}")
    return int(r.stdout) if r.returncode == 0 and r.stdout.strip().isdigit() else None


def server_running():
    return server_pid() is not None


def start_server():
    """A tmux server that stays up with no session (exit-empty off); only asctl-tmux.service
    runs this, so the server is that unit's (asctl tmux-server). The user's tmux config loads
    first, and a plugin line in it can hold the start for a while: a minute, not 5 s."""
    return run("start-server", ";", "set", "-g", "exit-empty", "off", timeout=60)


def has_session(name):
    return run("has-session", "-t", "=" + name).returncode == 0


def sessions():
    r = run("list-sessions", "-F", "#{session_name}")
    return r.stdout.split() if r.returncode == 0 else []


def panes(session=None, strict=False):
    """Panes as dicts: pane_id, pane_pid, session, command, in_mode. When tmux fails: [], or
    None if strict (a caller about to act must not take "no answer" for "no panes")."""
    fmt = "#{pane_id}\t#{pane_pid}\t#{session_name}\t#{pane_current_command}\t#{pane_in_mode}"
    args = ["list-panes", "-F", fmt] + (["-s", "-t", "=" + session] if session else ["-a"])
    r = run(*args)
    out = []
    if r.returncode != 0:
        return None if strict else out
    for line in r.stdout.splitlines():
        p = line.split("\t")
        if len(p) == 5 and p[1].isdigit():
            out.append({"pane_id": p[0], "pane_pid": int(p[1]), "session": p[2],
                        "command": p[3], "in_mode": p[4] == "1"})
    return out


def new_session(name, cwd, argv):
    # tmux expands formats in -c (#(cmd) would run a command): "##" is a literal "#".
    return run("new-session", "-d", "-s", name, "-c", cwd.replace("#", "##"), "--", *argv)


def client_activity(session):
    """When each client attached to the session last had a key (epoch seconds), or None if tmux
    did not answer."""
    r = run("list-clients", "-t", "=" + session, "-F", "#{client_activity}")
    if r.returncode != 0:
        return None
    return [int(x) for x in r.stdout.split() if x.isdigit()]


def respawn(pane, cwd, argv):
    """Run argv in pane %N in place of whatever ended there (the session and its clients stay)."""
    return run("respawn-pane", "-k", "-t", pane, "-c", cwd.replace("#", "##"), "--", *argv)


def kill_session(name):
    return run("kill-session", "-t", "=" + name)


def capture(name):
    r = run("capture-pane", "-p", "-t", "=" + name + ":")
    return r.stdout if r.returncode == 0 else ""


def send_key(name, key):
    return run("send-keys", "-t", "=" + name + ":", key)


# By pane id (%N): one exact pane, never the session's active one by chance.
def capture_pane(pane, escapes=False):
    r = run("capture-pane", "-p", *(["-e"] if escapes else []), "-t", pane)
    return r.stdout if r.returncode == 0 else ""


def pane_in_mode(pane):
    r = run("display-message", "-p", "-t", pane, "#{pane_in_mode}")
    return r.returncode != 0 or r.stdout.strip() != "0"  # unknown counts as in a mode


def send_pane(pane, *keys):
    return run("send-keys", "-t", pane, *keys)


def type_pane(pane, text):
    """Text as typed, key names not read (-l)."""
    return run("send-keys", "-t", pane, "-l", text)
