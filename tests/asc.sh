#!/usr/bin/env bash
# Tests of asctl (registry, live, fav, on, off, rename, mode, forget) with the fake claude in
# tests/asc/bin, a throwaway HOME and a tmux server of their own (tmux -L). Touches neither
# your tmux nor your ~/.claude. Seconds, no network.
#   tests/asc.sh                  prints ok/FAIL per check; exit 0 = all passed
#   ASC_MUTANTS=1 tests/asc.sh    also 30 mutants of asctl, each must make it fail (minutes)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || exit 2
export ASC_TMUX_SOCKET="asc-test-$$" ASC_CLAUDE="$REPO/tests/asc/bin/claude"
export REPO_HOME="${REPO_HOME:-$HOME}"
export HOME="$T/home" XDG_STATE_HOME="" XDG_CONFIG_HOME="" SHELL=/bin/bash
unset TMUX
mkdir -p "$HOME" "$T/fakebash"
cp "$(command -v bash)" "$T/fakebash/claude"
export FAKE_BASH="$T/fakebash/claude"
# Memory as asctl sees it (asc/memory.py): plenty, unless a test says otherwise.
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' "$1" "$2" > "$T/meminfo"; }
export ASC_MEMINFO="$T/meminfo"
mem 32000000 16000000
# Memory pressure counters as the watcher reads them (asc/memory.py): PSI full total (µs), pages
# swapped in and out, OOM kills.
vm() { printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=%s\n' "$1" > "$T/pressure"
	printf 'nr_free_pages 1\npswpin %s\npswpout %s\noom_kill %s\n' "$2" "$3" "$4" > "$T/vmstat"; }
