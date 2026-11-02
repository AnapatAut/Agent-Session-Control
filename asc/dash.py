"""asctl dash: the dashboard server, for one Linux user and one Tailscale login.

It listens only on a unix socket, $XDG_RUNTIME_DIR/asctl/dash.sock (the folder 0700, the
socket 0600), or on the socket systemd passes it (asctl-dash.socket): on a shared machine any
local user could reach a localhost port and forge the login header, while only this user and
root (tailscaled, for `tailscale serve unix:...`) can open the socket.

Only root and the Tailscale operator can change what `tailscale serve` puts on a port, so
while another user is the operator (`tailscale set --operator=NAME`), they could mount a page
of theirs on this origin and drive this one: every request is then refused (fail closed: also
when the setting cannot be read). Clear it with `sudo tailscale set --operator=`.

Every request must carry exactly one Tailscale-User-Login equal to the configured login, and
exactly one X-Forwarded-Host equal to the configured host (tailscale serve passes the
browser's Host there, and sends Host: localhost to a unix socket; Host must be that or the
configured host), and come from another machine: the last X-Forwarded-For
entry (the one tailscale serve adds; a client can put its own before it) must not be one of
this machine's addresses. tailscaled tags a request with the login of the device it comes
from, so without that check any local user, or an agent of theirs, could ask this machine's
own serve port and be taken for the owner. Anything else gets 403. Every action is a POST with the
page's token and a matching Origin. Actions run `asctl` itself (an argument list, no shell),
so they take the same locks and checks as the CLI. From the web the permission mode can be
set only to auto or manual; skip is set only with `asctl mode ID skip` (a favorite already in
skip still starts with it).

Config, ~/.config/agent-session-control/dash.json (it and its folder yours and writable only by
you, or the server refuses to start):
  {"login": "<your Tailscale login>", "host": "<MagicDNS name>:<port>", "prefix": "/user"}
host is what the browser sends as Host (and, after https://, as Origin): with the port when
it is not 443.
prefix (optional) is the path `tailscale serve --set-path` mounts this user's dashboard on.
Give each user's dashboard an origin of its own (its own serve port or host): paths of one
host:port share one browser origin, so a page under another user's path could read this
page's token and post actions with this login (the Origin header has no path).
The server exits after --idle seconds without a request (systemd starts it again on the next),
once no action is running; on SIGTERM it waits up to 100 s for running actions. The page token
is kept in the socket's folder (0600), so a page left open still works after a restart.
"""
import fcntl
import hmac
import http.server
import ipaddress
import json
import os
import pwd
import re
import secrets
import signal
import socket
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.parse

from . import cli, icons, live, memory, past, registry, tmuxctl
from .registry import RegistryError

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
STATIC = {"/app.js": "application/javascript", "/splash.js": "application/javascript", "/app.css": "text/css"}
MAX_BODY = 4096
WEB_MODES = ("auto", "manual")
# img-src data: for the iPhone startup image, which the page draws on a canvas (app.js).
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'none'")

# --- the installable app (PWA) --------------------------------------------------------------
# Icons are drawn by asc/icons.py. ICON_VER is in every icon URL and in the app's id:
# browsers cache icons by URL, and Android builds the installed app once per id, so a new icon
# reaches a phone only through a new id (a reinstall). Bump it whenever an icon file changes.
ICON_VER = "1"
# URLs are relative to the manifest, so the app works under a prefix too.
MANIFEST = json.dumps({
    # name: a zero-width space, as Android prints it under the icon on its launch screen, which
    # cannot be turned off; short_name labels the launcher. x_title: the full name, for readers
    # that list serve ports and are refused the page (serve-dash reads it first); browsers ignore it.
    "name": "\u200b", "short_name": "Sessions", "x_title": "Agent Session Control",
    "id": f"asctl?v={ICON_VER}", "start_url": f"./?v={ICON_VER}", "scope": "./", "display": "standalone",
    "background_color": "#ffffff", "theme_color": "#ffffff",
    "icons": [{"src": f"icon-{n}.png?v={ICON_VER}", "sizes": f"{n}x{n}", "type": "image/png"} for n in (192, 512)]
    + [{"src": f"icon-maskable-{n}.png?v={ICON_VER}", "sizes": f"{n}x{n}", "type": "image/png", "purpose": "maskable"}
       for n in (192, 512)]})
