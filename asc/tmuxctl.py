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


def run(*args, check=False):
    return subprocess.run(_base() + list(args), capture_output=True, text=True, check=check)


def server_pid():
    """The tmux server's PID, or None when none runs."""
    r = run("display-message", "-p", "#{pid}")
    return int(r.stdout) if r.returncode == 0 and r.stdout.strip().isdigit() else None


def server_running():
    return server_pid() is not None


def has_session(name):
    return run("has-session", "-t", "=" + name).returncode == 0


def sessions():
    r = run("list-sessions", "-F", "#{session_name}")
    return r.stdout.split() if r.returncode == 0 else []


def panes(session=None):
    """Panes as dicts: pane_id, pane_pid, session, command, in_mode."""
    fmt = "#{pane_id}\t#{pane_pid}\t#{session_name}\t#{pane_current_command}\t#{pane_in_mode}"
    args = ["list-panes", "-F", fmt] + (["-s", "-t", "=" + session] if session else ["-a"])
    r = run(*args)
    out = []
    if r.returncode != 0:
        return out
    for line in r.stdout.splitlines():
        p = line.split("\t")
        if len(p) == 5 and p[1].isdigit():
            out.append({"pane_id": p[0], "pane_pid": int(p[1]), "session": p[2],
                        "command": p[3], "in_mode": p[4] == "1"})
    return out


def new_session(name, cwd, argv):
    # tmux expands formats in -c (#(cmd) would run a command): "##" is a literal "#".
    return run("new-session", "-d", "-s", name, "-c", cwd.replace("#", "##"), "--", *argv)


def kill_session(name):
    return run("kill-session", "-t", "=" + name)


def capture(name):
    r = run("capture-pane", "-p", "-t", "=" + name + ":")
    return r.stdout if r.returncode == 0 else ""


def send_key(name, key):
    return run("send-keys", "-t", "=" + name + ":", key)