export ASC_PRESSURE="$T/pressure" ASC_VMSTAT="$T/vmstat"
# On starts asctl-tmux.service when no tmux server runs: a fake systemctl (never the real one).
export ASC_SYSTEMCTL="$REPO/tests/asc/bin/systemctl"
vm 0 0 0 0
tm() { tmux -L "$ASC_TMUX_SOCKET" -f /dev/null "$@"; }
# kill-server has a time limit: it once hung for hours on a stuck test server (and with it this run)
cleanup() { timeout -k 2 10 tmux -L "$ASC_TMUX_SOCKET" -f /dev/null kill-server 2>/dev/null; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ASC_TMUX_SOCKET"; rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); [ -z "${TEST_FAILFAST:-}" ] || exit 1; }
asctl() { "$REPO/bin/asctl" "$@"; }
# What asctl writes to stderr (its exit status is checked separately, if at all).
errof() { { "$REPO/bin/asctl" "$@" >/dev/null; } 2>&1; true; }
REG="$HOME/.local/state/agent-session-control/registry.json"
jqe() { jq -r "$1" "$REG"; }
# The arguments of the last claude started (a /rename typed after a start comes later in the log).
lastargs() { grep ' args=' "$HOME/claude-args.log" | tail -1; }
# grep that reads all its input: grep -q stops at the first match, and the writer's broken
# pipe would then fail the pipeline (pipefail), taking the wrong branch of a check.
seen() { grep "$@" >/dev/null; }
. "$REPO/tests/mutate.sh"
# The pid of the live fake claude in a tmux session, waiting up to 10 s.
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
# A live fake claude started by hand in a tmux session, as a user would (folder trusted).
W="$T/work"; mkdir -p "$W" "$T/other"
printf '%s\n' "$W" > "$HOME/fake-trusted"
SID=11111111-2222-4333-8444-555555555555

echo "== no tmux server"
asctl list >/dev/null && ok "list works with nothing set up" || bad "list fails with nothing set up"
asctl live | seen 'no live claude' && ok "live: none" || bad "live: wrong when none"

echo "== fav"
# The server stays up with no session, as asctl-tmux.service will keep it (exit-empty off).
tm start-server \; set -g exit-empty off
tm new-session -d -s dev -c "$W" -- "$ASC_CLAUDE" --session-id "$SID" --name dev
pid=$(claude_in dev) && ok "a hand-started claude is up" || bad "the hand-started claude did not come up"
asctl live | seen "$SID.*dev" && ok "live: lists it with its tmux session" || bad "live: does not list it"
asctl fav "$pid" --name das >/dev/null && ok "fav by pid" || bad "fav by pid failed"
id=$(jqe '.entries | keys[0]')
[[ $id =~ ^[0-9]{4}$ ]] && ok "the id is 4 digits ($id)" || bad "bad id: $id"
tm has-session -t "=das-$id" 2>/dev/null && ok "its tmux session renamed to das-$id" || bad "tmux session not renamed"
[ "$(jqe ".entries[\"$id\"].session_id")" = "$SID" ] && ok "the entry holds its session id" || bad "the entry's session id is wrong"
[ "$(stat -c %a "$REG")" = 600 ] && ok "registry mode 0600" || bad "registry mode $(stat -c %a "$REG")"
asctl fav "$SID" >/dev/null 2>&1 && bad "fav twice accepted" || ok "fav of the same session twice refused"
asctl list | seen "^$id  das-$id .*on " && ok "list: on" || bad "list: not on: $(asctl list)"

echo "== off"
asctl off "$id" >/dev/null && ok "off" || bad "off failed"
tm has-session -t "=das-$id" 2>/dev/null && bad "tmux session still there after off" || ok "its tmux session closed"
runs() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $st != Z* ]]; }  # a zombie has ended
runs "$pid" && bad "claude still runs after off" || ok "claude ended"
[ "$(jqe ".entries[\"$id\"].want_on")" = false ] && ok "want_on false after off" || bad "want_on not false after off"
asctl list | seen "^$id .* off " && ok "list: off" || bad "list: not off"

echo "== on"
asctl on "$id" >/dev/null && ok "on" || bad "on failed"
pid=$(claude_in "das-$id") && ok "claude up in das-$id" || bad "no claude in das-$id"
# tmux with systemd moves each pane into a scope of its own just after starting it; claude must
# be forked after that, in the wrapper's scope, not left in the server's cgroup.
cg() { cut -d: -f3 "/proc/$1/cgroup" 2>/dev/null; }
wp=$(ps -o ppid= -p "$pid" | tr -d ' '); sp=$(tm display -p '#{pid}')
if [ "$(cg "$wp")" = "$(cg "$sp")" ]; then ok "no pane scopes here (no user bus for tmux): nothing to check"
else [ "$(cg "$pid")" = "$(cg "$wp")" ] && ok "claude is in its pane's scope, not the server's cgroup" || bad "claude in $(cg "$pid"), its pane in $(cg "$wp")"; fi
lastargs | grep -q -- "--resume $SID --name das-$id --permission-mode auto" && ok "started with --resume, --name and the mode" || bad "wrong args: $(lastargs)"
[ "$(jqe ".entries[\"$id\"].want_on")" = true ] && ok "want_on true after on" || bad "want_on not true after on"
asctl on "$id" >/dev/null 2>&1 && bad "a second on accepted" || ok "a second on refused (session exists)"
tm rename-session -t "=das-$id" moved
asctl on "$id" >/dev/null 2>&1 && bad "on accepted while a live claude holds the id" || ok "on refused while a live claude holds the session id"
tm rename-session -t "=moved" "das-$id"

echo "== busy"
touch "$HOME/fake-busy"; sleep 0.6
errof off "$id" | grep -q 'busy: claude is working' && ok "off refused: claude busy" || bad "off not refused while busy"
rm -f "$HOME/fake-busy"; sleep 0.6
tm new-window -t "=das-$id:" -- sleep 300
sleep 0.5
errof off "$id" | grep -q 'runs sleep' && ok "off refused: another pane runs sleep" || bad "off not refused for a running pane"
asctl off "$id" --force >/dev/null && ok "off --force" || bad "off --force failed"
tm has-session -t "=das-$id" 2>/dev/null && bad "tmux session still there after --force" || ok "--force closed it all"
ex=$(cut -d' ' -f1 "$HOME/.local/state/agent-session-control/exit/$id" 2>/dev/null)
[ "$ex" = 143 ] && ok "the wrapper recorded exit 143 (SIGTERM)" || bad "exit record: ${ex:-none}"

echo "== exact names, trust prompt, rename, mode"
tm new-session -d -s "das-${id}x" -- sleep 300
asctl on "$id" >/dev/null && ok "on while a longer-named session das-${id}x exists" || bad "on refused by a longer name"
asctl off "$id" >/dev/null
tm has-session -t "=das-${id}x" 2>/dev/null && ok "off left das-${id}x alone" || bad "off killed das-${id}x"
tm kill-session -t "=das-${id}x"
asctl fav "$(cat /proc/sys/kernel/random/uuid)" >/dev/null 2>&1 && bad "fav of an unknown session id accepted" || ok "fav of an unknown session id refused"
SID2=22222222-3333-4444-8555-666666666666
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"agent-name","agentName":"Old Talk"}\n' "$T/other" "$SID2" > "$HOME/.claude/projects/-x/$SID2.jsonl"
asctl fav "$SID2" >/dev/null && ok "fav of a past conversation" || bad "fav of a past conversation failed"
id2=$(jq -r --arg s "$SID2" '.entries[] | select(.session_id == $s) | .id4' "$REG")
[ "$(jqe ".entries[\"$id2\"].tmux")" = "old-talk-$id2" ] && ok "named from its title: old-talk-$id2" || bad "name: $(jqe ".entries[\"$id2\"].tmux")"
asctl on "$id2" >/dev/null && ok "on in a folder not trusted yet: the prompt answered" || bad "on stopped at the trust prompt"
grep -q 'trust: yes' "$HOME/claude-args.log" && ok "trust answered yes (Down, check, Enter)" || bad "trust not answered yes"
asctl off "$id2" >/dev/null
asctl rename "$id2" chat >/dev/null && [ "$(jqe ".entries[\"$id2\"].tmux")" = "chat-$id2" ] && ok "rename" || bad "rename failed"
asctl rename "$id2" 'Bad Name' >/dev/null 2>&1 && bad "a bad name accepted" || ok "a bad name refused"
asctl mode "$id2" skip >/dev/null && asctl on "$id2" >/dev/null
lastargs | grep -q -- '--permission-mode bypassPermissions' && ok "mode skip starts with bypassPermissions" || bad "mode skip not passed"
asctl off "$id2" >/dev/null
asctl mode "$id2" sudo >/dev/null 2>&1 && bad "an unknown mode accepted" || ok "an unknown mode refused"
# A start follows the mode the conversation last ran in (its transcript's last permissionMode).
pm() { printf '{"type":"%s","permissionMode":"%s","sessionId":"%s"}\n' "${2:-permission-mode}" "$1" "$SID2" >> "$HOME/.claude/projects/-x/$SID2.jsonl"; }
started_with() { asctl on "$id2" >/dev/null; lastargs | grep -o -- '--permission-mode [A-Za-z]*' | cut -d' ' -f2; asctl off "$id2" --force >/dev/null; }
pm acceptEdits; [ "$(started_with)" = acceptEdits ] && ok "mode: follows the transcript (acceptEdits, set inside claude)" || bad "mode not followed"
pm bypassPermissions; [ "$(started_with)" = bypassPermissions ] && ok "mode: last ran in skip, the favorite set to skip: skip" || bad "skip with mode skip"
asctl mode "$id2" auto >/dev/null
[ "$(started_with)" = bypassPermissions ] && ok "mode: last ran in skip, the favorite set to auto: skip (kept)" || bad "skip not kept"
pm plan; [ "$(started_with)" = plan ] && ok "mode: plan is followed too" || bad "plan not followed"
pm default; [ "$(started_with)" = manual ] && ok "mode: default (manual's old name) starts as manual" || bad "default not mapped"
pm sudo; [ "$(started_with)" = auto ] && ok "mode: one not known here: its own mode" || bad "an unknown mode passed on"
pm manual user; [ "$(started_with)" = manual ] && ok "mode: the last message's permissionMode counts too" || bad "message mode not followed"
# The mode a running claude is in: the transcript's, unless written before it started (claude
# writes its mode only with a message), then the --permission-mode it was started with.
modenow() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, live
print(next(cli.mode_now(s) for s in live.live() if s["session_id"] == sys.argv[2]))' "$REPO" "$SID2"; }
ts() { printf '{"type":"user","timestamp":"%s","sessionId":"%s"}\n' "$1" "$SID2" >> "$HOME/.claude/projects/-x/$SID2.jsonl"; }
pm acceptEdits; asctl on "$id2" >/dev/null; claude_in "chat-$id2" >/dev/null
ts 2020-01-01T00:00:00.000Z; pm bypassPermissions
[ "$(modenow)" = acceptEdits ] && ok "mode now: a record from before the start: the start's mode" || bad "mode now: $(modenow)"
ts "$(date -u -d '+5 sec' +%Y-%m-%dT%H:%M:%S.000Z)"; pm dontAsk
[ "$(modenow)" = dontAsk ] && ok "mode now: a record since the start: the transcript's" || bad "mode now, newer: $(modenow)"
asctl off "$id2" --force >/dev/null
pm manual user

echo "== a new name for a running claude: /rename when idle, or a restart"
asctl on "$id2" >/dev/null; c1=$(claude_in "chat-$id2")
sname() { jq -r .name "$HOME/.claude/sessions/$1.json"; }
touch "$HOME/fake-busy"; sleep 0.8
out=$(asctl rename "$id2" talk 2>&1)
seen "renamed to talk-$id2; claude's own name not changed now: claude is busy" <<<"$out" && [ "$(sname "$c1")" = "chat-$id2" ] && ! seen 'line: /rename' "$HOME/claude-args.log" \
	&& ok "rename while claude works: the favorite renamed, nothing typed" || bad "rename while busy: $out"
rm -f "$HOME/fake-busy"; sleep 0.8
out=$(asctl rename "$id2" talk 2>&1)
seen 'claude and its claude.ai title too' <<<"$out" && [ "$(claude_in "talk-$id2")" = "$c1" ] && [ "$(sname "$c1")" = "talk-$id2" ] && seen "line: /rename talk-$id2" "$HOME/claude-args.log" \
	&& ok "rename of an idle claude: /rename typed, the same claude takes the name" || bad "live rename: $out / $(sname "$c1")"
touch "$HOME/fake-menu-on"
out=$(asctl rename "$id2" talk3 2>&1)
seen 'not changed now: a menu opened under its prompt; nothing was sent' <<<"$out" && [ "$(sname "$c1")" = "talk-$id2" ] && ok "rename: not when a menu would take Enter" || bad "rename with a menu: $out"
rm -f "$HOME/fake-menu-on"
touch "$HOME/fake-no-rename"
out=$(asctl rename "$id2" talk4 2>&1)
seen "not changed now: typed, but claude did not record the new name" <<<"$out" && ok "rename: typed but not taken by claude: said so" || bad "rename not taken: $out"
rm -f "$HOME/fake-no-rename"
asctl rename "$id2" talk >/dev/null
touch "$HOME/fake-task"; sleep 0.8
out=$(asctl rename "$id2" talk2 --restart 2>&1)
seen 'not restarted now: busy: .* runs a command' <<<"$out" && [ "$(claude_in "talk2-$id2")" = "$c1" ] && ok "rename --restart: not while claude runs a command (a background one too)" || bad "restart with a command running: $out"
asctl off "$id2" >/dev/null 2>&1 && bad "off went ahead while claude runs a command" || ok "off refused while claude runs a command"
rm -f "$HOME/fake-task"; sleep 0.8
AG="$HOME/.claude/projects/-x/$SID2/subagents"; mkdir -p "$AG"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a1.jsonl"
out=$(errof restart "$id2"); seen 'runs a subagent' <<<"$out" && ok "restart: not while a subagent runs" || bad "restart with a subagent: $out"
printf '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}\n' >> "$AG/agent-a1.jsonl"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a2.jsonl"; echo '{"finished":true}' > "$AG/agent-a2.meta.json"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a3.jsonl"; touch -d '20 minutes ago' "$AG/agent-a3.jsonl"
asctl rc "$id2" on --next-start >/dev/null
out=$(asctl restart "$id2" 2>&1); c2=$(claude_in "talk2-$id2")
[ -n "$c2" ] && [ "$c2" != "$c1" ] && [ "$(jqe ".entries[\"$id2\"].session_id")" = "$SID2" ] \
	&& lastargs | seen -- "--resume $SID2 --name talk2-$id2 .*--remote-control talk2-$id2" \
	&& ok "restart: a new claude on the same conversation, with the new name and rc title (finished, ended or old subagents do not hold it)" || bad "restart: $out / $(lastargs)"
grep "pid=$c2 " "$HOME/claude-args.log" | seen "line: /rename talk2-$id2" && ok "a start with rc sends its name to claude.ai (/rename, once rc is up)" || bad "no /rename after an rc start: $(grep "pid=$c2 " "$HOME/claude-args.log")"
out=$(asctl rename "$id2" chat --restart 2>&1); c3=$(claude_in "chat-$id2")
[ -n "$c3" ] && [ "$c3" != "$c2" ] && lastargs | seen -- "--name chat-$id2" && ok "rename --restart of an idle claude: restarted with the new name" || bad "rename --restart: $out"
touch "$HOME/fake-wait"; sleep 0.8
out=$(errof restart "$id2"); seen 'its claude is waiting' <<<"$out" && [ "$(claude_in "chat-$id2")" = "$c3" ] && ok "restart: not while claude waits (a question or dialog would be lost)" || bad "restart while waiting: $out"
rm -f "$HOME/fake-wait" "$AG"/*
asctl rc "$id2" off --next-start >/dev/null; asctl off "$id2" --force >/dev/null
asctl restart "$id2" >/dev/null 2>&1 && bad "restart of an off favorite went ahead" || ok "restart: refused when it is off"

echo "== shared session, stale files, locks, a broken registry"
tm new-session -d -s shared -c "$W" -- "$ASC_CLAUDE" --session-id 33333333-4444-4555-8666-777777777777
tm split-window -t "=shared:" -- sleep 300
p3=$(claude_in shared)
asctl fav "$p3" >/dev/null 2>&1 && bad "fav of a claude sharing its session accepted" || ok "fav refused: shares its tmux session with another pane"
asctl fav "$p3" --whole-session >/dev/null && ok "fav --whole-session accepted" || bad "fav --whole-session failed"
kill -KILL "$p3"; sleep 0.5
[ -f "$HOME/.claude/sessions/$p3.json" ] && ok "SIGKILL leaves the session file (as Claude Code does)" || bad "the fake removed its file on SIGKILL"
asctl live | seen 33333333 && bad "live lists a dead claude from its stale file" || ok "live ignores a stale file (PID check)"
printf '{"pid":%s,"sessionId":"not-a-uuid","cwd":"/"}\n' $$ > "$HOME/.claude/sessions/$$.json"
asctl live | seen 'unknown format' && ok "live reports a session file in an unknown format" || bad "unknown format not reported"
rm -f "$HOME/.claude/sessions/$$.json"
(flock 9; sleep 3) 9>"$HOME/.local/state/agent-session-control/locks/$id" &
sleep 0.3
errof on "$id" | grep -q 'being started or stopped' && ok "on refused while another asctl holds the entry" || bad "entry lock not honoured"
wait
cp "$REG" "$T/reg.bak"; printf '{"entries": [' > "$REG"
errof list | grep -q 'is not valid JSON' && ok "a broken registry refused, with a clear message" || bad "a broken registry not refused cleanly"
asctl forget "$id" >/dev/null 2>&1; [ "$(cat "$REG")" = '{"entries": [' ] && ok "a broken registry left unchanged" || bad "a broken registry was overwritten"
cp "$T/reg.bak" "$REG"
asctl forget "$id" >/dev/null && ! jq -e ".entries[\"$id\"]" "$REG" >/dev/null && ok "forget" || bad "forget failed"

echo "== PID checks, exact kill"
tm new-session -d -s solo -c "$W" -- "$ASC_CLAUDE" --session-id 44444444-5555-4666-8777-888888888888
p4=$(claude_in solo)
asctl fav "$p4" --name solo >/dev/null; id4=$(jq -r '.entries[] | select(.name == "solo") | .id4' "$REG")
asctl off "$id4" >/dev/null
tm new-session -d -s "solo-${id4}x" -- sleep 300
asctl off "$id4" --force >/dev/null
tm has-session -t "=solo-${id4}x" 2>/dev/null && ok "off of a stopped entry left solo-${id4}x alone" || bad "off of a stopped entry killed solo-${id4}x"

echo "== off never reaches outside its own tmux session"
asctl on "$id4" >/dev/null 2>&1 || true
p5=$(claude_in "solo-$id4")
tm rename-session -t "=solo-$id4" userwork; tm new-window -t "=userwork:" -- sleep 300
errof off "$id4" | grep -q 'runs outside its tmux session' && ok "off refused: its claude now runs in another session" || bad "off acted outside its tmux session"
kill -0 "$p5" 2>/dev/null && ok "that claude still runs" || bad "that claude was killed"
errof off "$id4" --force | grep -q 'runs outside' && ok "--force does not reach outside either" || bad "--force reached outside"
cp "$HOME/.claude/sessions/$p5.json" "$HOME/.claude/sessions/1.json"
asctl live | grep -c "^ *$p5 " | grep -qx 1 && ok "a copied session file (wrong file name) is not a second live claude" || bad "a copied session file counted"
rm -f "$HOME/.claude/sessions/1.json"
tm kill-session -t =userwork
echo "== busy: a second claude in the session"
tm new-session -d -s duo -c "$W" -- "$ASC_CLAUDE" --session-id 77777777-8888-4999-8aaa-bbbbbbbbbbbb
p6=$(claude_in duo); tm new-window -t "=duo:" -c "$W" -- "$ASC_CLAUDE" --session-id 88888888-9999-4aaa-8bbb-cccccccccccc
sleep 1; asctl fav "$p6" --name duo --whole-session >/dev/null; id6=$(jq -r '.entries[] | select(.name == "duo") | .id4' "$REG")
touch "$HOME/fake-busy"; sleep 0.8
errof off "$id6" | grep -q 'is working' && ok "off refused: a second claude in the session is working" || bad "off ignored a busy second claude"
rm -f "$HOME/fake-busy"; asctl off "$id6" --force >/dev/null
echo "== a session file asctl cannot read"
"$FAKE_BASH" -c 'sleep 300; true' >/dev/null 2>&1 & sp=$!
sleep 0.3; printf '{"pid": %s, "sessionId": "%s"' "$sp" "$SID" > "$HOME/.claude/sessions/$sp.json"
errof on "$id2" | grep -q 'cannot read' && ok "on refused: an unreadable session file of a running claude" || bad "on ignored an unreadable session file"
kill $(pgrep -P "$sp") "$sp"; wait "$sp" 2>/dev/null; rm -f "$HOME/.claude/sessions/$sp.json"
sleep 300 >/dev/null 2>&1 & np=$!
printf '{"pid": %s, "sessionId": "%s"' "$np" "$SID2" > "$HOME/.claude/sessions/$np.json"
errof on "$id2" | grep -q 'cannot read' && ok "on refused: an unreadable session file names its session id" || bad "on ignored an unreadable file naming its session id"
kill "$np"; wait "$np" 2>/dev/null; rm -f "$HOME/.claude/sessions/$np.json"
echo "== PID checks: start time, name, machine"
"$FAKE_BASH" -c 'sleep 300; true' >/dev/null 2>&1 & sp=$!
sleep 300 >/dev/null 2>&1 & np=$!
sleep 0.3
start_of() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat"; }
sfile() { printf '{"pid":%s,"sessionId":"%s","cwd":"/","procStart":"%s"%s}\n' "$1" "$2" "$3" "${4:-}" > "$HOME/.claude/sessions/$1.json"; }
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000001 "$(start_of "$sp")"
asctl live | seen aaaaaaaa && ok "a claude with its own start time is live" || bad "a claude with its own start time is not live"
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000002 1
asctl live | seen aaaaaaaa && bad "a reused PID (other start time) counted" || ok "a reused PID (other start time) is not live"
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000003 "$(start_of "$sp")" ',"pidDomain":"linux:other:pid:[1]"'
asctl live | seen aaaaaaaa && bad "a file from another machine counted" || ok "a file from another machine (right PID and start) is not live"
sfile "$np" aaaaaaaa-0000-4000-8000-000000000004 "$(start_of "$np")"
asctl live | seen aaaaaaaa && bad "a process not named claude counted" || ok "a process not named claude is not live"
sfile "$sp" "$SID2" 1
errof on "$id2" | grep -q 'cannot read or check' && ok "on refused: a well-formed file of a running claude does not check out" || bad "on ignored a file of a running claude that does not check out"
kill $(pgrep -P "$sp") "$sp" "$np"; wait "$sp" "$np" 2>/dev/null; rm -f "$HOME/.claude/sessions/$sp.json" "$HOME/.claude/sessions/$np.json"
echo "== a background job: Claude Code's version binary, shown in a favorite's pane"
mkdir -p "$T/versions"; cp "$(command -v bash)" "$T/versions/2.1.316"
( exec -a claude "$T/versions/2.1.316" -c 'sleep 300; true' ) >/dev/null 2>&1 & jp=$!
( exec -a other "$T/versions/2.1.316" -c 'sleep 300; true' ) >/dev/null 2>&1 & op=$!
JS=cccccccc-0000-4000-8000-000000000001; sleep 0.3
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"idle"'
sfile "$op" cccccccc-0000-4000-8000-000000000002 "$(start_of "$op")"
asctl live | seen "$JS" && ok "a background job (a version binary run as claude) is live" || bad "a background job is not live"
asctl live | seen cccccccc-0000-4000-8000-000000000002 && bad "a version-named process not run as claude counted" || ok "a version-named process not run as claude is not live"
PS7=dddddddd-aaaa-4bbb-8ccc-000000000007
tm new-session -d -s park -c "$W" -- "$ASC_CLAUDE" --session-id "$PS7"
p7=$(claude_in park); asctl fav "$p7" --name park >/dev/null; id7=$(jq -r '.entries[] | select(.name == "park") | .id4' "$REG")
echo cccc0001 > "$HOME/fake-parked-$PS7"; sleep 0.8
asctl live | grep "$JS" | seen "fav=$id7 *park-$id7 .*shown by claude $p7" && ok "the job takes the pane of the claude showing it" || bad "job not in the pane: $(asctl live)"
asctl live | seen "^ *$p7 " && bad "the claude showing a job listed as well" || ok "the claude showing a job is not listed apart"
asctl list | seen "park-$id7 *on " && ok "its favorite is on" || bad "favorite with a job: $(asctl list | grep park)"
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"busy"'
errof off "$id7" | seen 'is working' && ok "off refused: the job is working" || bad "off ignored a working job"
errof restart "$id7" | seen 'background job' && ok "restart refused: its pane shows a background job" || bad "restart with a job: $(errof restart "$id7")"
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"idle"'
EVF="$HOME/.local/state/agent-session-control/events.jsonl"; offs() { jq -s '[.[] | select(.kind == "off")] | length' "$EVF"; }
c7=$(offs); o=$(asctl off "$id7"); st=$(ps -o stat= -p "$p7")  # ended: gone, or a zombie not yet collected
[ "$(offs)" = $((c7 + 1)) ] && tail -1 "$EVF" | seen 'runs on in Claude Code' && ok "off with a job: one off event, the job named in it" || bad "off events with a job: $c7 then $(offs)"
[[ -z $st || $st == Z* ]] && kill -0 "$jp" 2>/dev/null && seen 'runs on in Claude Code' <<<"$o" && ok "off ends the claude in the pane, not the job (and says so)" || bad "off with a job: $o"
# a job's daemon can be a child of the claude that started it, so inside its pane
tm new-session -d -s daemonhome -- bash -c "exec -a claude '$T/versions/2.1.316' -c 'sleep 300; true'"
for _ in $(seq 1 10); do dp=$(tm list-panes -t "=daemonhome:" -F '#{pane_pid}'); [ "$(cat /proc/"$dp"/comm 2>/dev/null)" = 2.1.316 ] && break; sleep 0.2; done
sfile "$dp" cccccccc-0000-4000-8000-000000000003 "$(start_of "$dp")" ',"kind":"bg","jobId":"cccc0003","status":"idle"'
asctl live | grep cccccccc-0000-4000-8000-000000000003 | seen '(not in tmux)' && ok "a job under a pane, shown by no claude, is in no pane" || bad "a job took a pane by ancestry: $(asctl live)"
tm kill-session -t =daemonhome; rm -f "$HOME/.claude/sessions/$dp.json"
kill $(pgrep -P "$jp") $(pgrep -P "$op") "$jp" "$op"; wait "$jp" "$op" 2>/dev/null
rm -f "$HOME/.claude/sessions/$jp.json" "$HOME/.claude/sessions/$op.json" "$HOME/fake-parked-$PS7"
echo "== busy: a claude asctl cannot read; trust text in a transcript"
asctl on "$id6" >/dev/null && claude_in "duo-$id6" >/dev/null
tm new-window -t "=duo-$id6:" -- "$FAKE_BASH" -c 'sleep 300; true'
sleep 0.5
errof off "$id6" | grep -q 'runs a claude asctl cannot read' && ok "off refused: a pane runs a claude with no session file" || bad "off ignored a claude with no session file"
tm new-window -t "=duo-$id6:" -c "$W" -- "$ASC_CLAUDE" --session-id 99999999-aaaa-4bbb-8ccc-dddddddddddd
for _ in $(seq 1 25); do asctl live | seen 99999999 && break; sleep 0.2; done
errof fav 99999999-aaaa-4bbb-8ccc-dddddddddddd --whole-session | grep -q "tmux session of favorite $id6" && ok "fav refused: the claude runs in another favorite's tmux session" || bad "fav took over another favorite's tmux session"
asctl off "$id6" --force >/dev/null
touch "$HOME/fake-quote"
asctl on "$id6" >/dev/null && ok "on with the trust prompt quoted in a transcript" || bad "on failed with a quoted trust prompt"
grep -q 'quote: got a key' "$HOME/claude-args.log" && bad "asctl pressed keys at a quoted trust prompt" || ok "no key pressed at a quoted trust prompt"
rm -f "$HOME/fake-quote"; asctl off "$id6" --force >/dev/null
echo "== a folder name with tmux format characters"
SID3=33333333-aaaa-4bbb-8ccc-eeeeeeeeeeee
W3="$T/w#{pane_id}#(true)"; mkdir -p "$W3"; printf '%s\n' "$W3" >> "$HOME/fake-trusted"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W3" "$SID3" > "$HOME/.claude/projects/-x/$SID3.jsonl"
asctl fav "$SID3" --name fmt >/dev/null; id7=$(jq -r '.entries[] | select(.name == "fmt") | .id4' "$REG")
asctl on "$id7" >/dev/null && grep -qF "cwd=$W3 " "$HOME/claude-args.log" && ok "claude started in the literal folder (tmux formats not expanded)" || bad "the folder was expanded by tmux: $(lastargs)"
asctl off "$id7" --force >/dev/null

echo "== memory gate"
mem 32000000 1600000
out=$(errof on "$id2")
seen 'memory: 5.0% available, a start needs 20%' <<<"$out" && ! tm has-session -t "=chat-$id2" 2>/dev/null && ok "on refused below 20% available, nothing started" || bad "on below 20%: $out"
mem 4000000 850000
out=$(errof on "$id2")
seen 'would leave 5.9% available, under 15%' <<<"$out" && ok "on refused when the start would leave under 15% (600 MB expected)" || bad "on leaving too little: $out"
asctl on "$id2" --force-memory >/dev/null && ok "on --force-memory starts anyway" || bad "on --force-memory failed"
asctl off "$id2" --force >/dev/null
mem 32000000 16000000
echo "== rc, resurrect, note"
asctl rc "$id2" on --title "My chat" >/dev/null && [ "$(jqe ".entries[\"$id2\"].rc")" = true ] && [ "$(jqe ".entries[\"$id2\"].rc_title")" = "My chat" ] && ok "rc on with a title" || bad "rc on failed"
asctl on "$id2" >/dev/null; lastargs | seen -- '--remote-control My chat' && ok "started with --remote-control and its title" || bad "rc not passed: $(lastargs)"
asctl off "$id2" --force >/dev/null
asctl rc "$id2" off >/dev/null; asctl on "$id2" >/dev/null
lastargs | seen -- '--remote-control' && bad "rc off still passed --remote-control" || ok "rc off: no --remote-control"
echo "== rc now: typed into an idle claude (asc/rclive.py)"
pane=$(tm list-panes -t "=chat-$id2:" -F '#{pane_id}')
bridge() { jq -r 'select(.name == "chat-'"$id2"'") | .bridgeSessionId // ""' "$HOME"/.claude/sessions/*.json; }
screen() { tm capture-pane -p -t "$pane"; }
out=$(asctl rc "$id2" on); seen 'live now' <<<"$out" && [ -n "$(bridge)" ] && seen -x "pid=[0-9]* line: /remote-control My chat" "$HOME/claude-args.log" \
	&& ok "rc on: /remote-control with its title typed, confirmed from the session file" || bad "rc on live: $out / $(bridge) / $(screen | tail -6 | tr "\n" "|")"
out=$(asctl rc "$id2" on); seen 'live already' <<<"$out" && [ "$(grep -c 'line: /remote-control' "$HOME/claude-args.log")" = 1 ] && ok "rc on while live: nothing typed" || bad "rc on again: $out"
out=$(asctl rc "$id2" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && seen 'rc: disconnected' "$HOME/claude-args.log" && [ "$(jqe ".entries[\"$id2\"].rc")" = false ] \
	&& ok "rc off: the dialog, Disconnect selected and confirmed" || bad "rc off live: $out / $(bridge)"
tm send-keys -t "$pane" -l "half typed"; sleep 0.5
out=$(asctl rc "$id2" on); seen 'not changed now: something is typed in its prompt' <<<"$out" && [ -z "$(bridge)" ] && screen | seen 'half typed' \
	&& [ "$(jqe ".entries[\"$id2\"].rc")" = true ] && ok "text in its prompt: nothing typed, the setting saved for the next start" || bad "typed prompt: $out / $(screen | tail -3)"
tm send-keys -t "$pane" BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace; sleep 0.5
touch "$HOME/fake-busy"; sleep 0.6
out=$(asctl rc "$id2" on); seen 'not changed now: claude is busy' <<<"$out" && [ -z "$(bridge)" ] && ok "busy: nothing typed" || bad "busy: $out"
rm -f "$HOME/fake-busy"; sleep 0.6
tm copy-mode -t "$pane"
out=$(asctl rc "$id2" on); seen 'not changed now: its pane is in copy mode' <<<"$out" && [ -z "$(bridge)" ] && ok "copy mode: nothing typed" || bad "copy mode: $out"
tm send-keys -t "$pane" -X cancel
out=$(asctl rc "$id2" on --next-start); seen 'from its next start$' <<<"$out" && [ -z "$(bridge)" ] && ok "--next-start: only the setting" || bad "--next-start: $out"
touch "$HOME/fake-hint"; tm send-keys -t "$pane" x BSpace; sleep 0.5
screen | seen 'Try "fix lint"' && out=$(asctl rc "$id2" on) && seen 'live now' <<<"$out" && [ -n "$(bridge)" ] && ok "a dim placeholder counts as an empty prompt" || bad "placeholder: $out"
rm -f "$HOME/fake-hint"
empty() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import rclive; sys.exit(rclive.prompt_text(rclive.screen(sys.argv[2])) != "")' "$REPO" "$pane"; }
touch "$HOME/fake-menu-first"
out=$(asctl rc "$id2" off); seen 'not changed now: its command menu did not offer /remote-control first; nothing was sent' <<<"$out" && [ -n "$(bridge)" ] && empty \
	&& ! seen 'remote-controller' "$HOME/claude-args.log" && ok "off: another command first in the menu: Enter not pressed, the prompt cleared" || bad "menu first: $out"
rm -f "$HOME/fake-menu-first"
touch "$HOME/fake-slow-dialog"
out=$(asctl rc "$id2" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "off: a slow dialog, its lines quoted in the transcript: waited for the dialog itself" || bad "slow dialog: $out / $(screen | tail -4)"
rm -f "$HOME/fake-slow-dialog"
out=$(asctl rc "$id2" on --title "a@b"); seen 'not changed now: its title has characters asctl does not type' <<<"$out" && [ -z "$(bridge)" ] && ok "a title with @ (a file menu) is not typed" || bad "title @: $out"
asctl rc "$id2" on --title "x;" >/dev/null 2>&1 && bad "a title ending with ; accepted" || ok "a title ending with ; refused (tmux would drop it)"
asctl rc "$id2" on --title "My chat" --next-start >/dev/null
touch "$HOME/fake-menu-on"
out=$(asctl rc "$id2" on); seen 'not changed now: a menu opened under its prompt; nothing was sent' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "on: a menu under the prompt: Enter not pressed, the prompt cleared" || bad "menu on: $out"
rm -f "$HOME/fake-menu-on"
touch "$HOME/fake-mangle"
out=$(asctl rc "$id2" on); seen "its prompt now holds 'x/remote-control My chat'; check it" <<<"$out" && [ -z "$(bridge)" ] && screen | seen 'x/remote-control My chat' \
	&& ok "the prompt not showing the command as typed: Enter not pressed, text not ours left alone" || bad "mangle: $out"
rm -f "$HOME/fake-mangle"
# shellcheck disable=SC2046  # one key name per word, on purpose
tm send-keys -t "$pane" $(printf 'BSpace %.0s' $(seq 1 30)); sleep 0.5
touch "$HOME/fake-two-lines"; tm send-keys -t "$pane" x BSpace; sleep 0.5
out=$(asctl rc "$id2" on); seen "not changed now: its screen does not show claude's prompt" <<<"$out" && [ -z "$(bridge)" ] \
	&& ok "a prompt of two lines (the first empty) is not empty" || bad "two lines: $out"
rm -f "$HOME/fake-two-lines"; tm send-keys -t "$pane" x BSpace; sleep 0.5
[ "$(grep 'line: ' "$HOME/claude-args.log" | grep -vc 'line: /rename ')" = 4 ] && ok "nothing else ever reached its prompt (four rc lines, besides /rename)" || bad "lines entered: $(grep 'line: ' "$HOME/claude-args.log")"
asctl rc "$id2" off --next-start >/dev/null  # the tests below start from rc off
asctl off "$id2" --force >/dev/null
asctl rc "$id2" on --title=-x >/dev/null 2>&1 && bad "a title starting with - accepted" || ok "a title starting with - refused (claude would read an option)"
asctl rc "$id2" on --title "$(printf 'a\tb')" >/dev/null 2>&1 && bad "a title with a control character accepted" || ok "a title with a control character refused"
asctl resurrect "$id2" on >/dev/null && [ "$(jqe ".entries[\"$id2\"].resurrect")" = true ] && [ "$(jqe ".entries[\"$id2\"].rc")" = true ] && ok "resurrect on turns rc on" || bad "resurrect on did not turn rc on"
asctl rc "$id2" off >/dev/null && [ "$(jqe ".entries[\"$id2\"].resurrect")" = true ] && ok "rc can still be turned off by hand" || bad "rc off changed resurrect"
arg=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, registry; e = registry.find(registry.load(), sys.argv[2]); print(" ".join(cli.claude_argv(e, resurrect=True)), "|", " ".join(cli.claude_argv(e)))' "$REPO" "$id2")
[[ ${arg%%|*} == *--remote-control* && ${arg#*|} != *--remote-control* ]] && ok "a resurrect start always has rc; a manual one follows the toggle" || bad "resurrect rc rule: $arg"
asctl note "$id2" "talks to the API" >/dev/null && [ "$(jqe ".entries[\"$id2\"].note")" = "talks to the API" ] && ok "note" || bad "note failed"
asctl note "$id2" "$(head -c 501 /dev/zero | tr '\0' x)" >/dev/null 2>&1 && bad "a note over 500 characters accepted" || ok "a note over 500 characters refused"
asctl note "$id2" -- "-starts with a dash" >/dev/null && ok "a note may start with -" || bad "a note starting with - refused"


echo "== event log"
EV="$HOME/.local/state/agent-session-control/events.jsonl"
[ "$(stat -c %a "$EV")" = 600 ] && ok "events.jsonl mode 0600" || bad "events.jsonl mode $(stat -c %a "$EV")"
jq -e -s 'all(.t > 0 and (.kind | type) == "string" and .by == "cli")' "$EV" >/dev/null && ok "every line is JSON with a time, a kind and who (cli)" || bad "bad event lines"
for k in fav on off rename mode rc resurrect; do
	jq -e -s --arg k "$k" 'any(.kind == $k)' "$EV" >/dev/null || bad "no $k event logged"
done
jq -e -s --arg i "$id2" 'any(.kind == "refused" and .id4 == $i and (.text | test("^on: memory: 5.0% available")))' "$EV" >/dev/null \
	&& ok "a refused on is logged with why" || bad "refused on not logged"
jq -e -s --arg i "$id2" 'any(.kind == "on" and .id4 == $i and (.text | test("past the memory gate")))' "$EV" >/dev/null \
	&& ok "an on past the memory gate says so" || bad "forced on not marked"
asctl events "$id2" | tail -1 | seen -E "^[0-9-]{10} [0-9:]{8}  cli +(off|rc|resurrect|mode|rename) +chat-$id2 " && ok "asctl events ID: its events, oldest first" || bad "asctl events: $(asctl events "$id2" | tail -2)"
ASC_BY=page asctl mode "$id2" auto >/dev/null; ASC_BY='x"y' asctl mode "$id2" auto >/dev/null
tail -2 "$EV" | jq -s -e '.[0].by == "page" and .[1].by == "cli"' >/dev/null && ok "who: ASC_BY page kept, anything else is cli" || bad "who wrong: $(tail -2 "$EV")"
# Pruned: lines past 7 days and broken lines go; past 2 MB the oldest half goes.
{ printf '{"t": 1000, "kind": "on", "by": "cli", "text": "ancient"}\nnot json\n'; cat "$EV"; } > "$EV.x" && mv "$EV.x" "$EV"
asctl mode "$id2" auto >/dev/null
! seen -e ancient -e 'not json' "$EV" && seen '"mode"' "$EV" && ok "pruned: an event past 7 days and a broken line" || bad "not pruned: $(head -2 "$EV")"
n=$(wc -l < "$EV")
python3 -c 'import json,sys,time; t=int(time.time()); sys.stdout.writelines(json.dumps({"t": t, "kind": "on", "by": "cli", "text": "x" * 200}) + "\n" for _ in range(11000))' >> "$EV"
asctl mode "$id2" auto >/dev/null
sz=$(stat -c %s "$EV"); [ "$sz" -le 1100000 ] && [ "$(stat -c %a "$EV")" = 600 ] && tail -1 "$EV" | seen '"mode"' && ok "pruned past 2 MB to under 1 MB, the newest kept ($sz bytes)" || bad "size not bounded: $sz"
asctl events | wc -l | seen -x 50 && ok "asctl events: the latest 50" || bad "events limit"
# A symlink in its place is not followed; the action still works.
mv "$EV" "$EV.keep"; ln -s "$T/elsewhere" "$EV"
out=$( { asctl mode "$id2" auto >/dev/null; } 2>&1 ); r=$?
[ $r = 0 ] && [ ! -e "$T/elsewhere" ] && seen 'event not logged' <<<"$out" && ok "a symlinked events.jsonl is not written through; the action goes on" || bad "symlink: rc=$r $out"
rm -f "$EV"; mv "$EV.keep" "$EV"
# A FIFO in its place: refused at once, never waited on.
mv "$EV" "$EV.keep"; mkfifo "$EV"
out=$( { timeout 10 "$REPO/bin/asctl" mode "$id2" auto >/dev/null; } 2>&1 ); r=$?
[ $r = 0 ] && seen 'not a regular file' <<<"$out" && ok "a FIFO as events.jsonl: refused at once, the action goes on" || bad "FIFO: rc=$r $out"
rm -f "$EV"; mv "$EV.keep" "$EV"
# One event per off; a refusal of any action is logged, an error after a change as failed.
c0=$(jq -s '[.[] | select(.kind == "off")] | length' "$EV"); asctl off "$id2" >/dev/null
[ "$(jq -s '[.[] | select(.kind == "off")] | length' "$EV")" = $((c0 + 1)) ] && ok "one off, one off event" || bad "off events: $c0 then $(jq -s '[.[] | select(.kind == "off")] | length' "$EV")"
tm new-session -d -s "taken-$id2" -- sleep 300
asctl rename "$id2" taken >/dev/null 2>&1
tail -1 "$EV" | jq -e --arg i "$id2" '.kind == "refused" and .id4 == $i and (.text | startswith("rename: tmux session"))' >/dev/null && ok "a refused rename is logged" || bad "refused rename: $(tail -1 "$EV")"
tm kill-session -t "=taken-$id2"
asctl on 9999 >/dev/null 2>&1; tail -1 "$EV" | jq -e '.kind == "refused" and (.text | startswith("on 9999: no favorite"))' >/dev/null && ok "an action on an unknown id: refused, logged" || bad "unknown id: $(tail -1 "$EV")"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, events
e = {"id4": "0000", "tmux": "x-0000"}
try:
    with cli.refusals(e, "on"): raise cli.ActionFailed("half done")
except cli.ActionFailed: pass
r = events.read(limit=1)[0]; assert r["kind"] == "failed" and r["text"] == "on: half done", r' "$REPO" && ok "an error after a change is logged as failed" || bad "failed kind"
# Odd lines never break a read: a far-future or NaN time, a list as who, a lone surrogate.
printf '%s\n' '{"t": 1e20, "kind": "on", "by": "cli"}' '{"t": NaN, "kind": "on"}' '{"t": 5, "kind": "on", "by": []}' >> "$EV"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import events
events.log("mode", {"id4": "0000", "tmux": "s\udce9-0000"}, "folder /tmp/\udce9 \u202e!")
r = events.read(limit=1)[0]; assert r["tmux"] == "s -0000" and r["text"] == "folder /tmp/   !", r
assert events.read(limit=0) == [] and events.read(limit=-1) == []' "$REPO" && ok "a lone surrogate and bidi controls become spaces; limit 0 is none" || bad "surrogate or limit"
asctl events >/dev/null && ok "asctl events reads past odd lines" || bad "asctl events broke on odd lines"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import events
assert events._clean("a\x1b[31mb\nc\x7f") == "a [31mb c "
try: events.log("nonsense")
except ValueError: pass
else: raise SystemExit(1)' "$REPO" && ok "event text: control characters become spaces; an unknown kind is a bug" || bad "event text not cleaned"
echo "== watcher: memory, sizes, following, a pending rename, duplicates"
SD="$HOME/.local/state/agent-session-control"
watch() { ASC_BY=watch asctl watch; }
evn() { jq -s --arg k "$1" '[.[] | select(.kind == $k)] | length' "$SD/events.jsonl"; }
last() { jq -s -c --arg k "$1" '[.[] | select(.kind == $k)] | last' "$SD/events.jsonl"; }
# Seed 6 min of samples (as if the watcher had run every 30 s), from the fake readings now.
# (Runs of the tests come seconds apart, so samples taken since stay inside the 8 min kept.)
seed() { python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 30 * i) for i in range(12, 0, -1)])' "$REPO"; }
watch && jq -e 'length == 1 and .[0].avail_pct == 50 and .[0].oom_kill == 0 and (.[0].boot | length) > 0' "$SD/memory.json" >/dev/null \
	&& [ "$(stat -c %a "$SD/memory.json" "$SD/watch.json" | sort -u)" = 600 ] && ok "watch: a memory sample kept, its files 0600" || bad "watch: no sample: $(cat "$SD/memory.json")"
flock "$SD/watch.lock" sleep 2 & fl=$!; sleep 0.3
watch; [ "$(jq length "$SD/memory.json")" = 1 ] && ok "watch: a run while another holds the lock does nothing" || bad "watch ran twice at once"
wait $fl
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 600), dict(s, t=now - 400), dict(s, boot="old"), dict(s, t=now + 99)])' "$REPO"
watch; jq -e 'length == 2 and .[1].t - .[0].t >= 400 and .[1].t - .[0].t < 420' "$SD/memory.json" >/dev/null && ok "watch: samples kept 8 min, this boot's only, none from the future" || bad "samples kept: $(jq -c '[.[] | [.t, .boot]]' "$SD/memory.json")"
for _ in $(seq 1 125); do watch; done
[ "$(jq length "$SD/memory.json")" = 120 ] && ok "watch: at most 120 samples" || bad "samples kept: $(jq length "$SD/memory.json")"
m0=$(evn memory); mem 32000000 3200000; watch; watch
[ "$(evn memory)" = $((m0 + 1)) ] && last memory | seen 'memory low: 10.0% available' && ok "memory under 15%: one warning, not one per run" || bad "memory warning: $(evn memory) $(last memory)"
mem 32000000 4900000; watch; [ "$(evn memory)" = $((m0 + 1)) ] && ok "15.3%: still warned (back only 1 point over)" || bad "memory warning flaps"
mem 32000000 16000000; watch; last memory | seen 'memory back: 50.0% available' && ok "memory back: logged once" || bad "memory back: $(last memory)"
# A favorite started by asctl in its own session
WS=eeeeeeee-0000-4000-8000-00000000000a
tm new-session -d -s w -c "$W" -- "$ASC_CLAUDE" --session-id "$WS"
pw=$(claude_in w); asctl fav "$pw" --name wat >/dev/null; idw=$(jq -r '.entries[] | select(.name == "wat") | .id4' "$REG")
asctl off "$idw" >/dev/null; asctl on "$idw" >/dev/null; pw=$(claude_in "wat-$idw")
watch; [ "$(jq ".entries[\"$idw\"].rss_kb" "$REG")" -gt 0 ] && ok "watch: the favorite's memory kept as rss_kb" || bad "rss_kb: $(jq ".entries[\"$idw\"].rss_kb" "$REG")"
WS2=eeeeeeee-0000-4000-8000-00000000000b
echo "$WS2" > "$HOME/fake-branch-$WS"; sleep 0.8; watch
jq -e --arg i "$idw" --arg a "$WS" --arg b "$WS2" '.entries[$i] | .session_id == $b and .lineage[0] == $a' "$REG" >/dev/null && last followed | seen "now holds session $WS2" \
	&& ok "followed: a new session id in its own pane (a branch), the old one in lineage" || bad "branch not followed: $(jq -c ".entries[\"$idw\"] | {session_id, lineage}" "$REG")"
echo "$SID2" > "$HOME/fake-branch-$WS2"; sleep 0.8; f0=$(evn followed); watch
[ "$(jq -r ".entries[\"$idw\"].session_id" "$REG")" = "$WS2" ] && [ "$(evn followed)" = "$f0" ] && ok "not followed: a session id another favorite holds" || bad "followed into another favorite's session"
echo "$WS2" > "$HOME/fake-branch-$SID2"; sleep 0.8
mkdir -p "$T/moved"; echo "$T/moved" > "$HOME/fake-cd-$WS2"; sleep 0.8; watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$T/moved" ] && last followed | seen "moved to $T/moved" && ok "followed: a new folder (/cd)" || bad "cd not followed: $(jq -r ".entries[\"$idw\"].cwd" "$REG")"
echo /nonexistent > "$HOME/fake-cd-$WS2"; sleep 0.8; watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$T/moved" ] && ok "not followed: a folder that does not exist" || bad "followed a missing folder"
rm -f "$HOME/fake-cd-$WS2"
touch "$HOME/fake-busy"; sleep 0.6
asctl rename "$idw" wat2 | seen 'The watcher sends it once claude is idle' && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat2-$idw" ] \
	&& ok "rename while busy: pending" || bad "rename pending: $(jq -r ".entries[\"$idw\"].rename_pending" "$REG")"
watch; watch; watch; watch; [ "$(jq -r .name "$HOME/.claude/sessions/$pw.json")" = "wat-$idw" ] && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat2-$idw" ] \
	&& ok "watch: nothing typed while claude works, however long (the rename stays pending)" || bad "renamed while busy, or pending dropped"
rm -f "$HOME/fake-busy"; sleep 0.6; watch
[ "$(jq -r .name "$HOME/.claude/sessions/$pw.json")" = "wat2-$idw" ] && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = null ] && last rename | seen "took the name wat2-$idw" \
	&& ok "watch: the pending rename sent once idle, then cleared" || bad "pending rename: $(jq -r .name "$HOME/.claude/sessions/$pw.json")"
tm new-session -d -s twin -c "$W" -- "$ASC_CLAUDE" --resume "$WS2"; claude_in twin >/dev/null
d0=$(evn duplicate); watch; watch
[ "$(evn duplicate)" = $((d0 + 1)) ] && last duplicate | jq -e --arg i "$idw" '.id4 == $i and (.text | test("2 live claudes"))' >/dev/null \
	&& ok "duplicate: logged once, on its favorite" || bad "duplicate: $(evn duplicate) $(last duplicate)"
[ "$(jq -r ".entries[\"$idw\"].session_id" "$REG")" = "$WS2" ] && ok "a duplicate is never followed or touched" || bad "duplicate changed the entry"
tm kill-session -t =twin

python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import memory
b = memory.boot_id(); S = lambda t, p=50, **k: dict({"t": t, "boot": b, "avail_pct": p, "oom_kill": 0, "psi_full_us": 0, "pswpin": 0, "pswpout": 0}, **k)
full = [S(1000 + 30 * i) for i in range(12)]          # 1000 .. 1330
assert memory.steady(full, now=1340) == "", memory.steady(full, now=1340)
assert "gap" in memory.steady(full[:4] + full[7:], now=1340)   # 1090 -> 1210
assert "no recent" in memory.steady(full, now=1500)
assert "under 5 min" in memory.steady(full[4:], now=1340)
assert "down to 19" in memory.steady(full[:5] + [S(1150, 19)] + full[6:], now=1340)
assert memory.steady([S(t, boot="old") for t in range(1000, 1340, 30)], now=1340)
ev = [S(1000), S(1030, oom_kill=1)]
assert memory.evidence(ev, 1010) == (True, "1 OOM kill(s)"), memory.evidence(ev, 1010)
assert memory.evidence([S(1000), S(1030, psi_full_us=200000)], 1010)[1] == "stalled on memory 0.2 s"
assert memory.evidence([S(1000), S(1030, pswpin=3000)], 1010)[1] == "11 MB swapped"
assert memory.evidence([S(1000, 12), S(1030)], 1010)[1] == "12% available"
assert memory.evidence([S(1000), S(1030, psi_full_us=50000, pswpin=100)], 1010)[0] is False
assert memory.evidence([S(1000), S(1200, oom_kill=1)], 1010)[0] is None   # too far apart
assert memory.evidence([S(1000)], 1010)[0] is None and memory.evidence([S(1020)], 1010)[0] is None
assert memory.evidence([S(1000), S(1010, oom_kill=1)], 1010)[0] is None   # same second: not after
assert memory.evidence([S(1000), S(1010, oom_kill=1), S(1040, oom_kill=1)], 1010) == (True, "1 OOM kill(s)")
assert memory._ok(S(1)) and not memory._ok(S(1, oom_kill="3")) and not memory._ok(S(1, p=float("nan"))) and not memory._ok(S(1, p=True))' "$REPO" \
	&& ok "steady and evidence: gaps, a dip, another boot, each kind of pressure, samples too far apart" || bad "steady/evidence rules"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import live, tmuxctl
tmuxctl.panes = lambda *a, **k: None
assert live.busy_reason("x", []) == "tmux did not list its panes"' "$REPO" && ok "busy: tmux not answering counts as busy" || bad "tmux failure read as not busy"

echo "== watcher: a claude that ended with its tmux session up"
# OOM kills seen: a counter that only grows, as the kernel's does
oomk=0; bump() { oomk=$((oomk + 1)); vm 0 0 0 "$oomk"; }
ended() { last ended | jq -r .text; }
asctl events "$idw" >/dev/null
kill -TERM "$pw"; sleep 1.2; watch
ended | seen '^claude ended, exit 143 (a signal), its tmux session up; .*not started again: auto-restart is off' && ok "ended by SIGTERM: logged, auto-restart off by default" || bad "ended: $(ended)"
e0=$(evn ended); watch; [ "$(evn ended)" = "$e0" ] && ok "an end is logged once" || bad "logged again"
asctl auto-restart on | seen 'auto-restart on' && [ "$(jq -r .settings.auto_restart "$REG")" = true ] && ok "auto-restart on" || bad "auto-restart on failed"
watch; last waiting | jq -r .text | seen 'no memory pressure seen' && ok "no memory pressure seen: not started, said once" || bad "waiting: $(last waiting)"
w0=$(evn waiting); watch; [ "$(evn waiting)" = "$w0" ] && ok "waiting said once" || bad "waiting repeated"
asctl off "$idw" --force >/dev/null; asctl on "$idw" >/dev/null; pw=$(claude_in "wat2-$idw")
seed; watch; bump; kill -TERM "$pw"; sleep 1.2; watch
pn=$(claude_in "wat2-$idw") && [ "$pn" != "$pw" ] && last restarted | jq -r .text | seen 'started again after exit 143 (1 OOM kill' && [ "$(jq ".entries[\"$idw\"].auto_restarted > 0" "$REG")" = true ] \
	&& ok "restarted: ended by a signal, an OOM kill seen, memory steady" || bad "not restarted: $(ended) / $(last waiting) / $(last restarted)"
last on | jq -e '.by == "watch"' >/dev/null && ok "its on is by watch" || bad "on by: $(last on)"
pw=$pn; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; watch
ended | seen 'started again under 30 min ago' && ok "not again within 30 min" || bad "30 min: $(ended)"
python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
tm send-keys -t "=wat2-$idw:" 'sleep 300' Enter; sleep 0.8; seed; watch
last waiting | jq -r .text | seen "its pane's shell runs something" && ! claude_in "wat2-$idw" >/dev/null 2>&1 && ok "its pane runs something: not started" || bad "busy pane: $(last waiting)"
tm send-keys -t "=wat2-$idw:" C-c; sleep 0.5; mem 32000000 4800000; watch
last waiting | jq -r .text | seen 'memory: ' && ok "memory short: waiting" || bad "memory gate: $(last waiting)"
mem 32000000 16000000; watch
last waiting | jq -r .text | seen 'memory: down to 15.0% available in the last 5 min' && ok "after a dip, waits for 5 min steady" || bad "steady: $(last waiting)"
rk() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["rss_kb"] = int(sys.argv[3])' "$REPO" "$idw" "$1"; }
rk 13000000; seed; watch
last waiting | jq -r .text | seen 'would leave' && ! claude_in "wat2-$idw" >/dev/null 2>&1 && ok "steady, but no room for its size: waiting" || bad "room check: $(last waiting)"
rk 400000
seed; bump; watch; pn=$(claude_in "wat2-$idw") && ok "steady again: started" || bad "not started when steady: $(last waiting)"
# An end with no sample after it yet: told by the next run, not taken as "no pressure". (The end is
# 3 s ahead in whole seconds, as samples are: the next sample over 4 s later is surely after it.)
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
pw=$pn; seed; bump; watch; kill -TERM "$pw"; sleep 1.2
printf '143 %s %s %s\n' "$(( $(date +%s) + 3 ))" "$(cat /proc/sys/kernel/random/boot_id)" "$(tm display -p -t "=wat2-$idw:" '#{pane_pid}')" > "$SD/exit/$idw"; watch
ended | seen 'no memory samples around that time' || bad "no sample after: $(ended)"
bump; sleep 4.2; watch; pn=$(claude_in "wat2-$idw") && last restarted | seen '1 OOM kill' && ok "no sample after the end yet: asked again next run, then started" || bad "evidence not asked again: $(jq -s -c '.[-4:] | map([.kind, .text])' "$SD/events.jsonl") / $(cat "$SD/exit/$idw" 2>&1) / $(jq -c '[.[-3:][] | [.t, .oom_kill]]' "$SD/memory.json")"
pw=$pn; watch; kill -INT "$pw"; sleep 1.2; bump; watch
ended | seen 'exit 0, .*not started again: it did not end by a signal' && ok "exit 0 (the user ended it): never started again" || bad "exit 0: $(ended)"
printf '143 %s some-other-boot\n' "$(date +%s)" > "$SD/exit/$idw"; watch
ended | seen 'not started again: it ended before this boot' && ok "an exit of another boot: not started again" || bad "other boot: $(ended)"
: > "$HOME/no-boot"; printf '143 %s\n' "$(( $(date +%s) + 1 ))" > "$SD/exit/$idw"; ASC_BOOT_ID="$HOME/no-boot" watch
ended | seen 'not started again: it ended before this boot' && ok "no boot id, here or in the record: not taken as this boot" || bad "empty boot: $(ended)"
rm -f "$SD/exit/$idw"; watch
ended | seen 'no exit record' && ok "no exit record: logged, not started" || bad "no record: $(ended)"
bootid=$(cat /proc/sys/kernel/random/boot_id); ppid_=$(tm display -p -t "=wat2-$idw:" '#{pane_pid}')
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
printf '143 %s %s %s\n' "$(( $(date +%s) - 3700 ))" "$bootid" "$ppid_" > "$SD/exit/$idw"; seed; watch
ended | seen 'it ended over 60 min ago' && ok "an end over an hour old: not started again" || bad "age: $(ended)"
printf '143 %s %s %s\n' "$(date +%s)" "$bootid" 1 > "$SD/exit/$idw"; seed; bump; sleep 1.1; watch
ended | seen 'runs another process than the one asctl started' && ok "its pane is not the shell asctl-wrap left: not started" || bad "pane pid: $(ended)"
printf '143 %s %s %s\n' "$(date +%s)" "$bootid" "$ppid_" > "$SD/exit/$idw"; seed; bump; tm copy-mode -t "=wat2-$idw:"; sleep 1.1; watch
ended | seen 'copy mode' && ok "its pane scrolled back: not started" || bad "copy mode: $(ended)"
tm send-keys -t "=wat2-$idw:" -X cancel
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import cli, tmuxctl, registry
e = registry.find(registry.load(), sys.argv[2]); p = tmuxctl.panes(e["tmux"])[0]
tmuxctl.client_activity = lambda s: [int(time.time()) - 5]
assert "typed" in cli.pane_free(e, p["pane_id"], p["pane_pid"])
tmuxctl.client_activity = lambda s: None
assert "clients" in cli.pane_free(e, p["pane_id"], p["pane_pid"])
tmuxctl.client_activity = lambda s: [int(time.time()) - 500]
assert cli.pane_free(e, p["pane_id"], p["pane_pid"]) == ""' "$REPO" "$idw" && ok "someone typing in it (a recent key from a client): not started" || bad "client activity check"
rm -f "$SD/exit/$idw"
# Odd values never crash a run nor pass for evidence.
python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); from asc import registry
p = registry.state_dir() + "/watch.json"; d = json.load(open(p))
d["ended"][sys.argv[2]] = {"key": "x", "reason": "", "has": "yes"}; json.dump(d, open(p, "w"))
with registry.changing() as r: r["settings"] = ["on"]; r["entries"][sys.argv[2]]["rss_kb"] = "big"' "$REPO" "$idw"
f0=$(evn failed); watch; watch
[ "$(evn failed)" = "$f0" ] && ok "odd watch.json, settings and rss_kb: no crash, no failed events" || bad "odd values: $(last failed)"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import watch, events, registry
def boom(*a): raise RuntimeError("boom")
watch.cli.live_in = boom
st = watch._state(registry.state_dir()); n = len(registry.load()["entries"])
c = lambda: sum(1 for r in events.read(limit=10000) if r["kind"] == "failed" and r["text"] == "watch: RuntimeError: boom")
c0 = c(); watch._run(st); c1 = c(); watch._run(st); c2 = c()
assert c1 - c0 == n and c2 == c1, (n, c0, c1, c2)
watch.cli.live_in = lambda *a: None; watch._run(st)
assert not st["failed"], st["failed"]' "$REPO" && ok "an error with one entry: logged once while it lasts, the others go on" || bad "failed dedupe"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as r: r["settings"] = {"auto_restart": True}; r["entries"][sys.argv[2]]["rss_kb"] = 400000' "$REPO" "$idw"
# A restart keeps the session (the dead pane runs claude again), so whoever is attached stays.
printf '%s\n' "$T/moved" >> "$HOME/fake-trusted"
asctl off "$idw" --force >/dev/null; asctl on "$idw" >/dev/null; pw=$(claude_in "wat2-$idw")
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
born=$(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}')
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; watch
pn=$(claude_in "wat2-$idw") && [ "$(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}')" = "$born" ] \
	&& ok "restart in place: the same session and pane" || bad "restart in place: $born vs $(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}') / $(ended) / $(last waiting) / $(last failed)"
pw=$pn
# Each check On makes still holds, and a refusal stamps nothing (it is tried again next run).
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; mv "$T/moved" "$T/moved.x"; watch
last waiting | jq -r .text | seen "folder $T/moved does not exist" && tm has-session -t "=wat2-$idw" && [ "$(jq ".entries[\"$idw\"].auto_restarted" "$REG")" = 1 ] \
	&& ok "On refuses (folder gone): its session kept, nothing stamped, said once" || bad "folder gone: $(last waiting) / $(jq ".entries[\"$idw\"].auto_restarted" "$REG")"
mv "$T/moved.x" "$T/moved"
tm split-window -t "=wat2-$idw:" -- sleep 300; seed; watch
last waiting | jq -r .text | seen 'has 2 panes' && ok "a session of 2 panes: not started again" || bad "2 panes: $(last waiting)"
tm kill-pane -t "$(tm list-panes -t "=wat2-$idw:" -F '#{pane_id} #{pane_current_command}' | awk '$2 == "sleep" {print $1}')"
w1=$(evn waiting); mem 32000000 4800000; watch; mem 32000000 4700000; watch
[ "$(evn waiting)" = $((w1 + 1)) ] && ok "waiting: the same reason with other numbers is said once" || bad "waiting repeats: $w1 -> $(evn waiting)"
mem 32000000 16000000
# Its lock held by an action: the watcher leaves it to the next run.
flock "$SD/locks/$idw" sleep 3 & fl=$!; sleep 0.3; seed; watch
claude_in "wat2-$idw" >/dev/null 2>&1 && bad "started while an action held it" || ok "an entry an action holds: left alone"
wait $fl; seed; watch; pw=$(claude_in "wat2-$idw") && ok "and started once the action is done" || bad "not started after the lock: $(last waiting)"
# A claude started by hand in the pane after an end: that end is never acted on again.
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = int(time.time())' "$REPO" "$idw"
watch; sleep 1.1; tm send-keys -t "=wat2-$idw:" "exec $ASC_CLAUDE --resume $WS2 --name wat2-$idw" Enter; ph=$(claude_in "wat2-$idw"); watch
[ ! -e "$SD/exit/$idw" ] && ok "a claude started by hand after the end: the old exit record dropped" || bad "stale exit record kept: $(cat "$SD/exit/$idw")"
# A second claude in its session: nothing there is sure to be about it (no rename typed).
touch "$HOME/fake-busy"; sleep 0.6; asctl rename "$idw" wat3 >/dev/null; rm -f "$HOME/fake-busy"
[ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat3-$idw" ] || bad "rename not pending: $(jq -r .name "$HOME/.claude/sessions/$ph.json")"
cw=$(jq -r ".entries[\"$idw\"].cwd" "$REG")
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["cwd"] = sys.argv[3]' "$REPO" "$idw" "$HOME"
tm new-window -t "=wat3-$idw:" -c "$W" -- "$ASC_CLAUDE" --session-id eeeeeeee-0000-4000-8000-00000000000c
for _ in $(seq 1 25); do asctl live | seen eeeeeeee-0000-4000-8000-00000000000c && break; sleep 0.2; done; watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$HOME" ] && ok "a second claude in the session: its folder not followed" || bad "followed with two claudes there: $(last followed)"
[ "$(jq -r .name "$HOME/.claude/sessions/$ph.json")" = "wat2-$idw" ] && ok "a second claude in the session: no rename typed" || bad "renamed with two claudes there: $(last rename) / $(asctl live) / $(tm list-panes -s -t "=wat3-$idw:" -F '#{window_index} #{pane_id} #{pane_pid} #{pane_current_command} #{pane_dead}') / $(tm capture-pane -p -t "=wat3-$idw:1" | head -5)"
tm kill-window -t "=wat3-$idw:1"; sleep 0.5; watch
[ "$(jq -r .name "$HOME/.claude/sessions/$ph.json")" = "wat3-$idw" ] && ok "alone again: the pending rename sent" || bad "pending rename after: $(jq -r .name "$HOME/.claude/sessions/$ph.json")"
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$cw" ] && ok "and its folder followed again" || bad "folder after: $(jq -r ".entries[\"$idw\"].cwd" "$REG") (want $cw)"
# Broken state files: the run goes on, from scratch.
echo '{"ended": [], "rename_tries": {"x": "y"}, "dups": 5}' > "$SD/watch.json"
python3 -c 'import json, sys, time; print(json.dumps([{"t": int(time.time()) - 30, "boot": "", "avail_pct": 50, "oom_kill": "3"}, {"t": "x"}, 7]))' > "$SD/memory.json"
watch && jq -e '.ended | type == "object"' "$SD/watch.json" >/dev/null && jq -e 'all(.[]; (.oom_kill | type) != "string")' "$SD/memory.json" >/dev/null \
	&& ok "broken watch.json and memory.json: the run goes on, odd samples dropped" || bad "broken state: $(cat "$SD/watch.json")"
tm kill-session -t "=wat3-$idw"; idw_t=wat3
asctl off "$idw" --force >/dev/null; watch
claude_in "wat3-$idw" >/dev/null 2>&1 && bad "off, and started anyway" || ok "off: the watcher leaves it off"
[ "$(jq -r ".entries[\"$idw\"].want_on" "$REG")" = false ] && ok "want_on only changed by off" || bad "want_on changed"
asctl auto-restart off >/dev/null

echo "== the tmux server unit, and boot"
SC="$HOME/systemctl.log"
asctl tmux-server | seen 'already runs' && [ ! -e "$SC" ] && ok "tmux-server with a server up: left as it is" || bad "tmux-server with a server up: $(asctl tmux-server 2>&1)"
# Before the reboot: idw on, resurrect on, rc off (a resurrect start still has rc); of the others,
# one with resurrect on that was off, the rest on with resurrect off.
asctl resurrect "$idw" on >/dev/null; asctl rc "$idw" off --next-start >/dev/null; asctl on "$idw" >/dev/null
claude_in "wat3-$idw" >/dev/null || bad "not on before the reboot"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d:
    others = sorted(i for i in d["entries"] if i != sys.argv[2])
    for n, i in enumerate(others):
        d["entries"][i].update(resurrect=n == 0, want_on=n != 0)' "$REPO" "$idw"
others=$(jq -r --arg w "$idw" '[.entries[] | select(.id4 != $w) | .tmux] | join(" ")' "$REG")
tm kill-server; for _ in $(seq 1 25); do tm display -p x >/dev/null 2>&1 || break; sleep 0.2; done
touch "$HOME/fake-systemctl-fail"
errof on "$idw" | seen 'asctl-tmux.service did not start one: .*not found' && ! tm display -p x >/dev/null 2>&1 \
	&& ok "on, no server and no unit: refused, no server started by asctl itself" || bad "on with no unit: $(errof on "$idw")"
rm -f "$HOME/fake-systemctl-fail"
# A port that takes connections (claude.ai, for boot) and one that refuses them.
python3 -c 'import socket, time
a, b = socket.socket(), socket.socket(); a.bind(("127.0.0.1", 0)); a.listen(8); b.bind(("127.0.0.1", 0))
print(a.getsockname()[1], b.getsockname()[1], flush=True); time.sleep(300)' > "$T/ports" & lp=$!
for _ in $(seq 1 50); do [ -s "$T/ports" ] && break; sleep 0.1; done; read -r up_port shut_port < "$T/ports"
boot() { ASC_BY=boot asctl boot "$@"; }
# Its lock held by an action: boot waits (here 0 s), then leaves it.
: > "$SC"; flock "$SD/locks/$idw" sleep 3 & fl=$!; sleep 0.3; seed
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
grep -qx -- '--user start asctl-tmux.service' "$SC" && [ "$(tm show -gv exit-empty)" = off ] \
	&& ok "boot, no server: asctl-tmux.service started (exit-empty off)" || bad "server at boot: $(cat "$SC")"
[ "$rc" = 1 ] && last waiting | seen 'not started yet: .*being started or stopped' && last refused | seen 'boot: not started in 0 s' \
	&& ok "boot: an entry an action holds waits, then is left (refused)" || bad "boot, lock held: rc $rc $(last waiting) $(last refused)"
wait $fl
mem 32000000 4000000; seed
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && last waiting | seen 'boot: not started yet: memory' && ! claude_in "wat3-$idw" >/dev/null 2>&1 \
	&& ok "boot, memory short: waits, then left" || bad "boot, memory: rc $rc $(last waiting)"
mem 32000000 16000000; rm -f "$SD/memory.json"
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && last waiting | seen 'boot: not started yet: memory: watched for under 5 min' && ! claude_in "wat3-$idw" >/dev/null 2>&1 \
	&& ok "boot, memory fine but not watched 5 min: waits" || bad "boot, steady: rc $rc $(last waiting)"
# Resurrect turned off while boot waits: left, with nothing said.
seed; flock "$SD/locks/$idw" sleep 1.5 & fl=$!; sleep 0.3
(ASC_NET=127.0.0.1:$up_port boot --wait 4 > "$T/boot.out" 2>&1; echo $? >> "$T/boot.out") & bp=$!; sleep 0.7
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["resurrect"] = False' "$REPO" "$idw"
wait $fl $bp
seen -x 'boot: 0 started' "$T/boot.out" && seen -x 0 "$T/boot.out" && ! claude_in "wat3-$idw" >/dev/null 2>&1 \
	&& ok "resurrect off while boot waits: left" || bad "resurrect off mid-boot: $(cat "$T/boot.out")"
asctl resurrect "$idw" on >/dev/null; asctl rc "$idw" off --next-start >/dev/null
mem 32000000 16000000; seed; nw=$(jq -s '[.[] | select((.text // "") | test("did not answer"))] | length' "$SD/events.jsonl")
flock "$SD/boot.lock" sleep 2 & fl=$!; sleep 0.3
errof boot | seen 'another asctl boot is running' && ok "one boot at a time" || bad "two boots: $(errof boot)"
wait $fl
t0=$(date +%s); out=$(ASC_NET=127.0.0.1:$up_port boot --net-wait 30 --wait 60 2>&1); rc=$?
[ "$rc" = 0 ] && seen -x "boot: 1 started (wat3-$idw)" <<<"$out" && claude_in "wat3-$idw" >/dev/null \
	&& ok "boot: the favorite with resurrect on that was on is started" || bad "boot: rc $rc $out"
lastargs | seen -- "--resume .*--remote-control wat3-$idw" && ok "with rc (resurrect), rc being off" || bad "boot args: $(lastargs)"
last on | seen '"by":"boot"' && ok "logged as boot's" || bad "on event: $(last on)"
[ "$(jq -s '[.[] | select((.text // "") | test("did not answer"))] | length' "$SD/events.jsonl")" = "$nw" ] && [ $(( $(date +%s) - t0 )) -lt 25 ] \
	&& ok "claude.ai answering: no wait" || bad "net wait with the port up: $(( $(date +%s) - t0 )) s"
n=0; for o in $others; do tm has-session -t "=$o" 2>/dev/null && n=$((n + 1)); done
[ "$n" = 0 ] && ok "not started: resurrect on but off, on but resurrect off" || bad "boot started others: $(tm ls)"
non=$(evn on) nref=$(evn refused); out=$(ASC_NET=127.0.0.1:$up_port boot --net-wait 0 2>&1)
seen "wat3-$idw: its tmux session is up already" <<<"$out" && [ "$(evn on)" = "$non" ] && [ "$(evn refused)" = "$nref" ] \
	&& ok "boot again: a session up already is left as it is" || bad "boot, up already: $out"
tm kill-session -t "=wat3-$idw"; sleep 0.5
out=$(ASC_NET=127.0.0.1:$shut_port boot --net-wait 1 --wait 60 2>&1)
last waiting | seen "127.0.0.1:$shut_port did not answer in 1 s; starting anyway" && [ "$(evn on)" = $((non + 1)) ] \
	&& ok "claude.ai not answering: started anyway after the wait" || bad "net down: $out $(last waiting)"
kill "$lp" 2>/dev/null
echo "== asctl setup (a fake user manager: tests/asc/bin/systemctl)"
# A home of its own: its fake units must not change how On starts the tmux server above.
H2="$T/h2" F2="$T/h2/fake-units"; mkdir -p "$H2" "$T/linger"
# A template's instance, its name put together at run time (the privacy check reads x@y.z as an
# email); the units setup disables, as setup.json lists them.
AT=@; IM="tmux${AT}main.service"
ALL="[\"envtmux.service\",\"shtmux.service\",\"tmux.service\",\"$IM\"]"
su2() { HOME="$H2" ASC_LINGER_DIR="$T/linger" "$REPO/bin/asctl" setup "$@" 2>&1; }
SUD="$H2/.config/systemd/user" SJ="$H2/.local/state/agent-session-control/setup.json"
en() { [ -e "$F2/enabled/$1" ]; }
calls() { grep -c -E "^--user ($1)" "$H2/systemctl.log" 2>/dev/null || true; }
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "asctl's units are not installed (asctl-tmux.service, asctl-boot.service" <<<"$out" && [ "$(calls 'enable|disable|start|daemon-reload')" = 0 ] \
	&& ok "setup, units not installed: refused, nothing changed" || bad "setup, no units: rc $rc $out"
mkdir -p "$F2/enabled"
for u in asctl-tmux.service asctl-boot.service asctl-watch.timer asctl-dash.socket; do echo "ExecStart=/x/bin/asctl run" > "$F2/$u"; done
echo "ExecStart=/usr/bin/tmux new-session -d" > "$F2/tmux.service"; : > "$F2/enabled/tmux.service"
echo "ExecStart=/usr/bin/python3 -m http.server" > "$F2/web.service"; : > "$F2/enabled/web.service"
echo "ExecStart=/usr/bin/tmux -L other start-server" > "$F2/asctl-old.service"; : > "$F2/enabled/asctl-old.service"
echo "ExecStart=/usr/bin/env TERM=xterm tmux new-session -d -s envtmux" > "$F2/envtmux.service"; : > "$F2/enabled/envtmux.service"
echo "ExecStart=/usr/bin/env python3 tmux" > "$F2/notmux.service"; : > "$F2/enabled/notmux.service"
echo "ExecStart=/bin/sh -c tmux new-session -d" > "$F2/shtmux.service"; : > "$F2/enabled/shtmux.service"
# a template enabled as one instance: systemd lists the template, the link names the instance
echo "ExecStart=/usr/bin/tmux -L %i start-server" > "$F2/tmux@.service"; cp "$F2/tmux@.service" "$F2/$IM"
: > "$F2/enabled/tmux@.service"; : > "$F2/enabled/$IM"
mkdir -p "$SUD/default.target.wants"; ln -s "$SUD/tmux@.service" "$SUD/default.target.wants/$IM"
mkdir -p "$H2/.local/state/tmux-claude-restore"; : > "$H2/.local/state/tmux-claude-restore/manifest.json"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "an earlier tmux-claude-restore install is here (its manifest $H2/.local/state/tmux-claude-restore/manifest.json)" <<<"$out" && en tmux.service \
	&& ok "setup, an old tmux-claude-restore install: refused (its manifest)" || bad "setup, old manifest: rc $rc $out"
rm -r "$H2/.local/state/tmux-claude-restore"
printf '%s\n' "set -g mouse on" "# >>> tmux-claude-restore >>> (managed by /old/tcr/install.sh; edits here are overwritten)" "# <<< tmux-claude-restore <<<" > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "its block in $H2/.tmux.conf (installed by /old/tcr/install.sh)" <<<"$out" \
	&& ok "setup, its block in the tmux config: refused, its installer named" || bad "setup, old block: rc $rc $out"
printf '%s\n' "set -g mouse on" "# set -g @continuum-restore 'on'" "set -g @continuum-restore 'off'" "set -g @continuum-boot \"on\"  # at boot" > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.tmux.conf:4: @continuum-boot 'on'" <<<"$out" && ! seen ":2: @continuum" <<<"$out" && ! seen ":3: @continuum" <<<"$out" \
	&& ok "setup, continuum's boot on in the config: refused, the line named (a comment and 'off' are not)" || bad "setup, continuum config: rc $rc $out"
printf '%s\n' "source-file -q ~/.tmux.conf.local" > "$H2/.tmux.conf"; printf '%s\n' "set -g @continuum-restore 'on'" > "$H2/.tmux.conf.local"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.tmux.conf.local:1: @continuum-restore 'on'" <<<"$out" \
	&& ok "setup, continuum's restore on in a file the config sources (source-file -q ~/…): refused" || bad "setup, sourced continuum: rc $rc $out"
rm "$H2/.tmux.conf.local"
mkdir -p "$H2/.config/tmux"; printf '%s\n' "set-option -gq @continuum-restore on" > "$H2/.config/tmux/tmux.conf"; : > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.config/tmux/tmux.conf:1: @continuum-restore 'on'" <<<"$out" \
	&& ok "setup, continuum's restore on in the XDG config (set-option -gq): refused" || bad "setup, XDG continuum: rc $rc $out"
rm -r "$H2/.config/tmux"; tm set -g @continuum-restore on
out=$(su2 --yes); rc=$?
tm set -gu @continuum-restore
[ "$rc" = 1 ] && seen "the running tmux server: @continuum-restore on" <<<"$out" \
	&& ok "setup, continuum's restore on in the running server: refused" || bad "setup, server continuum: rc $rc $out"
touch "$F2/fail-show-environment"; out=$(su2 --yes); rc=$?; rm "$F2/fail-show-environment"
[ "$rc" = 1 ] && seen "cannot reach your systemd user manager (systemctl --user: Failed to connect to bus" <<<"$out" && en tmux.service \
	&& ok "setup, the user manager not answering: refused as that (not as units missing)" || bad "setup, no manager: rc $rc $out"
out=$(su2 </dev/null); rc=$?
[ "$rc" = 1 ] && seen "disable tmux.service, which runs tmux" <<<"$out" && seen "enable asctl-tmux.service, asctl-boot.service, asctl-watch.timer, asctl-dash.socket" <<<"$out" \
	&& seen "run asctl setup --yes to do it" <<<"$out" && en tmux.service && ! en asctl-tmux.service && ! [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] \
	&& ok "setup, no terminal and no --yes: shows the plan, changes nothing" || bad "setup, no --yes: rc $rc $out"
out=$(su2 --yes); rc=$?
dropin_ok() { cmp -s "$SUD/tmux-spawn-.scope.d/asctl.conf" "$REPO/systemd/tmux-spawn-.scope.d/asctl.conf" && [ "$(stat -c %a "$SUD/tmux-spawn-.scope.d/asctl.conf")" = 644 ]; }
[ "$rc" = 0 ] && ! en tmux.service && ! en envtmux.service && ! en shtmux.service && ! en $IM && en web.service && en asctl-old.service && en notmux.service && dropin_ok \
	&& en asctl-tmux.service && en asctl-boot.service && en asctl-watch.timer && en asctl-dash.socket \
	&& [ -e "$F2/active/asctl-watch.timer" ] && [ -e "$F2/active/asctl-dash.socket" ] && ! [ -e "$F2/active/asctl-tmux.service" ] \
	&& ok "setup --yes: the drop-in, the units that run tmux disabled (through env, sh -c, a template's instance; others left), asctl's units on, timer and socket started" || bad "setup --yes: rc $rc $out"
[ "$(jq -c .disabled "$SJ")" = "$ALL" ] && [ "$(stat -c %a "$SJ")" = 600 ] \
	&& ok "  what it disabled is recorded (setup.json, 0600)" || bad "  setup.json: $(cat "$SJ" 2>&1)"
seen "note: linger is off" <<<"$out" && seen "note: the dashboard has no config yet: $H2/.config/agent-session-control/dash.json" <<<"$out" \
	&& ok "  notes: linger off, no dashboard config" || bad "  notes: $out"
jq -s -e 'last | .kind == "setup" and .by == "cli" and (.text | test("disabled tmux.service"))' "$H2/.local/state/agent-session-control/events.jsonl" >/dev/null \
	&& ok "  logged (kind setup)" || bad "  setup event: $(tail -1 "$H2/.local/state/agent-session-control/events.jsonl")"
n=$(calls 'enable|disable|start'); : > "$T/linger/$(id -un)"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl is set up already: nothing to do" <<<"$out" && [ "$(calls 'enable|disable|start')" = "$n" ] && ! seen "linger" <<<"$out" \
	&& ok "setup again: nothing to do, nothing called (and no linger note with linger on)" || bad "setup again: rc $rc $out"
echo "# mine" >> "$SUD/tmux-spawn-.scope.d/asctl.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl.conf is not the one asctl ships: left as it is" <<<"$out" && tail -1 "$SUD/tmux-spawn-.scope.d/asctl.conf" | seen -x "# mine" \
	&& ok "setup, a changed drop-in: left as it is, said so" || bad "setup, changed drop-in: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && ! en asctl-tmux.service && ! en asctl-boot.service && ! en asctl-watch.timer && ! en asctl-dash.socket && ! [ -e "$F2/active/asctl-watch.timer" ] \
	&& en tmux.service && en envtmux.service && en $IM && [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] && ! [ -e "$SJ" ] && seen "is not the one asctl ships: left as it is" <<<"$out" \
	&& ok "setup --remove: asctl's units off, tmux.service enabled again, a changed drop-in left" || bad "setup --remove: rc $rc $out"
! seen "^--user stop.*asctl-tmux.service" "$H2/systemctl.log" && ok "  the tmux server unit never stopped" || bad "  asctl-tmux.service was stopped"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl is not set up: nothing to do" <<<"$out" && ok "setup --remove again: nothing to do" || bad "remove again: rc $rc $out"
rm "$SUD/tmux-spawn-.scope.d/asctl.conf"; : > "$F2/fail-enable-asctl-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "setup stopped part way (wrote .*; disabled $IM): systemctl --user enable" <<<"$out" && ! en tmux.service && [ "$(jq -c .disabled "$SJ")" = "$ALL" ] \
	&& jq -s -e 'last | .kind == "failed"' "$H2/.local/state/agent-session-control/events.jsonl" >/dev/null \
	&& ok "setup failing part way: says what it did, logged failed, the disabled unit recorded" || bad "setup part way: rc $rc $out"
rm "$F2/fail-enable-asctl-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && en asctl-tmux.service && ! seen "disable tmux.service" <<<"$out" && ok "  setup again finishes it" || bad "  setup again: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && en tmux.service && ! [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] && ! [ -e "$SJ" ] \
	&& ok "  then --remove: tmux.service enabled again, the unchanged drop-in removed" || bad "  remove after: rc $rc $out"
: > "$F2/fail-disable-tmux.service"
out=$(su2 --yes); rc=$?; rm "$F2/fail-disable-tmux.service"
[ "$rc" = 1 ] && seen "disabled envtmux.service; disabled shtmux.service): systemctl --user disable tmux.service" <<<"$out" && ! en envtmux.service && en tmux.service \
	&& [ "$(jq -c .disabled "$SJ")" = "$ALL" ] \
	&& ok "setup, a disable failing part way: the ones before it recorded as disabled" || bad "setup, disable part way: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && en envtmux.service && en shtmux.service && en tmux.service && ! [ -e "$SJ" ] \
	&& ok "  --remove after it: those enabled again" || bad "  remove after part way: rc $rc $out"
: > "$F2/global-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "tmux.service is still enabled (enabled for every user?" <<<"$out" && ! en asctl-tmux.service \
	&& [ "$(jq '.disabled | index("tmux.service")' "$SJ")" = null ] && jq -e '.disabled | index("envtmux.service")' "$SJ" >/dev/null \
	&& ok "setup, a tmux unit a disable does not turn off: stops, says why, and does not record it" || bad "setup, global unit: rc $rc $out $(cat "$SJ")"
rm "$F2/global-tmux.service"
ud() { HOME="$H2" XDG_CONFIG_HOME="$1" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import setup; print(setup.unit_dir())' "$REPO"; }
[ "$(ud "$T/shellcfg")" = "$H2/.config/systemd/user" ] && echo "XDG_CONFIG_HOME=$H2/mgrcfg" > "$F2/environment" && [ "$(ud "$T/shellcfg")" = "$H2/mgrcfg/systemd/user" ] \
	&& ok "the unit folder follows the manager's XDG_CONFIG_HOME, not the shell's" || bad "unit_dir: $(ud "$T/shellcfg")"
rm "$F2/environment"
# ASC_MUTANTS=1: break asctl one way at a time, in a copy; each must make this test fail.
if [ "${ASC_MUTANTS:-}" = 1 ]; then
	echo "== mutants"
	run_mutants asc.sh ASC_MUTANTS <<'MUTANTS'
asc/live.py %%% and proc_start is not None and st[2] == str(proc_start) %%% 
asc/live.py %%% st is not None and is_claude(pid, st[0]) and %%% st is not None and
asc/live.py %%%                 if s["status"] == "busy": %%%                 if False:
asc/live.py %%%                     return f"it runs a claude asctl cannot read (pid {pid})" %%%                     continue
asc/live.py %%%             if name in WRAPPERS: %%%             if True:
asc/live.py %%%             if name == "claude": %%%             if False:
asc/live.py %%% base == str(pid) and %%% 
asc/live.py %%% (raw.get("pidDomain") is None or raw.get("pidDomain") == domain) %%% True
asc/live.py %%%         if (st and is_claude(pid, st[0])) or %%%         if False and
asc/cli.py %%%     if away: %%%     if False:
asc/cli.py %%%     return live_in(e, lv) or next( %%%     return live_in(e, lv) or None and next(
asc/cli.py %%%     return (any(l.endswith("No, exit") %%%     return True or (any(l.endswith("No, exit")
asc/tmuxctl.py %%%     return run("has-session", "-t", "=" + name) %%%     return run("has-session", "-t", name)
asc/tmuxctl.py %%% cwd.replace("#", "##") %%% cwd
asc/live.py %%%         if s["live"]: %%%         if s["ok"]:
asc/cli.py %%%             if owner: %%%             if False:
asc/cli.py %%%             if others and not whole: %%%             if False:
asc/cli.py %%%     if live_for(e): %%%     if False:
asc/cli.py %%%             if "❯ Yes, I trust this folder" not in screen: %%%             if False:
asc/cli.py %%% ["--resume", e["session_id"]] if e.get("started") else %%% ["--session-id", e["session_id"]] if e.get("started") else
asc/registry.py %%% fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB) %%% fcntl.LOCK_EX
asc/registry.py %%% MODES = {"auto": "auto", "manual": "manual", "skip": "bypassPermissions"} %%% MODES = {"auto": "auto", "manual": "manual", "skip": "auto"}
asc/registry.py %%%     except ValueError as e: %%%     except ZeroDivisionError as e:
bin/asctl-wrap %%% > "$f.tmp") && mv -f "$f.tmp" "$f" %%% > /dev/null)
asc/memory.py %%%     if 100 * avail / total < START_PCT: %%%     if False:
asc/memory.py %%%     if left < LEAVE_PCT: %%%     if False:
asc/cli.py %%%     if not force_memory: %%%     if False:
asc/cli.py %%%             e["rc"] = True %%%             pass
asc/cli.py %%%  or (resurrect and e.get("resurrect")) %%%  or False
asc/registry.py %%%     if not t or t.startswith("-"): %%%     if not t:
asc/rclive.py %%%     if now["status"] != "idle": %%%     if now["status"] == "busy" and False:
asc/rclive.py %%%         return "its pane is in copy mode" %%%         pass
asc/rclive.py %%%     if t: %%%     if False:
asc/rclive.py %%% plain(DIM.sub("", lines[i])) %%% plain(lines[i])
asc/rclive.py %%% why = enter(s, f"{CMD} {title}" if on else CMD, %%% why = enter(s, CMD,
asc/rclive.py %%% rules[-1] - rules[-2] == 2 else None %%% rules[-1] - rules[-2] >= 2 else None
asc/cli.py %%%         s = None if args.next_start else live_in(e) %%%         s = live_in(e)
asc/cli.py %%%         elif s["rc"] == on: %%%         elif False:
asc/rclive.py %%%     if prompt_text(scr) != cmd: %%%     if False:
asc/rclive.py %%% if menu(under(scr)) - menu(before) else None %%% if False else None
asc/rclive.py %%% if menu(under(scr)) - menu(before) else None %%% if under(scr) != before else None
asc/rclive.py %%%         None if offers_cmd(scr) else %%%         None if True else
asc/rclive.py %%%     if not wait_for(lambda: seen() > n and (session(s["pid"]) or {}).get("name") == name, confirm): %%%     if False:
asc/rclive.py %%%             n += f.read(tail).count(text) %%%             n = 1
asc/cli.py %%%             why = rclive.rename(s, new) %%%             why = None
asc/cli.py %%%     if "--remote-control" in argv and %%%     if False and
asc/rclive.py %%%     if t and cmd.startswith(t): %%%     if t:
asc/rclive.py %%%             if not dialog_open(pid, scr) or selected(scr, DISCONNECT): %%%             if not dialog_open(pid, scr):
asc/rclive.py %%%     l = next((l for l in reversed(bottom(scr)) if label in l), "") %%%     l = next((l for l in bottom(scr) if "❯" in l and label in l), "")
asc/rclive.py %%%     return status(pid) == "waiting" and prompt_text(scr) is None and %%%     return
asc/cli.py %%%     return FOLLOW.get(m) or own %%%     return m or own
asc/cli.py %%%         for line in reversed(lines[1:] if st.st_size > tail else lines): %%%         for line in lines:
asc/live.py %%%         if name in SHELLS and snap in _cmdline(pid): %%%         if False:
asc/live.py %%%         if isinstance(meta, dict) and meta.get("finished") is True: %%%         if False:
asc/live.py %%%  and m.get("stop_reason") == "end_turn": %%%  and False:
asc/live.py %%%             if now - os.lstat(path).st_mtime > AGENT_FRESH: %%%             if False:
asc/live.py %%%                 t = claude_tasks(s, kids) %%%                 t = ""
asc/cli.py %%%     if s["status"] != "idle": %%%     if False:
asc/live.py %%%         j["pane"], j["host"] = h["pane"], h %%%         pass
asc/live.py %%% s["pane"] = None if s["kind"] == "bg" else next( %%% s["pane"] = next(
asc/live.py %%%     known.update({s["host"]["pid"]: s for s in lv if s.get("host")}) %%%     pass
asc/live.py %%%                                 and _cmdline(pid).split(" ", 1)[0].rsplit("/", 1)[-1] == "claude") %%%                                 )
asc/cli.py %%%         job, s = (s, s["host"]) if s.get("host") else (None, s) %%%         job = None
asc/cli.py %%%     if s.get("host"): %%%     if False:
asc/cli.py %%%     if m is None or (at is not None and s.get("started_at") and at < s["started_at"]): %%%     if m is None:
asc/cli.py %%%         if not s or s["name"] == new: %%%         if True:
asc/events.py %%%     if size <= MAX_BYTES and _time(first) >= time.time() - KEEP_DAYS * 86400: %%%     if True:
asc/events.py %%%     keep = [l for l in lines if _time(l) >= cut] %%%     keep = lines
asc/events.py %%%     while keep and sum(map(len, keep)) > MAX_BYTES // 2 and size > MAX_BYTES: %%%     while False:
asc/events.py %%%     fd = os.open(p, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600) %%%     fd = os.open(p, flags | os.O_CLOEXEC, 0o600)
asc/events.py %%%     if not stat.S_ISREG(os.fstat(fd).st_mode): %%%     if False:
asc/events.py %%%     return t if ok and 0 < t <= time.time() + 86400 else 0 %%%     return t if ok else 0
asc/cli.py %%%         events.log("failed", e, f"{what}: {x}") %%%         events.log("refused", e, f"{what}: {x}")
asc/cli.py %%%             out(ended) %%%             say("off", e, ended)
asc/cli.py %%%                 pending(id4, new) %%%                 pass
asc/watch.py %%%             fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB) %%%             pass
asc/watch.py %%%     if pct < memory.WARN_PCT and not st["warned"]: %%%     if pct < memory.WARN_PCT:
asc/watch.py %%%     elif pct >= memory.WARN_PCT + 1 and st["warned"]: %%%     elif pct >= memory.WARN_PCT and st["warned"]:
asc/watch.py %%%     for sid in sorted(set(dups) - set(st["dups"])): %%%     for sid in dups:
asc/watch.py %%%     if sum(1 for x in lv if x["pane"] and x["pane"]["session"] == e["tmux"]) != 1: %%%     if False:
asc/watch.py %%%         if not held and _set( %%%         if _set(
asc/watch.py %%%     if s["cwd"] != e.get("cwd") and os.path.isdir(s["cwd"]): %%%     if s["cwd"] != e.get("cwd"):
asc/watch.py %%%     if ex and s.get("started_at") and s["started_at"] >= ex[1]: %%%     if False:
asc/watch.py %%%     if rclive.guard(s) is not None:  # busy, waiting, typing: the next run %%%     if False:
asc/watch.py %%%     if not same: %%%     if True:
asc/watch.py %%%  if same and prev.get("has") is not None %%%  if same and "has" in prev
asc/watch.py %%%     reason = re.sub(r"[0-9][0-9.]*", "N", why)  # the same reason with other numbers is not news %%%     reason = why
asc/watch.py %%%     if not isinstance(settings, dict) or settings.get("auto_restart") is not True: %%%     if False:
asc/watch.py %%%     if code not in (137, 143): %%%     if False:
asc/watch.py %%%     if has is not True: %%%     if has is None:
asc/watch.py %%%     if abs(time.time() - last) < RESTART_EVERY: %%%     if False:
asc/watch.py %%%     if len(panes) != 1: %%%     if False:
asc/watch.py %%%     why = cli.pane_free(e, panes[0]["pane_id"], pid) %%%     why = ""
asc/watch.py %%%     return memory.steady(samples)  # the gate (room for its size) is On's own %%%     return ""
asc/watch.py %%%     if time.time() - t > RESTART_WITHIN: %%%     if False:
asc/watch.py %%%     if not boot or boot != memory.boot_id(): %%%     if boot != memory.boot_id():
asc/cli.py %%%     if p["pane_pid"] != pane_pid: %%%     if False:
asc/cli.py %%%     if p["in_mode"]: %%%     if False:
asc/cli.py %%%     if any(time.time() - a < TYPING_S for a in acts): %%%     if False:
asc/cli.py %%%     if live.children_map().get(pane_pid): %%%     if False:
asc/watch.py %%%             if st["failed"].get(e["id4"]) != msg: %%%             if True:
asc/watch.py %%%             with registry.entry_lock(e["id4"]): %%%             if True:
asc/watch.py %%%         return str(x) %%%         _set(e, {}, {"auto_restarted": int(time.time())}); return str(x)
asc/cli.py %%%         r = tmuxctl.respawn(pane, e["cwd"], [wrap, exit_file(e["id4"])] + argv) %%%         tmuxctl.kill_session(e["tmux"]); r = tmuxctl.new_session(e["tmux"], e["cwd"], [wrap, exit_file(e["id4"])] + argv)
asc/memory.py %%%     if any(b["t"] - a["t"] > GAP_S for a, b in zip(chain, chain[1:])): %%%     if False:
asc/memory.py %%%     if low < pct: %%%     if False:
asc/memory.py %%%     if (grew("oom_kill") or 0) > 0: %%%     if False:
asc/memory.py %%%     b = next((s for s in xs if s["t"] > t_end), None) %%%     b = next((s for s in xs if s["t"] >= t_end), None)
asc/memory.py %%%             if x["boot"] == s["boot"] and s["t"] - KEEP_S <= x["t"] <= s["t"]][-(MAX_SAMPLES - 1):] + [s] %%%             if True][-(MAX_SAMPLES - 1):] + [s]
asc/memory.py %%%             and all(s.get(k) is None or type(s.get(k)) is int %%%             and all(True
asc/live.py %%%         return "tmux did not list its panes" %%%         pane_list = []
asc/events.py %%%     return b if b in BY else "cli" %%%     return b or "cli"
asc/events.py %%%     return "".join(" " if unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp", "Cs") else c %%%     return "".join(" " if unicodedata.category(c) in ("Cc",) else c
asc/cli.py %%%         events.log("refused", e, f"{what}: {x}") %%%         pass
asc/cli.py %%%         elif not args.restart: %%%         elif False:
asc/cli.py %%%     if pid is not None: %%%     if False:
asc/cli.py %%%     if pid is None: %%%     if False:
asc/cli.py %%%         server = ensure_server() %%%         server = tmuxctl.server_pid()
asc/cli.py %%%         argv = claude_argv(e, resurrect) %%%         argv = claude_argv(e)
asc/cli.py %%%     if running is not None: %%%     if False:
asc/boot.py %%%     if not e or e.get("resurrect") is not True or e.get("want_on") is not True: %%%     if not e:
asc/boot.py %%%     if tmuxctl.has_session(e["tmux"]): %%%     if False:
asc/boot.py %%%         if not locked:  # an action holds it: the next look %%%         if False:
asc/boot.py %%%         why = memory.steady(samples) or memory.gate(e.get("rss_kb")) or _start(e, started) %%%         why = _start(e, started)
asc/boot.py %%%             raise RegistryError("another asctl boot is running") %%%             return 0
asc/boot.py %%%             socket.create_connection((host, int(port)), timeout=NET_TRY_S).close() %%%             raise OSError
asc/boot.py %%%         cli.ensure_server() %%%         pass
asc/boot.py %%%         if said.get(e["id4"]) != reason: %%%         if False:
bin/asctl-wrap %%% for ((i = 0; i < 30; i++)); do %%% for ((i = 0; i < 0; i++)); do
asc/setup.py %%%     if missing: %%%     if False:
asc/setup.py %%%     if os.path.lexists(manifest): %%%     if False:
asc/setup.py %%%             if line.startswith(OLD_MARK): %%%             if False:
asc/setup.py %%%             if m: %%%             if False:
asc/setup.py %%% (?:-[A-Za-z]+\s+)*@continuum %%% (?:-g\s+)?@continuum
asc/setup.py %%%             if r.returncode == 0 and r.stdout.strip() == "on": %%%             if False:
asc/setup.py %%%     if cont: %%%     if False:
asc/setup.py %%%     if not sys.stdin.isatty(): %%%     if False:
asc/setup.py %%%         if old_units:  # recorded before any is disabled %%%         if False:  # recorded before any is disabled
asc/setup.py %%%  or u.startswith("asctl-"): %%% :
asc/setup.py %%%  and runs_tmux(_prop(u, "ExecStart")): %%% :
asc/setup.py %%%  and _enabled(u) and runs_tmux %%%  and runs_tmux
asc/setup.py %%%         if prog == "env" and %%%         if False and
asc/setup.py %%%                 if os.path.isabs(q): %%%                 if False:
asc/setup.py %%%         if prog in ("sh", "bash", "dash", "zsh") and %%%         if False and
asc/setup.py %%%         if u.endswith("@.service"):  # a template %%%         if False:  # a template
asc/setup.py %%%         if r.returncode != 0:  # the manager did not answer %%%         if False:
asc/setup.py %%%     base = manager_env().get("XDG_CONFIG_HOME") or %%%     base = os.environ.get("XDG_CONFIG_HOME") or
asc/setup.py %%%                 registry.write_private(_record_path(), {"disabled": [x for x in _recorded() if x != u], %%%                 registry.write_private(_record_path(), {"disabled": [x for x in _recorded()],
asc/setup.py %%%             if _enabled(u): %%%             if False:
asc/setup.py %%%             os.unlink(dropin) %%%             pass
asc/setup.py %%%     back = [u for u in _recorded() if %%%     back = [u for u in [] if
asc/setup.py %%%     return ("same" if _read(p) == _template() else "differs"), p %%%     return "same", p
asc/setup.py %%%     to_start = [u for u in STARTED if _prop(u, "ActiveState") != "active"] %%%     to_start = []
asc/setup.py %%%         cli.out("asctl is set up already: nothing to do") %%%         pass
MUTANTS
fi

echo "asc: $pass passed, $fail failed"
[ "$fail" = 0 ]