# A worker makes the app installable. This one passes every request to the network and never
# caches: the sessions must always be live.
SW = """self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => { e.respondWith(fetch(e.request)); });
"""
# Served before the login check, by exact path only: the install checks fetch these outside the
# page, and a 403 there turns the install into a plain bookmark. Nothing in them is private.
PUBLIC = {"/manifest.json": "application/manifest+json", "/sw.js": "application/javascript",
          "/favicon.svg": "image/svg+xml", **{"/" + n: "image/png" for n in icons.ICONS}}
# The page's refusal: its title and tab icon only, as every page has them (a reader such as
# serve-dash, which fetches pages from this machine and so is always refused, shows them).
# Nothing else: no token, no data, not why it was refused.
REFUSED_PAGE = (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
                f'<meta name="viewport" content="width=device-width, initial-scale=1">'
                f'<title>Agent Session Control</title>'
                f'<link rel="icon" type="image/svg+xml" href="favicon.svg?v={ICON_VER}">'
                f'<link rel="icon" type="image/png" sizes="512x512" href="favicon-512.png?v={ICON_VER}">'
                f'</head><body><p>Not allowed.</p></body></html>')


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "agent-session-control", "dash.json")


def _private(path, st):
    """The config decides who gets in: like sshd's StrictModes, refuse it (or its folder) when
    another user owns it or others can write it, since they could put their login in it."""
    if st.st_uid != os.getuid() or st.st_mode & 0o022:
        raise RegistryError(f"{path} decides who may use the dashboard, so it must be yours and "
                            f"writable only by you (chmod go-w {path})")


def load_config():
    p = config_path()
    try:
        with open(p, encoding="utf-8") as f:
            _private(p, os.fstat(f.fileno()))
            # the folder of the file itself (a symlinked config is checked where it lives)
            d = os.path.dirname(os.path.realpath(p))
            _private(d, os.stat(d))
            c = json.load(f)
    except FileNotFoundError:
        raise RegistryError(f"no {p}: it names the one Tailscale login and host allowed in "
                            '({"login": "<your Tailscale login>", "host": "<this machine\'s MagicDNS name>"})')
    except ValueError as e:
        raise RegistryError(f"{p} is not valid JSON ({e})")
    if not isinstance(c, dict) or not all(isinstance(c.get(k), str) and c[k] for k in ("login", "host")):
        raise RegistryError(f"{p} needs \"login\" and \"host\" (non-empty strings)")
    prefix = c.get("prefix") or ""
    if prefix and (not isinstance(prefix, str) or not prefix.startswith("/") or prefix.endswith("/")):
        raise RegistryError(f"{p}: prefix must start with / and not end with one (e.g. \"/user\")")
    return {"login": c["login"], "host": c["host"], "prefix": prefix}


def default_socket():
    run = os.environ.get("XDG_RUNTIME_DIR")
    if not run:
        raise RegistryError("XDG_RUNTIME_DIR is not set; pass --socket PATH")
    return os.path.join(run, "asctl", "dash.sock")


def _private_dir(d):
    """Create d as 0700, or check an existing one is ours and 0700 (never loosen or chown)."""
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise RegistryError(f"{d} must be a folder owned by you with mode 0700")


# --- who may ask --------------------------------------------------------------------------

_local = {"at": 0.0, "ips": None}


def local_addresses():
    """This machine's own addresses (every interface, tailscale0 too), cached 30 s; None when
    they cannot be read (then every request is refused)."""
    now = time.monotonic()
    if _local["ips"] is not None and now - _local["at"] < 30:
        return _local["ips"]
    try:
        r = subprocess.run(["ip", "-j", "addr", "show"], capture_output=True, text=True, timeout=5)
        ips = {ipaddress.ip_address(a["local"]) for i in json.loads(r.stdout)
               for a in i.get("addr_info", []) if "local" in a}
    except (OSError, ValueError, subprocess.SubprocessError, KeyError, TypeError):
        ips = None
    _local.update(at=now, ips=ips)
    return ips


_operator = {"at": 0.0, "ok": False}


