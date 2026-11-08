#!/usr/bin/env bash
# The dashboard server (asc/dash.py) over its unix socket, with curl, in a throwaway HOME, a
# tmux server of its own and the fake claude of tests/asc.sh.
#   tests/dash.sh                  about 1 min
#   ASC_ONLY=<case,...> tests/dash.sh   only those cases (tests/cases.sh)
# Its mutants (changes to the dashboard each check must catch) are in tests/mutants-dash.txt,
# run by tests/mutate.sh. TEST_STOP_AT=<check>: exit right after that check's FAIL.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || exit 2
export ASC_TMUX_SOCKET="asc-dash-$$" ASC_CLAUDE="$REPO/tests/asc/bin/claude"
export HOME="$T/home" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_RUNTIME_DIR="$T/run" SHELL=/bin/bash
unset TMUX
mkdir -p "$HOME" "$T/fakebash" "$T/run"
chmod 700 "$T/run"
cp "$(command -v bash)" "$T/fakebash/claude"
export FAKE_BASH="$T/fakebash/claude"
# Memory as asctl sees it (asc/memory.py): plenty, unless a test says otherwise.
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' "$1" "$2" > "$T/meminfo"; }
export ASC_MEMINFO="$T/meminfo"
export ASC_SYSTEMCTL="$REPO/tests/asc/bin/systemctl"  # never the real one (On with no server)
mem 32000000 16000000
export PATH="$REPO/tests/dash/bin:$PATH"  # a fake tailscale (the operator setting) and ip (fixed addresses)
tm() { tmux -L "$ASC_TMUX_SOCKET" -f /dev/null "$@"; }
DPID=
. "$REPO/tests/reap.sh"
# What the run started ends before its folder goes (else a dashboard's action still running
# writes into it again after the rm), and before each case (fresh): its jobs and their children
# (the dashboard and its actions among them), then the test tmux server and what its panes run.
# Each call to that server has a time limit: kill-server once hung for hours on a stuck test
# server (and with it this run).
end_started() {
	local srv panes=
	reap $$
	srv=$(timeout -k 1 5 tmux -L "$ASC_TMUX_SOCKET" -f /dev/null display -p '#{pid}' 2>/dev/null) && tree_of "$srv" && panes=${kids[*]}
	timeout -k 2 10 tmux -L "$ASC_TMUX_SOCKET" -f /dev/null kill-server 2>/dev/null
	# shellcheck disable=SC2086  # pids
	end_pids $panes
}
cleanup() {
	end_started
	rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ASC_TMUX_SOCKET"; rm -rf "$T"
}
trap cleanup EXIT
pass=0 fail=0
# One check, one fixed name: `ok NAME` or `bad NAME [DETAILS]`, the same NAME both ways, never a
# value in it, and run once: not in a loop or a function (tests/checklint.py, run by
# tests/lint.sh). DETAILS, what was seen, go on the lines after the FAIL, each indented.
# `skip NAME WHY` for a check that cannot run here.
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); [ "${TEST_STOP_AT-}" != "$1" ] || exit 1; }
skip() { echo "  skip  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; }
# A setup step that did not come (what the test itself started: a claude in a session it made, a
# process of its own): one FAIL, "setup: NAME" (NAME fixed, as a check's), and the suite ends there,
# as each check after it would test nothing. Its exit must end the suite: never inside ( ), $( ),
# <( ), a pipeline or an & job.
stop() { echo "  FAIL  setup: $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); echo "dash: $pass passed, $fail failed (stopped at a setup step)"; exit 1; }
# Waits: CMD... (run in this shell, so a function may set variables) every 0.1 s until it succeeds
# (poll) or fails (poll_gone), at most LIMIT whole seconds of pauses, then once more; non-zero at
# the limit. Each wait's status must be used: a check, `|| stop`, or `|| return 1` in a helper
# (tests/checklint.py).
poll()      { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" && return 0; sleep 0.1; done; "${@:2}"; }
poll_gone() { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" || return 0; sleep 0.1; done; ! "${@:2}"; }
asctl() { "$REPO/bin/asctl" "$@"; }
seen() { grep "$@" >/dev/null; }
# flagged: after a fake claude flag file changed (fake-busy, fake-wait, ...), until each running
# fake claude has written its session file since (it reads the flags as it writes it), at most 5 s:
# never a fixed sleep, which a busy host outlasts
flagged() { : > "$T/flag-mark"; poll 5 flag_seen || stop "each fake claude wrote the flag change"; }
flag_seen() {
	local f p
	for f in "$HOME"/.claude/sessions/*.json; do
		p=${f##*/}; p=${p%.json}
		[[ $p =~ ^[0-9]+$ ]] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = claude ] && seen statusUpdatedAt "$f" || continue
		[[ $(awk '{sub(/.*\) /, ""); print $1}' "/proc/$p/stat" 2>/dev/null) == [RSD] ]] || continue  # stopped: never writes
		[ -n "$(find "$f" -newer "$T/flag-mark" 2>/dev/null)" ] || return 1
	done
}
. "$REPO/tests/cases.sh"
# Put together at run time, so the privacy check does not read them as real ones.
E=@ N=.ts
LOGIN="someone${E}example.com" HOST="machine.example${N}.net"
SOCK="$T/run/asctl/dash.sock"
CONF="$HOME/.config/agent-session-control/dash.json"
# curl to the dashboard as tailscale serve would pass it on: the login and host headers.
# The client address tailscale serve passes on: another machine (TEST-NET-1, RFC 5737).
XFF="X-Forwarded-For: 192.0.2.10"
# As tailscale serve passes a request to a unix socket: Host: localhost, the browser's host in
# X-Forwarded-Host.
XFH="X-Forwarded-Host: $HOST"
dc() { curl -s --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "$XFH" -H "$XFF" "$@"; }
code() { dc -o /dev/null -w '%{http_code}' "$@"; }
# The status of a GET sent as raw header lines (curl folds a doubled Host into one).
raw() {
	python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(("GET /api/state HTTP/1.1\r\n" + "".join(h + "\r\n" for h in sys.argv[2:]) + "Connection: close\r\n\r\n").encode())
print(s.recv(64).split()[1].decode())' "$SOCK" "$XFF" "$XFH" "$@"
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
# The token goes to curl as a header file from printf (a builtin: in no process's arguments,
# which any user on the machine can read with ps); tests/checklint.py refuses it on a command line.
# POST an action; prints the HTTP code, then the body.
post() { dc -w '\n%{http_code}' -X POST -H "Origin: https://$HOST" -H @<(printf 'X-Asctl-Token: %s\n' "$TOK") \
	-H 'Content-Type: application/json' --data "$1" "http://x$PREFIX/api/action"; }
state() { dc "http://x$PREFIX/api/state"; }
# The arguments of the last claude started (a /rename typed after a start comes later in the log).
lastargs() { grep ' args=' "$HOME/claude-args.log" | tail -1; }
# Up once it answers, whatever the answer: with another user as the operator it refuses every
# request (403), the page's files too (000: nothing listens yet).
start_dash() {
	"$REPO/bin/asctl" dash --idle "${1:-0}" 2>"$T/dash.err" & DPID=$!
	local i; for i in $(seq 1 50); do [ "$(code "http://x$PREFIX/app.css")" != 000 ] && return 0; sleep 0.1; done; return 1
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
# A refusal is exit 1 at once; a server that starts anyway is cut off by timeout (124).
refuses() { timeout 5 "$REPO/bin/asctl" dash --idle 0 2>"$T/err"; [ $? = 1 ]; }
# No login: as an install check fetches the manifest, worker and icons, outside the page.
anon() { curl -s --unix-socket "$SOCK" -H "Host: localhost" "$@"; }
acode() { anon -o /dev/null -w '%{http_code}' "$@"; }
REG="$HOME/.local/state/agent-session-control/registry.json"
# Each case's setup: no checks (a case's own checks, the starts of its dashboard among them,
# stay in it). Every case but page starts with fresh, from what the preamble leaves, so that it
# tests the same run alone (ASC_ONLY) as after the cases before it: nothing the run started
# still running, no tmux server, a new HOME and runtime folder, plenty of memory, no prefix, no
# token.
fresh() {
	end_started
	DPID='' PREFIX='' TOK=''
	find "$T" -mindepth 1 -maxdepth 1 ! -name fakebash ! -name work -exec rm -rf {} +
	mkdir -p "$HOME" "$T/run"; chmod 700 "$T/run"
	printf '%s\n' "$W" > "$HOME/fake-trusted"
	mem 32000000 16000000
}
# The config and the socket folder as the config case leaves them, with the prefix $1 if given.
dash_conf() {
	mkdir -p "$(dirname "$CONF")" "$T/run/asctl"
	if [ -n "${1-}" ]; then
		printf '{"login": "%s", "host": "%s", "prefix": "%s"}\n' "$LOGIN" "$HOST" "$1" > "$CONF"
	else
		printf '{"login": "%s", "host": "%s"}\n' "$LOGIN" "$HOST" > "$CONF"
	fi
	chmod 755 "$(dirname "$CONF")" "$T/run"; chmod 644 "$CONF"; chmod 700 "$T/run/asctl"
	PREFIX=${1-}
}
tmux_up() { tm start-server \; set -g exit-empty off || stop "the tmux server for the case"; }
# fresh, configured, the tmux server and a dashboard up, its token in TOK.
dash_up() {
	fresh; dash_conf; tmux_up
	start_dash || stop "a dashboard for the case"
	TOK=$(token)
}
# A claude in tmux session dev, not a favorite; its pid in pid.
dev_up() {
	tm new-session -d -s dev -c "$W" -- "$ASC_CLAUDE" --session-id "$SID" --name dev
	pid=$(claude_in dev) || stop "a claude in dev for the case"
}
# The favorite trio, on (its claude in tmux session trio-ID); its id in id3.
trio_fav() {
	tm new-session -d -s trio -c "$W" -- "$ASC_CLAUDE" --session-id 44444444-5555-4666-8777-888888888888
	p3=$(claude_in trio) || stop "a claude in trio for the case"
	asctl fav "$p3" --name trio >/dev/null || stop "trio a favorite for the case"
	id3=$(jq -r '.entries[] | select(.name == "trio") | .id4' "$REG")
}
trio_off() { asctl off "$id3" --force >/dev/null || stop "trio off for the case"; }
# The page as a browser gets it, in $T/page.
page_get() { dc -f -o "$T/page" "http://x$PREFIX/" || stop "the page for the case"; }
# The maskable icon drawn and cached as the dashboard does it (with no dashboard: the case starts
# its own), its cache file in ic.
icon_cached() {
	ic=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import icons
icons.icon("icon-maskable-512.png"); print(icons.cache_path("icon-maskable-512.png"))' "$REPO") && [ -s "$ic" ] \
		|| stop "the icon cache for the case"
}

case_page() {
echo "== the page's own logic (tests/dash/page.js, in node)"
if command -v node >/dev/null; then
	# Its checks relayed as they come (their names are page.js's own, fixed there), a FAIL's details
	# (the indented lines after it) with it. Any other line, such as the stack trace of an app.js
	# that does not load, goes into one FAIL of its own.
	other='' pfails=0 last=''
	while IFS= read -r line; do
		case $line in
		"  ok    "*) ok "${line#  ok    }"; last= ;;
		"  FAIL  "*) bad "${line#  FAIL  }"; pfails=$((pfails + 1)); last=fail ;;
		"        "*) if [ "$last" = fail ]; then echo "$line"; else other+="$line"$'\n'; fi ;;
		*) other+="$line"$'\n'; last= ;;
		esac
	done < <(node "$REPO/tests/dash/page.js" "$REPO" 2>&1)
	wait $!; prc=$?
	[ -z "$other" ] && ok "page: nothing from node but its checks" || bad "page: nothing from node but its checks" "${other%$'\n'}"
	{ [ "$prc" = 0 ] && [ "$pfails" = 0 ]; } || { [ "$prc" = 1 ] && [ "$pfails" -gt 0 ]; } && ok "page: node's exit status matches its checks" \
		|| bad "page: node's exit status matches its checks" "exit $prc with $pfails FAIL lines"
else
	skip "page: the page's own logic" "node not installed"
fi
}

case_config() {
echo "== config"
fresh
refuses && ok "dash refuses to start without a config" || bad "dash refuses to start without a config" "dash started without a config"
seen 'login and host allowed' "$T/err" && ok "it says what the config needs" || bad "it says what the config needs" "no hint: $(cat "$T/err")"
mkdir -p "$(dirname "$CONF")"
printf '{"login": "%s"}\n' "$LOGIN" > "$CONF"
refuses && ok "dash refuses a config with no host" || bad "dash refuses a config with no host" "dash started with no host"
printf '{"login": "%s", "host": "%s"}\n' "$LOGIN" "$HOST" > "$CONF"
chmod 700 "$(dirname "$CONF")"; chmod 664 "$CONF"
refuses && seen 'chmod go-w' "$T/err" && ok "dash refuses a config others can write" || bad "dash refuses a config others can write" "dash used a config others can write: $(cat "$T/err")"
chmod 644 "$CONF"; chmod 775 "$(dirname "$CONF")"
refuses && ok "dash refuses a config in a folder others can write" || bad "dash refuses a config in a folder others can write" "dash used a config in a folder others can write"
chmod 755 "$(dirname "$CONF")"
mkdir -p "$T/open"; chmod 777 "$T/open"; mv "$CONF" "$T/open/dash.json"; ln -s "$T/open/dash.json" "$CONF"
refuses && ok "and a symlinked config in a folder others can write" || bad "and a symlinked config in a folder others can write" "dash used a symlinked config in an open folder"
rm "$CONF"; mv "$T/open/dash.json" "$CONF"
chmod 755 "$T/run"; mkdir -p "$T/run/asctl"; chmod 755 "$T/run/asctl"
refuses && ok "dash refuses a socket folder that is not 0700" || bad "dash refuses a socket folder that is not 0700" "dash used a socket folder others can open"
chmod 700 "$T/run/asctl"
}

case_socket() {
echo "== the socket and the checks on every request"
fresh; dash_conf; tmux_up
start_dash && [ "$(code http://x/app.css)" = 200 ] && ok "dash listens on its socket" || bad "dash listens on its socket" "no socket, or app.css not served: $(cat "$T/dash.err")"
[ "$(stat -c %a "$SOCK")" = 600 ] && ok "socket mode 0600" || bad "socket mode 0600" "socket mode $(stat -c %a "$SOCK")"
[ "$(stat -c %a "$T/run/asctl")" = 700 ] && ok "socket folder 0700" || bad "socket folder 0700" "socket folder $(stat -c %a "$T/run/asctl")"
[ "$(code http://x/api/state)" = 200 ] && ok "the right login and host: 200" || bad "the right login and host: 200" "the right login and host: $(code http://x/api/state)"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Host: $HOST" http://x/api/state)" = 403 ] && ok "no login header: 403" || bad "no login header: 403" "no login header let in"
r=$(curl -s -D - --unix-socket "$SOCK" -H "Host: $HOST" http://x/)
seen '^HTTP/1.[01] 403' <<<"$r" && seen -i '^content-type: text/html' <<<"$r" && seen '<title>Agent Session Control</title>' <<<"$r" \
	&& seen 'href="favicon.svg?v=' <<<"$r" && ! seen -i 'asctl-token\|@TOKEN@\|<script' <<<"$r" \
	&& ok "the page refused: 403 with its title and tab icon only (no token, no script)" || bad "the page refused: 403 with its title and tab icon only (no token, no script)" "refused page: $r"
curl -s --unix-socket "$SOCK" -H "Host: $HOST" http://x/api/state | seen -x '{"error": "forbidden"}' && ok "the API refused: plain JSON 403" || bad "the API refused: plain JSON 403" "refused API body changed"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: other${E}example.com" -H "Host: $HOST" -H "$XFH" -H "$XFF" http://x/api/state)" = 403 ] && ok "another login: 403" || bad "another login: 403" "another login let in"
[ "$(raw "Host: $HOST" "Tailscale-User-Login: $LOGIN")" = 200 ] && ok "raw request with the right headers: 200" || bad "raw request with the right headers: 200" "raw request refused"
[ "$(raw "Host: $HOST" "Tailscale-User-Login: $LOGIN" "Tailscale-User-Login: $LOGIN")" = 403 ] && ok "the login header twice: 403" || bad "the login header twice: 403" "a doubled login header let in"
[ "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: evil.example" -H "$XFH" -H "$XFF" http://x/api/state)" = 403 ] && ok "another Host (neither localhost nor the host): 403" || bad "another Host (neither localhost nor the host): 403" "another Host let in"
xfh() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "$XFF" "$@" http://x/api/state; }
[ "$(xfh)" = 403 ] && ok "no X-Forwarded-Host: 403" || bad "no X-Forwarded-Host: 403" "no X-Forwarded-Host let in"
[ "$(xfh -H 'X-Forwarded-Host: evil.example')" = 403 ] && ok "another X-Forwarded-Host: 403" || bad "another X-Forwarded-Host: 403" "another X-Forwarded-Host let in"
[ "$(xfh -H "$XFH" -H "$XFH")" = 403 ] && ok "X-Forwarded-Host twice: 403" || bad "X-Forwarded-Host twice: 403" "a doubled X-Forwarded-Host let in"
[ "$(raw "Host: $HOST" "Host: evil.example" "Tailscale-User-Login: $LOGIN")" = 403 ] && ok "two Host headers: 403" || bad "two Host headers: 403" "two Host headers let in"
second="GET /api/state HTTP/1.1
Host: $HOST
$XFF
$XFH
Tailscale-User-Login: $LOGIN
"
r=$(printf 'GET / HTTP/1.1\nHost: %s\n%s\n%s\nTailscale-User-Login: evil%sexample.com\nContent-Length: %s\n\n%s\n' "$HOST" "$XFF" "$XFH" "$E" "$(( ${#second} + $(printf '%s' "$second" | tr -cd '\n' | wc -c) + 2 ))" "$second" | rawsend)
[ "$r" = 403 ] && ok "a request smuggled in a refused one's body is never answered (one request per connection)" || bad "a request smuggled in a refused one's body is never answered (one request per connection)" "smuggling: responses $r"
r=$(printf 'GET /api/state HTTP/1.1\nHost: %s\n%s\n%s\nTailscale-User-Login: %s\n\nGET /api/state HTTP/1.1\nHost: %s\n%s\n%s\nTailscale-User-Login: %s\n\n' "$HOST" "$XFF" "$XFH" "$LOGIN" "$HOST" "$XFF" "$XFH" "$LOGIN" | rawsend)
[ "$r" = 200 ] && ok "keep-alive: the connection closes after one response" || bad "keep-alive: the connection closes after one response" "keep-alive: responses $r"
r=$(printf 'POST /api/action HTTP/1.1\nHost: %s\n%s\n%s\nTailscale-User-Login: %s\nTransfer-Encoding: chunked\n\n0\n\n' "$HOST" "$XFF" "$XFH" "$LOGIN" | rawsend)
[ "$r" = 400 ] && ok "a chunked body: 400" || bad "a chunked body: 400" "a chunked body: $r"
r=$(printf 'GET /api/state HTTP/1.1\nHost: %s\n%s\n%s\nTailscale-User-Login: %s\nContent-Length: 3\n\nabc' "$HOST" "$XFF" "$XFH" "$LOGIN" | rawsend)
[ "$r" = 400 ] && ok "a GET with a body: 400" || bad "a GET with a body: 400" "a GET with a body: $r"
refuses && ok "a second dash refuses the socket in use" || bad "a second dash refuses the socket in use" "a second dash took the socket"
[ "$(code http://x/app.css)" = 200 ] && ok "the first one still answers" || bad "the first one still answers" "the first dash lost its socket"
[ "$(code http://x/nope)" = 404 ] && ok "an unknown path: 404" || bad "an unknown path: 404" "an unknown path: $(code http://x/nope)"
hdr=$(dc -D - -o "$T/page" http://x/)
seen -i "^content-security-policy: default-src 'self'; script-src 'self'" <<<"$hdr" && ok "the page has a strict CSP" || bad "the page has a strict CSP" "no strict CSP"
seen -i '^x-frame-options: DENY' <<<"$hdr" && seen -i '^cache-control: no-store' <<<"$hdr" && ok "no framing, no caching" || bad "no framing, no caching" "framing or caching allowed"
seen -i '^connection: close' <<<"$hdr" && ok "responses say Connection: close" || bad "responses say Connection: close" "no Connection: close"
TOK=$(token)
[ ${#TOK} -ge 40 ] && ok "the page carries a token" || bad "the page carries a token" "no token in the page"
grep -E '<script>|<script [^>]*>[^<]' "$T/page" >/dev/null && bad "the page has no inline script" "the page has inline script" || ok "the page has no inline script"
[ "$(code http://x/app.js)" = 200 ] && [ "$(code http://x/app.css)" = 200 ] && ok "app.js and app.css served" || bad "app.js and app.css served" "static files missing"
# Reading outerHTML (to compare two rows) is fine; any way of turning a string into HTML is not.
grep -nE '(inner|outer)HTML[[:space:]]*\+?=|insertAdjacentHTML|document\.write|createContextualFragment|DOMParser|srcdoc' "$REPO/asc/web/app.js" "$REPO/asc/web/splash.js" >/dev/null && bad "app.js sets text only (no innerHTML)" "app.js writes HTML from strings" || ok "app.js sets text only (no innerHTML)"
grep -nE '\b(window\.)?(confirm|prompt|alert)\(' "$REPO/asc/web/app.js" >/dev/null && bad "app.js asks with its own dialog (no confirm, prompt or alert)" "app.js uses the browser's own dialogs" || ok "app.js asks with its own dialog (no confirm, prompt or alert)"
}

case_pwa() {
echo "== the installable app (PWA)"
dash_up; page_get
m=$(anon "http://x$PREFIX/manifest.json?v=1")
jq -e '.display == "standalone" and .short_name == "Sessions" and .x_title == "Agent Session Control" and (.start_url | startswith("./?v="))
	and .scope == "./" and (.id | test("v=")) and (.icons | length == 4)' <<<"$m" >/dev/null \
	&& ok "the manifest, without a login: standalone, relative URLs, versioned id" || bad "the manifest, without a login: standalone, relative URLs, versioned id" "manifest: $m"
anon -D - -o /dev/null "http://x/manifest.json" | seen -i '^content-type: application/manifest+json' && ok "the manifest's type" || bad "the manifest's type" "manifest type wrong"
miss=; for u in $(jq -r '.icons[].src' <<<"$m"); do [ "$(acode "http://x/$u")" = 200 ] || miss="$miss $u: $(acode "http://x/$u")"; done
[ -z "$miss" ] && ok "every icon the manifest names is served" || bad "every icon the manifest names is served" "not served:$miss"
sw=$(anon http://x/sw.js)
seen -F 'fetch(e.request)' <<<"$sw" && ! seen caches <<<"$sw" && ok "the worker passes through and never caches" || bad "the worker passes through and never caches" "worker: $sw"
miss=; for f in favicon-512.png apple-touch-icon.png splash-512.png icon-192.png icon-512.png icon-maskable-192.png icon-maskable-512.png; do
	h=$(anon -D - -o "$T/icon" "http://x/$f?v=1")
	seen -i '^content-type: image/png' <<<"$h" && seen -i '^cache-control: public' <<<"$h" \
		&& [ "$(head -c 4 "$T/icon" | od -An -tx1 | tr -d ' ')" = 89504e47 ] || miss="$miss $f"
done
[ -z "$miss" ] && ok "every icon is a PNG, served without a login, cacheable" || bad "every icon is a PNG, served without a login, cacheable" "not so:$miss"
# Pixels where the recipe needs them (asc/icons.py): maskable tile edge to edge with white only in
# its corners, the lime knob, a transparent favicon corner, the "any" icons plain white.
px() { anon "http://x/$1" | python3 -I -c 'import struct, sys, zlib
d = sys.stdin.buffer.read(); w, h, _, ct = struct.unpack(">IIBB", d[16:26]); n = 4 if ct == 6 else 3
i = 8; raw = b""
while i < len(d):
    ln, t = struct.unpack(">I4s", d[i:i + 8]); raw += d[i + 8:i + 8 + ln] if t == b"IDAT" else b""; i += 12 + ln
raw = zlib.decompress(raw); x, y = (int(v) for v in sys.argv[1:3]); o = y * (w * n + 1) + 1 + x * n
print(raw[o:o + n].hex())' "$2" "$3"; }
[ "$(px icon-maskable-512.png 0 0)" = ffffff ] && [ "$(px icon-maskable-512.png 256 0)" = 3d3df5 ] \
	&& [ "$(px icon-maskable-512.png 0 256)" = 3d3df5 ] && [ "$(px icon-maskable-512.png 336 256)" = d7f34f ] \
	&& ok "maskable icon: white corners, blue edges, the lime knob" || bad "maskable icon: white corners, blue edges, the lime knob" "maskable icon pixels: $(px icon-maskable-512.png 0 0) $(px icon-maskable-512.png 256 0) $(px icon-maskable-512.png 336 256)"
v=$(px icon-maskable-512.png 26 27)  # on the corner's curve: a blend, so edges are smooth
[ "$v" != ffffff ] && [ "$v" != 3d3df5 ] && ok "anti-aliased edges" || bad "anti-aliased edges" "hard edges: $v"
[ "$(px apple-touch-icon.png 0 0)" = 3d3df5 ] && ok "apple-touch icon: full bleed" || bad "apple-touch icon: full bleed" "apple-touch corner: $(px apple-touch-icon.png 0 0)"
[ "$(px favicon-512.png 0 0)" = 00000000 ] && [ "$(px favicon-512.png 256 4)" = 3d3df5ff ] && ok "favicon: transparent corners" || bad "favicon: transparent corners" "favicon pixels"
[ "$(px icon-192.png 96 96)" = ffffff ] && [ "$(px icon-512.png 256 256)" = ffffff ] && ok "the any icons are plain white" || bad "the any icons are plain white" "any icons not white"
# Drawn once, then served from the cache (the server starts again after every idle exit).
# shellcheck disable=SC2012  # one cache file name, made by asctl
ic=$(ls "$HOME/.cache/agent-session-control/icons/"*-icon-maskable-512.png 2>/dev/null | head -1)
[ -n "$ic" ] && [ "$(stat -c %a "$(dirname "$ic")")" = 700 ] && [ "$(stat -c %a "$ic")" = 600 ] && cmp -s "$ic" <(anon http://x/icon-maskable-512.png) \
	&& ok "icons cached 0600 in a 0700 folder, the same bytes served" || bad "icons cached 0600 in a 0700 folder, the same bytes served" "no icon cache: $ic"
anon -D - -o /dev/null http://x/favicon.svg | seen -i '^content-type: image/svg+xml' && ok "favicon.svg" || bad "favicon.svg" "no favicon.svg"
[ "$(acode -I http://x/sw.js)" = 200 ] && ok "HEAD on a public file" || bad "HEAD on a public file"
r=""; for u in / /app.js /app.css /splash.js /api/state "/api/past?q=" /index.html /sw.js/ /./sw.js /%2e%2e/asc/dash.py /icon-1.png /favicon.ico; do
	[ "$(acode --path-as-is "http://x$u")" = 403 ] || r="$r $u"
done
[ -z "$r" ] && ok "everything else still needs the login (exact paths only)" || bad "everything else still needs the login (exact paths only)" "served without a login:$r"
r=$(printf 'GET /sw.js HTTP/1.1\nHost: localhost\nContent-Length: 3\n\nabc' | rawsend)
[ "$r" = 403 ] && ok "a public path with a body goes through the checks: 403" || bad "a public path with a body goes through the checks: 403" "a public path with a body: $r"
r=$(printf 'GET /sw.js HTTP/1.1\nHost: localhost\nTransfer-Encoding: chunked\n\n0\n\n' | rawsend)
[ "$r" = 403 ] && ok "a public path, chunked: 403" || bad "a public path, chunked: 403" "a public path, chunked: $r"
seen -F 'href="manifest.json?v=' "$T/page" && seen -F 'src="splash-512.png?v=' "$T/page" && ! seen -F '@V@' "$T/page" \
	&& ok "the page links the manifest and icons, versioned" || bad "the page links the manifest and icons, versioned" "page: no manifest link or @V@ left"
# Width, height or top animate on the main thread (a busy page makes them stutter); transform
# and opacity run on the compositor.
seen -E 'transition: transform' "$REPO/asc/web/app.css" && ! seen -E 'transition:[^;]*\b(width|height|top|left)\b' "$REPO/asc/web/app.css" \
	&& ok "the splash animates only transform and opacity" || bad "the splash animates only transform and opacity" "the splash animates a property the compositor cannot"
seen -F 'rel="preload" href="splash.js"' "$T/page" && seen -F 'rel="preload" href="splash-512.png?v=' "$T/page" \
	&& ok "the splash script and image are preloaded" || bad "the splash script and image are preloaded" "splash not preloaded"
seen -F 'serviceWorker.register("sw.js")' "$REPO/asc/web/app.js" && ok "the page registers the worker (relative, works under a prefix)" || bad "the page registers the worker (relative, works under a prefix)" "no worker registration"
}

case_state() {
echo "== state"
dash_up
tm new-session -d -s dev -c "$W" -- "$ASC_CLAUDE" --session-id "$SID" --name dev
pid=$(claude_in dev) || stop "a claude in dev"
s=$(state)
jq -e '.memory.avail_pct > 0 and .memory.total_kb > 0' <<<"$s" >/dev/null && ok "state: memory" || bad "state: memory" "state: no memory"
jq -e --arg s "$SID" '.active | map(select(.session_id == $s and .tmux == "dev")) | length == 1' <<<"$s" >/dev/null && ok "state: the running claude, not favorited" || bad "state: the running claude, not favorited" "state: active list wrong: $s"
jq -e '.top.mine | length > 0 and all(keys == ["mem_kb", "name"])' <<<"$s" >/dev/null && ok "state: own biggest processes, names and sizes only" || bad "state: own biggest processes, names and sizes only" "state: top processes wrong"
jq -e '.top.others_kb | type == "number"' <<<"$s" >/dev/null && ok "state: other users as one total" || bad "state: other users as one total" "state: no others total"
mem 100000000 60000000
jq -e '(.top.mine_kb > 0) and (.top.mine_kb >= (.top.mine | map(.mem_kb) | add)) and (.top.others_kb + .top.mine_kb == 40000000)' <<<"$(state)" >/dev/null \
	&& ok "state: other users and the system are what is in use less this user's (never more than the machine has)" || bad "state: other users and the system are what is in use less this user's (never more than the machine has)" "state: others $(state | jq -c .top)"
mem 100000000 99999990
jq -e '.top.others_kb == 0' <<<"$(state)" >/dev/null && ok "state: less in use than this user's own: the rest is 0, not below" || bad "state: less in use than this user's own: the rest is 0, not below" "state: others below 0: $(state | jq -c .top)"
mem 32000000 16000000
jq -e '.server == true' <<<"$s" >/dev/null && ok "state: the tmux server is up" || bad "state: the tmux server is up" "state: server not seen"
}

case_actions_token() {
echo "== actions: token, origin, body"
dash_up; dev_up
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST without the token: 403" || bad "a POST without the token: 403" "a POST without the token: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://evil.example" -H @<(printf 'X-Asctl-Token: %s\n' "$TOK") -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST from another origin: 403" || bad "a POST from another origin: 403" "a POST from another origin: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H @<(printf 'X-Asctl-Token: %s\n' "$TOK") -H 'Content-Type: application/json' --data '{"action":"fav","ref":"'"$pid"'"}' http://x/api/action)
[ "$r" = 403 ] && ok "a POST with no origin: 403" || bad "a POST with no origin: 403" "a POST with no origin: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H @<(printf 'X-Asctl-Token: %s\n' "$TOK") --data '{"action":"fav"}' http://x/api/action)
[ "$r" = 415 ] && ok "a form POST (not JSON): 415" || bad "a form POST (not JSON): 415" "a form POST: $r"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H @<(printf 'X-Asctl-Token: %s\n' "$TOK") -H 'Content-Type: application/json' --data "$(head -c 5000 /dev/zero | tr '\0' x)" http://x/api/action)
[ "$r" = 413 ] && ok "a body over 4 KB: 413" || bad "a body over 4 KB: 413" "a big body: $r"
[ "$(post '{"action":"fav","ref":"--help"}' | tail -1)" = 400 ] && ok "a ref that is no pid or id: 400" || bad "a ref that is no pid or id: 400" "a bad ref accepted"
[ "$(post '{"action":"on","id":"12; rm"}' | tail -1)" = 400 ] && ok "an id that is not 4 digits: 400" || bad "an id that is not 4 digits: 400" "a bad id accepted"
[ "$(post '{"action":"exec","id":"1234"}' | tail -1)" = 400 ] && ok "an unknown action: 400" || bad "an unknown action: 400" "an unknown action accepted"
r=$(dc -w '%{http_code}' -o /dev/null -X POST -H "Origin: https://$HOST" -H "X-Asctl-Token: tökén" -H 'Content-Type: application/json' --data '{}' http://x/api/action)
[ "$r" = 403 ] && ok "a token with non-ASCII bytes: 403 (no crash)" || bad "a token with non-ASCII bytes: 403 (no crash)" "a non-ASCII token: $r"
[ "$(post '[1]' | tail -1)" = 400 ] && ok "a body that is not an object: 400" || bad "a body that is not an object: 400" "a non-object body accepted"
}

case_actions_fav() {
echo "== actions: favorite, off, on, mode, rename, forget"
dash_up; dev_up
out=$(post '{"action":"fav","ref":"'"$pid"'","name":"das"}')
[ "$(tail -1 <<<"$out")" = 200 ] && ok "fav by pid" || bad "fav by pid" "fav failed: $out"
id=$(state | jq -r '.favorites[0].id4'); TM="das-$id"
s=$(state)
jq -e --arg i "$id" '.favorites[0] | .tmux == "das-\($i)" and .state == "on" and .status == "idle" and .mem_kb > 0' <<<"$s" >/dev/null && ok "state: the favorite, on, idle, its memory" || bad "state: the favorite, on, idle, its memory" "state: favorite wrong: $(jq -c '.favorites[0]' <<<"$s")"
jq -e '.active | length == 0' <<<"$s" >/dev/null && ok "state: no longer in the not-favorited list" || bad "state: no longer in the not-favorited list" "state: still listed as not favorited"
pp=$(tm list-panes -t "=das-$id:" -F '#{pane_pid}'); rss=$(ps -o rss= -p "$pp" --ppid "$pp" | awk '{ s += $1 } END { print s }')
jq -e --argjson r "${rss:-0}" '.favorites[0].mem_kb > 0 and .favorites[0].mem_kb < $r' <<<"$s" >/dev/null && ok "state: memory is PSS (shared pages split), under the tree's RSS" || bad "state: memory is PSS (shared pages split), under the tree's RSS" "state: memory $(jq '.favorites[0].mem_kb' <<<"$s") vs RSS $rss"
jq -e '.favorites[0] | .mode_used == null and .mode_next == "auto"' <<<"$s" >/dev/null && ok "state: the mode used (none in a transcript) and the next start's" || bad "state: the mode used (none in a transcript) and the next start's" "state: modes: $(jq -c '.favorites[0] | {mode_used, mode_next}' <<<"$s")"
mkdir -p "$HOME/.claude/projects/-w"; tr="$HOME/.claude/projects/-w/$SID.jsonl"
printf '{"type":"permission-mode","permissionMode":"auto","sessionId":"%s"}\n' "$SID" > "$tr"
state | jq -e '.favorites[0].mode_used == "auto"' >/dev/null && ok "state: the mode used, read from the transcript" || bad "state: the mode used, read from the transcript" "state: mode not read from the transcript"
printf '{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"%s"}\n' "$SID" >> "$tr"
state | jq -e '.favorites[0] | .mode_used == "acceptEdits" and .mode_next == "acceptEdits"' >/dev/null \
	&& ok "state: the mode claude switched to (the transcript read again when it changes)" || bad "state: the mode claude switched to (the transcript read again when it changes)" "state: mode stale: $(state | jq -c '.favorites[0] | {mode_used, mode_next}')"
rm -f "$tr"
jq -e --arg l "$LOGIN" --arg h "$HOME" '.login == $l and .home == $h and .favorites[0].rc_live == false' <<<"$s" >/dev/null && ok "state: the login, the home folder, remote control not live" || bad "state: the login, the home folder, remote control not live" "state: login, home or rc_live wrong: $(jq -c '{login, home, rc_live: .favorites[0].rc_live}' <<<"$s")"
touch "$HOME/fake-rc" "$HOME/fake-wait"; flagged
state | jq -e '.favorites[0] | .rc_live == true and .status == "waiting" and .busy == "" and .waiting_for == "dialog open" and (.status_at | type) == "number"' >/dev/null && ok "state: remote control live, waiting (not busy), why and since when" || bad "state: remote control live, waiting (not busy), why and since when" "state: rc_live/waiting wrong: $(state | jq -c '.favorites[0] | {rc_live, status, busy}')"
rm -f "$HOME/fake-rc" "$HOME/fake-wait"; flagged
touch "$HOME/fake-task"; flagged
state | jq -e '.favorites[0] | .status == "busy" and .task == "runs a command" and .status_at == null and (.busy | test("runs a command"))' >/dev/null \
	&& ok "state: an idle claude that runs a command (a background one too) is working" || bad "state: an idle claude that runs a command (a background one too) is working" "state: task not shown: $(state | jq -c '.favorites[0] | {status, task, busy}')"
rm -f "$HOME/fake-task"; flagged
state | jq -e '.favorites[0] | .status == "idle" and .task == ""' >/dev/null && ok "state: idle again once the command ended" || bad "state: idle again once the command ended" "state: still working after the command"
touch "$HOME/fake-busy"; flagged
out=$(post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'"}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen 'busy: claude is working' <<<"$out" && ok "off refused while busy, with the reason" || bad "off refused while busy, with the reason" "off while busy: $out"
state | jq -e '.favorites[0].busy | test("is working")' >/dev/null && ok "state: busy reason shown" || bad "state: busy reason shown" "state: no busy reason"
rm -f "$HOME/fake-busy"; flagged
[ "$(post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'"}' | tail -1)" = 200 ] && ok "off" || bad "off" "off failed"
state | jq -e '.favorites[0].state == "off"' >/dev/null && ok "state: off" || bad "state: off" "state: not off"
[ "$(post '{"action":"mode","id":"'"$id"'","tmux":"'"$TM"'","mode":"skip"}' | tail -1)" = 400 ] && ok "mode skip from the page: refused" || bad "mode skip from the page: refused" "mode skip from the page accepted"
[ "$(jq -r ".entries[\"$id\"].mode" "$HOME/.local/state/agent-session-control/registry.json")" = auto ] && ok "the mode stayed auto" || bad "the mode stayed auto" "the mode changed"
[ "$(post '{"action":"mode","id":"'"$id"'","tmux":"'"$TM"'","mode":"manual"}' | tail -1)" = 200 ] && ok "mode manual from the page" || bad "mode manual from the page" "mode manual failed"
asctl mode "$id" skip >/dev/null
[ "$(post '{"action":"on","id":"'"$id"'","tmux":"'"$TM"'"}' | tail -1)" = 200 ] && ok "on (a favorite in skip still starts from the page)" || bad "on (a favorite in skip still starts from the page)" "on failed"
lastargs | seen -- '--permission-mode bypassPermissions' && ok "started with its skip mode" || bad "started with its skip mode" "skip not passed: $(lastargs)"
touch "$HOME/fake-busy"; flagged
[ "$(post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'","force":"yes"}' | tail -1)" = 409 ] && ok "force only when it is true (\"yes\" is not)" || bad "force only when it is true (\"yes\" is not)" "force taken from a non-boolean"
[ "$(post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'","force":true}' | tail -1)" = 200 ] && ok "off with force while busy" || bad "off with force while busy" "off --force failed"
rm -f "$HOME/fake-busy"
[ "$(post '{"action":"rename","id":"'"$id"'","tmux":"'"$TM"'","name":"Bad Name"}' | tail -1)" = 400 ] && ok "rename to a bad name: 400" || bad "rename to a bad name: 400" "a bad name accepted"
asctl mode "$id" auto >/dev/null
[ "$(post '{"action":"on","id":"'"$id"'","tmux":"'"$TM"'"}' | tail -1)" = 200 ] && ok "on from the page, before the renames" || bad "on from the page, before the renames" "on before the rename failed"
state | jq -e --arg t "$TM" '.favorites[0] | .claude_name == $t and .claude_name_kept == false' >/dev/null && ok "state: the name its claude goes by" || bad "state: the name its claude goes by" "state: claude_name: $(state | jq -c '.favorites[0].claude_name')"
touch "$HOME/fake-peer-name"; flagged
state | jq -e '.favorites[0].claude_name_kept == true' >/dev/null && ok "state: a name claude keeps from its own job record (a restart does not change it)" || bad "state: a name claude keeps from its own job record (a restart does not change it)" "state: claude_name_kept not set"
rm -f "$HOME/fake-peer-name"; flagged
pid0=$(state | jq '.favorites[0].pid')
out=$(post '{"action":"rename","id":"'"$id"'","tmux":"'"$TM"'","name":"db"}')
[ "$(tail -1 <<<"$out")" = 200 ] && seen 'claude and its claude.ai title too' <<<"$out" && state | jq -e --argjson p "$pid0" '.favorites[0] | (.tmux | startswith("db-")) and .claude_name == .tmux and .pid == $p' >/dev/null \
	&& ok "rename from the page: the same claude takes the name (/rename)" || bad "rename from the page: the same claude takes the name (/rename)" "rename: $out / $(state | jq -c '.favorites[0] | {tmux, claude_name, pid}')"
TM="db-$id"
touch "$HOME/fake-busy"; flagged
post '{"action":"rename","id":"'"$id"'","tmux":"'"$TM"'","name":"db2"}' >/dev/null; TM="db2-$id"
state | jq -e --arg t "db-$id" '.favorites[0].claude_name == $t' >/dev/null && ok "rename while busy: claude's name not changed" || bad "rename while busy: claude's name not changed" "rename while busy changed claude's name"
rm -f "$HOME/fake-busy"; flagged
out=$(post '{"action":"rename","id":"'"$id"'","tmux":"'"$TM"'","name":"db2"}')
seen 'claude and its claude.ai title too' <<<"$out" && state | jq -e --arg t "$TM" '.favorites[0].claude_name == $t' >/dev/null \
	&& ok "rename to the same name sends it to a claude that goes by another (renamed while busy)" || bad "rename to the same name sends it to a claude that goes by another (renamed while busy)" "same-name rename: $out"
out=$(post '{"action":"restart","id":"'"$id"'","tmux":"'"$TM"'"}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen 'not outside it: nothing to move in' <<<"$out" && [ "$(state | jq '.favorites[0].pid')" = "$pid0" ] \
	&& ok "restart from the page only moves a claude outside its tmux session in (one in it: refused, left alone)" || bad "restart from the page only moves a claude outside its tmux session in (one in it: refused, left alone)" "page restart in tmux: $out"
post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'","force":true}' >/dev/null
# its claude in a Claude Code background session, outside its tmux session
fsid=$(state | jq -r '.favorites[0].session_id')
( exec -a claude "$FAKE_BASH" -c 'trap "exit 143" TERM; sleep 300 & wait' ) >/dev/null 2>&1 & bgp=$!; sleep 0.3
bgfile() { printf '{"pid":%s,"sessionId":"%s","cwd":"/","procStart":"%s","kind":"bg","jobId":"ffff0001","status":"%s"}\n' \
	"$bgp" "$fsid" "$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$bgp/stat")" "$1" > "$HOME/.claude/sessions/$bgp.json"; }
bgfile busy
state | jq -e '.favorites[0] | (.state | startswith("on (outside")) and .outside.how == "background"
	and .outside.text == "a Claude Code background session (job ffff0001)" and .outside.busy == "its claude is working"' >/dev/null \
	&& ok "state: a claude outside its tmux session says where it runs, and why a move in waits" || bad "state: a claude outside its tmux session says where it runs, and why a move in waits" "state outside: $(state | jq -c '.favorites[0] | {state, outside}')"
bgfile idle
state | jq -e '.favorites[0].outside.busy == ""' >/dev/null && ok "state: outside and idle: nothing to wait for" || bad "state: outside and idle: nothing to wait for" "state outside idle: $(state | jq -c '.favorites[0].outside')"
out=$(post '{"action":"restart","id":"'"$id"'","tmux":"'"$TM"'"}')
# shellcheck disable=SC2329  # called by poll
fav_on() { state | jq -e '.favorites[0].state == "on"' >/dev/null; }
[ "$(tail -1 <<<"$out")" = 200 ] && poll 4 fav_on && ! kill -0 "$bgp" 2>/dev/null && state | jq -e '.favorites[0] | .state == "on" and .outside == null' >/dev/null \
	&& ok "restart in tmux from the page: the background session stopped, its claude now in its tmux session" || bad "restart in tmux from the page: the background session stopped, its claude now in its tmux session" "page restart outside: $out / $(state | jq -c '.favorites[0] | {state, outside}')"
wait "$bgp" 2>/dev/null; rm -f "$HOME/.claude/sessions/$bgp.json"
post '{"action":"off","id":"'"$id"'","tmux":"'"$TM"'","force":true}' >/dev/null
ev=$(dc "http://x/api/events?id=$id")
jq -e '.keep == 200 and (.events | length > 5) and ([.events[] | select(.kind != "mode") | .by] | all(. == "page"))
	and any(.events[]; .kind == "mode" and .by == "cli")
	and ([.events[].kind] | index("fav") and index("off") and index("on") and index("rename") and index("refused"))
	and .events[0].kind == "off"' <<<"$ev" >/dev/null && ok "events: the page's actions by page (asctl's own by cli), newest first" || bad "events: the page's actions by page (asctl's own by cli), newest first" "events: $(jq -c '[.events[] | [.kind, .by]]' <<<"$ev")"
[ "$(post '{"action":"forget","id":"'"$id"'","tmux":"'"$TM"'"}' | tail -1)" = 200 ] && state | jq -e '.favorites | length == 0' >/dev/null && ok "forget" || bad "forget" "forget failed"
dc "http://x/api/events?id=$id" | jq -e '.events == []' >/dev/null && ok "events of an id: none from before its forget (an earlier favorite's)" || bad "events of an id: none from before its forget (an earlier favorite's)" "events after forget: $(dc "http://x/api/events?id=$id" | jq -c '[.events[].kind]')"
dc "http://x/api/events" | jq -e '(.events | length > 5) and .events[0].kind == "forget"' >/dev/null && ok "events: all of them without an id" || bad "events: all of them without an id" "events: all"
[ "$(dc -o /dev/null -w '%{http_code}' "http://x/api/events?id=12")" = 400 ] && ok "events: a bad id is 400" || bad "events: a bad id is 400" "events: bad id accepted"
}

case_actions_new() {
echo "== actions: a new session in a folder pasted by path"
dash_up
mkdir -p "$HOME/web" "$HOME/fresh2"; printf '%s\n' "$HOME/web" >> "$HOME/fake-trusted"
n0=$(state | jq '.favorites | length')
[ "$(post '{"action":"new","path":5}' | tail -1)" = 400 ] && ok "new: the path must be text" || bad "new: the path must be text" "a number taken as a path"
[ "$(post '{"action":"new","path":"'"$HOME"'/web","mode":"skip"}' | tail -1)" = 400 ] && ok "new from the page: mode skip refused" || bad "new from the page: mode skip refused" "skip taken from the page"
[ "$(post '{"action":"new","path":"'"$HOME"'/web","rc":"yes"}' | tail -1)" = 400 ] && ok "new: rc only when it is true (\"yes\" is not)" || bad "new: rc only when it is true (\"yes\" is not)" "rc taken from a non-boolean"
[ "$(post '{"action":"new","path":"'"$HOME"'/web","name":"Bad Name"}' | tail -1)" = 400 ] && ok "new: a bad name refused" || bad "new: a bad name refused" "a bad name taken"
out=$(post '{"action":"new","path":"-x"}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen 'is not an absolute path' <<<"$out" && ok "new: a path starting with - stays a path" || bad "new: a path starting with - stays a path" "a dash path: $out"
# trust sent with new is not passed on: its claude waits at the prompt all the same
out=$(post '{"action":"new","path":"'"$HOME"'/fresh2","trust":true}')
idn=$(jq -r --arg c "$HOME/fresh2" '.entries[] | select(.cwd == $c) | .id4' "$REG")
[ "$(tail -1 <<<"$out")" = 200 ] && [ -n "$idn" ] && seen "waiting: fresh2-$idn: its claude waits: Claude Code asks whether to trust $HOME/fresh2" <<<"$out" \
	&& state | jq -e --arg i "$idn" '.favorites[] | select(.id4 == $i) | .state == "waiting for trust"' >/dev/null && ! seen -xF "$HOME/fresh2" "$HOME/fake-trusted" \
	&& ok "new from the page, an untrusted folder: made, its claude waiting for trust, nothing answered" || bad "new from the page, an untrusted folder: made, its claude waiting for trust, nothing answered" "untrusted: $out"
out=$(post '{"action":"trust","id":"'"$idn"'","tmux":"fresh2-'"$idn"'"}')
[ "$(tail -1 <<<"$out")" = 200 ] && state | jq -e --arg i "$idn" '.favorites[] | select(.id4 == $i) | .state == "on"' >/dev/null \
	&& seen -xF "$HOME/fresh2" "$HOME/fake-trusted" && lastargs | seen -- "--session-id " \
	&& ok "trust from the page: the prompt answered for its folder, on, started as new" || bad "trust from the page: the prompt answered for its folder, on, started as new" "trust: $out"
post '{"action":"off","force":true,"id":"'"$idn"'","tmux":"fresh2-'"$idn"'"}' >/dev/null
post '{"action":"forget","id":"'"$idn"'","tmux":"fresh2-'"$idn"'"}' >/dev/null
}

case_past() {
echo "== past conversations"
dash_up
mkdir -p "$HOME/.claude/projects/-x"
P1=22222222-3333-4444-8555-666666666666 P2=33333333-4444-4555-8666-777777777777
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"custom-title","customTitle":"first name"}\n{"type":"custom-title","customTitle":"<b>Old</b> & talk"}\n{"type":"ai-title","aiTitle":"not this"}\n' "$W" "$P1" > "$HOME/.claude/projects/-x/$P1.jsonl"
{ printf '{"type":"user","cwd":"/srv/api","sessionId":"%s"}\n' "$P2"; head -c 200000 /dev/zero | tr '\0' ' '; printf '\n{"type":"agent-name","agentName":"api work"}\n'; } > "$HOME/.claude/projects/-x/$P2.jsonl"
touch -d '1 hour ago' "$HOME/.claude/projects/-x/$P2.jsonl"
P4=44444444-5555-4666-8777-000000000004
printf '{"type":"user","cwd":"/srv/x","sessionId":"%s"}\n{"type":"ai-title","aiTitle":"Old summary"}\n{"type":"ai-title","aiTitle":"Earlyoom setup"}\n' "$P4" > "$HOME/.claude/projects/-x/$P4.jsonl"
touch -d '2 hours ago' "$HOME/.claude/projects/-x/$P4.jsonl"
pj=$(dc "http://x/api/past")
jq -e --arg a "$P1" --arg b "$P2" '[.past[].session_id] | index($a) < index($b)' <<<"$pj" >/dev/null && ok "past: newest first" || bad "past: newest first" "past: order wrong: $pj"
jq -e --arg a "$P1" '.past[] | select(.session_id == $a) | .title == "<b>Old</b> & talk"' <<<"$pj" >/dev/null && ok "past: the latest title, sent as raw text (the page sets it as text)" || bad "past: the latest title, sent as raw text (the page sets it as text)" "past: title changed"
jq -e --arg b "$P2" '.past[] | select(.session_id == $b) | .title == "api work" and .cwd == "/srv/api"' <<<"$pj" >/dev/null && ok "past: title from the end of a big transcript, folder from its start" || bad "past: title from the end of a big transcript, folder from its start" "past: big transcript read wrong"
jq -e --arg d "$P4" '.past[] | select(.session_id == $d) | .title == "Earlyoom setup"' <<<"$pj" >/dev/null && ok "past: without a title given, claude's own (the last ai-title)" || bad "past: without a title given, claude's own (the last ai-title)" "past: ai-title not used"
jq -e '.past | length == 2' <<<"$(dc "http://x/api/past?q=SRV")" >/dev/null && ok "past: search by folder, any case" || bad "past: search by folder, any case" "past: search wrong"
tm new-session -d -s dev2 -c "$W" -- "$ASC_CLAUDE" --resume "$P2"
claude_in dev2 >/dev/null || stop "a claude in dev2"
asctl fav "$P1" >/dev/null
pj=$(dc "http://x/api/past")
jq -e --arg b "$P2" '[.past[].session_id] | index($b) == null' <<<"$pj" >/dev/null && ok "past: a running conversation is not listed" || bad "past: a running conversation is not listed" "past: a running one listed"
jq -e --arg a "$P1" '[.past[].session_id] | index($a) == null' <<<"$pj" >/dev/null && ok "past: a favorite is not listed" || bad "past: a favorite is not listed" "past: a favorite listed"
state | jq -e --arg b "$P2" '.active[] | select(.session_id == $b) | .name == "api work" and (.claude_name | endswith("-1a"))' >/dev/null && ok "a running claude with a made-up name goes by its title" || bad "a running claude with a made-up name goes by its title" "active: made-up name shown: $(state | jq -c .active)"
tm new-session -d -s dev4 -c "$W" -- "$ASC_CLAUDE" --resume "$P4" --name given
claude_in dev4 >/dev/null || stop "a claude in dev4"
state | jq -e --arg d "$P4" '.active[] | select(.session_id == $d) | .name == "given"' >/dev/null && ok "a name given to claude stays, over its title" || bad "a name given to claude stays, over its title" "active: a given name replaced: $(state | jq -c .active)"
tm kill-session -t =dev4
}

case_client() {
echo "== the client must be another machine"
dash_up
nox() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "$XFH" "$@" http://x/api/state; }
myip=$(ip -j addr show | jq -r '[.[].addr_info[].local] | map(select(startswith("127.") or . == "::1" | not)) | .[0]')
[ "$(nox)" = 403 ] && ok "no X-Forwarded-For: 403" || bad "no X-Forwarded-For: 403" "no X-Forwarded-For let in"
[ "$(nox -H 'X-Forwarded-For: 127.0.0.1')" = 403 ] && ok "from loopback: 403" || bad "from loopback: 403" "loopback let in"
[ "$(nox -H 'X-Forwarded-For: ::ffff:127.0.0.1')" = 403 ] && ok "from loopback as IPv4-mapped IPv6: 403" || bad "from loopback as IPv4-mapped IPv6: 403" "mapped loopback let in"
[ "$myip" = 192.0.2.77 ] && [ "$(nox -H "X-Forwarded-For: $myip")" = 403 ] && ok "from one of this machine's own addresses: 403" || bad "from one of this machine's own addresses: 403" "this machine's own address let in ($myip)"
[ "$(nox -H "X-Forwarded-For: 192.0.2.10, $myip")" = 403 ] && ok "a client's own entry first does not hide that the last is this machine" || bad "a client's own entry first does not hide that the last is this machine" "the first entry was trusted"
[ "$(nox -H "X-Forwarded-For: 127.0.0.1, 192.0.2.10")" = 200 ] && ok "the last entry decides (another machine: 200)" || bad "the last entry decides (another machine: 200)" "the last entry not used"
[ "$(nox -H "$XFF" -H "$XFF")" = 403 ] && ok "X-Forwarded-For twice: 403" || bad "X-Forwarded-For twice: 403" "a doubled X-Forwarded-For let in"
[ "$(nox -H 'X-Forwarded-For: nonsense')" = 403 ] && ok "a bad address: 403" || bad "a bad address: 403" "a bad address let in"
}

case_operator() {
echo "== the Tailscale operator"
fresh; dash_conf; tmux_up
# Restart (the setting is cached 30 s), then the status of a request. Not in $(...): a server
# started in a subshell would hold its pipe open.
op_code() { stop_dash; start_dash || return 1; code http://x/api/state > "$T/opc"; }
whoami > "$HOME/fake-operator"
op_code && [ "$(cat "$T/opc")" = 200 ] && ok "this user as the operator: served" || bad "this user as the operator: served" "own operator refused"
echo someone-else > "$HOME/fake-operator"
op_code && [ "$(cat "$T/opc")" = 403 ] && ok "another user as the Tailscale operator: every request refused" || bad "another user as the Tailscale operator: every request refused" "served while another user is the operator"
seen 'refused: another user is the Tailscale operator' "$T/dash.err" && ok "the log says why (the client only gets 403)" || bad "the log says why (the client only gets 403)" "no reason logged"
rm -f "$HOME/fake-operator"; touch "$HOME/fake-tailscale-broken"
op_code && [ "$(cat "$T/opc")" = 403 ] && ok "the setting cannot be read: refused (fail closed)" || bad "the setting cannot be read: refused (fail closed)" "served without reading the operator"
rm -f "$HOME/fake-tailscale-broken"
op_code && [ "$(cat "$T/opc")" = 200 ] && ok "no operator: served" || bad "no operator: served" "no operator refused"
TOK=$(token)
}

case_stale() {
echo "== stale pages, odd bodies, a second claude"
dash_up
tm new-session -d -s trio -c "$W" -- "$ASC_CLAUDE" --session-id 44444444-5555-4666-8777-888888888888
p3=$(claude_in trio) || stop "a claude in trio"
asctl fav "$p3" --name trio >/dev/null; id3=$(jq -r '.entries[] | select(.name == "trio") | .id4' "$HOME/.local/state/agent-session-control/registry.json")
out=$(post '{"action":"off","id":"'"$id3"'","tmux":"old-'"$id3"'"}')
[ "$(tail -1 <<<"$out")" = 400 ] && seen 'out of date' <<<"$out" && tm has-session -t "=trio-$id3" && ok "an action from an out-of-date page (another name): refused, nothing done" || bad "an action from an out-of-date page (another name): refused, nothing done" "a stale page acted: $out"
[ "$(post '{"action":"off","id":"'"$id3"'"}' | tail -1)" = 400 ] && ok "an action without the tmux name: refused" || bad "an action without the tmux name: refused" "an action without the tmux name accepted"
[ "$(post '{"action":"fav","ref":"123","name":[1]}' | tail -1)" = 400 ] && ok "a name that is not a string: 400 (no crash)" || bad "a name that is not a string: 400 (no crash)" "a list as name"
tm new-window -t "=trio-$id3:" -c "$W" -- "$ASC_CLAUDE" --session-id 55555555-6666-4777-8888-999999999999
# shellcheck disable=SC2329  # called by poll
two_claudes() { state | jq -e '.favorites[] | select(.id4 == "'"$id3"'") | .claudes == 2' >/dev/null; }
poll 5 two_claudes && ok "state: two claudes in the favorite's session" || bad "state: two claudes in the favorite's session" "state: claude count wrong"
out=$(post '{"action":"off","id":"'"$id3"'","tmux":"trio-'"$id3"'"}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen 'another claude runs in it' <<<"$out" && ok "off refused: an idle second claude would end too" || bad "off refused: an idle second claude would end too" "off would end a second claude: $out"
post '{"action":"off","id":"'"$id3"'","tmux":"trio-'"$id3"'","force":true}' >/dev/null

tm new-session -d -s quad -c "$W" -- "$ASC_CLAUDE" --session-id 99999999-aaaa-4bbb-8ccc-dddddddddddd
p4=$(claude_in quad) || stop "a claude in quad"
out=$(post '{"action":"fav","ref":"99999999-aaaa-4bbb-8ccc-dddddddddddd","name":"quad"}')
[ "$(tail -1 <<<"$out")" = 200 ] && ok "fav by session id (what the page sends)" || bad "fav by session id (what the page sends)" "fav by session id: $out"
}

case_tmux_hang() {
echo "== a tmux server that does not answer"
dash_up; trio_fav; dev_up
mkdir -p "$HOME/.claude/projects/-hang"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SID" > "$HOME/.claude/projects/-hang/$SID.jsonl"
srv=$(tm display-message -p '#{pid}')
kill -STOP "$srv"
t0=$(date +%s); r=$(dc -m 90 -o "$T/hung" -w '%{http_code}' http://x/api/state); t1=$(date +%s)
pj=$(dc -m 90 http://x/api/past)
kill -CONT "$srv"
[ "$r" = 200 ] && [ $((t1 - t0)) -lt 80 ] && ok "state still answers while tmux hangs" || bad "state still answers while tmux hangs" "state with a hung tmux: $r after $((t1 - t0)) s"
# not "no server", and no state guessed: what tmux would say is not known
jq -e '.tmux_error == "tmux did not answer: no answer in 5 s" and .server == null and .active == []
	and (.favorites | length > 0 and all(.state == "unknown" and .pid == null))' "$T/hung" >/dev/null \
	&& ok "state while tmux hangs: said, not taken for no server, every favorite unknown" || bad "state while tmux hangs: said, not taken for no server, every favorite unknown" "state: $(jq -c '{tmux_error, server, active, favorites: [.favorites[] | {state, pid}]}' "$T/hung")"
jq -e --arg s "$SID" '[.past[].session_id] | index($s) == null' <<<"$pj" >/dev/null \
	&& ok "past while tmux hangs: a live claude's conversation still not listed" || bad "past while tmux hangs: a live claude's conversation still not listed" "past: $(jq -c '[.past[].session_id]' <<<"$pj")"
jq -e '.tmux_error == "" and .server == true and any(.favorites[]; .state == "on")' <<<"$(state)" >/dev/null \
	&& ok "state once tmux answers again: as before" || bad "state once tmux answers again: as before" "state: $(state | jq -c '{tmux_error, server}')"
pgrep -P "$DPID" -x tmux >/dev/null && bad "no tmux client left waiting" "tmux clients left behind" || ok "no tmux client left waiting"
}

case_transcripts() {
echo "== transcripts and session files that could hang or crash a read"
dash_up; dev_up
mkdir -p "$HOME/.claude/projects/-y"
python3 -c 'import sys; open(sys.argv[1], "w").write("[" * 50000 + "\n")' "$HOME/.claude/projects/-y/66666666-7777-4888-8999-aaaaaaaaaaaa.jsonl"
python3 -c 'import sys; open(sys.argv[1], "w").write("[" * 100000)' "$HOME/.claude/sessions/4000001.json"
mkfifo "$HOME/.claude/projects/-y/77777777-8888-4999-8aaa-bbbbbbbbbbbb.jsonl" "$HOME/.claude/sessions/4000002.json"
ln -s /dev/zero "$HOME/.claude/projects/-y/88888888-9999-4aaa-8bbb-cccccccccccc.jsonl"
[ "$(dc -m 10 -o /dev/null -w '%{http_code}' http://x/api/past)" = 200 ] && ok "past: deep JSON, a FIFO and a symlink to /dev/zero neither hang nor crash it" || bad "past: deep JSON, a FIFO and a symlink to /dev/zero neither hang nor crash it" "past hangs or crashes on odd transcripts"
[ "$(dc -m 10 -o /dev/null -w '%{http_code}' http://x/api/state)" = 200 ] && ok "state: deep JSON and a FIFO in the session files neither hang nor crash it" || bad "state: deep JSON and a FIFO in the session files neither hang nor crash it" "state hangs or crashes on odd session files"
dc http://x/api/past | jq -e '[.past[].session_id] | (index("77777777-8888-4999-8aaa-bbbbbbbbbbbb") == null and index("88888888-9999-4aaa-8bbb-cccccccccccc") == null)' >/dev/null && ok "past: a FIFO or a symlink is not listed" || bad "past: a FIFO or a symlink is not listed" "past lists a FIFO or a symlink"
"$REPO/bin/asctl" fav 66666666-7777-4888-8999-aaaaaaaaaaaa 2>"$T/err" >/dev/null
seen 'no conversation' "$T/err" && ! seen Traceback "$T/err" && ok "fav of a deep-JSON transcript: a clean refusal" || bad "fav of a deep-JSON transcript: a clean refusal" "fav of a deep-JSON transcript: $(tail -1 "$T/err")"
state | jq -e '.unknown_files >= 2' >/dev/null && ok "state: they count as session files in an unknown format" || bad "state: they count as session files in an unknown format" "odd session files not counted"
timeout 10 "$REPO/bin/asctl" live >/dev/null && ok "asctl live too" || bad "asctl live too" "asctl live hangs or crashes on them"
rm -f "$HOME/.claude/projects/-y/"* "$HOME/.claude/sessions/4000001.json" "$HOME/.claude/sessions/4000002.json"
}

case_token() {
echo "== the token, a running action at SIGTERM, a socket path too long"
dash_up; trio_fav; trio_off
TOK1=$(token)
[ "$(stat -c %a "$T/run/asctl/token")" = 600 ] && ok "the token file is 0600" || bad "the token file is 0600" "token file mode $(stat -c %a "$T/run/asctl/token")"
stop_dash; start_dash && ok "dash up again, the same token to keep" || bad "dash up again, the same token to keep" "no dash: $(cat "$T/dash.err")"
[ "$(token)" = "$TOK1" ] && ok "the token survives a restart (an open page keeps working)" || bad "the token survives a restart (an open page keeps working)" "a new token after restart"
(post '{"action":"on","id":"'"$id3"'","tmux":"trio-'"$id3"'"}' | tail -1 > "$T/inflight") &
inf=$!
# SIGTERM once the action runs (its tmux session is there; it then waits for claude): a request
# not yet read when the signal comes is refused, rightly, and says nothing about this
# shellcheck disable=SC2329  # called by poll
trio_up() { tm has-session -t "=trio-$id3" 2>/dev/null; }
poll 5 trio_up && ok "the action runs (its tmux session is up) before the SIGTERM" || bad "the action runs (its tmux session is up) before the SIGTERM" "no trio-$id3: $(cat "$T/inflight" 2>&1)"
kill -TERM "$DPID"; wait "$inf"; wait "$DPID" 2>/dev/null; DPID=
[ "$(cat "$T/inflight")" = 200 ] && tm has-session -t "=trio-$id3" && ok "SIGTERM waits for a running action to finish" || bad "SIGTERM waits for a running action to finish" "SIGTERM cut a running action: $(cat "$T/inflight")"
long="$T/run/long/$(printf 'x%.0s' $(seq 1 120)).sock"
timeout 5 "$REPO/bin/asctl" dash --socket "$long" --idle 0 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && seen 'cannot listen' "$T/err" && ok "a socket path too long: a clean error" || bad "a socket path too long: a clean error" "a long socket path: rc $rc, $(tail -1 "$T/err")"
python3 -I -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(30)' "$SOCK" & holder=$!
poll 3 [ -S "$SOCK" ] || stop "the test's own listener on the dashboard's socket"
refuses && seen 'is in use' "$T/err" && ok "a socket another process listens on (asctl-dash.socket) is refused, not removed" || bad "a socket another process listens on (asctl-dash.socket) is refused, not removed" "dash took a socket in use"
[ -S "$SOCK" ] && ok "that socket is still there" || bad "that socket is still there" "that socket was removed"
kill "$holder"; wait "$holder" 2>/dev/null
start_dash && [ "$(code http://x/app.css)" = 200 ] && ok "a socket nothing listens on (stale) is replaced" || bad "a socket nothing listens on (stale) is replaced" "a stale socket blocked the start"
}

case_rc() {
echo "== rc, resurrect and the memory gate from the page"
dash_up; trio_fav
R3='"id":"'"$id3"'","tmux":"trio-'"$id3"'"'
[ "$(post '{"action":"rc","on":true,"title":"Trio work",'"$R3"'}' | tail -1)" = 200 ] && [ "$(jq -r ".entries[\"$id3\"].rc_title" "$REG")" = "Trio work" ] && ok "rc on with a title" || bad "rc on with a title" "rc on from the page failed"
[ "$(post '{"action":"rc","on":"yes",'"$R3"'}' | tail -1)" = 400 ] && ok "rc on must be a boolean" || bad "rc on must be a boolean" "rc took a non-boolean"
[ "$(post '{"action":"rc","on":true,"title":"-x",'"$R3"'}' | tail -1)" = 400 ] && ok "an rc title starting with - refused" || bad "an rc title starting with - refused" "an rc title starting with - accepted"
[ "$(post '{"action":"rc","on":false,'"$R3"'}' | tail -1)" = 200 ] && [ "$(jq -r ".entries[\"$id3\"].rc" "$REG")" = false ] && ok "rc off" || bad "rc off" "rc off failed"
[ "$(post '{"action":"resurrect","on":true,'"$R3"'}' | tail -1)" = 200 ] && state | jq -e '.favorites[] | select(.id4 == "'"$id3"'") | .resurrect and .rc' >/dev/null && ok "resurrect on turns rc on" || bad "resurrect on turns rc on" "resurrect on from the page"
[ "$(post '{"action":"note","text":"x",'"$R3"'}' | tail -1)" = 400 ] && ok "no note action from the page" || bad "no note action from the page" "the page can set a note"
post '{"action":"off","force":true,'"$R3"'}' >/dev/null
mem 32000000 1600000
out=$(post '{"action":"on",'"$R3"'}')
[ "$(tail -1 <<<"$out")" = 409 ] && seen '"error": "memory: 5.0% available' <<<"$out" && ok "on refused when memory is short, with the reason" || bad "on refused when memory is short, with the reason" "on with short memory: $out"
state | jq -e '.memory.warn' >/dev/null && ok "state: the memory warning is on below 15%" || bad "state: the memory warning is on below 15%" "no memory warning"
[ "$(post '{"action":"on","force_memory":"yes",'"$R3"'}' | tail -1)" = 409 ] && ok "force_memory only when it is true" || bad "force_memory only when it is true" "force_memory taken from a non-boolean"
[ "$(post '{"action":"on","force_memory":true,'"$R3"'}' | tail -1)" = 200 ] && ok "on with force_memory (after the page's confirm)" || bad "on with force_memory (after the page's confirm)" "forced on failed"
post '{"action":"off","force":true,'"$R3"'}' >/dev/null
mem 32000000 16000000
touch "$HOME/fake-exit-at-once"
out=$(post '{"action":"on",'"$R3"'}')
rm -f "$HOME/fake-exit-at-once"
[ "$(tail -1 <<<"$out")" = 409 ] && seen '"error": "trio-'"$id3"': tmux session started, but claude exited 3 ' <<<"$out" \
	&& ok "on, a claude that ends at once: refused with its exit, not an unknown error" || bad "on, a claude that ends at once: refused with its exit, not an unknown error" "on, claude ending at once: $out"
post '{"action":"off","force":true,'"$R3"'}' >/dev/null
}

case_notices() {
echo "== the page's notices (boot, the watcher, setup), settings, a conversation's length"
dash_up; trio_fav; trio_off
SD="$HOME/.local/state/agent-session-control"
BID=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import memory; print(memory.boot_id())' "$REPO")
bootjs() { printf '{"boot": "%s", "at": 1, "todo": ["%s"], "why": "memory: watched for under 5 min", "done": %s}\n' "$1" "$id3" "$2" > "$SD/boot.json"; }
bootjs "$BID" false
state | jq -e '.boot == null' >/dev/null && ok "boot.lock not held: no boot shown (one that was killed)" || bad "boot.lock not held: no boot shown (one that was killed)" "boot with no lock: $(state | jq -c .boot)"
python3 -I -c 'import fcntl, sys, time; f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)' "$SD/boot.lock" & bl=$!
poll_gone 5 flock -n "$SD/boot.lock" true || stop "boot.lock held by the test"
state | jq -e --arg i "$id3" '.boot == {"todo": [$i], "why": "memory: watched for under 5 min"}' >/dev/null \
	&& ok "state: what boot still brings back, and why the next waits (boot.lock held)" || bad "state: what boot still brings back, and why the next waits (boot.lock held)" "boot: $(state | jq -c .boot)"
bootjs "$BID" true
state | jq -e '.boot == null' >/dev/null && ok "boot done: no boot shown" || bad "boot done: no boot shown" "boot done: $(state | jq -c .boot)"
bootjs "not-this-boot" false
state | jq -e '.boot == null' >/dev/null && ok "a boot.json from an earlier boot: none shown" || bad "a boot.json from an earlier boot: none shown" "old boot: $(state | jq -c .boot)"
printf '{"boot": "%s", "todo": "x", "why": 5, "done": false}\n' "$BID" > "$SD/boot.json"
state | jq -e '.boot == null' >/dev/null && ok "an odd boot.json: none shown, no error" || bad "an odd boot.json: none shown, no error" "odd boot.json: $(state | jq -c .boot)"
bootjs "$BID" false; mv "$SD/boot.json" "$T/boot.json"; ln -s "$T/boot.json" "$SD/boot.json"
state | jq -e '.boot == null' >/dev/null && ok "a symlinked boot.json is not read" || bad "a symlinked boot.json is not read" "symlinked boot.json read"
kill "$bl"; wait "$bl" 2>/dev/null
rm -f "$SD/boot.json"
state | jq -e '.watch_at == null' >/dev/null && ok "state: no watcher run yet" || bad "state: no watcher run yet" "watch_at: $(state | jq -c .watch_at)"
echo '{"at": 1700000000, "ended": {}}' > "$SD/watch.json"
state | jq -e '.watch_at == 1700000000' >/dev/null && ok "state: when the watcher last ran" || bad "state: when the watcher last ran" "watch_at: $(state | jq -c .watch_at)"
echo '{"at": "soon"}' > "$SD/watch.json"
state | jq -e '.watch_at == null' >/dev/null && ok "an odd watch.json: no time" || bad "an odd watch.json: no time" "odd watch_at: $(state | jq -c .watch_at)"
rm -f "$SD/watch.json"
state | jq -e '.setup == false' >/dev/null && ok "state: not set up (asctl's units not enabled)" || bad "state: not set up (asctl's units not enabled)" "setup: $(state | jq -c .setup)"
mkdir -p "$HOME/fake-units/enabled"; : > "$HOME/fake-units/asctl-boot.service"; : > "$HOME/fake-units/enabled/asctl-boot.service"
stop_dash; start_dash && state | jq -e '.setup == false' >/dev/null && ok "boot enabled, the watcher not: not set up" || bad "boot enabled, the watcher not: not set up" "half set up: $(state | jq -c .setup)"
: > "$HOME/fake-units/enabled/asctl-watch.timer"
state | jq -e '.setup == false' >/dev/null && ok "setup is asked once a minute, not on every request" || bad "setup is asked once a minute, not on every request" "setup not cached"
stop_dash; start_dash && state | jq -e '.setup == true' >/dev/null && ok "state: set up (boot and the watcher enabled)" || bad "state: set up (boot and the watcher enabled)" "set up: $(state | jq -c .setup)"
stop_dash; ASC_SYSTEMCTL=/bin/false start_dash && state | jq -e '.setup == null' >/dev/null && ok "no answer from the user manager: setup unknown (no notice)" || bad "no answer from the user manager: setup unknown (no notice)" "no manager: $(state | jq -c .setup)"
stop_dash; start_dash && ok "dash up again, the user manager answering" || bad "dash up again, the user manager answering" "no dash: $(cat "$T/dash.err")"
rm -rf "$HOME/fake-units"
state | jq -e '.settings == {"auto_restart": false}' >/dev/null && ok "state: auto-restart off by default" || bad "state: auto-restart off by default" "settings: $(state | jq -c .settings)"
ev1=$(state | jq -r .events_v)
[ "$(post '{"action":"auto_restart","on":true}' | tail -1)" = 200 ] && state | jq -e '.settings.auto_restart' >/dev/null \
	&& [ "$(jq -r '.settings.auto_restart' "$REG")" = true ] && ok "auto-restart on from the page" || bad "auto-restart on from the page" "auto-restart on failed"
tail -1 "$SD/events.jsonl" | jq -e '.kind == "setting" and .by == "page" and .text == "auto-restart on"' >/dev/null \
	&& ok "logged as the page's setting" || bad "logged as the page's setting" "setting event: $(tail -1 "$SD/events.jsonl")"
ev2=$(state | jq -r .events_v)
[ -n "$ev1" ] && [ "$ev1" != "$ev2" ] && [ "$ev2" = "$(state | jq -r .events_v)" ] \
	&& ok "state: the event log's version moves with a new event, not otherwise" || bad "state: the event log's version moves with a new event, not otherwise" "events_v: $ev1 then $ev2"
[ "$(post '{"action":"auto_restart","on":"yes"}' | tail -1)" = 400 ] && ok "auto-restart on must be a boolean" || bad "auto-restart on must be a boolean" "auto-restart took a non-boolean"
[ "$(post '{"action":"auto_restart","on":false}' | tail -1)" = 200 ] && state | jq -e '.settings.auto_restart == false' >/dev/null \
	&& ok "auto-restart off from the page" || bad "auto-restart off from the page" "auto-restart off failed"
sid3=$(jq -r ".entries[\"$id3\"].session_id" "$REG")
state | jq -e --arg i "$id3" '.favorites[] | select(.id4 == $i) | .conv_lines == null and .conv_bytes == null' >/dev/null \
	&& ok "state: no length before the watcher counted it" || bad "state: no length before the watcher counted it" "length before a count"
printf '{"%s": {"ino": 7, "size": 1024, "lines": 6, "seen": 2048}}\n' "$sid3" > "$SD/lengths.json"
state | jq -e --arg i "$id3" '.favorites[] | select(.id4 == $i) | .conv_lines == null' >/dev/null && ok "a first count not done yet: no length shown" || bad "a first count not done yet: no length shown" "partial length shown"
printf '{"%s": {"ino": 7, "size": 2048, "lines": 12, "seen": 2048}, "x": {"ino": 1, "size": 1, "lines": 1, "seen": 1}}\n' "$sid3" > "$SD/lengths.json"
state | jq -e --arg i "$id3" '.favorites[] | select(.id4 == $i) | .conv_lines == 12 and .conv_bytes == 2048' >/dev/null \
	&& ok "state: a conversation's lines and bytes, as the watcher counted them" || bad "state: a conversation's lines and bytes, as the watcher counted them" "length: $(state | jq -c --arg i "$id3" '.favorites[] | select(.id4 == $i) | [.conv_lines, .conv_bytes]')"
# No length shown for a record with these fields.
oddlen() { printf '{"%s": {"ino": 7, %s}}\n' "$sid3" "$1" > "$SD/lengths.json"
	state | jq -e --arg i "$id3" '.favorites[] | select(.id4 == $i) | .conv_lines == null' >/dev/null; }
oddlen '"size": 2048, "lines": "12", "seen": 2048' && ok "odd lengths: lines as a string, none shown" || bad "odd lengths: lines as a string, none shown"
oddlen '"size": 2048, "lines": -12, "seen": 2048' && ok "odd lengths: lines below 0, none shown" || bad "odd lengths: lines below 0, none shown"
oddlen '"size": "2048", "lines": 12, "seen": "2048"' && ok "odd lengths: size and seen as strings, none shown" || bad "odd lengths: size and seen as strings, none shown"
rm -f "$SD/lengths.json"
}

case_prefix() {
echo "== prefix and idle exit"
fresh; dash_conf; tmux_up; icon_cached
stop_dash
printf '{"login": "%s", "host": "%s", "prefix": "/u"}\n' "$LOGIN" "$HOST" > "$CONF"
PREFIX=/u
start_dash && [ "$(stat -c %a "$T/run/asctl")" = 700 ] && ok "the socket folder is still 0700 after a restart" || bad "the socket folder is still 0700 after a restart" "socket folder mode changed"
[ "$(code http://x/u/api/state)" = 200 ] && ok "under the prefix: 200" || bad "under the prefix: 200" "prefix: $(code http://x/u/api/state)"
[ "$(code http://x/api/state)" = 404 ] && [ "$(code http://x/x/api/state)" = 404 ] && ok "outside the prefix: 404 (also a path as long as it)" || bad "outside the prefix: 404 (also a path as long as it)" "outside the prefix served"
[ "$(code http://x/u)" = 301 ] && dc -D - -o /dev/null http://x/u | seen -i '^location: /u/' && ok "the prefix without a slash redirects to /u/" || bad "the prefix without a slash redirects to /u/" "no redirect for /u"
TOK=$(token); [ ${#TOK} -ge 40 ] && ok "the page under the prefix" || bad "the page under the prefix" "no page under the prefix"
printf 'not a png' > "$ic"
[ "$(anon http://x/u/icon-maskable-512.png | head -c 4 | od -An -tx1 | tr -d ' ')" = 89504e47 ] && ok "a cached file that is no PNG is drawn again" || bad "a cached file that is no PNG is drawn again" "a broken cache file served"
[ "$(acode http://x/u/manifest.json)" = 200 ] && [ "$(acode http://x/u/icon-192.png)" = 200 ] && ok "the app files under the prefix, without a login" || bad "the app files under the prefix, without a login" "app files under the prefix"
[ "$(acode http://x/manifest.json)" = 403 ] && ok "and not outside it" || bad "and not outside it" "the manifest served outside the prefix"
stop_dash
[ -e "$SOCK" ] && bad "SIGTERM: the server removes its socket" "SIGTERM left the socket file" || ok "SIGTERM: the server removes its socket"
start_dash 2 && ok "dash up, idle exit after 2 s: before the refused requests" || bad "dash up, idle exit after 2 s: before the refused requests" "no dash: $(cat "$T/dash.err")"
for _ in 1 2 3 4 5 6 7; do curl -s -o /dev/null --unix-socket "$SOCK" -H "Host: $HOST" "http://x/u/"; sleep 0.5; done
kill -0 "$DPID" 2>/dev/null && bad "refused requests do not keep dash alive" "refused requests kept dash from its idle exit" || ok "refused requests do not keep dash alive"
DPID=
start_dash 2 && ok "dash up, idle exit after 2 s: before it is left idle" || bad "dash up, idle exit after 2 s: before it is left idle" "no dash: $(cat "$T/dash.err")"
sleep 3.5
kill -0 "$DPID" 2>/dev/null && bad "dash exits when idle" "dash still runs after 2 s idle" || ok "dash exits when idle"
[ -e "$SOCK" ] && bad "it removes its socket on exit" "the socket file was left behind" || ok "it removes its socket on exit"
DPID=
}

case_systemd() {
echo "== systemd socket activation"
fresh; dash_conf /u; tmux_up
if command -v systemd-socket-activate >/dev/null; then
	mkdir -p "$T/sa"; chmod 700 "$T/sa"
	systemd-socket-activate -E HOME -E PATH -E ASC_TMUX_SOCKET ${ASC_MUT_RUN:+-E ASC_MUT_RUN} -l "$T/sa/s.sock" "$REPO/bin/asctl" dash --idle 0 2>"$T/err" & DPID=$!
	poll 3 [ -S "$T/sa/s.sock" ] || stop "systemd-socket-activate listening"
	chmod 666 "$T/sa/s.sock"  # before the first connection, which starts asctl
	curl -s -m 5 -o /dev/null --unix-socket "$T/sa/s.sock" http://x/ ; sleep 0.5
	seen 'open to other users' "$T/err" && ok "a passed socket open to other users is refused" || bad "a passed socket open to other users is refused" "a passed socket 0666 accepted: $(tail -1 "$T/err")"
	stop_dash; rm -f "$T/sa/s.sock"
	systemd-socket-activate -E HOME -E PATH -E ASC_TMUX_SOCKET ${ASC_MUT_RUN:+-E ASC_MUT_RUN} -l "$T/sa/s.sock" "$REPO/bin/asctl" dash --idle 0 2>"$T/sa.err" & DPID=$!
	poll 3 [ -S "$T/sa/s.sock" ] || stop "systemd-socket-activate listening again"
	r=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$T/sa/s.sock" -H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "$XFH" -H "$XFF" http://x/u/api/state)
	[ "$r" = 200 ] && ok "serves on the socket systemd passes" || bad "serves on the socket systemd passes" "socket activation: $r $(tail -2 "$T/sa.err")"
	stop_dash
else
	skip "a passed socket open to other users is refused" "systemd-socket-activate not installed"
	skip "serves on the socket systemd passes" "systemd-socket-activate not installed"
fi
}

run_cases dash page config socket pwa state actions_token actions_fav actions_new past client operator stale tmux_hang transcripts token rc notices prefix systemd

echo "dash: $pass passed, $fail failed"
[ "$fail" = 0 ]
