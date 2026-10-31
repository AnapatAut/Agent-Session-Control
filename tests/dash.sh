#!/usr/bin/env bash
# The dashboard server (asc/dash.py) over its unix socket, with curl, in a throwaway HOME, a
# tmux server of its own and the fake claude of tests/asc.sh.
#   tests/dash.sh                  about 20 s
#   DASH_MUTANTS=1 tests/dash.sh   also the mutants below, each must make it fail (minutes)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || exit 2
export ASC_TMUX_SOCKET="asc-dash-$$" ASC_CLAUDE="$REPO/tests/asc/bin/claude"
export REPO_HOME="${REPO_HOME:-$HOME}"
export HOME="$T/home" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_RUNTIME_DIR="$T/run" SHELL=/bin/bash
unset TMUX
mkdir -p "$HOME" "$T/fakebash" "$T/run"
chmod 700 "$T/run"
cp "$(command -v bash)" "$T/fakebash/claude"
export FAKE_BASH="$T/fakebash/claude"
tm() { tmux -L "$ASC_TMUX_SOCKET" -f /dev/null "$@"; }
DPID=
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
asctl() { "$REPO/bin/asctl" "$@"; }
seen() { grep "$@" >/dev/null; }
# Put together at run time, so the privacy check does not read them as real ones.
E=@ N=.ts
LOGIN="someone${E}example.com" HOST="machine.example${N}.net"
SOCK="$T/run/asctl/dash.sock"
CONF="$HOME/.config/agent-session-control/dash.json"
# curl to the dashboard as tailscale serve would pass it on: the login and host headers.
dc() { curl -s --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: $HOST" "$@"; }
code() { dc -o /dev/null -w '%{http_code}' "$@"; }
# The status of a GET sent as raw header lines (curl folds a doubled Host into one).
raw() {
	python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(("GET /api/state HTTP/1.1\r\n" + "".join(h + "\r\n" for h in sys.argv[2:]) + "Connection: close\r\n\r\n").encode())
print(s.recv(64).split()[1].decode())' "$SOCK" "$@"
}
# Send stdin as is on one connection; print the status code of every response until it closes.
rawsend() {
	python3 -I -c 'import re, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read().replace(b"\n", b"\r\n"))
data = b""
try:
    while True:
        b = s.recv(65536)
        if not b:
            break
        data += b
except socket.timeout:
    data += b" TIMEOUT"
print(" ".join(m.decode() for m in re.findall(rb"HTTP/1\.[01] ([0-9]{3})", data)) + (" open" if data.endswith(b" TIMEOUT") else ""))' "$SOCK"
}
token() { dc "http://x$PREFIX/" | sed -n 's/.*name="asctl-token" content="\([^"]*\)".*/\1/p'; }
# POST an action; prints the HTTP code, then the body.
post() { dc -w '\n%{http_code}' -X POST -H "Origin: https://$HOST" -H "X-Asctl-Token: $TOK" \
	-H 'Content-Type: application/json' --data "$1" "http://x$PREFIX/api/action"; }
state() { dc "http://x$PREFIX/api/state"; }
start_dash() {
	"$REPO/bin/asctl" dash --idle "${1:-0}" 2>"$T/dash.err" & DPID=$!
	local i; for i in $(seq 1 50); do [ "$(code "http://x$PREFIX/app.css")" = 200 ] && return 0; sleep 0.1; done; return 1
}
stop_dash() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; }
claude_in() {
	local i pp
	for i in $(seq 1 50); do
		for pp in $(tm list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null); do
			local c=$pp
			[ "$(cat /proc/"$pp"/comm 2>/dev/null)" = claude ] || c=$(pgrep -P "$pp" -x claude | head -1)
			[ -n "$c" ] && [ -f "$HOME/.claude/sessions/$c.json" ] && { echo "$c"; return 0; }
		done
		sleep 0.2
	done
	return 1
}
W="$T/work"; mkdir -p "$W"
printf '%s\n' "$W" > "$HOME/fake-trusted"
SID=11111111-2222-4333-8444-555555555555
PREFIX=

echo "== config"
# A refusal is exit 1 at once; a server that starts anyway is cut off by timeout (124).
refuses() { timeout 5 "$REPO/bin/asctl" dash --idle 0 2>"$T/err"; [ $? = 1 ]; }
refuses && ok "dash refuses to start without a config" || bad "dash started without a config"
seen 'login and host allowed' "$T/err" && ok "it says what the config needs" || bad "no hint: $(cat "$T/err")"
mkdir -p "$(dirname "$CONF")"
printf '{"login": "%s"}\n' "$LOGIN" > "$CONF"
refuses && ok "dash refuses a config with no host" || bad "dash started with no host"
printf '{"login": "%s", "host": "%s"}\n' "$LOGIN" "$HOST" > "$CONF"
chmod 755 "$T/run"; mkdir -p "$T/run/asctl"; chmod 755 "$T/run/asctl"
refuses && ok "dash refuses a socket folder that is not 0700" || bad "dash used a socket folder others can open"
chmod 700 "$T/run/asctl"

echo "== the socket and the checks on every request"
tm start-server \; set -g exit-empty off
start_dash && ok "dash listens on its socket" || bad "no socket: $(cat "$T/dash.err")"
[ "$(stat -c %a "$SOCK")" = 600 ] && ok "socket mode 0600" || bad "socket mode $(stat -c %a "$SOCK")"
[ "$(stat -c %a "$T/run/asctl")" = 700 ] && ok "socket folder 0700" || bad "socket folder $(stat -c %a "$T/run/asctl")"
[ "$(code http://x/api/state)" = 200 ] && ok "the right login and host: 200" || bad "the right login and host: $(code http://x/api/state)"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Host: $HOST" http://x/api/state)" = 403 ] && ok "no login header: 403" || bad "no login header let in"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: other${E}example.com" -H "Host: $HOST" http://x/api/state)" = 403 ] && ok "another login: 403" || bad "another login let in"
[ "$(raw "Host: $HOST" "Tailscale-User-Login: $LOGIN")" = 200 ] && ok "raw request with the right headers: 200" || bad "raw request refused"
[ "$(raw "Host: $HOST" "Tailscale-User-Login: $LOGIN" "Tailscale-User-Login: $LOGIN")" = 403 ] && ok "the login header twice: 403" || bad "a doubled login header let in"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: evil.example" http://x/api/state)" = 403 ] && ok "another Host: 403" || bad "another Host let in"
[ "$(raw "Host: $HOST" "Host: evil.example" "Tailscale-User-Login: $LOGIN")" = 403 ] && ok "two Host headers: 403" || bad "two Host headers let in"
second="GET /api/state HTTP/1.1
Host: $HOST
Tailscale-User-Login: $LOGIN
"
r=$(printf 'GET / HTTP/1.1\nHost: %s\nTailscale-User-Login: evil%sexample.com\nContent-Length: %s\n\n%s\n' "$HOST" "$E" "$(( ${#second} + 5 ))" "$second" | rawsend)
[ "$r" = 403 ] && ok "a request smuggled in a refused one's body is never answered (one request per connection)" || bad "smuggling: responses $r"
r=$(printf 'GET /api/state HTTP/1.1\nHost: %s\nTailscale-User-Login: %s\n\nGET /api/state HTTP/1.1\nHost: %s\nTailscale-User-Login: %s\n\n' "$HOST" "$LOGIN" "$HOST" "$LOGIN" | rawsend)
[ "$r" = 200 ] && ok "keep-alive: the connection closes after one response" || bad "keep-alive: responses $r"
r=$(printf 'POST /api/action HTTP/1.1\nHost: %s\nTailscale-User-Login: %s\nTransfer-Encoding: chunked\n\n0\n\n' "$HOST" "$LOGIN" | rawsend)
[ "$r" = 400 ] && ok "a chunked body: 400" || bad "a chunked body: $r"
r=$(printf 'GET /api/state HTTP/1.1\nHost: %s\nTailscale-User-Login: %s\nContent-Length: 3\n\nabc' "$HOST" "$LOGIN" | rawsend)
[ "$r" = 400 ] && ok "a GET with a body: 400" || bad "a GET with a body: $r"
refuses && ok "a second dash refuses the socket in use" || bad "a second dash took the socket"
[ "$(code http://x/app.css)" = 200 ] && ok "the first one still answers" || bad "the first dash lost its socket"
[ "$(code http://x/nope)" = 404 ] && ok "an unknown path: 404" || bad "an unknown path: $(code http://x/nope)"
hdr=$(dc -D - -o "$T/page" http://x/)
seen -i "^content-security-policy: default-src 'self'; script-src 'self'" <<<"$hdr" && ok "the page has a strict CSP" || bad "no strict CSP"
seen -i '^x-frame-options: DENY' <<<"$hdr" && seen -i '^cache-control: no-store' <<<"$hdr" && ok "no framing, no caching" || bad "framing or caching allowed"
seen -i '^connection: close' <<<"$hdr" && ok "responses say Connection: close" || bad "no Connection: close"
TOK=$(token)
[ ${#TOK} -ge 40 ] && ok "the page carries a token" || bad "no token in the page"
grep -E '<script>|<script [^>]*>[^<]' "$T/page" >/dev/null && bad "the page has inline script" || ok "the page has no inline script"
[ "$(code http://x/app.js)" = 200 ] && [ "$(code http://x/app.css)" = 200 ] && ok "app.js and app.css served" || bad "static files missing"
grep -n 'innerHTML\|outerHTML\|insertAdjacentHTML\|document.write' "$REPO/asc/web/app.js" >/dev/null && bad "app.js writes HTML from strings" || ok "app.js sets text only (no innerHTML)"

echo "== state"
tm new-session -d -s dev -c "$W" -- "$ASC_CLAUDE" --session-id "$SID" --name dev
pid=$(claude_in dev)
s=$(state)
jq -e '.memory.avail_pct > 0 and .memory.total_kb > 0' <<<"$s" >/dev/null && ok "state: memory" || bad "state: no memory"
jq -e --arg s "$SID" '.active | map(select(.session_id == $s and .tmux == "dev")) | length == 1' <<<"$s" >/dev/null && ok "state: the running claude, not favorited" || bad "state: active list wrong: $s"
jq -e '.top.mine | length > 0 and all(has("name") and has("rss_kb") and (has("cmdline") | not))' <<<"$s" >/dev/null && ok "state: own biggest processes, names and sizes only" || bad "state: top processes wrong"
jq -e '.top.others_kb | type == "number"' <<<"$s" >/dev/null && ok "state: other users as one total" || bad "state: no others total"
jq -e '.server == true' <<<"$s" >/dev/null && ok "state: the tmux server is up" || bad "state: server not seen"

echo "== actions: token, origin, body"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST without the token: 403" || bad "a POST without the token: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://evil.example" -H "X-Asctl-Token: $TOK" -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST from another origin: 403" || bad "a POST from another origin: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "X-Asctl-Token: $TOK" -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST with no origin: 403" || bad "a POST with no origin: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H "X-Asctl-Token: $TOK" --data '{"action":"fav"}' http://x/api/action)
[ "$r" = 415 ] && ok "a form POST (not JSON): 415" || bad "a form POST: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H "X-Asctl-Token: $TOK" -H 'Content-Type: application/json' --data "$(head -c 5000 /dev/zero | tr '\0' x)" http://x/api/action)
[ "$r" = 413 ] && ok "a body over 4 KB: 413" || bad "a big body: $r"
[ "$(post '{"action":"fav","ref":"--help"}' | tail -1)" = 400 ] && ok "a ref that is no pid or id: 400" || bad "a bad ref accepted"
[ "$(post '{"action":"on","id":"12; rm"}' | tail -1)" = 400 ] && ok "an id that is not 4 digits: 400" || bad "a bad id accepted"
[ "$(post '{"action":"exec","id":"1234"}' | tail -1)" = 400 ] && ok "an unknown action: 400" || bad "an unknown action accepted"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H "X-Asctl-Token: tökén" -H 'Content-Type: application/json' --data '{}' http://x/api/action)
[ "$r" = 403 ] && ok "a token with non-ASCII bytes: 403 (no crash)" || bad "a non-ASCII token: $r"
[ "$(post '[1]' | tail -1)" = 400 ] && ok "a body that is not an object: 400" || bad "a non-object body accepted"

echo "== actions: favorite, off, on, mode, rename, forget"
out=$(post '{"action":"fav","ref":"'"$pid"'","name":"das"}')
[ "$(tail -1 <<<"$out")" = 200 ] && ok "fav by pid" || bad "fav failed: $out"
id=$(state | jq -r '.favorites[0].id4')
s=$(state)
jq -e --arg i "$id" '.favorites[0] | .tmux == "das-\($i)" and .state == "on" and .status == "idle" and .rss_kb > 0 and .attach == "tmux attach -t =das-\($i)"' <<<"$s" >/dev/null && ok "state: the favorite, on, idle, its memory, the attach command" || bad "state: favorite wrong: $(jq -c '.favorites[0]' <<<"$s")"
jq -e '.active | length == 0' <<<"$s" >/dev/null && ok "state: no longer in the not-favorited list" || bad "state: still listed as not favorited"
touch "$HOME/fake-busy"; sleep 0.6
out=$(post '{"action":"off","id":"'"$id"'"}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen 'busy: the claude in pane' <<<"$out" && ok "off refused while busy, with the reason" || bad "off while busy: $out"
state | jq -e '.favorites[0].busy | test("is working")' >/dev/null && ok "state: busy reason shown" || bad "state: no busy reason"
rm -f "$HOME/fake-busy"; sleep 0.6
[ "$(post '{"action":"off","id":"'"$id"'"}' | tail -1)" = 200 ] && ok "off" || bad "off failed"
state | jq -e '.favorites[0].state == "off"' >/dev/null && ok "state: off" || bad "state: not off"
[ "$(post '{"action":"mode","id":"'"$id"'","mode":"skip"}' | tail -1)" = 400 ] && ok "mode skip from the page: refused" || bad "mode skip from the page accepted"
[ "$(jq -r ".entries[\"$id\"].mode" "$HOME/.local/state/agent-session-control/registry.json")" = auto ] && ok "the mode stayed auto" || bad "the mode changed"
[ "$(post '{"action":"mode","id":"'"$id"'","mode":"manual"}' | tail -1)" = 200 ] && ok "mode manual from the page" || bad "mode manual failed"
asctl mode "$id" skip >/dev/null
[ "$(post '{"action":"on","id":"'"$id"'"}' | tail -1)" = 200 ] && ok "on (a favorite in skip still starts from the page)" || bad "on failed"
tail -1 "$HOME/claude-args.log" | seen -- '--permission-mode bypassPermissions' && ok "started with its skip mode" || bad "skip not passed: $(tail -1 "$HOME/claude-args.log")"
touch "$HOME/fake-busy"; sleep 0.6
[ "$(post '{"action":"off","id":"'"$id"'","force":"yes"}' | tail -1)" = 409 ] && ok "force only when it is true (\"yes\" is not)" || bad "force taken from a non-boolean"
[ "$(post '{"action":"off","id":"'"$id"'","force":true}' | tail -1)" = 200 ] && ok "off with force while busy" || bad "off --force failed"
rm -f "$HOME/fake-busy"
[ "$(post '{"action":"rename","id":"'"$id"'","name":"Bad Name"}' | tail -1)" = 400 ] && ok "rename to a bad name: 400" || bad "a bad name accepted"
[ "$(post '{"action":"rename","id":"'"$id"'","name":"db"}' | tail -1)" = 200 ] && state | jq -e '.favorites[0].tmux | startswith("db-")' >/dev/null && ok "rename" || bad "rename failed"
[ "$(post '{"action":"forget","id":"'"$id"'"}' | tail -1)" = 200 ] && state | jq -e '.favorites | length == 0' >/dev/null && ok "forget" || bad "forget failed"

echo "== past conversations"
mkdir -p "$HOME/.claude/projects/-x"
P1=22222222-3333-4444-8555-666666666666 P2=33333333-4444-4555-8666-777777777777
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"custom-title","customTitle":"first name"}\n{"type":"custom-title","customTitle":"<b>Old</b> & talk"}\n' "$W" "$P1" > "$HOME/.claude/projects/-x/$P1.jsonl"
{ printf '{"type":"user","cwd":"/srv/api","sessionId":"%s"}\n' "$P2"; head -c 200000 /dev/zero | tr '\0' ' '; printf '\n{"type":"agent-name","agentName":"api work"}\n'; } > "$HOME/.claude/projects/-x/$P2.jsonl"
touch -d '1 hour ago' "$HOME/.claude/projects/-x/$P2.jsonl"
pj=$(dc "http://x/api/past")
jq -e --arg a "$P1" --arg b "$P2" '[.past[].session_id] | index($a) < index($b)' <<<"$pj" >/dev/null && ok "past: newest first" || bad "past: order wrong: $pj"
jq -e --arg a "$P1" '.past[] | select(.session_id == $a) | .title == "<b>Old</b> & talk"' <<<"$pj" >/dev/null && ok "past: the latest title, sent as raw text (the page sets it as text)" || bad "past: title changed"
jq -e --arg b "$P2" '.past[] | select(.session_id == $b) | .title == "api work" and .cwd == "/srv/api"' <<<"$pj" >/dev/null && ok "past: title from the end of a big transcript, folder from its start" || bad "past: big transcript read wrong"
jq -e '.past | length == 1' <<<"$(dc "http://x/api/past?q=SRV")" >/dev/null && ok "past: search by folder, any case" || bad "past: search wrong"
tm new-session -d -s dev2 -c "$W" -- "$ASC_CLAUDE" --session-id "$P2"
claude_in dev2 >/dev/null
asctl fav "$P1" >/dev/null
pj=$(dc "http://x/api/past")
jq -e --arg b "$P2" '[.past[].session_id] | index($b) == null' <<<"$pj" >/dev/null && ok "past: a running conversation is not listed" || bad "past: a running one listed"
jq -e --arg a "$P1" '[.past[].session_id] | index($a) == null' <<<"$pj" >/dev/null && ok "past: a favorite is not listed" || bad "past: a favorite listed"

echo "== prefix and idle exit"
stop_dash
printf '{"login": "%s", "host": "%s", "prefix": "/u"}\n' "$LOGIN" "$HOST" > "$CONF"
PREFIX=/u
start_dash
[ "$(stat -c %a "$T/run/asctl")" = 700 ] && ok "the socket folder is still 0700 after a restart" || bad "socket folder mode changed"
[ "$(code http://x/u/api/state)" = 200 ] && ok "under the prefix: 200" || bad "prefix: $(code http://x/u/api/state)"
[ "$(code http://x/api/state)" = 404 ] && [ "$(code http://x/x/api/state)" = 404 ] && ok "outside the prefix: 404 (also a path as long as it)" || bad "outside the prefix served"
[ "$(code http://x/u)" = 301 ] && dc -D - -o /dev/null http://x/u | seen -i '^location: /u/' && ok "the prefix without a slash redirects to /u/" || bad "no redirect for /u"
TOK=$(token); [ ${#TOK} -ge 40 ] && ok "the page under the prefix" || bad "no page under the prefix"
stop_dash
[ -e "$SOCK" ] && bad "SIGTERM left the socket file" || ok "SIGTERM: the server removes its socket"
start_dash 2
for _ in 1 2 3 4 5 6 7; do curl -s -o /dev/null --unix-socket "$SOCK" -H "Host: $HOST" "http://x/u/"; sleep 0.5; done
kill -0 "$DPID" 2>/dev/null && bad "refused requests kept dash from its idle exit" || ok "refused requests do not keep dash alive"
DPID=
start_dash 2
sleep 3.5
kill -0 "$DPID" 2>/dev/null && bad "dash still runs after 2 s idle" || ok "dash exits when idle"
[ -e "$SOCK" ] && bad "the socket file was left behind" || ok "it removes its socket on exit"
DPID=

echo "== systemd socket activation"
if command -v systemd-socket-activate >/dev/null; then
	mkdir -p "$T/sa"; chmod 700 "$T/sa"
	systemd-socket-activate -l "$T/sa/s.sock" "$REPO/bin/asctl" dash --idle 0 2>/dev/null & DPID=$!
	for _ in $(seq 1 30); do [ -S "$T/sa/s.sock" ] && break; sleep 0.1; done
	r=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$T/sa/s.sock" -H "Tailscale-User-Login: $LOGIN" -H "Host: $HOST" http://x/u/api/state)
	[ "$r" = 200 ] && ok "serves on the socket systemd passes" || bad "socket activation: $r"
	stop_dash
else
	echo "  skip  systemd-socket-activate not installed"
fi

# DASH_MUTANTS=1: break the server one way at a time, in a copy; each must make this test fail.
if [ "${DASH_MUTANTS:-}" = 1 ]; then
	echo "== mutants"
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		f=${m%%' %%% '*}; rest=${m#*' %%% '}; old=${rest%%' %%% '*}; new=${rest#*' %%% '}
		d=$(mktemp -d -p "$T") || exit 2
		cp -r "$REPO/asc" "$REPO/bin" "$REPO/tests" "$d/"
		body=$(<"$d/$f")
		[[ $body == *"$old"* ]] || { bad "mutant does not apply: $f: $old"; continue; }
		printf '%s\n' "${body/"$old"/"$new"}" > "$d/$f"
		out=$(HOME="$REPO_HOME" DASH_MUTANTS='' bash "$d/tests/dash.sh" 2>&1)
		seen '  FAIL  ' <<<"$out" && ok "mutant caught: $f: $old" || bad "mutant missed: $f: $old"
	done <<'MUTANTS'
asc/dash.py %%% len(logins) == 1 and %%% len(logins) >= 1 and
asc/dash.py %%% logins[0] == cfg["login"] and %%% True and
asc/dash.py %%% len(hosts) == 1 and hosts[0] == cfg["host"] %%% True
asc/dash.py %%% if (origins != ["https://" + self.server.cfg["host"]] %%% if (False
asc/dash.py %%% or not hmac.compare_digest( %%% or False and hmac.compare_digest(
asc/dash.py %%% if not (self.headers.get("Content-Type") or "").startswith("application/json"): %%% if False:
asc/dash.py %%% if not 0 <= n <= MAX_BODY: %%% if n < 0:
asc/dash.py %%%         if a.get("mode") not in WEB_MODES: %%%         if False:
asc/dash.py %%% (["--force"] if a.get("force") is True else []) %%% (["--force"] if a.get("force") else [])
asc/dash.py %%% or re.fullmatch(r"[0-9]{1,10}", ref)) %%% or True)
asc/dash.py %%% or stat.S_IMODE(st.st_mode) != 0o700 %%% or False
asc/dash.py %%%         old = os.umask(0o177) %%%         old = os.umask(0o022)
asc/dash.py %%% return path[len(prefix):] if path.startswith(prefix + "/") else None %%% return path[len(prefix):]
asc/dash.py %%%         self.send_header("Content-Security-Policy", CSP) %%%         pass
asc/dash.py %%% if s["session_id"] not in fav_sids and not (s["pane"] and s["pane"]["session"] in fav_tmux)] %%% if True]
asc/dash.py %%%         self.send_header("Connection", "close") %%%         pass
asc/dash.py %%%         if not self._allowed(): %%%         if self.server.touch() or not self._allowed():
asc/dash.py %%%                 if _answers(sock_path): %%%                 if False:
asc/dash.py %%%         if self.headers.get_all("Transfer-Encoding") or ( %%%         if False and (
asc/dash.py %%% token.encode("utf-8", "replace") %%% token
asc/past.py %%%                 title = t %%%                 title = title or t
asc/past.py %%%     out.sort(key=lambda c: c["mtime"], reverse=True) %%%     out.sort(key=lambda c: c["mtime"])
MUTANTS
fi

echo "dash: $pass passed, $fail failed"
[ "$fail" = 0 ]