def serve_is_ours():
    """True when no user but this one can change tailscale serve: the Tailscale operator is
    unset or this user (cached 30 s; False when it cannot be read)."""
    now = time.monotonic()
    if now - _operator["at"] < 30:
        return _operator["ok"]
    try:
        r = subprocess.run(["tailscale", "debug", "prefs"], capture_output=True, text=True, timeout=5,
                           stdin=subprocess.DEVNULL)
        op = json.loads(r.stdout).get("OperatorUser") if r.returncode == 0 else None
        ok = r.returncode == 0 and op in (None, "", pwd.getpwuid(os.getuid()).pw_name)
    except (OSError, ValueError, AttributeError, KeyError, subprocess.SubprocessError):
        ok = False
    if not ok:
        sys.stderr.write("asctl dash: refusing requests: another user is the Tailscale operator, "
                         "or it cannot be read (sudo tailscale set --operator=)\n")
    _operator.update(at=now, ok=ok)
    return ok


def remote_client(headers):
    """True when the client tailscale serve names is another machine."""
    xff = headers.get_all("X-Forwarded-For") or []
    if len(xff) != 1:
        return False
    try:
        ip = ipaddress.ip_address(xff[0].split(",")[-1].strip())
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    ips = local_addresses()
    return ips is not None and not ip.is_loopback and not ip.is_unspecified and ip not in ips


# --- what the page shows -------------------------------------------------------------------

def top_processes(n=5):
    """This user's n biggest processes (name and size only: command lines can hold paths and
    arguments), and the total of every other user's, with no names (R7)."""
    me, mine, others = os.getuid(), [], 0
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            uid = os.stat(f"/proc/{d}").st_uid
        except OSError:
            continue
        if uid != me:
            others += live.rss_kb(int(d))  # their PSS cannot be read: RSS
            continue
        kb = live.pss_kb(int(d))
        st = live.proc_stat(int(d))
        if st and kb:
            mine.append({"name": st[0], "mem_kb": kb})
    mine.sort(key=lambda p: p["mem_kb"], reverse=True)
    return {"mine": mine[:n], "others_kb": others}


_snap = threading.Lock()


def snapshot():
    with _snap:  # one at a time: many open pages never mean many /proc walks and tmux calls
        return _snapshot()


def _snapshot():
    data = registry.load()
    pane_list = tmuxctl.panes()
    lv = live.live(pane_list=pane_list)
    up = set(tmuxctl.sessions())
    kids = live.children_map()
    by_session = {}
    for p in pane_list:
        by_session.setdefault(p["session"], []).append(p)
    count = {}
    for s in lv:
        count[s["session_id"]] = count.get(s["session_id"], 0) + 1
    favs, fav_sids, fav_tmux = [], set(), set()
    for e in sorted(data["entries"].values(), key=lambda e: e["tmux"]):
        st, s = cli.state_of(e, lv, up)
        if s and count.get(s["session_id"], 0) > 1:
            st = "duplicate"
        panes = by_session.get(e["tmux"], [])
        fav_sids.add(e.get("session_id"))
        fav_sids.update(e.get("lineage", []))
        fav_tmux.add(e["tmux"])
        favs.append({
            "id4": e["id4"], "name": e["name"], "tmux": e["tmux"], "cwd": e["cwd"],
            "session_id": e.get("session_id"), "rc": bool(e.get("rc")), "rc_title": e.get("rc_title") or "",
            "rc_live": bool(s and s["rc"]),
            "mode": e.get("mode", "auto"), "resurrect": bool(e.get("resurrect")),
            # the mode claude last ran in (its transcript), and what a start would use
            "mode_used": cli.last_mode(e["session_id"]) if e.get("session_id") else None,
            "mode_next": cli.start_mode(e),
            "want_on": bool(e.get("want_on")), "note": e.get("note") or "",
            "last_on": e.get("last_on"), "last_off": e.get("last_off"), "state": st,
            "pid": s["pid"] if s else None, "status": s["status"] if s else None,
            "waiting_for": s["waiting_for"] if s else "", "status_at": s["status_at"] if s else None,
            "busy": live.busy_reason(e["tmux"], lv, kids, panes, e.get("session_id")) if e["tmux"] in up else "",
            "claudes": sum(1 for x in lv if x["pane"] and x["pane"]["session"] == e["tmux"]),
            "mem_kb": sum(live.tree_mem_kb(p["pane_pid"], kids) for p in panes),
            "attach": f"tmux attach -t ={e['tmux']}",
        })
    # a claude with a made-up name (folder-NN) goes by its conversation's title, as the Claude apps list it
    active = [{"pid": s["pid"], "session_id": s["session_id"], "claude_name": s["name"], "cwd": s["cwd"],
               "name": (s["derived"] or not s["name"]) and past.title(s["session_id"]) or s["name"],
               "status": s["status"], "waiting_for": s["waiting_for"], "status_at": s["status_at"],
               "tmux": s["pane"]["session"] if s["pane"] else None,
               "pane": s["pane"]["pane_id"] if s["pane"] else None,
               "duplicate": count.get(s["session_id"], 0) > 1}
              for s in lv if s["session_id"] not in fav_sids and not (s["pane"] and s["pane"]["session"] in fav_tmux)]
    unknown = sum(1 for s in live.read_sessions() if not s["ok"])
    return {"time": int(time.time()), "memory": memory.meminfo(), "top": top_processes(),
            "server": bool(pane_list) or tmuxctl.server_running(),
            "favorites": favs, "active": active, "unknown_files": unknown,
            "on": sum(1 for f in favs if f["state"] == "on")}, fav_sids | {s["session_id"] for s in lv}


# --- actions -------------------------------------------------------------------------------

def action_argv(a):
    """The asctl arguments for one action from the page, or a RegistryError."""
    if not isinstance(a, dict):
        raise RegistryError("the body must be a JSON object")
    kind, id4 = a.get("action"), a.get("id")
    if kind == "fav":
        ref = a.get("ref")
        if not isinstance(ref, str) or not (live.UUID_RE.fullmatch(ref) or re.fullmatch(r"[0-9]{1,10}", ref)):
            raise RegistryError("fav needs ref: a session id or a pid")
        argv = ["fav", ref]
        if a.get("name") is not None:
            argv += ["--name", registry.check_name(_text(a["name"]))]
        return argv + (["--whole-session"] if a.get("whole_session") is True else [])
    if not isinstance(id4, str) or not registry.ID4_RE.fullmatch(id4):
        raise RegistryError("id must be a favorite's 4-digit id")
    # The page names the entry it shows: a page out of date (a rename, an id forgotten and drawn
    # again) never acts on another session.
    e = registry.find(registry.load(), id4)
    if a.get("tmux") != e["tmux"]:
        raise RegistryError(f"this page is out of date ({id4} is now {e['tmux']}); reload it")
    # asctl gets the full NAME-ID, so an id forgotten and drawn again meanwhile finds nothing.
    ref = e["tmux"]
    if kind == "on":
        # Past the memory gate only from a manual On the user confirmed (never automatic).
        return ["on", ref] + (["--force-memory"] if a.get("force_memory") is True else [])
    if kind == "off":
        return ["off", ref] + (["--force"] if a.get("force") is True else [])
    if kind == "forget":
        return ["forget", ref]
    if kind == "rename":
        return ["rename", ref, registry.check_name(_text(a.get("name")))]
    if kind == "mode":
        if a.get("mode") not in WEB_MODES:
            raise RegistryError("from the page the mode can be auto or manual; skip only with asctl mode ID skip")
        return ["mode", ref, a["mode"]]
    if kind in ("rc", "resurrect"):
        if not isinstance(a.get("on"), bool):
            raise RegistryError(f"{kind} needs on: true or false")
        argv = [kind, ref, "on" if a["on"] else "off"]
        if kind == "rc" and a.get("title") is not None:
            argv += ["--title", registry.check_title(a["title"])]
        return argv
    if kind == "note":
        return ["note", ref, "--", registry.check_note(a.get("text"))]  # a note may start with -
    raise RegistryError(f"unknown action {kind!r}")


def _text(v):
    return v if isinstance(v, str) else ""


def run_asctl(argv):
    r = subprocess.run([os.path.join(cli.HERE, "bin", "asctl")] + argv, capture_output=True, text=True,
                       timeout=90, stdin=subprocess.DEVNULL)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()


# --- the server ----------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "asctl"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 30  # a slow or idle client is dropped (one thread each)

    def log_message(self, fmt, *args):
        sys.stderr.write("asctl dash: " + (fmt % args) + "\n")

    def address_string(self):
        return "unix"

    def _send(self, code, body, ctype="application/json", extra=(), cache="no-store"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if ctype.startswith(("text/", "application/j")) else ""))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", CSP)
        # One request per connection: bytes left unread (a refused request's body) can never
        # be taken as a next request, which a proxy reusing connections could smuggle in.
        self.send_header("Connection", "close")
        self.close_connection = True
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _refusal(self):
        """Why this request is refused, or "" (logged, never sent: the client learns only 403)."""
        cfg = self.server.cfg
        logins = self.headers.get_all("Tailscale-User-Login") or []
        hosts = self.headers.get_all("Host") or []
        fwd = self.headers.get_all("X-Forwarded-Host") or []
        if not (len(logins) == 1 and logins[0] == cfg["login"]):
            return f"login ({len(logins)} login header(s), not the configured one)"
        if not (len(fwd) == 1 and fwd[0] == cfg["host"] and len(hosts) == 1 and hosts[0] in ("localhost", cfg["host"])):
            return f"host (X-Forwarded-Host {[h[:100] for h in fwd]!r}, Host {[h[:100] for h in hosts]!r})"
        if not remote_client(self.headers):
            return "the client is this machine, or no usable X-Forwarded-For"
        if not serve_is_ours():
            return "another user is the Tailscale operator, or it cannot be read"
        return ""

    def _path(self):
        """The request path below the prefix, or None when it is not under it."""
        path = urllib.parse.urlsplit(self.path).path
        prefix = self.server.cfg["prefix"]
        if not prefix:
            return path
        if path == prefix:
            return ""
        return path[len(prefix):] if path.startswith(prefix + "/") else None

    def _begin(self):
        why = self._refusal()
        if why:
            self.log_message("refused: %s", why)
            if self.command in ("GET", "HEAD") and self._path() == "/":
                self._send(403, REFUSED_PAGE, "text/html")
            else:
                self._send(403, {"error": "forbidden"})
            return None
        self.server.touch()  # only allowed requests keep the server from its idle exit
        if self.headers.get_all("Transfer-Encoding") or (
                self.command != "POST" and (self.headers.get("Content-Length") or "0") != "0"):
            self._send(400, {"error": "no chunked bodies, and no body on GET or HEAD"})
            return None
        path = self._path()
        if path is None:
            self._send(404, {"error": "not found"})
        return path

    def _public(self, path):
        """Answer a public PWA file; False when this request is not one (it then goes through
        every check like any other)."""
        if path not in PUBLIC or self.headers.get_all("Transfer-Encoding") or (
                self.headers.get("Content-Length") or "0") != "0":
            return False
        if path == "/manifest.json":
            self._send(200, MANIFEST, PUBLIC[path])
        elif path == "/sw.js":
            self._send(200, SW, PUBLIC[path])
        elif path == "/favicon.svg":
            with open(os.path.join(WEB, "favicon.svg"), "rb") as f:
                self._send(200, f.read(), PUBLIC[path], cache="public, max-age=86400")
        else:
            self._send(200, icons.icon(path[1:]), PUBLIC[path], cache="public, max-age=86400")
        return True

    def do_GET(self):
        if self._public(self._path()):
            return
        path = self._begin()
        if path is None:
            return
        if path == "":
            return self._send(301, "", "text/plain", [("Location", self.server.cfg["prefix"] + "/")])
        if path == "/":
            with open(os.path.join(WEB, "index.html"), encoding="utf-8") as f:
                page = f.read().replace("@TOKEN@", self.server.token).replace("@V@", ICON_VER)
            return self._send(200, page, "text/html")
        if path in STATIC:
            with open(os.path.join(WEB, path[1:]), "rb") as f:
                return self._send(200, f.read(), STATIC[path])
        if path == "/api/state":
            state, _ = snapshot()
            return self._send(200, dict(state, login=self.server.cfg["login"], home=os.path.expanduser("~")))
        if path == "/api/past":
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("q", [""])[0]
            _, exclude = snapshot()
            return self._send(200, {"past": past.search(q, exclude)})
        self._send(404, {"error": "not found"})

    do_HEAD = do_GET

    def do_POST(self):
        path = self._begin()
        if path is None:
            return
        if path != "/api/action":
            return self._send(404, {"error": "not found"})
        origins = self.headers.get_all("Origin") or []
        token = self.headers.get("X-Asctl-Token", "")
        if (origins != ["https://" + self.server.cfg["host"]]
                or not hmac.compare_digest(token.encode("utf-8", "replace"), self.server.token.encode())):
            return self._send(403, {"error": "bad origin or token (reload the page)"})
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self._send(415, {"error": "JSON only"})
        try:
            n = int(self.headers.get("Content-Length") or "-1")
        except ValueError:
            n = -1
        if not 0 <= n <= MAX_BODY:
            self.close_connection = True
            return self._send(413, {"error": f"the body must be 0 to {MAX_BODY} bytes"})
        try:
            argv = action_argv(json.loads(self.rfile.read(n) or b"null"))
        except ValueError:
            return self._send(400, {"error": "the body is not JSON"})
        except RegistryError as e:
            return self._send(400, {"error": str(e)})
        with self.server.actions:
            self.server.running += 1
        try:  # counted until the answer is sent: a stop waiting for actions must not cut it off
            try:
                ok, out, err = run_asctl(argv)
            except subprocess.TimeoutExpired:
                return self._send(504, {"error": "asctl took over 90 s"})
            self._send(200 if ok else 409, {"ok": ok, "out": out, "error": err.removeprefix("asctl: ")})
        finally:
            with self.server.actions:
                self.server.running -= 1
                self.server.actions.notify_all()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_UNIX
    daemon_threads = True

    def __init__(self, cfg, token, sock=None, path=None):
        self.cfg, self.token, self.last = cfg, token, time.monotonic()
        self.actions, self.running = threading.Condition(), 0
        socketserver.TCPServer.__init__(self, path, Handler, bind_and_activate=sock is None)
        if sock is not None:
            self.socket.close()
            self.socket = sock

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "asctl", 0

    def touch(self):
        self.last = time.monotonic()

    def wait_actions(self, timeout):
        with self.actions:
            self.actions.wait_for(lambda: self.running == 0, timeout)


def systemd_socket():
    """The socket systemd passed (LISTEN_FDS), or None."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        return None
    for k in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):
        os.environ.pop(k, None)
    s = socket.socket(fileno=3)
    path = s.getsockname() if s.family == socket.AF_UNIX else None
    if not isinstance(path, str) or not path.startswith("/"):
        raise RegistryError("the socket systemd passed is not a unix socket with a path")
    _private_dir(os.path.dirname(path))
    if stat.S_IMODE(os.stat(path).st_mode) & 0o022:  # connecting needs write permission
        raise RegistryError(f"{path} is open to other users (SocketMode=0600)")
    return s


def _answers(path):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()


def load_token(d):
    """The page token kept in d/token (0600), made on first use."""
    p = os.path.join(d, "token")
    try:
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        f = live.open_regular(p)
        if f is None:
            raise RegistryError(f"{p} is not a regular file")
        with f:
            st = os.fstat(f.fileno())
            t = f.read(256).decode("ascii", "replace").strip()
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600 or len(t) < 40:
            raise RegistryError(f"{p} must be yours, mode 0600, holding a token; remove it to make a new one")
        return t
    t = secrets.token_urlsafe(32)
    with os.fdopen(fd, "w") as f:
        f.write(t + "\n")
    return t


def serve(sock_path=None, idle=600):
    cfg = load_config()
    sock = systemd_socket()
    sock_path = sock_path or (sock.getsockname() if sock else default_socket())
    d = os.path.dirname(sock_path)
    _private_dir(d)
    # One server per folder: held while it runs, so two starting together cannot both decide
    # a socket is stale and remove each other's.
    lock = os.open(os.path.join(d, "dash.lock"), os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RegistryError(f"another asctl dash runs on {d}")
    token = load_token(d)
    if sock is None:
        try:
            if stat.S_ISSOCK(os.lstat(sock_path).st_mode):
                if _answers(sock_path):
                    raise RegistryError(f"{sock_path} is in use (another asctl dash, or asctl-dash.socket)")
                os.unlink(sock_path)  # stale: nothing listens on it
        except FileNotFoundError:
            pass
        old = os.umask(0o177)
        try:
            srv = Server(cfg, token, path=sock_path)
        except OSError as e:
            raise RegistryError(f"cannot listen on {sock_path}: {e}")
        finally:
            os.umask(old)
        mine = os.lstat(sock_path).st_ino
        print(f"asctl dash: on {sock_path} for {cfg['login']}", file=sys.stderr, flush=True)
    else:
        srv = Server(cfg, token, sock=sock)
    # SIGTERM (systemctl stop) ends the loop like the idle exit, so the socket file is removed.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown, daemon=True).start())
    if idle:
        def watch():
            while time.monotonic() - srv.last < idle or srv.running:
                time.sleep(1)
            srv.shutdown()
        threading.Thread(target=watch, daemon=True).start()
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        srv.wait_actions(100)  # an asctl on or off half done would leave its entry half changed
        srv.server_close()
        if sock is None:
            try:
                if os.lstat(sock_path).st_ino == mine:  # never another instance's socket
                    os.unlink(sock_path)
            except FileNotFoundError:
                pass
    return 0
