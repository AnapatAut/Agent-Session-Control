#!/usr/bin/env bash
# Tests of asctl (registry, live, fav, on, off, rename, restart, mode, rc, forget, the event log,
# the watcher, boot, the tmux server unit, setup) with the fake claude in tests/asc/bin, a
# throwaway HOME and a tmux server of their own (tmux -L). Touches neither your tmux nor your
# ~/.claude. About 4 min, no network.
#   tests/asc.sh                  prints ok/FAIL per check; exit 0 = all passed
#   ASC_ONLY=<case,...> tests/asc.sh   only those cases (tests/cases.sh)
#   ASC_TRACE=1 tests/asc.sh      after a FAIL, the end of the fake claudes' trace (each key, frame,
#                                 status change and tmux send-keys, timed): to find a race
# Its mutants (changes to asctl each check must catch) are in tests/mutants-asc.txt, run by
# tests/mutate.sh. TEST_STOP_AT=<check>: exit right after that check's FAIL (the mutant run).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || exit 2
export ASC_TMUX_SOCKET="asc-test-$$" ASC_CLAUDE="$REPO/tests/asc/bin/claude"
export HOME="$T/home" XDG_STATE_HOME="" XDG_CONFIG_HOME="" SHELL=/bin/bash
unset TMUX
mkdir -p "$HOME" "$T/fakebash"
cp "$(command -v bash)" "$T/fakebash/claude"
if [ -n "${ASC_TRACE-}" ]; then  # each tmux send-keys (asctl's and the suite's) in the fake claudes' trace
	mkdir "$T/tracebin"
	printf '%s\n' '#!/usr/bin/env bash' 't0=${EPOCHREALTIME/./}' "$(printf '%q' "$(command -v tmux)")"' "$@"; r=$?' \
		'case " $* " in *" send-keys "*) printf "%s tmux %s -> %s in %s ms\n" $((t0 / 1000)) "$*" $r $(((${EPOCHREALTIME/./} - t0) / 1000)) >> "$HOME/fake-trace.log" ;; esac' \
		'exit $r' > "$T/tracebin/tmux"
	chmod +x "$T/tracebin/tmux"; export PATH="$T/tracebin:$PATH"
fi
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
. "$REPO/tests/reap.sh"
# What the run started ends before its folder goes (else a job still running, such as a boot when
# a check failed first, writes into it again after the rm): its jobs and their children, then the
# test tmux server and what its panes run. Each call to that server has a time limit: kill-server
# once hung for hours on a stuck test server (and with it this run).
cleanup() {
	local srv panes=
	reap $$
	srv=$(timeout -k 1 5 tmux -L "$ASC_TMUX_SOCKET" -f /dev/null display -p '#{pid}' 2>/dev/null) && tree_of "$srv" && panes=${kids[*]}
	timeout -k 2 10 tmux -L "$ASC_TMUX_SOCKET" -f /dev/null kill-server 2>/dev/null
	# shellcheck disable=SC2086  # pids
	end_pids $panes
	rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$ASC_TMUX_SOCKET"; rm -rf "$T"
}
trap cleanup EXIT
pass=0 fail=0
# One check, one fixed name: `ok NAME` or `bad NAME [DETAILS]`, the same NAME both ways, never a
# value in it, and run once: not in a loop or a function (tests/checklint.py, run by
# tests/lint.sh). DETAILS, what was seen, go on the lines after the FAIL, each indented.
# `skip NAME WHY` for a check that cannot run here.
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; trace_end; fail=$((fail + 1)); [ "${TEST_STOP_AT-}" != "$1" ] || exit 1; }
# ASC_TRACE set: the end of the fake claudes' trace (tests/asc/bin/claude), after a FAIL or stop
trace_end() { [ -z "${ASC_TRACE-}" ] || [ ! -f "$HOME/fake-trace.log" ] || { echo "        trace, now $(date +%s%3N):"; tail -30 "$HOME/fake-trace.log" | sed 's/^/          /'; }; }
skip() { echo "  skip  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; }
# A setup step that did not come (what the test itself started: a claude in a session it made, a
# process of its own): one FAIL, "setup: NAME" (NAME fixed, as a check's), and the suite ends there,
# as each check after it would test nothing. Its exit must end the suite: never inside ( ), $( ),
# <( ), a pipeline or an & job.
stop() { echo "  FAIL  setup: $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; trace_end; fail=$((fail + 1)); echo "asc: $pass passed, $fail failed (stopped at a setup step)"; exit 1; }
# Waits: CMD... (run in this shell, so a function may set variables) every 0.1 s until it succeeds
# (poll) or fails (poll_gone), at most LIMIT whole seconds of pauses, then once more; non-zero at
# the limit. Each wait's status must be used: a check, `|| stop`, or `|| return 1` in a helper
# (tests/checklint.py).
poll()      { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" && return 0; sleep 0.1; done; "${@:2}"; }
poll_gone() { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" || return 0; sleep 0.1; done; ! "${@:2}"; }
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
# The pid of the live fake claude in a tmux session, now (one look, no wait).
claude_now() {
	local pp c
	for pp in $(tm list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null); do
		c=$pp
		[ "$(cat /proc/"$pp"/comm 2>/dev/null)" = claude ] || c=$(pgrep -P "$pp" -x claude | head -1)
		[ -n "$c" ] && [ -f "$HOME/.claude/sessions/$c.json" ] && { echo "$c"; return 0; }
	done
	return 1
}
# The same, waiting up to 10 s. A check that no claude was started looks once, with claude_now,
# right after the asctl command returned: every start waits for its claude's session file before
# it returns (asc/cli.py wait_started; checked by "on returns only once its claude is up").
claude_in() {
	local i
	for i in $(seq 1 50); do
		claude_now "$1" && return 0
		sleep 0.2
	done
	return 1
}
# A case's setup: the tmux server up, kept with no session.
server_up() { tm start-server \; set -g exit-empty off || stop "the tmux server for the case"; }
# A live fake claude started by hand in a tmux session, as a user would (folder trusted).
W="$T/work"; mkdir -p "$W" "$T/other"
printf '%s\n' "$W" > "$HOME/fake-trusted"
SID=11111111-2222-4333-8444-555555555555

# Helpers more than one case uses.
start_of() { awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat"; }
sfile() { printf '{"pid":%s,"sessionId":"%s","cwd":"/","procStart":"%s"%s}\n' "$1" "$2" "$3" "${4:-}" > "$HOME/.claude/sessions/$1.json"; }
live_has() { asctl live | seen "$1"; }
SD="$HOME/.local/state/agent-session-control"
watch() { ASC_BY=watch asctl watch; }
evn() { jq -s --arg k "$1" '[.[] | select(.kind == $k)] | length' "$SD/events.jsonl"; }
last() { jq -s -c --arg k "$1" '[.[] | select(.kind == $k)] | last' "$SD/events.jsonl"; }
# Seed 6 min of samples (as if the watcher had run every 30 s), from the fake readings now.
# (Runs of the tests come seconds apart, so samples taken since stay inside the 8 min kept.)
seed() { python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 30 * i) for i in range(12, 0, -1)])' "$REPO"; }

case_no_tmux_server() {
echo "== no tmux server"
asctl list >/dev/null && ok "list works with nothing set up" || bad "list works with nothing set up" "list fails with nothing set up"
asctl live | seen 'no live claude' && ok "live: none" || bad "live: none" "live: wrong when none"
}

# shellcheck disable=SC2329  # helpers run only through poll
case_main() {
echo "== fav"
# The server stays up with no session, as asctl-tmux.service will keep it (exit-empty off).
server_up
tm new-session -d -s dev -c "$W" -- "$ASC_CLAUDE" --session-id "$SID" --name dev
pid=$(claude_in dev) && ok "a hand-started claude is up" || bad "a hand-started claude is up" "the hand-started claude did not come up"
asctl live | seen "$SID.*dev" && ok "live: lists it with its tmux session" || bad "live: lists it with its tmux session" "live: does not list it"
asctl fav "$pid" --name das >/dev/null && ok "fav by pid" || bad "fav by pid" "fav by pid failed"
id=$(jqe '.entries | keys[0]')
[[ $id =~ ^[0-9]{4}$ ]] && ok "the id is 4 digits" || bad "the id is 4 digits" "bad id: $id"
tm has-session -t "=das-$id" 2>/dev/null && ok "its tmux session renamed to das-<id>" || bad "its tmux session renamed to das-<id>" "tmux session not renamed"
[ "$(jqe ".entries[\"$id\"].session_id")" = "$SID" ] && ok "the entry holds its session id" || bad "the entry holds its session id" "the entry's session id is wrong"
[ "$(stat -c %a "$REG")" = 600 ] && ok "registry mode 0600" || bad "registry mode 0600" "registry mode $(stat -c %a "$REG")"
asctl fav "$SID" >/dev/null 2>&1 && bad "fav of the same session twice refused" "fav twice accepted" || ok "fav of the same session twice refused"
asctl list | seen "^$id  das-$id .*on " && ok "list: on" || bad "list: on" "list: not on: $(asctl list)"

echo "== off"
asctl off "$id" >/dev/null && ok "off" || bad "off" "off failed"
tm has-session -t "=das-$id" 2>/dev/null && bad "its tmux session closed" "tmux session still there after off" || ok "its tmux session closed"
runs() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $st != Z* ]]; }  # a zombie has ended
runs "$pid" && bad "claude ended" "claude still runs after off" || ok "claude ended"
[ "$(jqe ".entries[\"$id\"].want_on")" = false ] && ok "want_on false after off" || bad "want_on false after off" "want_on not false after off"
asctl list | seen "^$id .* off " && ok "list: off" || bad "list: off" "list: not off"

echo "== on"
asctl on "$id" >/dev/null && ok "on" || bad "on" "on failed"
claude_now "das-$id" >/dev/null && ok "on returns only once its claude is up" || bad "on returns only once its claude is up" "no claude in das-$id as on returned"
pid=$(claude_in "das-$id") && ok "claude up in das-<id>" || bad "claude up in das-<id>" "no claude in das-$id"
# tmux with systemd moves each pane into a scope of its own just after starting it; claude must
# be forked after that, in the wrapper's scope, not left in the server's cgroup.
cg() { cut -d: -f3 "/proc/$1/cgroup" 2>/dev/null; }
wp=$(ps -o ppid= -p "$pid" | tr -d ' '); sp=$(tm display -p '#{pid}')
if [ "$(cg "$wp")" = "$(cg "$sp")" ]; then skip "claude is in its pane's scope, not the server's cgroup" "no pane scopes here (no user bus for tmux)"
else [ "$(cg "$pid")" = "$(cg "$wp")" ] && ok "claude is in its pane's scope, not the server's cgroup" || bad "claude is in its pane's scope, not the server's cgroup" "claude in $(cg "$pid"), its pane in $(cg "$wp")"; fi
# dev's claude had no message yet, so no transcript: started as new on its session id (--resume
# would find nothing, and claude would exit at once)
lastargs | grep -q -- "--session-id $SID --name das-$id --permission-mode auto" && ok "no transcript yet: started with --session-id, --name and the mode" || bad "no transcript yet: started with --session-id, --name and the mode" "wrong args: $(lastargs)"
[ "$(jqe ".entries[\"$id\"].want_on")" = true ] && ok "want_on true after on" || bad "want_on true after on" "want_on not true after on"
asctl on "$id" >/dev/null 2>&1 && bad "a second on refused (session exists)" "a second on accepted" || ok "a second on refused (session exists)"
tm rename-session -t "=das-$id" moved
asctl on "$id" >/dev/null 2>&1 && bad "on refused while a live claude holds the session id" "on accepted while a live claude holds the id" || ok "on refused while a live claude holds the session id"
tm rename-session -t "=moved" "das-$id"

echo "== busy"
touch "$HOME/fake-busy"; flagged
errof off "$id" | grep -q 'busy: claude is working' && ok "off refused: claude busy" || bad "off refused: claude busy" "off not refused while busy"
rm -f "$HOME/fake-busy"; flagged
tm new-window -t "=das-$id:" -- sleep 300
sleep 0.5
errof off "$id" | grep -q 'runs sleep' && ok "off refused: another pane runs sleep" || bad "off refused: another pane runs sleep" "off not refused for a running pane"
asctl off "$id" --force >/dev/null && ok "off --force" || bad "off --force" "off --force failed"
tm has-session -t "=das-$id" 2>/dev/null && bad "--force closed it all" "tmux session still there after --force" || ok "--force closed it all"
ex=$(cut -d' ' -f1 "$HOME/.local/state/agent-session-control/exit/$id" 2>/dev/null)
[ "$ex" = 143 ] && ok "the wrapper recorded exit 143 (SIGTERM)" || bad "the wrapper recorded exit 143 (SIGTERM)" "exit record: ${ex:-none}"

echo "== exact names, trust prompt, rename, mode"
tm new-session -d -s "das-${id}x" -- sleep 300
asctl on "$id" >/dev/null && ok "on while a longer-named session das-<id>x exists" || bad "on while a longer-named session das-<id>x exists" "on refused by a longer name"
asctl off "$id" >/dev/null
tm has-session -t "=das-${id}x" 2>/dev/null && ok "off left das-<id>x alone" || bad "off left das-<id>x alone" "off killed das-${id}x"
tm kill-session -t "=das-${id}x"
asctl fav "$(cat /proc/sys/kernel/random/uuid)" >/dev/null 2>&1 && bad "fav of an unknown session id refused" "fav of an unknown session id accepted" || ok "fav of an unknown session id refused"
SID2=22222222-3333-4444-8555-666666666666
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"agent-name","agentName":"Old Talk"}\n' "$T/other" "$SID2" > "$HOME/.claude/projects/-x/$SID2.jsonl"
asctl fav "$SID2" >/dev/null && ok "fav of a past conversation" || bad "fav of a past conversation" "fav of a past conversation failed"
id2=$(jq -r --arg s "$SID2" '.entries[] | select(.session_id == $s) | .id4' "$REG")
[ "$(jqe ".entries[\"$id2\"].tmux")" = "old-talk-$id2" ] && ok "named from its title: old-talk-<id>" || bad "named from its title: old-talk-<id>" "name: $(jqe ".entries[\"$id2\"].tmux")"
asctl on "$id2" >/dev/null && ok "on in a folder not trusted yet: the prompt answered" || bad "on in a folder not trusted yet: the prompt answered" "on stopped at the trust prompt"
grep -q 'trust: yes' "$HOME/claude-args.log" && ok "trust answered yes (Down, check, Enter)" || bad "trust answered yes (Down, check, Enter)" "trust not answered yes"
asctl off "$id2" >/dev/null
asctl rename "$id2" chat >/dev/null && [ "$(jqe ".entries[\"$id2\"].tmux")" = "chat-$id2" ] && ok "rename" || bad "rename" "rename failed"
asctl rename "$id2" 'Bad Name' >/dev/null 2>&1 && bad "a bad name refused" "a bad name accepted" || ok "a bad name refused"
asctl mode "$id2" skip >/dev/null && asctl on "$id2" >/dev/null
lastargs | grep -q -- '--permission-mode bypassPermissions' && ok "mode skip starts with bypassPermissions" || bad "mode skip starts with bypassPermissions" "mode skip not passed"
asctl off "$id2" >/dev/null
asctl mode "$id2" sudo >/dev/null 2>&1 && bad "an unknown mode refused" "an unknown mode accepted" || ok "an unknown mode refused"
# A start follows the mode the conversation last ran in (its transcript's last permissionMode).
pm() { printf '{"type":"%s","permissionMode":"%s","sessionId":"%s"}\n' "${2:-permission-mode}" "$1" "$SID2" >> "$HOME/.claude/projects/-x/$SID2.jsonl"; }
started_with() { asctl on "$id2" >/dev/null; lastargs | grep -o -- '--permission-mode [A-Za-z]*' | cut -d' ' -f2; asctl off "$id2" --force >/dev/null; }
pm acceptEdits; [ "$(started_with)" = acceptEdits ] && ok "mode: follows the transcript (acceptEdits, set inside claude)" || bad "mode: follows the transcript (acceptEdits, set inside claude)" "mode not followed"
pm bypassPermissions; [ "$(started_with)" = bypassPermissions ] && ok "mode: last ran in skip, the favorite set to skip: skip" || bad "mode: last ran in skip, the favorite set to skip: skip" "skip with mode skip"
asctl mode "$id2" auto >/dev/null
[ "$(started_with)" = bypassPermissions ] && ok "mode: last ran in skip, the favorite set to auto: skip (kept)" || bad "mode: last ran in skip, the favorite set to auto: skip (kept)" "skip not kept"
pm plan; [ "$(started_with)" = plan ] && ok "mode: plan is followed too" || bad "mode: plan is followed too" "plan not followed"
pm default; [ "$(started_with)" = manual ] && ok "mode: default (manual's old name) starts as manual" || bad "mode: default (manual's old name) starts as manual" "default not mapped"
pm sudo; [ "$(started_with)" = auto ] && ok "mode: one not known here: its own mode" || bad "mode: one not known here: its own mode" "an unknown mode passed on"
pm manual user; [ "$(started_with)" = manual ] && ok "mode: the last message's permissionMode counts too" || bad "mode: the last message's permissionMode counts too" "message mode not followed"
# The mode a running claude is in: the transcript's, unless written before it started (claude
# writes its mode only with a message), then the --permission-mode it was started with.
modenow() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, live
print(next(cli.mode_now(s) for s in live.live() if s["session_id"] == sys.argv[2]))' "$REPO" "$SID2"; }
ts() { printf '{"type":"user","timestamp":"%s","sessionId":"%s"}\n' "$1" "$SID2" >> "$HOME/.claude/projects/-x/$SID2.jsonl"; }
pm acceptEdits; asctl on "$id2" >/dev/null
claude_in "chat-$id2" >/dev/null && ok "mode now: claude up after on" || bad "mode now: claude up after on" "no claude in chat-$id2"
ts 2020-01-01T00:00:00.000Z; pm bypassPermissions
[ "$(modenow)" = acceptEdits ] && ok "mode now: a record from before the start: the start's mode" || bad "mode now: a record from before the start: the start's mode" "mode now: $(modenow)"
ts "$(date -u -d '+5 sec' +%Y-%m-%dT%H:%M:%S.000Z)"; pm dontAsk
[ "$(modenow)" = dontAsk ] && ok "mode now: a record since the start: the transcript's" || bad "mode now: a record since the start: the transcript's" "mode now, newer: $(modenow)"
asctl off "$id2" --force >/dev/null
pm manual user
}

case_shared_stale() {
# Setup: as main has it at this point, a favorite (id), started and then off.
server_up
SS=22222222-3333-4444-8555-00000000003a
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SS" > "$HOME/.claude/projects/-x/$SS.jsonl"
asctl fav "$SS" --name das >/dev/null || stop "a favorite for the shared session tests"
id=$(jq -r --arg s "$SS" '.entries[] | select(.session_id == $s) | .id4' "$REG")
asctl on "$id" >/dev/null && claude_in "das-$id" >/dev/null || stop "the favorite started"
asctl off "$id" >/dev/null || stop "the favorite off"
echo "== shared session, stale files, locks, a broken registry"
tm new-session -d -s shared -c "$W" -- "$ASC_CLAUDE" --session-id 33333333-4444-4555-8666-777777777777
tm split-window -t "=shared:" -- sleep 300
p3=$(claude_in shared) || stop "a claude in shared"
asctl fav "$p3" >/dev/null 2>&1 && bad "fav refused: shares its tmux session with another pane" "fav of a claude sharing its session accepted" || ok "fav refused: shares its tmux session with another pane"
asctl fav "$p3" --whole-session >/dev/null && ok "fav --whole-session accepted" || bad "fav --whole-session accepted" "fav --whole-session failed"
kill -KILL "$p3"; sleep 0.5
[ -f "$HOME/.claude/sessions/$p3.json" ] && ok "SIGKILL leaves the session file (as Claude Code does)" || bad "SIGKILL leaves the session file (as Claude Code does)" "the fake removed its file on SIGKILL"
asctl live | seen 33333333 && bad "live ignores a stale file (PID check)" "live lists a dead claude from its stale file" || ok "live ignores a stale file (PID check)"
printf '{"pid":%s,"sessionId":"not-a-uuid","cwd":"/"}\n' $$ > "$HOME/.claude/sessions/$$.json"
asctl live | seen 'unknown format' && ok "live reports a session file in an unknown format" || bad "live reports a session file in an unknown format" "unknown format not reported"
rm -f "$HOME/.claude/sessions/$$.json"
(flock 9; sleep 3) 9>"$HOME/.local/state/agent-session-control/locks/$id" &
sleep 0.3
errof on "$id" | grep -q 'being started or stopped' && ok "on refused while another asctl holds the entry" || bad "on refused while another asctl holds the entry" "entry lock not honoured"
wait
cp "$REG" "$T/reg.bak"; printf '{"entries": [' > "$REG"
errof list | grep -q 'is not valid JSON' && ok "a broken registry refused, with a clear message" || bad "a broken registry refused, with a clear message" "a broken registry not refused cleanly"
asctl forget "$id" >/dev/null 2>&1; [ "$(cat "$REG")" = '{"entries": [' ] && ok "a broken registry left unchanged" || bad "a broken registry left unchanged" "a broken registry was overwritten"
cp "$T/reg.bak" "$REG"
asctl forget "$id" >/dev/null && ! jq -e ".entries[\"$id\"]" "$REG" >/dev/null && ok "forget" || bad "forget" "forget failed"

echo "== PID checks, exact kill"
tm new-session -d -s solo -c "$W" -- "$ASC_CLAUDE" --session-id 44444444-5555-4666-8777-888888888888
p4=$(claude_in solo) || stop "a claude in solo"
asctl fav "$p4" --name solo >/dev/null; id4=$(jq -r '.entries[] | select(.name == "solo") | .id4' "$REG")
asctl off "$id4" >/dev/null
tm new-session -d -s "solo-${id4}x" -- sleep 300
asctl off "$id4" --force >/dev/null
tm has-session -t "=solo-${id4}x" 2>/dev/null && ok "off of a stopped entry left solo-<id>x alone" || bad "off of a stopped entry left solo-<id>x alone" "off of a stopped entry killed solo-${id4}x"

echo "== off never reaches outside its own tmux session"
asctl on "$id4" >/dev/null 2>&1 || true
p5=$(claude_in "solo-$id4") && ok "on: claude up in solo-<id>" || bad "on: claude up in solo-<id>" "no claude in solo-$id4"
tm rename-session -t "=solo-$id4" userwork; tm new-window -t "=userwork:" -- sleep 300
errof off "$id4" | grep -q 'runs outside its tmux session' && ok "off refused: its claude now runs in another session" || bad "off refused: its claude now runs in another session" "off acted outside its tmux session"
kill -0 "$p5" 2>/dev/null && ok "that claude still runs" || bad "that claude still runs" "that claude was killed"
errof off "$id4" --force | grep -q 'runs outside' && ok "--force does not reach outside either" || bad "--force does not reach outside either" "--force reached outside"
cp "$HOME/.claude/sessions/$p5.json" "$HOME/.claude/sessions/1.json"
asctl live | grep -c "^ *$p5 " | grep -qx 1 && ok "a copied session file (wrong file name) is not a second live claude" || bad "a copied session file (wrong file name) is not a second live claude" "a copied session file counted"
rm -f "$HOME/.claude/sessions/1.json"
tm kill-session -t =userwork
}

# The setup of the guards cases, each with a conversation of its own (SID2): as main has it at this
# point, a favorite of a past conversation (id2), off, named chat, in a trusted folder.
#   chat_setup <SID2>
chat_setup() {
server_up
SID2=$1
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SID2" > "$HOME/.claude/projects/-x/$SID2.jsonl"
asctl fav "$SID2" --name chat >/dev/null || stop "a favorite for the guards"
id2=$(jq -r --arg s "$SID2" '.entries[] | select(.session_id == $s) | .id4' "$REG")
}

# shellcheck disable=SC2329  # helpers run only through poll
case_guards() {
chat_setup 22222222-3333-4444-8555-000000000035
echo "== busy: a second claude in the session"
tm new-session -d -s duo -c "$W" -- "$ASC_CLAUDE" --session-id 77777777-8888-4999-8aaa-bbbbbbbbbbbb
p6=$(claude_in duo) || stop "a claude in duo"
tm new-window -t "=duo:" -c "$W" -- "$ASC_CLAUDE" --session-id 88888888-9999-4aaa-8bbb-cccccccccccc
sleep 1; asctl fav "$p6" --name duo --whole-session >/dev/null; id6=$(jq -r '.entries[] | select(.name == "duo") | .id4' "$REG")
touch "$HOME/fake-busy"; flagged
errof off "$id6" | grep -q 'is working' && ok "off refused: a second claude in the session is working" || bad "off refused: a second claude in the session is working" "off ignored a busy second claude"
rm -f "$HOME/fake-busy"; asctl off "$id6" --force >/dev/null
echo "== a session file asctl cannot read"
"$FAKE_BASH" -c 'sleep 300; true' >/dev/null 2>&1 & sp=$!
sleep 0.3; printf '{"pid": %s, "sessionId": "%s"' "$sp" "$SID" > "$HOME/.claude/sessions/$sp.json"
errof on "$id2" | grep -q 'cannot read' && ok "on refused: an unreadable session file of a running claude" || bad "on refused: an unreadable session file of a running claude" "on ignored an unreadable session file"
kill $(pgrep -P "$sp") "$sp"; wait "$sp" 2>/dev/null; rm -f "$HOME/.claude/sessions/$sp.json"
sleep 300 >/dev/null 2>&1 & np=$!
printf '{"pid": %s, "sessionId": "%s"' "$np" "$SID2" > "$HOME/.claude/sessions/$np.json"
errof on "$id2" | grep -q 'cannot read' && ok "on refused: an unreadable session file names its session id" || bad "on refused: an unreadable session file names its session id" "on ignored an unreadable file naming its session id"
kill "$np"; wait "$np" 2>/dev/null; rm -f "$HOME/.claude/sessions/$np.json"
echo "== PID checks: start time, name, machine"
"$FAKE_BASH" -c 'sleep 300; true' >/dev/null 2>&1 & sp=$!
sleep 300 >/dev/null 2>&1 & np=$!
sleep 0.3
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000001 "$(start_of "$sp")"
asctl live | seen aaaaaaaa && ok "a claude with its own start time is live" || bad "a claude with its own start time is live" "a claude with its own start time is not live"
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000002 1
asctl live | seen aaaaaaaa && bad "a reused PID (other start time) is not live" "a reused PID (other start time) counted" || ok "a reused PID (other start time) is not live"
sfile "$sp" aaaaaaaa-0000-4000-8000-000000000003 "$(start_of "$sp")" ',"pidDomain":"linux:other:pid:[1]"'
asctl live | seen aaaaaaaa && bad "a file from another machine (right PID and start) is not live" "a file from another machine counted" || ok "a file from another machine (right PID and start) is not live"
sfile "$np" aaaaaaaa-0000-4000-8000-000000000004 "$(start_of "$np")"
asctl live | seen aaaaaaaa && bad "a process not named claude is not live" "a process not named claude counted" || ok "a process not named claude is not live"
sfile "$sp" "$SID2" 1
errof on "$id2" | grep -q 'cannot read or check' && ok "on refused: a well-formed file of a running claude does not check out" || bad "on refused: a well-formed file of a running claude does not check out" "on ignored a file of a running claude that does not check out"
kill $(pgrep -P "$sp") "$sp" "$np"; wait "$sp" "$np" 2>/dev/null; rm -f "$HOME/.claude/sessions/$sp.json" "$HOME/.claude/sessions/$np.json"
echo "== a background job: Claude Code's version binary, shown in a favorite's pane"
mkdir -p "$T/versions"; cp "$(command -v bash)" "$T/versions/2.1.316"
( exec -a claude "$T/versions/2.1.316" -c 'sleep 300; true' ) >/dev/null 2>&1 & jp=$!
( exec -a other "$T/versions/2.1.316" -c 'sleep 300; true' ) >/dev/null 2>&1 & op=$!
JS=cccccccc-0000-4000-8000-000000000001; sleep 0.3
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"idle"'
sfile "$op" cccccccc-0000-4000-8000-000000000002 "$(start_of "$op")"
asctl live | seen "$JS" && ok "a background job (a version binary run as claude) is live" || bad "a background job (a version binary run as claude) is live" "a background job is not live"
asctl live | seen cccccccc-0000-4000-8000-000000000002 && bad "a version-named process not run as claude is not live" "a version-named process not run as claude counted" || ok "a version-named process not run as claude is not live"
PS7=dddddddd-aaaa-4bbb-8ccc-000000000007
tm new-session -d -s park -c "$W" -- "$ASC_CLAUDE" --session-id "$PS7"
p7=$(claude_in park) || stop "a claude in park"
asctl fav "$p7" --name park >/dev/null; id7=$(jq -r '.entries[] | select(.name == "park") | .id4' "$REG")
echo cccc0001 > "$HOME/fake-parked-$PS7"; sleep 0.8
asctl live | grep "$JS" | seen "fav=$id7 *park-$id7 .*shown by claude $p7" && ok "the job takes the pane of the claude showing it" || bad "the job takes the pane of the claude showing it" "job not in the pane: $(asctl live)"
asctl live | seen "^ *$p7 " && bad "the claude showing a job is not listed apart" "the claude showing a job listed as well" || ok "the claude showing a job is not listed apart"
asctl list | seen "park-$id7 *on " && ok "its favorite is on" || bad "its favorite is on" "favorite with a job: $(asctl list | grep park)"
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"busy"'
errof off "$id7" | seen 'is working' && ok "off refused: the job is working" || bad "off refused: the job is working" "off ignored a working job"
errof restart "$id7" | seen 'background job' && ok "restart refused: its pane shows a background job" || bad "restart refused: its pane shows a background job" "restart with a job: $(errof restart "$id7")"
sfile "$jp" "$JS" "$(start_of "$jp")" ',"kind":"bg","jobId":"cccc0001","status":"idle"'
EVF="$HOME/.local/state/agent-session-control/events.jsonl"; offs() { jq -s '[.[] | select(.kind == "off")] | length' "$EVF"; }
c7=$(offs); o=$(asctl off "$id7"); st=$(ps -o stat= -p "$p7")  # ended: gone, or a zombie not yet collected
[ "$(offs)" = $((c7 + 1)) ] && tail -1 "$EVF" | seen 'runs on in Claude Code' && ok "off with a job: one off event, the job named in it" || bad "off with a job: one off event, the job named in it" "off events with a job: $c7 then $(offs)"
[[ -z $st || $st == Z* ]] && kill -0 "$jp" 2>/dev/null && seen 'runs on in Claude Code' <<<"$o" && ok "off ends the claude in the pane, not the job (and says so)" || bad "off ends the claude in the pane, not the job (and says so)" "off with a job: $o"
# a job's daemon can be a child of the claude that started it, so inside its pane
tm new-session -d -s daemonhome -- bash -c "exec -a claude '$T/versions/2.1.316' -c 'sleep 300; true'"
daemon_up() { dp=$(tm list-panes -t "=daemonhome:" -F '#{pane_pid}'); [ "$(cat /proc/"$dp"/comm 2>/dev/null)" = 2.1.316 ]; }
poll 2 daemon_up || stop "a version binary in daemonhome's pane"
sfile "$dp" cccccccc-0000-4000-8000-000000000003 "$(start_of "$dp")" ',"kind":"bg","jobId":"cccc0003","status":"idle"'
asctl live | grep cccccccc-0000-4000-8000-000000000003 | seen '(not in tmux)' && ok "a job under a pane, shown by no claude, is in no pane" || bad "a job under a pane, shown by no claude, is in no pane" "a job took a pane by ancestry: $(asctl live)"
tm kill-session -t =daemonhome; rm -f "$HOME/.claude/sessions/$dp.json"
kill $(pgrep -P "$jp") $(pgrep -P "$op") "$jp" "$op"; wait "$jp" "$op" 2>/dev/null
rm -f "$HOME/.claude/sessions/$jp.json" "$HOME/.claude/sessions/$op.json" "$HOME/fake-parked-$PS7"
echo "== busy: a claude asctl cannot read; trust text in a transcript"
asctl on "$id6" >/dev/null && claude_in "duo-$id6" >/dev/null && ok "on: claude up in duo-<id>" || bad "on: claude up in duo-<id>" "no claude in duo-$id6"
tm new-window -t "=duo-$id6:" -- "$FAKE_BASH" -c 'sleep 300; true'
sleep 0.5
errof off "$id6" | grep -q 'runs a claude asctl cannot read' && ok "off refused: a pane runs a claude with no session file" || bad "off refused: a pane runs a claude with no session file" "off ignored a claude with no session file"
tm new-window -t "=duo-$id6:" -c "$W" -- "$ASC_CLAUDE" --session-id 99999999-aaaa-4bbb-8ccc-dddddddddddd
poll 5 live_has 99999999 && ok "live: a claude in another window of a favorite's session" || bad "live: a claude in another window of a favorite's session" "not listed: $(asctl live)"
errof fav 99999999-aaaa-4bbb-8ccc-dddddddddddd --whole-session | grep -q "tmux session of favorite $id6" && ok "fav refused: the claude runs in another favorite's tmux session" || bad "fav refused: the claude runs in another favorite's tmux session" "fav took over another favorite's tmux session"
asctl off "$id6" --force >/dev/null
touch "$HOME/fake-quote"
asctl on "$id6" >/dev/null && ok "on with the trust prompt quoted in a transcript" || bad "on with the trust prompt quoted in a transcript" "on failed with a quoted trust prompt"
grep -q 'quote: got a key' "$HOME/claude-args.log" && bad "no key pressed at a quoted trust prompt" "asctl pressed keys at a quoted trust prompt" || ok "no key pressed at a quoted trust prompt"
rm -f "$HOME/fake-quote"; asctl off "$id6" --force >/dev/null
}

case_on_gates() {
chat_setup 22222222-3333-4444-8555-000000000039
echo "== a folder name with tmux format characters"
SID3=33333333-aaaa-4bbb-8ccc-eeeeeeeeeeee
W3="$T/w#{pane_id}#(true)"; mkdir -p "$W3"; printf '%s\n' "$W3" >> "$HOME/fake-trusted"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W3" "$SID3" > "$HOME/.claude/projects/-x/$SID3.jsonl"
asctl fav "$SID3" --name fmt >/dev/null; id7=$(jq -r '.entries[] | select(.name == "fmt") | .id4' "$REG")
asctl on "$id7" >/dev/null && grep -qF "cwd=$W3 " "$HOME/claude-args.log" && ok "claude started in the literal folder (tmux formats not expanded)" || bad "claude started in the literal folder (tmux formats not expanded)" "the folder was expanded by tmux: $(lastargs)"
lastargs | seen -- "--resume $SID3 " && ok "a conversation with a transcript: started with --resume" || bad "a conversation with a transcript: started with --resume" "wrong args: $(lastargs)"
asctl off "$id7" --force >/dev/null

echo "== a claude that ends at once"
touch "$HOME/fake-exit-at-once"
t0=$(date +%s); out=$(errof on "$id2"); t1=$(date +%s)
rm -f "$HOME/fake-exit-at-once"
seen "^asctl: chat-$id2: tmux session started, but claude exited 3 [0-9]* s after it started" <<<"$out" && [ $((t1 - t0)) -lt 20 ] \
	&& ok "on, a claude that ends at once: said in seconds on stderr, with its exit" || bad "on, a claude that ends at once: said in seconds on stderr, with its exit" "after $((t1 - t0)) s: $out"
xf="$HOME/.local/state/agent-session-control/exit/$id2"
sx() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, registry; print(cli.started_exit(registry.find(registry.load(), sys.argv[2])))' "$REPO" "$id2"; }
a=$(sx); read -r xc xt xb _ < "$xf"; echo "$xc $xt $xb 1" > "$xf"; b=$(sx)
[[ $a == "(3, "* && $b == None ]] && ok "an exit record of another pane (one the session before wrote late) is not this start's" || bad "an exit record of another pane (one the session before wrote late) is not this start's" "this pane's: $a; another's: $b"
asctl off "$id2" --force >/dev/null

echo "== memory gate"
mem 32000000 1600000
out=$(errof on "$id2")
seen 'memory: 5.0% available, a start needs 20%' <<<"$out" && ! tm has-session -t "=chat-$id2" 2>/dev/null && ok "on refused below 20% available, nothing started" || bad "on refused below 20% available, nothing started" "on below 20%: $out"
mem 4000000 850000
out=$(errof on "$id2")
seen 'would leave 5.9% available, under 15%' <<<"$out" && ok "on refused when the start would leave under 15% (600 MB expected)" || bad "on refused when the start would leave under 15% (600 MB expected)" "on leaving too little: $out"
asctl on "$id2" --force-memory >/dev/null && ok "on --force-memory starts anyway" || bad "on --force-memory starts anyway" "on --force-memory failed"
asctl off "$id2" --force >/dev/null
mem 32000000 16000000
echo "== rc, resurrect, note"
asctl rc "$id2" on --title "My chat" >/dev/null && [ "$(jqe ".entries[\"$id2\"].rc")" = true ] && [ "$(jqe ".entries[\"$id2\"].rc_title")" = "My chat" ] && ok "rc on with a title" || bad "rc on with a title" "rc on failed"
asctl on "$id2" >/dev/null; lastargs | seen -- '--remote-control My chat' && ok "started with --remote-control and its title" || bad "started with --remote-control and its title" "rc not passed: $(lastargs)"
asctl off "$id2" --force >/dev/null
asctl rc "$id2" off >/dev/null; asctl on "$id2" >/dev/null
lastargs | seen -- '--remote-control' && bad "rc off: no --remote-control" "rc off still passed --remote-control" || ok "rc off: no --remote-control"
asctl rc "$id2" off --next-start >/dev/null  # the tests below start from rc off
asctl off "$id2" --force >/dev/null
asctl rc "$id2" on --title=-x >/dev/null 2>&1 && bad "a title starting with - refused (claude would read an option)" "a title starting with - accepted" || ok "a title starting with - refused (claude would read an option)"
asctl rc "$id2" on --title "$(printf 'a\tb')" >/dev/null 2>&1 && bad "a title with a control character refused" "a title with a control character accepted" || ok "a title with a control character refused"
asctl resurrect "$id2" on >/dev/null && [ "$(jqe ".entries[\"$id2\"].resurrect")" = true ] && [ "$(jqe ".entries[\"$id2\"].rc")" = true ] && ok "resurrect on turns rc on" || bad "resurrect on turns rc on" "resurrect on did not turn rc on"
asctl rc "$id2" off >/dev/null && [ "$(jqe ".entries[\"$id2\"].resurrect")" = true ] && ok "rc can still be turned off by hand" || bad "rc can still be turned off by hand" "rc off changed resurrect"
arg=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, registry; e = registry.find(registry.load(), sys.argv[2]); print(" ".join(cli.claude_argv(e, resurrect=True)), "|", " ".join(cli.claude_argv(e)))' "$REPO" "$id2")
[[ ${arg%%|*} == *--remote-control* && ${arg#*|} != *--remote-control* ]] && ok "a resurrect start always has rc; a manual one follows the toggle" || bad "a resurrect start always has rc; a manual one follows the toggle" "resurrect rc rule: $arg"
asctl note "$id2" "talks to the API" >/dev/null && [ "$(jqe ".entries[\"$id2\"].note")" = "talks to the API" ] && ok "note" || bad "note" "note failed"
asctl note "$id2" "$(head -c 501 /dev/zero | tr '\0' x)" >/dev/null 2>&1 && bad "a note over 500 characters refused" "a note over 500 characters accepted" || ok "a note over 500 characters refused"
asctl note "$id2" -- "-starts with a dash" >/dev/null && ok "a note may start with -" || bad "a note may start with -" "a note starting with - refused"
}

case_rc_now() {
echo "== rc now: the menu and the input box on screens drawn by hand (asc/rclive.py)"
# The menu by its shape and mark, on screens drawn by hand (each its own check).
mt=$(python3 -I - "$REPO" <<'EOF'
import sys; sys.path.insert(0, sys.argv[1]); from asc import rclive as r
R = "─" * 40
def scr(*rows): return "\n".join(rows) + "\n"
box = [R, "❯\xa0/remote-control", R, "  [ status ]"]
menu = "  \x1b[38;5;153m❯ /\x1b[1mremote-control\x1b[0m      Disconnect Remote Control"
before = scr("hello", "  notice", R, "❯\xa0", R, "  [ status ]")
print("found" if r.offers_cmd(scr("hello", menu, *box), before) else "-")
print("history" if r.takes(scr("❯ /remote-control", "  notice", *box), before) is None else "-")
print("two" if r.takes(scr(menu, menu.replace("Disconnect", "Quoted"), *box), before) == () else "-")
print("indented" if r.takes(scr("hello", "  notice", R, "  ❯ /remote-control", R, "  [ status ]"), before) is None else "-")
print("path" if r.entries(scr("hello", "  /srv/x/proj  main", *box), before) == [] else "-")
print("link" if r.plain("at \x1b]8;id=a;https://x.example/\x1b\\https://x.example/\x1b]8;;\x1b\\ now") == "at https://x.example/ now" else "-")
EOF
)
grep -qx found <<<"$mt" && ok "menu detection: the entry marked ❯ above the box is the one Enter takes" || bad "menu detection: the entry marked ❯ above the box is the one Enter takes"
grep -qx history <<<"$mt" && ok "menu detection: a prompt in the transcript (not indented) is not a menu entry" || bad "menu detection: a prompt in the transcript (not indented) is not a menu entry"
grep -qx two <<<"$mt" && ok "menu detection: two entries marked (one a quote in claude's answer): asctl cannot tell" || bad "menu detection: two entries marked (one a quote in claude's answer): asctl cannot tell"
grep -qx indented <<<"$mt" && ok "menu detection: claude's own input line, even indented, is not a menu entry" || bad "menu detection: claude's own input line, even indented, is not a menu entry"
grep -qx path <<<"$mt" && ok "menu detection: a plugin's line starting with a path is not a menu entry" || bad "menu detection: a plugin's line starting with a path is not a menu entry"
grep -qx link <<<"$mt" && ok "menu detection: a link (OSC 8) is read as its text" || bad "menu detection: a link (OSC 8) is read as its text"
# A real 2.1.318 screen (tests/asc/screens: a capture's last rows, names and links rewritten): the
# menu above the box, a status line under it, a plugin's band, prompts in the transcript.
rs=$(python3 -I - "$REPO" <<'EOF'
import os, sys; sys.path.insert(0, sys.argv[1]); from asc import rclive as r
d = os.path.join(sys.argv[1], "tests", "asc", "screens")
b, m = (open(os.path.join(d, f"2.1.318-{n}.txt"), encoding="utf-8").read() for n in ("before", "menu"))
print("box" if r.prompt_text(b) == "" and r.prompt_text(m) == "/remote-control" else "-")
print("offers" if r.offers_cmd(m, b) else "-")
print("seen" if r.no_menu(b, b) is None and r.no_menu(m, b) else "-")
EOF
)
grep -qx box <<<"$rs" && ok "a real 2.1.318 screen: its input box found, empty before, the command after" || bad "a real 2.1.318 screen: its input box found, empty before, the command after" "2.1.318 screen: the input box"
grep -qx offers <<<"$rs" && ok "a real 2.1.318 screen: the menu above the box takes /remote-control on Enter" || bad "a real 2.1.318 screen: the menu above the box takes /remote-control on Enter" "2.1.318 screen: the menu above the box"
grep -qx seen <<<"$rs" && ok "a real 2.1.318 screen: on and rename see that menu, and nothing on the screen before" || bad "a real 2.1.318 screen: on and rename see that menu, and nothing on the screen before" "2.1.318 screen: no_menu"
# Setup: a favorite of a past conversation, rc off with the title "My chat" saved, its claude on
# and idle; the claude log from here on.
server_up
: > "$HOME/claude-args.log"
SR=22222222-3333-4444-8555-000000000033
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SR" > "$HOME/.claude/projects/-x/$SR.jsonl"
asctl fav "$SR" --name rcnow >/dev/null || stop "a favorite for rc now"
idr=$(jq -r --arg s "$SR" '.entries[] | select(.session_id == $s) | .id4' "$REG")
{ asctl rc "$idr" on --title "My chat" && asctl rc "$idr" off; } >/dev/null || stop "rc off, the title My chat saved"
asctl on "$idr" >/dev/null && claude_in "rcnow-$idr" >/dev/null || stop "a claude for rc now"
echo "== rc now: typed into an idle claude (asc/rclive.py)"
pane=$(tm list-panes -t "=rcnow-$idr:" -F '#{pane_id}')
bridge() { jq -r 'select(.name == "rcnow-'"$idr"'") | .bridgeSessionId // ""' "$HOME"/.claude/sessions/*.json; }
screen() { tm capture-pane -p -t "$pane"; }
out=$(asctl rc "$idr" on); seen 'live now' <<<"$out" && [ -n "$(bridge)" ] && seen -x "pid=[0-9]* line: /remote-control My chat" "$HOME/claude-args.log" \
	&& ok "rc on: /remote-control with its title typed, confirmed from the session file" || bad "rc on: /remote-control with its title typed, confirmed from the session file" "rc on live: $out / $(bridge) / $(screen | tail -6 | tr "\n" "|")"
out=$(asctl rc "$idr" on); seen 'live already' <<<"$out" && [ "$(grep -c 'line: /remote-control' "$HOME/claude-args.log")" = 1 ] && ok "rc on while live: nothing typed" || bad "rc on while live: nothing typed" "rc on again: $out"
out=$(asctl rc "$idr" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && seen 'rc: disconnected' "$HOME/claude-args.log" && [ "$(jqe ".entries[\"$idr\"].rc")" = false ] \
	&& ok "rc off: the dialog, Disconnect selected and confirmed" || bad "rc off: the dialog, Disconnect selected and confirmed" "rc off live: $out / $(bridge)"
tm send-keys -t "$pane" -l "half typed"; sleep 0.5
out=$(asctl rc "$idr" on); seen 'not changed now: something is typed in its prompt' <<<"$out" && [ -z "$(bridge)" ] && screen | seen 'half typed' \
	&& [ "$(jqe ".entries[\"$idr\"].rc")" = true ] && ok "text in its prompt: nothing typed, the setting saved for the next start" || bad "text in its prompt: nothing typed, the setting saved for the next start" "typed prompt: $out / $(screen | tail -3)"
tm send-keys -t "$pane" BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace; sleep 0.5
touch "$HOME/fake-busy"; flagged
out=$(asctl rc "$idr" on); seen 'not changed now: claude is busy' <<<"$out" && [ -z "$(bridge)" ] && ok "busy: nothing typed" || bad "busy: nothing typed" "busy: $out"
rm -f "$HOME/fake-busy"; flagged
tm copy-mode -t "$pane"
out=$(asctl rc "$idr" on); seen 'not changed now: its pane is in copy mode' <<<"$out" && [ -z "$(bridge)" ] && ok "copy mode: nothing typed" || bad "copy mode: nothing typed" "copy mode: $out"
tm send-keys -t "$pane" -X cancel
out=$(asctl rc "$idr" on --next-start); seen 'from its next start$' <<<"$out" && [ -z "$(bridge)" ] && ok "--next-start: only the setting" || bad "--next-start: only the setting" "--next-start: $out"
touch "$HOME/fake-hint"; tm send-keys -t "$pane" x BSpace; sleep 0.5
screen | seen 'Try "fix lint"' && out=$(asctl rc "$idr" on) && seen 'live now' <<<"$out" && [ -n "$(bridge)" ] && ok "a dim placeholder counts as an empty prompt" || bad "a dim placeholder counts as an empty prompt" "placeholder: $out"
rm -f "$HOME/fake-hint"
empty() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import rclive; sys.exit(rclive.prompt_text(rclive.screen(sys.argv[2])) != "")' "$REPO" "$pane"; }
touch "$HOME/fake-menu-first"
out=$(asctl rc "$idr" off); seen "not changed now: its command menu did not offer /remote-control for Enter (it offered: ❯ /remote-controller   a plugin's command); nothing was sent" <<<"$out" && [ -n "$(bridge)" ] && empty \
	&& ! seen 'remote-controller' "$HOME/claude-args.log" && ok "off: another command marked first in the menu: Enter not pressed, the prompt cleared, what it offered named" || bad "off: another command marked first in the menu: Enter not pressed, the prompt cleared, what it offered named" "menu first: $out"
rm -f "$HOME/fake-menu-first"
touch "$HOME/fake-menu-slow"
out=$(asctl rc "$idr" off); rm -f "$HOME/fake-menu-slow"
seen 'live now\|off now' <<<"$out" && [ -z "$(bridge)" ] && ok "off: a menu drawn a moment after the typed text is waited for" || bad "off: a menu drawn a moment after the typed text is waited for" "slow menu: $out"
asctl rc "$idr" on >/dev/null
# Claude 2.1.318 draws the menu above the box; a status line and plugins draw any number of lines
# on both sides, one changing on its own, rules among them.
touch "$HOME/fake-menu-above" "$HOME/fake-plugins"; tm send-keys -t "$pane" x BSpace; sleep 0.5
out=$(asctl rc "$idr" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "off: the menu above the box, plugin lines around it: the entry Enter takes found" || bad "off: the menu above the box, plugin lines around it: the entry Enter takes found" "menu above: $out / $(screen | tail -12)"
out=$(asctl rc "$idr" on); seen 'live now' <<<"$out" && [ -n "$(bridge)" ] \
	&& ok "on: plugin lines around the box (one changing, rules among them) are not a menu" || bad "on: plugin lines around the box (one changing, rules among them) are not a menu" "on with plugins: $out"
touch "$HOME/fake-menu-first"
out=$(asctl rc "$idr" off); seen "not changed now: its command menu did not offer /remote-control for Enter (it offered: ❯ /remote-controller   a plugin's command); nothing was sent" <<<"$out" && [ -n "$(bridge)" ] && empty \
	&& ok "off: the menu above the box, another command marked: Enter not pressed" || bad "off: the menu above the box, another command marked: Enter not pressed" "menu above, another first: $out"
rm -f "$HOME/fake-menu-first"; touch "$HOME/fake-menu-unmarked"
out=$(asctl rc "$idr" off); seen "not changed now: its command menu did not offer /remote-control for Enter (asctl cannot tell which entry Enter takes); nothing was sent" <<<"$out" && [ -n "$(bridge)" ] && empty \
	&& ok "off: several entries, none marked: Enter not pressed" || bad "off: several entries, none marked: Enter not pressed" "unmarked: $out"
touch "$HOME/fake-menu-one"
out=$(asctl rc "$idr" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && ok "off: one entry, none marked: the one Enter takes" || bad "off: one entry, none marked: the one Enter takes" "one unmarked: $out"
rm -f "$HOME/fake-menu-unmarked" "$HOME/fake-menu-one" "$HOME/fake-menu-above" "$HOME/fake-plugins"
[ "$(grep 'line: ' "$HOME/claude-args.log" | grep -vc 'line: /rename ')" = 8 ] && ok "nothing else ever reached its prompt (eight rc lines, besides /rename)" || bad "nothing else ever reached its prompt (eight rc lines, besides /rename)" "lines entered: $(grep 'line: ' "$HOME/claude-args.log")"
}

case_rc_menu() {
# Setup, as rc_now has it at this point: a favorite of a past conversation, rc off with the title
# "My chat" saved, its claude on and idle; the menu above the box with plugin lines around it, and
# a menu that stays open after a space; the claude log from here on.
server_up
: > "$HOME/claude-args.log"
SM=22222222-3333-4444-8555-000000000034
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SM" > "$HOME/.claude/projects/-x/$SM.jsonl"
asctl fav "$SM" --name rcmenu >/dev/null || stop "a favorite for rc menus"
idr=$(jq -r --arg s "$SM" '.entries[] | select(.session_id == $s) | .id4' "$REG")
{ asctl rc "$idr" on --title "My chat" && asctl rc "$idr" off; } >/dev/null || stop "rc off for rc menus, the title My chat saved"
asctl on "$idr" >/dev/null && claude_in "rcmenu-$idr" >/dev/null || stop "a claude for rc menus"
echo "== rc now: a menu above the box, a slow dialog, a prompt not as typed (asc/rclive.py)"
pane=$(tm list-panes -t "=rcmenu-$idr:" -F '#{pane_id}')
bridge() { jq -r 'select(.name == "rcmenu-'"$idr"'") | .bridgeSessionId // ""' "$HOME"/.claude/sessions/*.json; }
screen() { tm capture-pane -p -t "$pane"; }
empty() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import rclive; sys.exit(rclive.prompt_text(rclive.screen(sys.argv[2])) != "")' "$REPO" "$pane"; }
touch "$HOME/fake-menu-above" "$HOME/fake-plugins" "$HOME/fake-menu-on"; tm send-keys -t "$pane" x BSpace; sleep 0.5
out=$(asctl rc "$idr" on); seen 'not changed now: a command menu opened at its prompt; nothing was sent' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "on: a menu above the box: Enter not pressed" || bad "on: a menu above the box: Enter not pressed" "menu above, on: $out"
nm=$(jqe ".entries[\"$idr\"].name")
out=$(asctl rename "$idr" talkx 2>&1); seen 'a command menu opened at its prompt; nothing was sent' <<<"$out" && ! seen 'line: /rename talkx' "$HOME/claude-args.log" \
	&& ok "rename: not when a menu above the box would take Enter" || bad "rename: not when a menu above the box would take Enter" "rename, menu above: $out"
rm -f "$HOME/fake-menu-on" "$HOME/fake-menu-above" "$HOME/fake-plugins"; tm send-keys -t "$pane" x BSpace; sleep 0.5
asctl rename "$idr" "$nm" >/dev/null 2>&1  # the favorite's name as before (a refused live rename still renames it)
asctl rc "$idr" on >/dev/null
touch "$HOME/fake-slow-dialog"
out=$(asctl rc "$idr" off); seen 'off now' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "off: a slow dialog, its lines quoted in the transcript: waited for the dialog itself" || bad "off: a slow dialog, its lines quoted in the transcript: waited for the dialog itself" "slow dialog: $out / $(screen | tail -4)"
rm -f "$HOME/fake-slow-dialog"
out=$(asctl rc "$idr" on --title "a@b"); seen 'not changed now: its title has characters asctl does not type' <<<"$out" && [ -z "$(bridge)" ] && ok "a title with @ (a file menu) is not typed" || bad "a title with @ (a file menu) is not typed" "title @: $out"
asctl rc "$idr" on --title "x;" >/dev/null 2>&1 && bad "a title ending with ; refused (tmux would drop it)" "a title ending with ; accepted" || ok "a title ending with ; refused (tmux would drop it)"
asctl rc "$idr" on --title "My chat" --next-start >/dev/null
touch "$HOME/fake-menu-on"
out=$(asctl rc "$idr" on); seen 'not changed now: a command menu opened at its prompt; nothing was sent' <<<"$out" && [ -z "$(bridge)" ] && empty \
	&& ok "on: a menu under the prompt: Enter not pressed, the prompt cleared" || bad "on: a menu under the prompt: Enter not pressed, the prompt cleared" "menu on: $out"
rm -f "$HOME/fake-menu-on"
touch "$HOME/fake-mangle"
out=$(asctl rc "$idr" on); seen "its prompt now holds 'x/remote-control My chat'; check it" <<<"$out" && [ -z "$(bridge)" ] && screen | seen 'x/remote-control My chat' \
	&& ok "the prompt not showing the command as typed: Enter not pressed, text not ours left alone" || bad "the prompt not showing the command as typed: Enter not pressed, text not ours left alone" "mangle: $out"
rm -f "$HOME/fake-mangle"
# shellcheck disable=SC2046  # one key name per word, on purpose
tm send-keys -t "$pane" $(printf 'BSpace %.0s' $(seq 1 30)); sleep 0.5
touch "$HOME/fake-two-lines"; tm send-keys -t "$pane" x BSpace; sleep 0.5
out=$(asctl rc "$idr" on); seen "not changed now: its screen does not show claude's prompt" <<<"$out" && [ -z "$(bridge)" ] \
	&& ok "a prompt of two lines (the first empty) is not empty" || bad "a prompt of two lines (the first empty) is not empty" "two lines: $out"
rm -f "$HOME/fake-two-lines"; tm send-keys -t "$pane" x BSpace; sleep 0.5
[ "$(grep 'line: ' "$HOME/claude-args.log" | grep -vc 'line: /rename ')" = 2 ] && ok "rc menus: nothing else ever reached its prompt (two rc lines, besides /rename)" || bad "rc menus: nothing else ever reached its prompt (two rc lines, besides /rename)" "lines entered: $(grep 'line: ' "$HOME/claude-args.log")"
}

case_events() {
# Setup: a favorite of a past conversation with an event of each kind: fav, a refused on (memory),
# an on past the memory gate, off, rename, mode, resurrect, rc (its last); its claude off.
server_up
SE=22222222-3333-4444-8555-000000000032
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SE" > "$HOME/.claude/projects/-x/$SE.jsonl"
asctl fav "$SE" --name evx >/dev/null || stop "a favorite for the event log"
ide=$(jq -r --arg s "$SE" '.entries[] | select(.session_id == $s) | .id4' "$REG")
mem 32000000 1600000
asctl on "$ide" >/dev/null 2>&1 && stop "on refused below 20% available"
asctl on "$ide" --force-memory >/dev/null || stop "on --force-memory"
mem 32000000 16000000
{ asctl off "$ide" --force && asctl rename "$ide" evlog && asctl mode "$ide" skip && asctl resurrect "$ide" on \
	&& asctl rc "$ide" off; } >/dev/null || stop "off, rename, mode, resurrect, rc"
echo "== event log"
EV="$HOME/.local/state/agent-session-control/events.jsonl"
[ "$(stat -c %a "$EV")" = 600 ] && ok "events.jsonl mode 0600" || bad "events.jsonl mode 0600" "events.jsonl mode $(stat -c %a "$EV")"
jq -e -s 'all(.t > 0 and (.kind | type) == "string" and .by == "cli")' "$EV" >/dev/null && ok "every line is JSON with a time, a kind and who (cli)" || bad "every line is JSON with a time, a kind and who (cli)" "bad event lines"
miss=; for k in fav on off rename mode rc resurrect; do jq -e -s --arg k "$k" 'any(.kind == $k)' "$EV" >/dev/null || miss="$miss $k"; done
[ -z "$miss" ] && ok "every kind logged: fav, on, off, rename, mode, rc, resurrect" || bad "every kind logged: fav, on, off, rename, mode, rc, resurrect" "not logged:$miss"
jq -e -s --arg i "$ide" 'any(.kind == "refused" and .id4 == $i and (.text | test("^on: memory: 5.0% available")))' "$EV" >/dev/null \
	&& ok "a refused on is logged with why" || bad "a refused on is logged with why" "refused on not logged"
jq -e -s --arg i "$ide" 'any(.kind == "on" and .id4 == $i and (.text | test("past the memory gate")))' "$EV" >/dev/null \
	&& ok "an on past the memory gate says so" || bad "an on past the memory gate says so" "forced on not marked"
asctl events "$ide" | tail -1 | seen -E "^[0-9-]{10} [0-9:]{8}  cli +(off|rc|resurrect|mode|rename) +evlog-$ide " && ok "asctl events ID: its events, oldest first" || bad "asctl events ID: its events, oldest first" "asctl events: $(asctl events "$ide" | tail -2)"
ASC_BY=page asctl mode "$ide" auto >/dev/null; ASC_BY='x"y' asctl mode "$ide" auto >/dev/null
tail -2 "$EV" | jq -s -e '.[0].by == "page" and .[1].by == "cli"' >/dev/null && ok "who: ASC_BY page kept, anything else is cli" || bad "who: ASC_BY page kept, anything else is cli" "who wrong: $(tail -2 "$EV")"
# Pruned: lines past 7 days and broken lines go; past 2 MB the oldest half goes.
{ printf '{"t": 1000, "kind": "on", "by": "cli", "text": "ancient"}\nnot json\n'; cat "$EV"; } > "$EV.x" && mv "$EV.x" "$EV"
asctl mode "$ide" auto >/dev/null
! seen -e ancient -e 'not json' "$EV" && seen '"mode"' "$EV" && ok "pruned: an event past 7 days and a broken line" || bad "pruned: an event past 7 days and a broken line" "not pruned: $(head -2 "$EV")"
n=$(wc -l < "$EV")
python3 -c 'import json,sys,time; t=int(time.time()); sys.stdout.writelines(json.dumps({"t": t, "kind": "on", "by": "cli", "text": "x" * 200}) + "\n" for _ in range(11000))' >> "$EV"
asctl mode "$ide" auto >/dev/null
sz=$(stat -c %s "$EV"); [ "$sz" -le 1100000 ] && [ "$(stat -c %a "$EV")" = 600 ] && tail -1 "$EV" | seen '"mode"' && ok "pruned past 2 MB to under 1 MB, the newest kept" || bad "pruned past 2 MB to under 1 MB, the newest kept" "size not bounded: $sz"
asctl events | wc -l | seen -x 50 && ok "asctl events: the latest 50" || bad "asctl events: the latest 50" "events limit"
# A symlink in its place is not followed; the action still works.
mv "$EV" "$EV.keep"; ln -s "$T/elsewhere" "$EV"
out=$( { asctl mode "$ide" auto >/dev/null; } 2>&1 ); r=$?
[ $r = 0 ] && [ ! -e "$T/elsewhere" ] && seen 'event not logged' <<<"$out" && ok "a symlinked events.jsonl is not written through; the action goes on" || bad "a symlinked events.jsonl is not written through; the action goes on" "symlink: rc=$r $out"
rm -f "$EV"; mv "$EV.keep" "$EV"
# A FIFO in its place: refused at once, never waited on.
mv "$EV" "$EV.keep"; mkfifo "$EV"
out=$( { timeout 10 "$REPO/bin/asctl" mode "$ide" auto >/dev/null; } 2>&1 ); r=$?
[ $r = 0 ] && seen 'not a regular file' <<<"$out" && ok "a FIFO as events.jsonl: refused at once, the action goes on" || bad "a FIFO as events.jsonl: refused at once, the action goes on" "FIFO: rc=$r $out"
rm -f "$EV"; mv "$EV.keep" "$EV"
# One event per off; a refusal of any action is logged, an error after a change as failed.
c0=$(jq -s '[.[] | select(.kind == "off")] | length' "$EV"); asctl off "$ide" >/dev/null
[ "$(jq -s '[.[] | select(.kind == "off")] | length' "$EV")" = $((c0 + 1)) ] && ok "one off, one off event" || bad "one off, one off event" "off events: $c0 then $(jq -s '[.[] | select(.kind == "off")] | length' "$EV")"
tm new-session -d -s "taken-$ide" -- sleep 300
asctl rename "$ide" taken >/dev/null 2>&1
tail -1 "$EV" | jq -e --arg i "$ide" '.kind == "refused" and .id4 == $i and (.text | startswith("rename: tmux session"))' >/dev/null && ok "a refused rename is logged" || bad "a refused rename is logged" "refused rename: $(tail -1 "$EV")"
tm kill-session -t "=taken-$ide"
asctl on 9999 >/dev/null 2>&1; tail -1 "$EV" | jq -e '.kind == "refused" and (.text | startswith("on 9999: no favorite"))' >/dev/null && ok "an action on an unknown id: refused, logged" || bad "an action on an unknown id: refused, logged" "unknown id: $(tail -1 "$EV")"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, events
e = {"id4": "0000", "tmux": "x-0000"}
try:
    with cli.refusals(e, "on"): raise cli.ActionFailed("half done")
except cli.ActionFailed: pass
r = events.read(limit=1)[0]; assert r["kind"] == "failed" and r["text"] == "on: half done", r' "$REPO" && ok "an error after a change is logged as failed" || bad "an error after a change is logged as failed" "failed kind"
# Odd lines never break a read: a far-future or NaN time, a list as who, a lone surrogate.
printf '%s\n' '{"t": 1e20, "kind": "on", "by": "cli"}' '{"t": NaN, "kind": "on"}' '{"t": 5, "kind": "on", "by": []}' >> "$EV"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import events
events.log("mode", {"id4": "0000", "tmux": "s\udce9-0000"}, "folder /tmp/\udce9 \u202e!")
r = events.read(limit=1)[0]; assert r["tmux"] == "s -0000" and r["text"] == "folder /tmp/   !", r
assert events.read(limit=0) == [] and events.read(limit=-1) == []
assert events._plausible(5) and not any(map(events._plausible, (True, float("inf"), float("nan"), "5")))' "$REPO" \
	&& ok "a lone surrogate and bidi controls become spaces; limit 0 is none; a time is a finite number" || bad "a lone surrogate and bidi controls become spaces; limit 0 is none; a time is a finite number" "surrogate, limit or time"
asctl events >/dev/null && ok "asctl events reads past odd lines" || bad "asctl events reads past odd lines" "asctl events broke on odd lines"
# What is kept: a favorite's last 200 however old, anything else 7 days; an id's events from
# before its forget belong to an earlier favorite. A state folder of its own.
python3 -I - "$REPO" "$T/evd" <<'PY' && ok "kept: a favorite's last 200 however old; others 7 days; before a forget is an earlier favorite's" || bad "kept: a favorite's last 200 however old; others 7 days; before a forget is an earlier favorite's" "event keeping"
import json, os, sys, time
sys.path.insert(0, sys.argv[1]); from asc import events, registry
d = sys.argv[2]; os.makedirs(d, mode=0o700)
reg = lambda ids, dd=d: registry.save({"version": 1, "entries": {i: {"id4": i, "tmux": "x-" + i} for i in ids}}, dd)
reg(["1111", "2222", "6666"])
now, old = int(time.time()), int(time.time()) - 30 * 86400
line = lambda t, i, k="on", x="": json.dumps({"t": t, "kind": k, "by": "cli", "text": x, **({"id4": i, "tmux": "x-" + i} if i else {})}) + "\n"
texts = lambda dd=d: [json.loads(l)["text"] for l in open(events.path(dd))]
numbered = lambda: [x for x in texts() if x[:1] in "ns" and x[1:].isdigit()]  # 6666's
with open(events.path(d), "w") as f:
    f.write(line(old, "2222", x="old of a favorite") + line(old, "3333", x="old of no favorite") + line(old, None, x="old machine")
            + line(old, "1111", x="earlier life") + line(old + 1, "1111", "forget") + line(old + 2, "1111", x="this life, old")
            + line(now, "3333", x="new of no favorite") + line(now, "1111", x="this life, new")
            + "".join(line(now, "6666", x=f"n{i}") for i in range(300)))
events.log("mode", {"id4": "2222", "tmux": "x-2222"}, "now", d=d)
t = texts()
many = numbered()
assert len(many) == 200 and many[-1] == "n299" and many[0] == "n100", (len(many), many[0])
assert {"old of a favorite", "this life, old", "this life, new", "new of no favorite"} <= set(t), t[:6]
assert not {"old of no favorite", "old machine", "earlier life"} & set(t), t[:6]
assert t[-1] == "now" and oct(os.stat(events.path(d)).st_mode & 0o777) == "0o600"
# under 200 + KEEP_SLACK, nothing to drop: not rewritten (same inode); at 250 it is cut back to 200
ino = os.stat(events.path(d)).st_ino
with open(events.path(d), "a") as f:
    f.write("".join(line(now, "6666", x=f"s{i}") for i in range(49)))
events.log("mode", {"id4": "2222", "tmux": "x-2222"}, "again", d=d)
assert os.stat(events.path(d)).st_ino == ino and len(numbered()) == 249
events.log("on", {"id4": "6666", "tmux": "x-6666"}, "s49", d=d)
assert os.stat(events.path(d)).st_ino != ino and len(numbered()) == 200
# read: an id's events back to its last forget only, at most 200, parsed once
with open(events.path(d), "a") as f:
    f.write(line(now, "2222", "forget") + line(now, "2222", "fav", "a new favorite with the old id"))
assert [r["kind"] for r in events.read("2222", d=d)] == ["fav"], events.read("2222", d=d)
assert [r["text"] for r in events.read("1111", d=d)] == ["this life, new", "this life, old"]
assert len(events.read("6666", d=d)) == 200 and len(events.read("6666", limit=3, d=d)) == 3
# a registry that does not read: no favorite's event dropped for its age
with open(events.path(d), "a") as f:
    f.write(line(old, "4444", x="old, registry broken"))
open(os.path.join(d, "registry.json"), "w").write("{")
with open(events.path(d), "r+") as f:
    body = f.read(); f.seek(0); f.write(line(old, None, x="old first") + body)
events.log("mode", None, "with a broken registry", d=d)
assert "old, registry broken" in texts() and "old first" not in texts(), texts()[:3]
# nothing old at all: a favorite far over 200 is still cut (the size alone sets off a look)
d2 = d + "2"; os.makedirs(d2, mode=0o700); reg(["5555"], d2)
open(events.path(d2), "w").write("".join(line(now, "5555", x=f"m{i}") for i in range(300)))
events.log("mode", {"id4": "5555", "tmux": "x-5555"}, "last", d=d2)
got = texts(d2)
assert len(got) == 200 and got[-1] == "last" and got[0] == "m101", (len(got), got[0])
# past 2 MB: halved, other events first, then evenly: a quiet favorite keeps its history
d3 = d + "3"; os.makedirs(d3, mode=0o700); reg([f"{i:04d}" for i in range(60)] + ["7777"], d3)
pad = "x" * 300
with open(events.path(d3), "w") as f:
    f.write(line(now - 9, "7777", x="quiet"))
    f.write("".join(line(now, None, x=pad) for i in range(3000)))
    f.write("".join(line(now, f"{i % 60:04d}", x=pad) for i in range(60 * 200)))
assert os.path.getsize(events.path(d3)) > events.MAX_BYTES
events.log("mode", {"id4": "0001", "tmux": "x-0001"}, "big", d=d3)
got = texts(d3)
assert os.path.getsize(events.path(d3)) <= events.MAX_BYTES // 2 and "quiet" in got and got[-1] == "big", (os.path.getsize(events.path(d3)), got[:2])
PY
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import events
assert events._clean("a\x1b[31mb\nc\x7f") == "a [31mb c "
try: events.log("nonsense")
except ValueError: pass
else: raise SystemExit(1)' "$REPO" && ok "event text: control characters become spaces; an unknown kind is a bug" || bad "event text: control characters become spaces; an unknown kind is a bug" "event text not cleaned"
# A conversation's length, counted on by the watcher (asc/past.py): only what was added.
python3 -I - "$REPO" "$T/lend" <<'PY' && ok "lengths: counted on from where the last count stopped; a replaced, shrunk or symlinked transcript handled" || bad "lengths: counted on from where the last count stopped; a replaced, shrunk or symlinked transcript handled" "conversation lengths"
import json, os, sys
sys.path.insert(0, sys.argv[1]); from asc import past
d = sys.argv[2]; home = os.path.join(d, "home"); os.makedirs(os.path.join(home, ".claude", "projects", "p"))
a, b, c = (f"{n}" * 8 + "-1111-4111-8111-" + f"{n}" * 12 for n in "abc")
p = lambda sid: os.path.join(home, ".claude", "projects", "p", sid + ".jsonl")
open(p(a), "w").write("x\n" * 3)
past.update_lengths([a, b, None, "not-an-id"], d, home)
L = past.lengths(d)
assert L == {a: {"lines": 3, "bytes": 6}}, L
assert oct(os.stat(os.path.join(d, past.LENGTHS)).st_mode & 0o777) == "0o600"
with open(p(a), "a") as f:
    f.write("yy\nzz")  # a last line not ended yet
st = json.load(open(os.path.join(d, past.LENGTHS)))
st[a]["lines"] = 100  # only what was added is read: the old count stays
json.dump(st, open(os.path.join(d, past.LENGTHS), "w"))
past.update_lengths([a], d, home)
assert past.lengths(d)[a] == {"lines": 101, "bytes": 11}, past.lengths(d)
os.replace(p(a), p(a) + ".old"); open(p(a), "w").write("1\n2\n")  # replaced: counted again
past.update_lengths([a], d, home)
assert past.lengths(d)[a] == {"lines": 2, "bytes": 4}, past.lengths(d)
open(p(a), "w").write("1\n")  # shrunk in place: counted again
past.update_lengths([a], d, home)
assert past.lengths(d)[a] == {"lines": 1, "bytes": 2}, past.lengths(d)
open(p(b), "w").write("l\n" * 1000)
past.update_lengths([a, b], d, home, budget=500)  # a large first count goes on over runs, not shown until done
assert b not in past.lengths(d) and json.load(open(os.path.join(d, past.LENGTHS)))[b]["size"] < 2000
for _ in range(10):
    past.update_lengths([a, b], d, home, budget=500)
assert past.lengths(d)[b] == {"lines": 1000, "bytes": 2000}, past.lengths(d)
os.makedirs(os.path.join(home, ".claude", "projects", "a"))  # a folder move left an old copy (sorted first): the newer one counts
q = os.path.join(home, ".claude", "projects", "a", a + ".jsonl"); open(q, "w").write("o\n" * 7); os.utime(q, (1, 1))
past.update_lengths([a], d, home)
assert past.lengths(d)[a]["lines"] == 1, past.lengths(d)
os.symlink(p(a), p(c))
past.update_lengths([a, c], d, home)
L = past.lengths(d)
assert set(L) == {a}, L  # b no longer asked for: dropped; c a symlink: not read
open(os.path.join(d, past.LENGTHS), "w").write("[1")
assert past.lengths(d) == {}
past.update_lengths([a], d, home)
assert past.lengths(d)[a]["lines"] == 1
PY
}

# The setup of the rc_slow cases, each with a conversation of its own (SL): a favorite of it (ids),
# on, its claude (cs, in pane spane) idle with an empty prompt, rc off; the claude log from here
# on. And the helpers on that claude.
#   slow_setup <SL>
# shellcheck disable=SC2329  # helpers run only through poll
slow_setup() {
server_up
: > "$HOME/claude-args.log"
SL=$1
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SL" > "$HOME/.claude/projects/-x/$SL.jsonl"
asctl fav "$SL" --name slow >/dev/null || stop "a favorite for a slow claude"
ids=$(jq -r --arg s "$SL" '.entries[] | select(.session_id == $s) | .id4' "$REG")
asctl on "$ids" >/dev/null && cs=$(claude_in "slow-$ids") || stop "a claude for a slow prompt"
spane=$(tm list-panes -t "=slow-$ids:" -F '#{pane_id}')
slow_bridge() { jq -r 'select(.name == "slow-'"$ids"'") | .bridgeSessionId // ""' "$HOME"/.claude/sessions/*.json; }
slow_prompt() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import rclive; print(rclive.prompt_text(rclive.screen(sys.argv[2])))' "$REPO" "$spane"; }
slow_empty() { [ -z "$(slow_prompt)" ]; }
# its prompt emptied and its screen still for 0.5 s: every BSpace drawn (an empty prompt alone can
# come while the rest still redraw, and asctl then sees a half-drawn screen)
slow_clear() { tm send-keys -t "$spane" -N 40 BSpace; poll 10 slow_quiet || stop "the slow claude's prompt emptied"; }
slow_quiet() { local a; a=$(tm capture-pane -p -t "$spane"); sleep 0.5; [ "$a" = "$(tm capture-pane -p -t "$spane")" ] && slow_empty; }
lines() { grep -c 'line: ' "$HOME/claude-args.log"; }
# take_back of the command, called at once; the stall flag removed 4.5 s after it starts (when
# take_back has waited for the prompt to stop changing, sent its BSpaces and waited 2 s for them)
take_back_held() {
	python3 -I -c 'import sys, os, threading; sys.path.insert(0, sys.argv[1]); from asc import rclive
threading.Timer(4.5, os.remove, [sys.argv[4]]).start()
print(rclive.take_back(sys.argv[2], sys.argv[3], lambda: None))' "$REPO" "$spane" "/remote-control Slow chat" "$HOME/fake-echo-stall"
}
attached() { [ "$(tm list-clients -t "=slow-$ids" -F x | wc -l)" = 1 ]; }
poll 5 slow_empty || stop "an empty prompt in the slow claude"
}

case_rc_slow() {
slow_setup 22222222-3333-4444-8555-000000000031
echo "== rc now, a slow claude: what is typed drawn late (a busy host)"
# settled() on prompts set by hand: what it holds to its timeout and what it takes once quiet
st=$(python3 -I - "$REPO" <<'EOF'
import sys, time; sys.path.insert(0, sys.argv[1]); from asc import rclive as r
r.screen = lambda pane: None
def took(shown):
    r.prompt_text = lambda scr: shown
    t0 = time.monotonic(); r.settled("%0", quiet=0.2, timeout=2, step=0.05, typed="/remote-control x")
    return time.monotonic() - t0
print("taken" if took("/remote-control x") < 1 and took("hello") < 1 else "-")
print("held" if took("/remote-con") >= 1.9 and took("") >= 1.9 else "-")
EOF
)
grep -qx taken <<<"$st" && ok "settled: all of what was typed, or other text, is taken once it stops changing" || bad "settled: all of what was typed, or other text, is taken once it stops changing" "settled: $st"
grep -qx held <<<"$st" && ok "settled: a start of what was typed, or none of it yet, waits on to its timeout" || bad "settled: a start of what was typed, or none of it yet, waits on to its timeout" "settled: $st"
# drawing stops after 4 characters for 4.5 s: longer than asctl waits for the command to show
# (2 s) and then for its prompt to stop changing (1.5 s); a start of it shown, the rest is on its
# way, and asctl waits on (up to 10 s from when it began to wait, 2 s after typing)
echo "5 4.5" > "$HOME/fake-echo-stall"
out=$(asctl rc "$ids" on --title "Slow chat"); seen 'live now' <<<"$out" && [ -n "$(slow_bridge)" ] && seen -x "pid=[0-9]* line: /remote-control Slow chat" "$HOME/claude-args.log" && slow_empty \
	&& ok "rc on, a slow claude: waited until its prompt stopped changing, then live" || bad "rc on, a slow claude: waited until its prompt stopped changing, then live" "slow on: $out / $(tm capture-pane -p -t "$spane" | tail -4 | tr "\n" "|")"
rm -f "$HOME/fake-echo-stall"; asctl rc "$ids" off --next-start >/dev/null; slow_clear
# taken back while 4 characters are drawn, the rest held: the whole command is removed
n0=$(lines); echo "5 hold" > "$HOME/fake-echo-stall"; tm send-keys -t "$spane" -l "/remote-control Slow chat"
out=$(take_back_held); sleep 0.5
[ "$out" = "nothing was sent" ] && slow_empty && [ "$(lines)" = "$n0" ] \
	&& ok "take back, a slow claude: the whole command removed once its prompt stopped changing" || bad "take back, a slow claude: the whole command removed once its prompt stopped changing" "slow take back: $out / $(slow_prompt)"
rm -f "$HOME/fake-echo-stall"; slow_clear
asctl off "$ids" --force >/dev/null; asctl forget "$ids" >/dev/null
}

case_rc_slow_seen() {
# Setup: as rc_slow leaves it: rc off, its prompt empty, the lines typed so far (n0)
slow_setup 22222222-3333-4444-8555-000000000036
echo "== rc now, a slow claude: a command shown late taken back, or someone at its session"
n0=$(lines)
# taken back while nothing of it is drawn yet: removed too, once it shows
echo "1 hold" > "$HOME/fake-echo-stall"; tm send-keys -t "$spane" -l "/remote-control Slow chat"
out=$(take_back_held); sleep 2  # it shows once the flag is gone, then its BSpaces
[ "$out" = "nothing was sent" ] && slow_empty && [ "$(lines)" = "$n0" ] \
	&& ok "take back, nothing drawn yet: removed as it shows" || bad "take back, nothing drawn yet: removed as it shows" "none drawn: $out / $(slow_prompt)"
rm -f "$HOME/fake-echo-stall"; slow_clear
# someone at its tmux session (a client attached, a key from it just now): nothing typed
out=$(asctl rc "$ids" off); seen 'off now\|not live already' <<<"$out" || stop "rc off in the slow claude" "$out / $(tm capture-pane -p -t "$spane" | tail -8 | tr "\n" "|")"
n0=$(lines)  # that off typed one
mkfifo "$T/slow-keys"
TERM=xterm script -qfc "tmux -L $ASC_TMUX_SOCKET -f /dev/null attach -t =slow-$ids" /dev/null < "$T/slow-keys" >/dev/null 2>&1 & ks=$!
exec {kfd}>"$T/slow-keys"  # the client's keyboard, held by the suite itself (no process to leave behind)
poll 5 attached || stop "a client attached to the slow claude's session"
printf 'x\177' >&"$kfd"; poll 5 slow_empty || stop "the client's keys reached the slow claude"
# its message ends there: nothing typed and taken back (asctl looks before typing, not only after)
out=$(asctl rc "$ids" on --title "Slow chat"); seen -x '.*; not changed now: someone typed in its tmux session just now' <<<"$out" && [ "$(lines)" = "$n0" ] && slow_empty \
	&& ok "rc on: not when someone at its tmux session typed just now" || bad "rc on: not when someone at its tmux session typed just now" "client typed: $out / $(slow_prompt)"
exec {kfd}>&-; kill "$ks" 2>/dev/null; wait "$ks" 2>/dev/null; poll_gone 5 attached || stop "the client gone"; rm -f "$T/slow-keys"
asctl off "$ids" --force >/dev/null; asctl forget "$ids" >/dev/null
}

case_rc_slow_typed() {
# Setup: as rc_slow_seen leaves it: rc off, its prompt empty, the lines typed so far (n0)
slow_setup 22222222-3333-4444-8555-000000000037
n0=$(lines)
echo "== rc now, a slow claude: someone typed while asctl typed; a dialog redrawn late"
# someone typed while asctl typed (tmux reports a client key after the first look): no Enter,
# and what is in its prompt left alone (their keys may be among it)
out=$(python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import rclive, tmuxctl
n = []
tmuxctl.client_activity = lambda session: [int(time.time())] if n.append(1) or len(n) > 1 else []
s = {"pid": int(sys.argv[3]), "pane": {"pane_id": sys.argv[2], "session": sys.argv[4]}}
print(rclive.enter(s, "/remote-control Slow chat", rclive.no_menu))' "$REPO" "$spane" "$cs" "slow-$ids")
sleep 0.5
[ "$out" = "someone typed in its tmux session just now; nothing was sent, but what asctl typed is left in its prompt (someone typed there too); check it" ] \
	&& [ "$(slow_prompt)" = "/remote-control Slow chat" ] && [ "$(lines)" = "$n0" ] \
	&& ok "someone typed while asctl typed: no Enter, its prompt left as it is" || bad "someone typed while asctl typed: no Enter, its prompt left as it is" "typed meanwhile: $out / $(slow_prompt)"
slow_clear
# its dialog redrawn late after each arrow key (a busy host): each Up seen to take effect before
# the next, so Enter takes Disconnect
out=$(asctl rc "$ids" on --title "Slow chat"); seen 'live now' <<<"$out" || stop "rc on in the slow claude, for its dialog" "$out"
touch "$HOME/fake-slow-keys"
out=$(asctl rc "$ids" off); rm -f "$HOME/fake-slow-keys"
seen 'off now' <<<"$out" && [ -z "$(slow_bridge)" ] \
	&& ok "rc off, a dialog redrawn late: Disconnect chosen, one Up at a time" || bad "rc off, a dialog redrawn late: Disconnect chosen, one Up at a time" "slow dialog: $out / $(tm capture-pane -p -t "$spane" | tail -6 | tr "\n" "|")"
asctl off "$ids" --force >/dev/null; asctl forget "$ids" >/dev/null
}

# The setup of the new_name cases, each with a conversation of its own (SID2): as "exact names,
# trust prompt, rename, mode" left it, a favorite of a past conversation (id2), off, named chat, in
# a trusted folder.
#   name_setup <SID2>
name_setup() {
server_up
SID2=$1
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SID2" > "$HOME/.claude/projects/-x/$SID2.jsonl"
asctl fav "$SID2" --name chat >/dev/null || stop "a favorite for a new name"
id2=$(jq -r --arg s "$SID2" '.entries[] | select(.session_id == $s) | .id4' "$REG")
}
sname() { jq -r .name "$HOME/.claude/sessions/$1.json"; }

case_new_name() {
# The claude log from here on (restart_name's last check reads it too): main's rc start typed a
# /rename, and this case's first check says none was typed.
: > "$HOME/claude-args.log"
name_setup 22222222-3333-4444-8555-000000000007
echo "== a new name for a running claude: /rename when idle"
asctl on "$id2" >/dev/null
c1=$(claude_in "chat-$id2") && ok "a new name: claude up after on" || bad "a new name: claude up after on" "no claude in chat-$id2"
touch "$HOME/fake-busy"; flagged
out=$(asctl rename "$id2" talk 2>&1)
seen "renamed to talk-$id2; claude's own name not changed now: claude is busy" <<<"$out" && [ "$(sname "$c1")" = "chat-$id2" ] && ! seen 'line: /rename' "$HOME/claude-args.log" \
	&& ok "rename while claude works: the favorite renamed, nothing typed" || bad "rename while claude works: the favorite renamed, nothing typed" "rename while busy: $out"
rm -f "$HOME/fake-busy"; flagged
out=$(asctl rename "$id2" talk 2>&1)
seen 'claude and its claude.ai title too' <<<"$out" && [ "$(claude_in "talk-$id2")" = "$c1" ] && [ "$(sname "$c1")" = "talk-$id2" ] && seen "line: /rename talk-$id2" "$HOME/claude-args.log" \
	&& ok "rename of an idle claude: /rename typed, the same claude takes the name" || bad "rename of an idle claude: /rename typed, the same claude takes the name" "live rename: $out / $(sname "$c1")"
touch "$HOME/fake-menu-on"
out=$(asctl rename "$id2" talk3 2>&1)
seen 'not changed now: a command menu opened at its prompt; nothing was sent' <<<"$out" && [ "$(sname "$c1")" = "talk-$id2" ] && ok "rename: not when a menu would take Enter" || bad "rename: not when a menu would take Enter" "rename with a menu: $out"
rm -f "$HOME/fake-menu-on"
touch "$HOME/fake-no-rename"
out=$(asctl rename "$id2" talk4 2>&1)
seen "not changed now: typed, but claude did not record the new name" <<<"$out" && ok "rename: typed but not taken by claude: said so" || bad "rename: typed but not taken by claude: said so" "rename not taken: $out"
rm -f "$HOME/fake-no-rename"
asctl off "$id2" --force >/dev/null
}

case_restart_name() {
# Setup: as new_name has it at this point: its favorite on, renamed talk, its claude (c1) idle.
name_setup 22222222-3333-4444-8555-00000000003b
asctl on "$id2" >/dev/null && c1=$(claude_in "chat-$id2") || stop "a claude for a restart"
asctl rename "$id2" talk >/dev/null && [ "$(sname "$c1")" = "talk-$id2" ] || stop "the claude renamed talk"
echo "== a new name for a running claude: a restart"
touch "$HOME/fake-task"; flagged
out=$(asctl rename "$id2" talk2 --restart 2>&1)
seen 'not restarted now: busy: .* runs a command' <<<"$out" && [ "$(claude_in "talk2-$id2")" = "$c1" ] && ok "rename --restart: not while claude runs a command (a background one too)" || bad "rename --restart: not while claude runs a command (a background one too)" "restart with a command running: $out"
asctl off "$id2" >/dev/null 2>&1 && bad "off refused while claude runs a command" "off went ahead while claude runs a command" || ok "off refused while claude runs a command"
rm -f "$HOME/fake-task"; flagged
AG="$HOME/.claude/projects/-x/$SID2/subagents"; mkdir -p "$AG"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a1.jsonl"
out=$(errof restart "$id2"); seen 'runs a subagent' <<<"$out" && ok "restart: not while a subagent runs" || bad "restart: not while a subagent runs" "restart with a subagent: $out"
printf '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}\n' >> "$AG/agent-a1.jsonl"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a2.jsonl"; echo '{"finished":true}' > "$AG/agent-a2.meta.json"
printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$AG/agent-a3.jsonl"; touch -d '20 minutes ago' "$AG/agent-a3.jsonl"
asctl rc "$id2" on --next-start >/dev/null
out=$(asctl restart "$id2" 2>&1)
c2=$(claude_in "talk2-$id2") && [ "$c2" != "$c1" ] && [ "$(jqe ".entries[\"$id2\"].session_id")" = "$SID2" ] \
	&& lastargs | seen -- "--resume $SID2 --name talk2-$id2 .*--remote-control talk2-$id2" \
	&& ok "restart: a new claude on the same conversation, with the new name and rc title (finished, ended or old subagents do not hold it)" || bad "restart: a new claude on the same conversation, with the new name and rc title (finished, ended or old subagents do not hold it)" "restart: $out / $(lastargs)"
grep "pid=$c2 " "$HOME/claude-args.log" | seen "line: /rename talk2-$id2" && ok "a start with rc sends its name to claude.ai (/rename, once rc is up)" || bad "a start with rc sends its name to claude.ai (/rename, once rc is up)" "no /rename after an rc start: $(grep "pid=$c2 " "$HOME/claude-args.log")"
out=$(asctl rename "$id2" chat --restart 2>&1)
c3=$(claude_in "chat-$id2") && [ "$c3" != "$c2" ] && lastargs | seen -- "--name chat-$id2" && ok "rename --restart of an idle claude: restarted with the new name" || bad "rename --restart of an idle claude: restarted with the new name" "rename --restart: $out"
touch "$HOME/fake-wait"; flagged
out=$(errof restart "$id2"); seen 'its claude is waiting' <<<"$out" && [ "$(claude_in "chat-$id2")" = "$c3" ] && ok "restart: not while claude waits (a question or dialog would be lost)" || bad "restart: not while claude waits (a question or dialog would be lost)" "restart while waiting: $out"
rm -f "$HOME/fake-wait" "$AG"/*
asctl rc "$id2" off --next-start >/dev/null; asctl off "$id2" --force >/dev/null
asctl restart "$id2" >/dev/null 2>&1 && bad "restart: refused when it is off" "restart of an off favorite went ahead" || ok "restart: refused when it is off"
[ "$(grep 'line: ' "$HOME/claude-args.log" | grep -vc 'line: /rename ')" = 0 ] && ok "new names: nothing but /rename ever reached a prompt" || bad "new names: nothing but /rename ever reached a prompt" "lines entered: $(grep 'line: ' "$HOME/claude-args.log")"
}

# The setup of the outside cases, each with a conversation of its own (OS): the tmux server kept
# up with no session (the case closes its only one), Claude Code's version binary (as "a
# background job" made it), the event log's path, a favorite of the conversation (ido, named
# outer) off with rc on at its next start, and a claude that ends on SIGTERM, as the real one
# does, for a terminal outside tmux (outer_tty [hold]: one that ignores SIGTERM; its pid tp).
#   outside_setup <OS>
# shellcheck disable=SC2329  # helpers run only through poll
outside_setup() {
server_up
[ -e "$T/versions/2.1.316" ] || { mkdir -p "$T/versions"; cp "$(command -v bash)" "$T/versions/2.1.316"; }
EVF="$HOME/.local/state/agent-session-control/events.jsonl"
OS=$1
tm new-session -d -s outer -c "$W" -- "$ASC_CLAUDE" --session-id "$OS"
po=$(claude_in outer) || stop "a claude in outer"
# its first message written: a transcript, so a start takes the conversation up (--resume)
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$OS" > "$HOME/.claude/projects/-x/$OS.jsonl"
asctl fav "$po" --name outer >/dev/null; ido=$(jq -r --arg s "$OS" '.entries[] | select(.session_id == $s) | .id4' "$REG")
asctl off "$ido" >/dev/null; asctl rc "$ido" on --next-start >/dev/null
# $1: anything: it ignores SIGTERM
printf '%s\n' '[ -n "${1:-}" ] && trap "" TERM || trap '"'"'kill $! 2>/dev/null; exit 143'"'"' TERM' 'sleep 300 & wait; wait' > "$T/outside.sh"
outer_up() { tp=$(pgrep -P "$sc" | head -1); [ -n "$tp" ] && [ "$(cat /proc/"$tp"/comm 2>/dev/null)" = claude ]; }
outer_tty() { script -qfc "exec -a claude '$FAKE_BASH' '$T/outside.sh' ${1:-}" /dev/null >/dev/null 2>&1 & sc=$!; poll 3 outer_up || return 1; }
}

case_outside() {
outside_setup eeeeeeee-0000-4000-8000-000000000001
echo "== a claude outside its tmux session: where it runs, restart into tmux, its name owed to claude.ai"
outer_tty || stop "a claude in a terminal outside tmux"
sfile "$tp" "$OS" "$(start_of "$tp")" ',"kind":"interactive","status":"busy"'
asctl list | seen "outer-$ido *on (outside" && ok "outside: its favorite is on, outside its tmux session" || bad "outside: its favorite is on, outside its tmux session" "outside list: $(asctl list | grep outer)"
o=$(errof off "$ido")
seen "runs outside its tmux session 'outer-$ido', in a terminal outside tmux (script, pts/[0-9]*);" <<<"$o" && seen "asctl restart $ido moves it" <<<"$o" && kill -0 "$tp" \
	&& ok "off refused: where it runs named (the program and its terminal), and how to move it in" || bad "off refused: where it runs named (the program and its terminal), and how to move it in" "outside off: $o"
o=$(errof restart "$ido")
seen "busy: its claude is working (its claude runs in a terminal outside tmux" <<<"$o" && kill -0 "$tp" && ok "restart refused while it works" || bad "restart refused while it works" "outside restart busy: $o"
sfile "$tp" "$OS" "$(start_of "$tp")" ',"kind":"interactive","status":"idle"'
tm new-session -d -s "outer-$ido" -- sleep 300
o=$(errof restart "$ido"); tm kill-session -t "=outer-$ido"
seen "is up without it: close that session first" <<<"$o" && kill -0 "$tp" && ok "restart refused: its tmux session is up without it (nothing ended)" || bad "restart refused: its tmux session is up without it (nothing ended)" "outside restart, session up: $o"
asctl restart "$ido" >/dev/null 2>&1; r=$?
pn=$(claude_in "outer-$ido") && [ $r = 0 ] && ! kill -0 "$tp" 2>/dev/null && seen "^pid=$pn .*--resume $OS" "$HOME/claude-args.log" \
	&& ok "restart: the idle claude outside ended, and started in its tmux session on the same conversation" || bad "restart: the idle claude outside ended, and started in its tmux session on the same conversation" "outside restart: rc $r tp $tp pn $pn"
jq -s -c --arg i "$ido" '[.[] | select(.id4 == $i and .kind == "off")] | last | .text' "$EVF" | seen "in a terminal outside tmux (script, pts/[0-9]*) ended, to start again in its tmux session" \
	&& ok "restart: its off event says where it ran" || bad "restart: its off event says where it ran" "outside off event: $(tail -3 "$EVF")"
o=$(errof restart "$ido" --outside); seen "runs in 'outer-$ido', not outside it: nothing to move in" <<<"$o" && [ "$(claude_in "outer-$ido")" = "$pn" ] \
	&& ok "restart --outside (the page's): refused for a claude in its tmux session" || bad "restart --outside (the page's): refused for a claude in its tmux session" "restart --outside in tmux: $o"
seen "pid=$pn line: /rename outer-$ido" "$HOME/claude-args.log" && [ "$(jq -r --arg i "$ido" '.entries[$i].rename_pending' "$REG")" = null ] \
	&& ok "restart with rc: its name sent to claude.ai at the start (a resumed claude.ai session keeps its old title)" || bad "restart with rc: its name sent to claude.ai at the start (a resumed claude.ai session keeps its old title)" "title at start: $(jq -c --arg i "$ido" '.entries[$i]' "$REG")"
asctl off "$ido" >/dev/null; touch "$HOME/fake-busy"
o=$(asctl on "$ido" 2>&1)
pb=$(claude_in "outer-$ido") && seen "its name not sent to claude.ai: claude is busy" <<<"$o" && [ "$(jq -r --arg i "$ido" '.entries[$i] | "\(.rename_pending) \(.rename_title)"' "$REG")" = "outer-$ido true" ] \
	&& ok "a start that cannot send its name to claude.ai (claude busy): owed to it, though claude has the name" || bad "a start that cannot send its name to claude.ai (claude busy): owed to it, though claude has the name" "title owed: $o / $(jq -c --arg i "$ido" '.entries[$i]' "$REG")"
rm -f "$HOME/fake-busy"; flagged
# the watcher's step for it alone (a whole watcher run here would start the watcher tests' state early)
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import cli, registry, watch
e = registry.find(registry.load(), sys.argv[2])
with registry.entry_lock(e["id4"]):
    watch._pending_rename({"rename_tries": {}}, e, cli.live_in(e))' "$REPO" "$ido"
seen "pid=$pb line: /rename outer-$ido" "$HOME/claude-args.log" && [ "$(jq -r --arg i "$ido" '.entries[$i] | "\(.rename_pending) \(.rename_title)"' "$REG")" = "null null" ] \
	&& ok "the watcher sends it once claude is idle (/rename, though claude has the name), and it is no longer owed" || bad "the watcher sends it once claude is idle (/rename, though claude has the name), and it is no longer owed" "title sent: $(jq -c --arg i "$ido" '.entries[$i]' "$REG")"
kill "$sc" 2>/dev/null; asctl off "$ido" >/dev/null; asctl forget "$ido" >/dev/null
}

case_outside_hold() {
# Setup: as outside leaves its favorite: off
outside_setup eeeeeeee-0000-4000-8000-000000000002
echo "== a claude outside its tmux session that does not end on SIGTERM"
outer_tty hold || stop "a claude outside tmux that ignores SIGTERM"
sfile "$tp" "$OS" "$(start_of "$tp")" ',"kind":"interactive","status":"idle"'
o=$(errof restart "$ido")
seen "still runs 15 s later; nothing was started" <<<"$o" && ! tm has-session -t "=outer-$ido" 2>/dev/null && ok "restart: a claude that does not end on SIGTERM: nothing started" || bad "restart: a claude that does not end on SIGTERM: nothing started" "outside restart, no end: $o"
kill -KILL "$tp" "$sc" 2>/dev/null; wait "$sc" 2>/dev/null; rm -f "$HOME/.claude/sessions/$tp.json"
asctl forget "$ido" >/dev/null
}

case_outside_bg() {
# Setup: as outside_hold leaves its favorite: off
outside_setup eeeeeeee-0000-4000-8000-000000000003
echo "== a claude outside its tmux session: off and restart of a background session"
( exec -a claude "$T/versions/2.1.316" "$T/outside.sh" ) >/dev/null 2>&1 & bp=$!; sleep 0.3
sfile "$bp" "$OS" "$(start_of "$bp")" ',"kind":"bg","jobId":"eeee0001","status":"busy"'
o=$(errof off "$ido")
seen "busy: its claude is working (its claude runs as a Claude Code background session (job eeee0001))" <<<"$o" && kill -0 "$bp" && ok "off of a background session refused while it works" || bad "off of a background session refused while it works" "bg off busy: $o"
sfile "$bp" "$OS" "$(start_of "$bp")" ',"kind":"bg","jobId":"eeee0001","status":"idle"'; touch "$HOME/fake-stop-fails"
o=$(errof off "$ido"); rm -f "$HOME/fake-stop-fails"
seen "claude stop eeee0001: Could not reach the daemon" <<<"$o" && kill -0 "$bp" && ok "off: claude stop failing is said, and the session still runs" || bad "off: claude stop failing is said, and the session still runs" "bg off, stop fails: $o"
o=$(asctl off "$ido" 2>&1); r=$?
[ $r = 0 ] && seen "its background session stopped; the conversation is kept" <<<"$o" && ! kill -0 "$bp" 2>/dev/null && seen "args=stop eeee0001" "$HOME/claude-args.log" \
	&& [ "$(jq -r --arg i "$ido" '.entries[$i].want_on' "$REG")" = false ] && ok "off of an idle background session: claude stop ends it, it is marked off" || bad "off of an idle background session: claude stop ends it, it is marked off" "bg off: rc $r $o"
tail -1 "$EVF" | seen "its background session (job eeee0001) stopped with claude stop" && ok "off of a background session: logged" || bad "off of a background session: logged" "bg off event: $(tail -1 "$EVF")"
( exec -a claude "$T/versions/2.1.316" "$T/outside.sh" ) >/dev/null 2>&1 & bp=$!; sleep 0.3
sfile "$bp" "$OS" "$(start_of "$bp")" ',"kind":"bg","jobId":"eeee0001","status":"idle"'
asctl restart "$ido" >/dev/null 2>&1; r=$?
pn=$(claude_in "outer-$ido") && [ $r = 0 ] && ! kill -0 "$bp" 2>/dev/null && [ "$(grep -c "args=stop eeee0001" "$HOME/claude-args.log")" = 3 ] \
	&& ok "restart of a background session: claude stop, then started in its tmux session" || bad "restart of a background session: claude stop, then started in its tmux session" "bg restart: rc $r pn $pn"
asctl off "$ido" >/dev/null; asctl forget "$ido" >/dev/null
[ "$(grep 'line: ' "$HOME/claude-args.log" | grep -vc 'line: /rename ')" = 0 ] && ok "outside: nothing but /rename ever reached a prompt" || bad "outside: nothing but /rename ever reached a prompt" "lines entered: $(grep 'line: ' "$HOME/claude-args.log")"
}

case_watcher_memory() {
# Setup: two favorites, off, as main leaves them: one holding SID2, one whose conversation has no
# transcript (its length counted).
server_up
SID2=22222222-3333-4444-8555-000000000022 NT=22222222-3333-4444-8555-000000000023
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SID2" > "$HOME/.claude/projects/-x/$SID2.jsonl"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$NT" > "$HOME/.claude/projects/-x/$NT.jsonl"
asctl fav "$SID2" --name held >/dev/null || stop "a favorite holding SID2"
asctl fav "$NT" --name nolen >/dev/null || stop "a favorite with no transcript"
rm -f "$HOME/.claude/projects/-x/$NT.jsonl"
echo "== watcher: memory samples, conversation lengths"
# memory.steady() and memory.evidence(), and live.busy_reason(), on values set by hand
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
	&& ok "steady and evidence: gaps, a dip, another boot, each kind of pressure, samples too far apart" || bad "steady and evidence: gaps, a dip, another boot, each kind of pressure, samples too far apart" "steady/evidence rules"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import live, tmuxctl
tmuxctl.panes = lambda *a, **k: None
assert live.busy_reason("x", []) == "tmux did not list its panes"' "$REPO" && ok "busy: tmux not answering counts as busy" || bad "busy: tmux not answering counts as busy" "tmux failure read as not busy"
watch && jq -e 'length == 1 and .[0].avail_pct == 50 and .[0].oom_kill == 0 and (.[0].boot | length) > 0' "$SD/memory.json" >/dev/null \
	&& [ "$(stat -c %a "$SD/memory.json" "$SD/watch.json" | sort -u)" = 600 ] && ok "watch: a memory sample kept, its files 0600" || bad "watch: a memory sample kept, its files 0600" "watch: no sample: $(cat "$SD/memory.json")"
jq -e --argjson n "$(date +%s)" '.at <= $n and .at > $n - 60' "$SD/watch.json" >/dev/null && ok "watch: when its run began, for the dashboard" || bad "watch: when its run began, for the dashboard" "watch.json at: $(cat "$SD/watch.json")"
flock "$SD/watch.lock" sleep 2 & fl=$!; sleep 0.3
watch; [ "$(jq length "$SD/memory.json")" = 1 ] && ok "watch: a run while another holds the lock does nothing" || bad "watch: a run while another holds the lock does nothing" "watch ran twice at once"
wait $fl
# The length of a favorite's conversation: one with no transcript yet gets one of 4 lines.
lsid=$(jq -r '[.entries[].session_id] | .[]' "$REG" | while read -r x; do compgen -G "$HOME/.claude/projects/*/$x.jsonl" >/dev/null || { echo "$x"; break; }; done)
mkdir -p "$HOME/.claude/projects/-len"; printf 'a\nb\nc\nd\n' > "$HOME/.claude/projects/-len/$lsid.jsonl"
watch; jq -e --arg s "$lsid" '.[$s].lines == 4 and .[$s].size == 8' "$SD/lengths.json" >/dev/null && [ "$(stat -c %a "$SD/lengths.json")" = 600 ] \
	&& ok "watch: a favorite's conversation length counted (lengths.json, 0600)" || bad "watch: a favorite's conversation length counted (lengths.json, 0600)" "watch lengths ($lsid): $(cat "$SD/lengths.json" 2>&1)"
rm -f "$HOME/.claude/projects/-len/$lsid.jsonl"
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 600), dict(s, t=now - 400), dict(s, boot="old"), dict(s, t=now + 99)])' "$REPO"
watch; jq -e 'length == 2 and .[1].t - .[0].t >= 400 and .[1].t - .[0].t < 420' "$SD/memory.json" >/dev/null && ok "watch: samples kept 8 min, this boot's only, none from the future" || bad "watch: samples kept 8 min, this boot's only, none from the future" "samples kept: $(jq -c '[.[] | [.t, .boot]]' "$SD/memory.json")"
for _ in $(seq 1 125); do watch; done
[ "$(jq length "$SD/memory.json")" = 120 ] && ok "watch: at most 120 samples" || bad "watch: at most 120 samples" "samples kept: $(jq length "$SD/memory.json")"
}

case_watcher_follow() {
# Setup: a favorite, off, holding a session of its own (SH: "not followed: a session id another
# favorite holds"), as watcher_memory's are.
server_up
SH=22222222-3333-4444-8555-000000000038
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$SH" > "$HOME/.claude/projects/-x/$SH.jsonl"
asctl fav "$SH" --name heldb >/dev/null || stop "a favorite holding SH"
echo "== watcher: memory warnings, following, a pending rename, duplicates"
m0=$(evn memory); mem 32000000 3200000; watch; watch
[ "$(evn memory)" = $((m0 + 1)) ] && last memory | seen 'memory low: 10.0% available' && ok "memory under 15%: one warning, not one per run" || bad "memory under 15%: one warning, not one per run" "memory warning: $(evn memory) $(last memory)"
mem 32000000 4900000; watch; [ "$(evn memory)" = $((m0 + 1)) ] && ok "15.3%: still warned (back only 1 point over)" || bad "15.3%: still warned (back only 1 point over)" "memory warning flaps"
mem 32000000 16000000; watch; last memory | seen 'memory back: 50.0% available' && ok "memory back: logged once" || bad "memory back: logged once" "memory back: $(last memory)"
# A favorite started by asctl in its own session
WS=eeeeeeee-0000-4000-8000-00000000000a
tm new-session -d -s w -c "$W" -- "$ASC_CLAUDE" --session-id "$WS"
pw=$(claude_in w) || stop "a claude in w"
asctl fav "$pw" --name wat >/dev/null; idw=$(jq -r '.entries[] | select(.name == "wat") | .id4' "$REG")
asctl off "$idw" >/dev/null; asctl on "$idw" >/dev/null
pw=$(claude_in "wat-$idw") && ok "watcher: claude up in wat-<id> after on" || bad "watcher: claude up in wat-<id> after on" "no claude in wat-$idw"
watch; [ "$(jq ".entries[\"$idw\"].rss_kb" "$REG")" -gt 0 ] && ok "watch: the favorite's memory kept as rss_kb" || bad "watch: the favorite's memory kept as rss_kb" "rss_kb: $(jq ".entries[\"$idw\"].rss_kb" "$REG")"
WS2=eeeeeeee-0000-4000-8000-00000000000b
echo "$WS2" > "$HOME/fake-branch-$WS"; sleep 0.8; watch
jq -e --arg i "$idw" --arg a "$WS" --arg b "$WS2" '.entries[$i] | .session_id == $b and .lineage[0] == $a' "$REG" >/dev/null && last followed | seen "now holds session $WS2" \
	&& ok "followed: a new session id in its own pane (a branch), the old one in lineage" || bad "followed: a new session id in its own pane (a branch), the old one in lineage" "branch not followed: $(jq -c ".entries[\"$idw\"] | {session_id, lineage}" "$REG")"
echo "$SH" > "$HOME/fake-branch-$WS2"; sleep 0.8; f0=$(evn followed); watch
[ "$(jq -r ".entries[\"$idw\"].session_id" "$REG")" = "$WS2" ] && [ "$(evn followed)" = "$f0" ] && ok "not followed: a session id another favorite holds" || bad "not followed: a session id another favorite holds" "followed into another favorite's session"
echo "$WS2" > "$HOME/fake-branch-$SH"; sleep 0.8
mkdir -p "$T/moved"; echo "$T/moved" > "$HOME/fake-cd-$WS2"; sleep 0.8; watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$T/moved" ] && last followed | seen "moved to $T/moved" && ok "followed: a new folder (/cd)" || bad "followed: a new folder (/cd)" "cd not followed: $(jq -r ".entries[\"$idw\"].cwd" "$REG")"
echo /nonexistent > "$HOME/fake-cd-$WS2"; sleep 0.8; watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$T/moved" ] && ok "not followed: a folder that does not exist" || bad "not followed: a folder that does not exist" "followed a missing folder"
rm -f "$HOME/fake-cd-$WS2"
touch "$HOME/fake-busy"; flagged
asctl rename "$idw" wat2 | seen 'The watcher sends it once claude is idle' && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat2-$idw" ] \
	&& ok "rename while busy: pending" || bad "rename while busy: pending" "rename pending: $(jq -r ".entries[\"$idw\"].rename_pending" "$REG")"
watch; watch; watch; watch; [ "$(jq -r .name "$HOME/.claude/sessions/$pw.json")" = "wat-$idw" ] && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat2-$idw" ] \
	&& ok "watch: nothing typed while claude works, however long (the rename stays pending)" || bad "watch: nothing typed while claude works, however long (the rename stays pending)" "renamed while busy, or pending dropped"
rm -f "$HOME/fake-busy"; flagged; watch
[ "$(jq -r .name "$HOME/.claude/sessions/$pw.json")" = "wat2-$idw" ] && [ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = null ] && last rename | seen "took the name wat2-$idw" \
	&& ok "watch: the pending rename sent once idle, then cleared" || bad "watch: the pending rename sent once idle, then cleared" "pending rename: $(jq -r .name "$HOME/.claude/sessions/$pw.json")"
tm new-session -d -s twin -c "$W" -- "$ASC_CLAUDE" --resume "$WS2"
claude_in twin >/dev/null || stop "a claude in twin"
d0=$(evn duplicate); watch; watch
[ "$(evn duplicate)" = $((d0 + 1)) ] && last duplicate | jq -e --arg i "$idw" '.id4 == $i and (.text | test("2 live claudes"))' >/dev/null \
	&& ok "duplicate: logged once, on its favorite" || bad "duplicate: logged once, on its favorite" "duplicate: $(evn duplicate) $(last duplicate)"
[ "$(jq -r ".entries[\"$idw\"].session_id" "$REG")" = "$WS2" ] && ok "a duplicate is never followed or touched" || bad "a duplicate is never followed or touched" "duplicate changed the entry"
tm kill-session -t =twin
# Its favorite off: no later case meets its claude.
asctl off "$idw" --force >/dev/null
}

# The setup of the watcher_ended cases, each with sessions of its own (WS2, OT): a favorite (idw)
# on, its claude (pw) started by asctl in wat2-<id> on session WS2, its folder followed to
# $T/moved, the watcher run since (a memory sample from before an end); and a second favorite,
# off ("the others go on").
#   ended_setup <WS2> <OT>
# shellcheck disable=SC2329  # helpers run only through poll
ended_setup() {
server_up
WS2=$1 OT=$2
tm new-session -d -s wend -c "$W" -- "$ASC_CLAUDE" --session-id "$WS2"
pw=$(claude_in wend) || stop "a claude in wend"
# its first message written: a transcript, so a start takes the conversation up (--resume)
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$WS2" > "$HOME/.claude/projects/-x/$WS2.jsonl"
asctl fav "$pw" --name wat2 >/dev/null || stop "a favorite of the claude in wend"
idw=$(jq -r --arg s "$WS2" '.entries[] | select(.session_id == $s) | .id4' "$REG")
asctl off "$idw" >/dev/null; asctl on "$idw" >/dev/null
pw=$(claude_in "wat2-$idw") || stop "a claude in wat2-<id> after on"
mkdir -p "$T/moved"; echo "$T/moved" > "$HOME/fake-cd-$WS2"
moved_in() { watch; [ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$T/moved" ]; }
poll 5 moved_in || stop "wat2-<id> followed to its folder"
rm -f "$HOME/fake-cd-$WS2"
mkdir -p "$HOME/.claude/projects/-x"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$OT" > "$HOME/.claude/projects/-x/$OT.jsonl"
asctl fav "$OT" --name wother >/dev/null || stop "a second favorite for the watcher"
}
# One more OOM kill seen: the counter only grows, as the kernel's does (from the cases before too)
bump() { local k; k=$(awk '$1 == "oom_kill" {print $2}' "$T/vmstat"); vm 0 0 0 $((k + 1)); }
ended() { last ended | jq -r .text; }
# A watcher_ended case's favorite as the case before it left it: auto-restart on, its size known,
# its last restart by the watcher at <when> (epoch s), memory steady.
#   ended_as_before <when>
ended_as_before() {
asctl auto-restart on >/dev/null || stop "auto-restart on"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]].update(rss_kb=400000, auto_restarted=int(sys.argv[3]))' "$REPO" "$idw" "$1" || stop "its size and last restart"
seed
}

case_watcher_ended() {
ended_setup eeeeeeee-0000-4000-8000-0000000000e2 eeeeeeee-0000-4000-8000-0000000000e3
echo "== watcher: a claude that ended with its tmux session up"
asctl events "$idw" >/dev/null
# the evidence needs a sample from a second before the end (whole seconds): the last one, from
# the watch above, may be of the same second as the kill
sleep 1.1; kill -TERM "$pw"; sleep 1.2; watch
ended | seen '^claude ended, exit 143 (a signal), its tmux session up; .*not started again: auto-restart is off' && ok "ended by SIGTERM: logged, auto-restart off by default" || bad "ended by SIGTERM: logged, auto-restart off by default" "ended: $(ended)"
e0=$(evn ended); watch; [ "$(evn ended)" = "$e0" ] && ok "an end is logged once" || bad "an end is logged once" "logged again"
asctl auto-restart on | seen 'auto-restart on' && [ "$(jq -r .settings.auto_restart "$REG")" = true ] && ok "auto-restart on" || bad "auto-restart on" "auto-restart on failed"
watch; last waiting | jq -r .text | seen 'no memory pressure seen' && ok "no memory pressure seen: not started, said once" || bad "no memory pressure seen: not started, said once" "waiting: $(last waiting)"
w0=$(evn waiting); watch; [ "$(evn waiting)" = "$w0" ] && ok "waiting said once" || bad "waiting said once" "waiting repeated"
asctl off "$idw" --force >/dev/null; asctl on "$idw" >/dev/null
pw=$(claude_in "wat2-$idw") && ok "auto-restart: claude up after on" || bad "auto-restart: claude up after on" "no claude in wat2-$idw"
seed; watch; bump; kill -TERM "$pw"; sleep 1.2; watch
pn=$(claude_in "wat2-$idw") && [ "$pn" != "$pw" ] && last restarted | jq -r .text | seen 'started again after exit 143 (1 OOM kill' && [ "$(jq ".entries[\"$idw\"].auto_restarted > 0" "$REG")" = true ] \
	&& ok "restarted: ended by a signal, an OOM kill seen, memory steady" || bad "restarted: ended by a signal, an OOM kill seen, memory steady" "not restarted: $(ended) / $(last waiting) / $(last restarted)"
last on | jq -e '.by == "watch"' >/dev/null && ok "its on is by watch" || bad "its on is by watch" "on by: $(last on)"
pw=$pn; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; watch
ended | seen 'started again under 30 min ago' && ok "not again within 30 min" || bad "not again within 30 min" "30 min: $(ended)"
python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
tm send-keys -t "=wat2-$idw:" 'sleep 300' Enter; sleep 0.8; seed; watch
last waiting | jq -r .text | seen "its pane's shell runs something" && ! claude_now "wat2-$idw" >/dev/null 2>&1 && ok "its pane runs something: not started" || bad "its pane runs something: not started" "busy pane: $(last waiting)"
tm send-keys -t "=wat2-$idw:" C-c; sleep 0.5; mem 32000000 4800000; watch
last waiting | jq -r .text | seen 'memory: ' && ok "memory short: waiting" || bad "memory short: waiting" "memory gate: $(last waiting)"
mem 32000000 16000000; watch
last waiting | jq -r .text | seen 'memory: down to 15.0% available in the last 5 min' && ok "after a dip, waits for 5 min steady" || bad "after a dip, waits for 5 min steady" "steady: $(last waiting)"
rk() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["rss_kb"] = int(sys.argv[3])' "$REPO" "$idw" "$1"; }
rk 13000000; seed; watch
last waiting | jq -r .text | seen 'would leave' && ! claude_now "wat2-$idw" >/dev/null 2>&1 && ok "steady, but no room for its size: waiting" || bad "steady, but no room for its size: waiting" "room check: $(last waiting)"
rk 400000
seed; bump; watch; pn=$(claude_in "wat2-$idw") && ok "steady again: started" || bad "steady again: started" "not started when steady: $(last waiting)"
# An end with no sample after it yet: told by the next run, not taken as "no pressure". (The end is
# 3 s ahead in whole seconds, as samples are: the next sample over 4 s later is surely after it.)
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
pw=$pn; seed; bump; watch; kill -TERM "$pw"; sleep 1.2
printf '143 %s %s %s\n' "$(( $(date +%s) + 3 ))" "$(cat /proc/sys/kernel/random/boot_id)" "$(tm display -p -t "=wat2-$idw:" '#{pane_pid}')" > "$SD/exit/$idw"; watch
ended | seen 'no memory samples around that time' && ok "an end with no sample after it yet: said so, not taken as no pressure" || bad "an end with no sample after it yet: said so, not taken as no pressure" "no sample after: $(ended)"
bump; sleep 4.2; watch; pn=$(claude_in "wat2-$idw") && last restarted | seen '1 OOM kill' && ok "no sample after the end yet: asked again next run, then started" || bad "no sample after the end yet: asked again next run, then started" "evidence not asked again: $(jq -s -c '.[-4:] | map([.kind, .text])' "$SD/events.jsonl") / $(cat "$SD/exit/$idw" 2>&1) / $(jq -c '[.[-3:][] | [.t, .oom_kill]]' "$SD/memory.json")"
# its favorite off, auto-restart off: as the next cases start
asctl off "$idw" --force >/dev/null; asctl auto-restart off >/dev/null
}

case_watcher_reasons() {
# Setup: as watcher_ended leaves its favorite: just started again by the watcher.
ended_setup eeeeeeee-0000-4000-8000-0000000000f2 eeeeeeee-0000-4000-8000-0000000000f3
ended_as_before "$(date +%s)"
echo "== watcher: why an ended claude is not started again; a restart in place"
watch; kill -INT "$pw"; sleep 1.2; bump; watch
ended | seen 'exit 0, .*not started again: it did not end by a signal' && ok "exit 0 (the user ended it): never started again" || bad "exit 0 (the user ended it): never started again" "exit 0: $(ended)"
printf '143 %s some-other-boot\n' "$(date +%s)" > "$SD/exit/$idw"; watch
ended | seen 'not started again: it ended before this boot' && ok "an exit of another boot: not started again" || bad "an exit of another boot: not started again" "other boot: $(ended)"
: > "$HOME/no-boot"; printf '143 %s\n' "$(( $(date +%s) + 1 ))" > "$SD/exit/$idw"; ASC_BOOT_ID="$HOME/no-boot" watch
ended | seen 'not started again: it ended before this boot' && ok "no boot id, here or in the record: not taken as this boot" || bad "no boot id, here or in the record: not taken as this boot" "empty boot: $(ended)"
rm -f "$SD/exit/$idw"; watch
ended | seen 'no exit record' && ok "no exit record: logged, not started" || bad "no exit record: logged, not started" "no record: $(ended)"
bootid=$(cat /proc/sys/kernel/random/boot_id); ppid_=$(tm display -p -t "=wat2-$idw:" '#{pane_pid}')
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
printf '143 %s %s %s\n' "$(( $(date +%s) - 3700 ))" "$bootid" "$ppid_" > "$SD/exit/$idw"; seed; watch
ended | seen 'it ended over 60 min ago' && ok "an end over an hour old: not started again" || bad "an end over an hour old: not started again" "age: $(ended)"
printf '143 %s %s %s\n' "$(date +%s)" "$bootid" 1 > "$SD/exit/$idw"; seed; bump; sleep 1.1; watch
ended | seen 'runs another process than the one asctl started' && ok "its pane is not the shell asctl-wrap left: not started" || bad "its pane is not the shell asctl-wrap left: not started" "pane pid: $(ended)"
printf '143 %s %s %s\n' "$(date +%s)" "$bootid" "$ppid_" > "$SD/exit/$idw"; seed; bump; tm copy-mode -t "=wat2-$idw:"; sleep 1.1; watch
ended | seen 'copy mode' && ok "its pane scrolled back: not started" || bad "its pane scrolled back: not started" "copy mode: $(ended)"
tm send-keys -t "=wat2-$idw:" -X cancel
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import cli, tmuxctl, registry
e = registry.find(registry.load(), sys.argv[2]); p = tmuxctl.panes(e["tmux"])[0]
tmuxctl.client_activity = lambda s: [int(time.time()) - 5]
assert "typed" in cli.pane_free(e, p["pane_id"], p["pane_pid"])
tmuxctl.client_activity = lambda s: None
assert "clients" in cli.pane_free(e, p["pane_id"], p["pane_pid"])
tmuxctl.client_activity = lambda s: [int(time.time()) - 500]
assert cli.pane_free(e, p["pane_id"], p["pane_pid"]) == ""' "$REPO" "$idw" && ok "someone typing in it (a recent key from a client): not started" || bad "someone typing in it (a recent key from a client): not started" "client activity check"
rm -f "$SD/exit/$idw"
# Odd values never crash a run nor pass for evidence.
python3 -I -c 'import sys, json; sys.path.insert(0, sys.argv[1]); from asc import registry
p = registry.state_dir() + "/watch.json"; d = json.load(open(p))
d["ended"][sys.argv[2]] = {"key": "x", "reason": "", "has": "yes"}; json.dump(d, open(p, "w"))
with registry.changing() as r: r["settings"] = ["on"]; r["entries"][sys.argv[2]]["rss_kb"] = "big"' "$REPO" "$idw"
f0=$(evn failed); watch; watch
[ "$(evn failed)" = "$f0" ] && ok "odd watch.json, settings and rss_kb: no crash, no failed events" || bad "odd watch.json, settings and rss_kb: no crash, no failed events" "odd values: $(last failed)"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import watch, events, registry
def boom(*a): raise RuntimeError("boom")
watch.cli.live_in = boom
st = watch._state(registry.state_dir()); n = len(registry.load()["entries"])
c = lambda: sum(1 for r in events.read(limit=10000) if r["kind"] == "failed" and r["text"] == "watch: RuntimeError: boom")
c0 = c(); watch._run(st); c1 = c(); watch._run(st); c2 = c()
assert c1 - c0 == n and c2 == c1, (n, c0, c1, c2)
watch.cli.live_in = lambda *a: None; watch._run(st)
assert not st["failed"], st["failed"]' "$REPO" && ok "an error with one entry: logged once while it lasts, the others go on" || bad "an error with one entry: logged once while it lasts, the others go on" "failed dedupe"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as r: r["settings"] = {"auto_restart": True}; r["entries"][sys.argv[2]]["rss_kb"] = 400000' "$REPO" "$idw"
# A restart keeps the session (the dead pane runs claude again), so whoever is attached stays.
printf '%s\n' "$T/moved" >> "$HOME/fake-trusted"
asctl off "$idw" --force >/dev/null; asctl on "$idw" >/dev/null
pw=$(claude_in "wat2-$idw") && ok "restart in place: claude up after on" || bad "restart in place: claude up after on" "no claude in wat2-$idw"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
born=$(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}')
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; watch
pn=$(claude_in "wat2-$idw") && [ "$(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}')" = "$born" ] \
	&& ok "restart in place: the same session and pane" || bad "restart in place: the same session and pane" "restart in place: $born vs $(tm display -p -t "=wat2-$idw:" '#{session_created} #{pane_id}') / $(ended) / $(last waiting) / $(last failed)"
pw=$pn
# Each check On makes still holds, and a refusal stamps nothing (it is tried again next run).
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump; mv "$T/moved" "$T/moved.x"; watch
last waiting | jq -r .text | seen "folder $T/moved does not exist" && tm has-session -t "=wat2-$idw" && [ "$(jq ".entries[\"$idw\"].auto_restarted" "$REG")" = 1 ] \
	&& ok "On refuses (folder gone): its session kept, nothing stamped, said once" || bad "On refuses (folder gone): its session kept, nothing stamped, said once" "folder gone: $(last waiting) / $(jq ".entries[\"$idw\"].auto_restarted" "$REG")"
mv "$T/moved.x" "$T/moved"
tm split-window -t "=wat2-$idw:" -- sleep 300; seed; watch
last waiting | jq -r .text | seen 'has 2 panes' && ok "a session of 2 panes: not started again" || bad "a session of 2 panes: not started again" "2 panes: $(last waiting)"
tm kill-pane -t "$(tm list-panes -t "=wat2-$idw:" -F '#{pane_id} #{pane_current_command}' | awk '$2 == "sleep" {print $1}')"
asctl off "$idw" --force >/dev/null; asctl auto-restart off >/dev/null
}

case_watcher_others() {
# Setup: as watcher_reasons leaves its favorite: ended by a signal (an exit record), its end seen
# by the watcher but not started again (its folder gone, then a second pane; both undone), its
# folder trusted, its last restart long ago.
ended_setup eeeeeeee-0000-4000-8000-0000000000d2 eeeeeeee-0000-4000-8000-0000000000d3
ended_as_before 1
printf '%s\n' "$T/moved" >> "$HOME/fake-trusted"
bump; watch; kill -TERM "$pw"; sleep 1.2; bump; mv "$T/moved" "$T/moved.x"; watch
mv "$T/moved.x" "$T/moved"
tm split-window -t "=wat2-$idw:" -- sleep 300; seed; watch
last waiting | jq -r .text | seen 'has 2 panes' || stop "its end seen, not started again: a second pane"
tm kill-pane -t "$(tm list-panes -t "=wat2-$idw:" -F '#{pane_id} #{pane_current_command}' | awk '$2 == "sleep" {print $1}')"
echo "== watcher: said once, an action's lock, a claude started by hand, a second claude, broken files"
w1=$(evn waiting); mem 32000000 4800000; watch; mem 32000000 4700000; watch
[ "$(evn waiting)" = $((w1 + 1)) ] && ok "waiting: the same reason with other numbers is said once" || bad "waiting: the same reason with other numbers is said once" "waiting repeats: $w1 -> $(evn waiting)"
mem 32000000 16000000
# Its lock held by an action: the watcher leaves it to the next run.
flock "$SD/locks/$idw" sleep 3 & fl=$!; sleep 0.3; seed; watch
claude_now "wat2-$idw" >/dev/null 2>&1 && bad "an entry an action holds: left alone" "started while an action held it" || ok "an entry an action holds: left alone"
wait $fl; seed; watch; pw=$(claude_in "wat2-$idw") && ok "and started once the action is done" || bad "and started once the action is done" "not started after the lock: $(last waiting)"
# A claude started by hand in the pane after an end: that end is never acted on again.
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = 1' "$REPO" "$idw"
seed; bump; watch; kill -TERM "$pw"; sleep 1.2; bump
python3 -I -c 'import sys, time; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["auto_restarted"] = int(time.time())' "$REPO" "$idw"
watch; sleep 1.1; tm send-keys -t "=wat2-$idw:" "exec $ASC_CLAUDE --resume $WS2 --name wat2-$idw" Enter
ph=$(claude_in "wat2-$idw") && ok "a claude started by hand in its pane: up" || bad "a claude started by hand in its pane: up" "no claude in wat2-$idw"
watch
[ ! -e "$SD/exit/$idw" ] && ok "a claude started by hand after the end: the old exit record dropped" || bad "a claude started by hand after the end: the old exit record dropped" "stale exit record kept: $(cat "$SD/exit/$idw")"
# A second claude in its session: nothing there is sure to be about it (no rename typed).
touch "$HOME/fake-busy"; flagged; asctl rename "$idw" wat3 >/dev/null; rm -f "$HOME/fake-busy"
[ "$(jq -r ".entries[\"$idw\"].rename_pending" "$REG")" = "wat3-$idw" ] && ok "a rename while claude works: kept pending" || bad "a rename while claude works: kept pending" "rename not pending: $(jq -r .name "$HOME/.claude/sessions/$ph.json")"
cw=$(jq -r ".entries[\"$idw\"].cwd" "$REG")
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["cwd"] = sys.argv[3]' "$REPO" "$idw" "$HOME"
tm new-window -t "=wat3-$idw:" -c "$W" -- "$ASC_CLAUDE" --session-id eeeeeeee-0000-4000-8000-00000000000c
poll 5 live_has eeeeeeee-0000-4000-8000-00000000000c && ok "live: a second claude in its session" || bad "live: a second claude in its session" "not listed: $(asctl live)"
watch
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$HOME" ] && ok "a second claude in the session: its folder not followed" || bad "a second claude in the session: its folder not followed" "followed with two claudes there: $(last followed)"
[ "$(jq -r .name "$HOME/.claude/sessions/$ph.json")" = "wat2-$idw" ] && ok "a second claude in the session: no rename typed" || bad "a second claude in the session: no rename typed" "renamed with two claudes there: $(last rename) / $(asctl live) / $(tm list-panes -s -t "=wat3-$idw:" -F '#{window_index} #{pane_id} #{pane_pid} #{pane_current_command} #{pane_dead}') / $(tm capture-pane -p -t "=wat3-$idw:1" | head -5)"
tm kill-window -t "=wat3-$idw:1"; sleep 0.5; watch
[ "$(jq -r .name "$HOME/.claude/sessions/$ph.json")" = "wat3-$idw" ] && ok "alone again: the pending rename sent" || bad "alone again: the pending rename sent" "pending rename after: $(jq -r .name "$HOME/.claude/sessions/$ph.json")"
[ "$(jq -r ".entries[\"$idw\"].cwd" "$REG")" = "$cw" ] && ok "and its folder followed again" || bad "and its folder followed again" "folder after: $(jq -r ".entries[\"$idw\"].cwd" "$REG") (want $cw)"
# Broken state files: the run goes on, from scratch.
echo '{"ended": [], "rename_tries": {"x": "y"}, "dups": 5}' > "$SD/watch.json"
python3 -c 'import json, sys, time; print(json.dumps([{"t": int(time.time()) - 30, "boot": "", "avail_pct": 50, "oom_kill": "3"}, {"t": "x"}, 7]))' > "$SD/memory.json"
watch && jq -e '.ended | type == "object"' "$SD/watch.json" >/dev/null && jq -e 'all(.[]; (.oom_kill | type) != "string")' "$SD/memory.json" >/dev/null \
	&& ok "broken watch.json and memory.json: the run goes on, odd samples dropped" || bad "broken watch.json and memory.json: the run goes on, odd samples dropped" "broken state: $(cat "$SD/watch.json")"
tm kill-session -t "=wat3-$idw"; idw_t=wat3
asctl off "$idw" --force >/dev/null; watch
claude_now "wat3-$idw" >/dev/null 2>&1 && bad "off: the watcher leaves it off" "off, and started anyway" || ok "off: the watcher leaves it off"
[ "$(jq -r ".entries[\"$idw\"].want_on" "$REG")" = false ] && ok "want_on only changed by off" || bad "want_on only changed by off" "want_on changed"
asctl auto-restart off >/dev/null
}

# shellcheck disable=SC2329  # helpers run only through poll
case_boot() {
# Setup, as the watcher tests left it: the tmux server up, not started by the unit (nothing has
# called systemctl yet); a favorite (idw) named wat3, off, its size known; and two other favorites
# for boot to leave alone ("boot: 1 started", "not started: resurrect on but off, on but
# resurrect off").
server_up
B1=bbbbbbbb-0000-4000-8000-000000000001 B2=bbbbbbbb-0000-4000-8000-000000000002 B3=bbbbbbbb-0000-4000-8000-000000000003
mkdir -p "$HOME/.claude/projects/-boot"
for x in "$B1" "$B2" "$B3"; do printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$W" "$x" > "$HOME/.claude/projects/-boot/$x.jsonl"; done
asctl fav "$B1" --name wat3 >/dev/null || stop "boot's favorite"
asctl fav "$B2" --name bootx >/dev/null || stop "a favorite boot leaves alone"
asctl fav "$B3" --name booty >/dev/null || stop "another favorite boot leaves alone"
idw=$(jq -r --arg s "$B1" '.entries[] | select(.session_id == $s) | .id4' "$REG")
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["rss_kb"] = 400000' "$REPO" "$idw" || stop "boot's favorite's size"
echo "== the tmux server unit, and boot"
SC="$HOME/systemctl.log"
asctl tmux-server | seen 'already runs' && [ ! -e "$SC" ] && ok "tmux-server with a server up: left as it is" || bad "tmux-server with a server up: left as it is" "tmux-server with a server up: $(asctl tmux-server 2>&1)"
# Before the reboot: idw on, resurrect on, rc off (a resurrect start still has rc); of the others,
# one with resurrect on that was off, the rest on with resurrect off.
asctl resurrect "$idw" on >/dev/null; asctl rc "$idw" off --next-start >/dev/null; asctl on "$idw" >/dev/null
claude_in "wat3-$idw" >/dev/null && ok "on before the reboot" || bad "on before the reboot" "no claude in wat3-$idw"
[ ! -e "$SC" ] && ok "on with a server up: asctl-tmux.service not started" || bad "on with a server up: asctl-tmux.service not started" "systemctl called: $(cat "$SC")"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d:
    others = sorted(i for i in d["entries"] if i != sys.argv[2])
    for n, i in enumerate(others):
        d["entries"][i].update(resurrect=n == 0, want_on=n != 0)' "$REPO" "$idw"
others=$(jq -r --arg w "$idw" '[.entries[] | select(.id4 != $w) | .tmux] | join(" ")' "$REG")
tmux_up() { tm display -p x >/dev/null 2>&1; }
tm kill-server; poll_gone 5 tmux_up || stop "the test tmux server ended"
touch "$HOME/fake-systemctl-fail"
errof on "$idw" | seen 'asctl-tmux.service did not start one: .*not found' && ! tm display -p x >/dev/null 2>&1 \
	&& ok "on, no server and no unit: refused, no server started by asctl itself" || bad "on, no server and no unit: refused, no server started by asctl itself" "on with no unit: $(errof on "$idw")"
rm -f "$HOME/fake-systemctl-fail"
# A port that takes connections (claude.ai, for boot) and one that refuses them.
python3 -c 'import socket, time
a, b = socket.socket(), socket.socket(); a.bind(("127.0.0.1", 0)); a.listen(8); b.bind(("127.0.0.1", 0))
print(a.getsockname()[1], b.getsockname()[1], flush=True); time.sleep(300)' > "$T/ports" & lp=$!
poll 5 [ -s "$T/ports" ] || stop "the test's two ports open"
read -r up_port shut_port < "$T/ports"
boot() { ASC_BY=boot asctl boot "$@"; }
# Its lock held by an action: boot waits (here 0 s), then leaves it.
: > "$SC"; flock "$SD/locks/$idw" sleep 3 & fl=$!; sleep 0.3; seed
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
grep -qx -- '--user start asctl-tmux.service' "$SC" && [ "$(tm show -gv exit-empty)" = off ] \
	&& ok "boot, no server: asctl-tmux.service started (exit-empty off)" || bad "boot, no server: asctl-tmux.service started (exit-empty off)" "server at boot: $(cat "$SC")"
[ "$rc" = 1 ] && last waiting | seen 'not started yet: .*being started or stopped' && last refused | seen 'boot: not started in 0 s' \
	&& ok "boot: an entry an action holds waits, then is left (refused)" || bad "boot: an entry an action holds waits, then is left (refused)" "boot, lock held: rc $rc $(last waiting) $(last refused)"
wait $fl
mem 32000000 4000000; seed
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && last waiting | seen 'boot: not started yet: memory' && ! claude_now "wat3-$idw" >/dev/null 2>&1 \
	&& ok "boot, memory short: waits, then left" || bad "boot, memory short: waits, then left" "boot, memory: rc $rc $(last waiting)"
mem 32000000 16000000; rm -f "$SD/memory.json"
ASC_NET=127.0.0.1:$up_port boot --wait 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && last waiting | seen 'boot: not started yet: memory: watched for under 5 min' && ! claude_now "wat3-$idw" >/dev/null 2>&1 \
	&& ok "boot, memory fine but not watched 5 min: waits" || bad "boot, memory fine but not watched 5 min: waits" "boot, steady: rc $rc $(last waiting)"
# Resurrect turned off while boot waits: left, with nothing said.
seed; flock "$SD/locks/$idw" sleep 1.5 & fl=$!; sleep 0.3
(ASC_NET=127.0.0.1:$up_port boot --wait 4 > "$T/boot.out" 2>&1; echo $? >> "$T/boot.out") & bp=$!; sleep 0.7
jq -e --arg i "$idw" '.done == false and .todo == [$i] and (.why | test("being started or stopped"))' "$SD/boot.json" >/dev/null \
	&& ! flock -n "$SD/boot.lock" true && [ "$(stat -c %a "$SD/boot.json")" = 600 ] \
	&& ok "boot.json while boot runs (its lock held): what it still brings back, and why it waits (0600)" || bad "boot.json while boot runs (its lock held): what it still brings back, and why it waits (0600)" "boot.json mid-boot: $(cat "$SD/boot.json")"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import registry
with registry.changing() as d: d["entries"][sys.argv[2]]["resurrect"] = False' "$REPO" "$idw"
wait $fl $bp
jq -e '.done == true and .todo == []' "$SD/boot.json" >/dev/null && ok "boot.json once boot ends: done" || bad "boot.json once boot ends: done" "boot.json after: $(cat "$SD/boot.json")"
python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); from asc import boot, registry
boot._status([sys.argv[2], "9999"], "x")
assert json.load(open(registry.state_dir() + "/boot.json"))["todo"] == [], "kept"' "$REPO" "$idw" \
	&& ok "boot.json leaves out a favorite turned off, resurrect off or forgotten since" || bad "boot.json leaves out a favorite turned off, resurrect off or forgotten since" "boot.json kept one no longer wanted"
seen -x 'boot: 0 started' "$T/boot.out" && seen -x 0 "$T/boot.out" && ! claude_now "wat3-$idw" >/dev/null 2>&1 \
	&& ok "resurrect off while boot waits: left" || bad "resurrect off while boot waits: left" "resurrect off mid-boot: $(cat "$T/boot.out")"
asctl resurrect "$idw" on >/dev/null; asctl rc "$idw" off --next-start >/dev/null
# Stopped while it waits (memory short): a SIGTERM ends it as an exit, so boot.json says done.
mem 32000000 4000000; seed; rm -f "$SD/boot.json"
ASC_BY=boot ASC_NET=127.0.0.1:$up_port "$REPO/bin/asctl" boot --wait 60 >/dev/null 2>&1 & bp=$!
boot_waits() { jq -e '.done == false and (.why | startswith("memory"))' "$SD/boot.json" >/dev/null 2>&1; }
poll 5 boot_waits && ok "boot, memory short: boot.json says it waits for memory" || bad "boot, memory short: boot.json says it waits for memory" "boot.json: $(cat "$SD/boot.json" 2>&1)"
kill -TERM "$bp"; wait "$bp"; rc=$?
[ "$rc" = 143 ] && jq -e '.done == true' "$SD/boot.json" >/dev/null && ok "boot stopped (SIGTERM): exit 143, boot.json done" || bad "boot stopped (SIGTERM): exit 143, boot.json done" "boot stopped: rc $rc $(cat "$SD/boot.json")"
mem 32000000 16000000
mem 32000000 16000000; seed; nw=$(jq -s '[.[] | select((.text // "") | test("did not answer"))] | length' "$SD/events.jsonl")
flock "$SD/boot.lock" sleep 2 & fl=$!; sleep 0.3
errof boot | seen 'another asctl boot is running' && ok "one boot at a time" || bad "one boot at a time" "two boots: $(errof boot)"
wait $fl
t0=$(date +%s); out=$(ASC_NET=127.0.0.1:$up_port boot --net-wait 30 --wait 60 2>&1); rc=$?
[ "$rc" = 0 ] && seen -x "boot: 1 started (wat3-$idw)" <<<"$out" && claude_in "wat3-$idw" >/dev/null \
	&& ok "boot: the favorite with resurrect on that was on is started" || bad "boot: the favorite with resurrect on that was on is started" "boot: rc $rc $out"
lastargs | seen -- "--resume .*--remote-control wat3-$idw" && ok "with rc (resurrect), rc being off" || bad "with rc (resurrect), rc being off" "boot args: $(lastargs)"
last on | seen '"by":"boot"' && ok "logged as boot's" || bad "logged as boot's" "on event: $(last on)"
[ "$(jq -s '[.[] | select((.text // "") | test("did not answer"))] | length' "$SD/events.jsonl")" = "$nw" ] && [ $(( $(date +%s) - t0 )) -lt 25 ] \
	&& ok "claude.ai answering: no wait" || bad "claude.ai answering: no wait" "net wait with the port up: $(( $(date +%s) - t0 )) s"
n=0; for o in $others; do tm has-session -t "=$o" 2>/dev/null && n=$((n + 1)); done
[ "$n" = 0 ] && ok "not started: resurrect on but off, on but resurrect off" || bad "not started: resurrect on but off, on but resurrect off" "boot started others: $(tm ls)"
non=$(evn on) nref=$(evn refused); out=$(ASC_NET=127.0.0.1:$up_port boot --net-wait 0 2>&1)
seen "wat3-$idw: its tmux session is up already" <<<"$out" && [ "$(evn on)" = "$non" ] && [ "$(evn refused)" = "$nref" ] \
	&& ok "boot again: a session up already is left as it is" || bad "boot again: a session up already is left as it is" "boot, up already: $out"
tm kill-session -t "=wat3-$idw"; sleep 0.5
out=$(ASC_NET=127.0.0.1:$shut_port boot --net-wait 1 --wait 60 2>&1)
last waiting | seen "127.0.0.1:$shut_port did not answer in 1 s; starting anyway" && [ "$(evn on)" = $((non + 1)) ] \
	&& ok "claude.ai not answering: started anyway after the wait" || bad "claude.ai not answering: started anyway after the wait" "net down: $out $(last waiting)"
kill "$lp" 2>/dev/null
}

case_asctl_setup() {
# Setup: a tmux server up (the section turns continuum on in it).
server_up
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
	&& ok "setup, units not installed: refused, nothing changed" || bad "setup, units not installed: refused, nothing changed" "setup, no units: rc $rc $out"
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
	&& ok "setup, an old tmux-claude-restore install: refused (its manifest)" || bad "setup, an old tmux-claude-restore install: refused (its manifest)" "setup, old manifest: rc $rc $out"
rm -r "$H2/.local/state/tmux-claude-restore"
printf '%s\n' "set -g mouse on" "# >>> tmux-claude-restore >>> (managed by /old/tcr/install.sh; edits here are overwritten)" "# <<< tmux-claude-restore <<<" > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "its block in $H2/.tmux.conf (installed by /old/tcr/install.sh)" <<<"$out" \
	&& ok "setup, its block in the tmux config: refused, its installer named" || bad "setup, its block in the tmux config: refused, its installer named" "setup, old block: rc $rc $out"
printf '%s\n' "set -g mouse on" "# set -g @continuum-restore 'on'" "set -g @continuum-restore 'off'" "set -g @continuum-boot \"on\"  # at boot" > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.tmux.conf:4: @continuum-boot 'on'" <<<"$out" && ! seen ":2: @continuum" <<<"$out" && ! seen ":3: @continuum" <<<"$out" \
	&& ok "setup, continuum's boot on in the config: refused, the line named (a comment and 'off' are not)" || bad "setup, continuum's boot on in the config: refused, the line named (a comment and 'off' are not)" "setup, continuum config: rc $rc $out"
printf '%s\n' "source-file -q ~/.tmux.conf.local" > "$H2/.tmux.conf"; printf '%s\n' "set -g @continuum-restore 'on'" > "$H2/.tmux.conf.local"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.tmux.conf.local:1: @continuum-restore 'on'" <<<"$out" \
	&& ok "setup, continuum's restore on in a file the config sources (source-file -q ~/…): refused" || bad "setup, continuum's restore on in a file the config sources (source-file -q ~/…): refused" "setup, sourced continuum: rc $rc $out"
rm "$H2/.tmux.conf.local"
mkdir -p "$H2/.config/tmux"; printf '%s\n' "set-option -gq @continuum-restore on" > "$H2/.config/tmux/tmux.conf"; : > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "$H2/.config/tmux/tmux.conf:1: @continuum-restore 'on'" <<<"$out" \
	&& ok "setup, continuum's restore on in the XDG config (set-option -gq): refused" || bad "setup, continuum's restore on in the XDG config (set-option -gq): refused" "setup, XDG continuum: rc $rc $out"
rm -r "$H2/.config/tmux"; tm set -g @continuum-restore on
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "still on in the running tmux server (@continuum-restore on): your tmux config no longer turns it on" <<<"$out" \
	&& seen "  tmux -L $ASC_TMUX_SOCKET set -g @continuum-restore off" <<<"$out" && ! seen "@continuum-boot" <<<"$out" \
	&& ok "setup, continuum's restore on only in the running server: refused, the tmux command that turns it off named" \
	|| bad "setup, continuum's restore on only in the running server: refused, the tmux command that turns it off named" "setup, server continuum: rc $rc $out"
printf '%s\n' "set -g @continuum-boot on" > "$H2/.tmux.conf"
out=$(su2 --yes); rc=$?
: > "$H2/.tmux.conf"; tm set -gu @continuum-restore
[ "$rc" = 1 ] && seen "$H2/.tmux.conf:1: @continuum-boot 'on'; the running tmux server: @continuum-restore on): set" <<<"$out" \
	&& ! seen "still on in the running" <<<"$out" \
	&& ok "setup, continuum on in the config and the server: the config first" || bad "setup, continuum on in the config and the server: the config first" "setup, config and server continuum: rc $rc $out"
touch "$F2/fail-show-environment"; out=$(su2 --yes); rc=$?; rm "$F2/fail-show-environment"
[ "$rc" = 1 ] && seen "cannot reach your systemd user manager (systemctl --user: Failed to connect to bus" <<<"$out" && en tmux.service \
	&& ok "setup, the user manager not answering: refused as that (not as units missing)" || bad "setup, the user manager not answering: refused as that (not as units missing)" "setup, no manager: rc $rc $out"
out=$(su2 </dev/null); rc=$?
[ "$rc" = 1 ] && seen "disable tmux.service, which runs tmux" <<<"$out" && seen "enable asctl-tmux.service, asctl-boot.service, asctl-watch.timer, asctl-dash.socket" <<<"$out" \
	&& seen "run asctl setup --yes to do it" <<<"$out" && en tmux.service && ! en asctl-tmux.service && ! [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] \
	&& ok "setup, no terminal and no --yes: shows the plan, changes nothing" || bad "setup, no terminal and no --yes: shows the plan, changes nothing" "setup, no --yes: rc $rc $out"
out=$(su2 --yes); rc=$?
dropin_ok() { cmp -s "$SUD/tmux-spawn-.scope.d/asctl.conf" "$REPO/systemd/tmux-spawn-.scope.d/asctl.conf" && [ "$(stat -c %a "$SUD/tmux-spawn-.scope.d/asctl.conf")" = 644 ]; }
[ "$rc" = 0 ] && ! en tmux.service && ! en envtmux.service && ! en shtmux.service && ! en $IM && en web.service && en asctl-old.service && en notmux.service && dropin_ok \
	&& en asctl-tmux.service && en asctl-boot.service && en asctl-watch.timer && en asctl-dash.socket \
	&& [ -e "$F2/active/asctl-watch.timer" ] && [ -e "$F2/active/asctl-dash.socket" ] && ! [ -e "$F2/active/asctl-tmux.service" ] \
	&& ok "setup --yes: the drop-in, the units that run tmux disabled (through env, sh -c, a template's instance; others left), asctl's units on, timer and socket started" || bad "setup --yes: the drop-in, the units that run tmux disabled (through env, sh -c, a template's instance; others left), asctl's units on, timer and socket started" "setup --yes: rc $rc $out"
[ "$(jq -c .disabled "$SJ")" = "$ALL" ] && [ "$(stat -c %a "$SJ")" = 600 ] \
	&& ok "what it disabled is recorded (setup.json, 0600)" || bad "what it disabled is recorded (setup.json, 0600)" "  setup.json: $(cat "$SJ" 2>&1)"
seen "note: linger is off" <<<"$out" && seen "note: the dashboard has no config yet: $H2/.config/agent-session-control/dash.json" <<<"$out" \
	&& ok "notes: linger off, no dashboard config" || bad "notes: linger off, no dashboard config" "  notes: $out"
jq -s -e 'last | .kind == "setup" and .by == "cli" and (.text | test("disabled tmux.service"))' "$H2/.local/state/agent-session-control/events.jsonl" >/dev/null \
	&& ok "logged (kind setup)" || bad "logged (kind setup)" "  setup event: $(tail -1 "$H2/.local/state/agent-session-control/events.jsonl")"
n=$(calls 'enable|disable|start'); : > "$T/linger/$(id -un)"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl is set up already: nothing to do" <<<"$out" && [ "$(calls 'enable|disable|start')" = "$n" ] && ! seen "linger" <<<"$out" \
	&& ok "setup again: nothing to do, nothing called (and no linger note with linger on)" || bad "setup again: nothing to do, nothing called (and no linger note with linger on)" "setup again: rc $rc $out"
echo "# mine" >> "$SUD/tmux-spawn-.scope.d/asctl.conf"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl.conf is not the one asctl ships: left as it is" <<<"$out" && tail -1 "$SUD/tmux-spawn-.scope.d/asctl.conf" | seen -x "# mine" \
	&& ok "setup, a changed drop-in: left as it is, said so" || bad "setup, a changed drop-in: left as it is, said so" "setup, changed drop-in: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && ! en asctl-tmux.service && ! en asctl-boot.service && ! en asctl-watch.timer && ! en asctl-dash.socket && ! [ -e "$F2/active/asctl-watch.timer" ] \
	&& en tmux.service && en envtmux.service && en $IM && [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] && ! [ -e "$SJ" ] && seen "is not the one asctl ships: left as it is" <<<"$out" \
	&& ok "setup --remove: asctl's units off, tmux.service enabled again, a changed drop-in left" || bad "setup --remove: asctl's units off, tmux.service enabled again, a changed drop-in left" "setup --remove: rc $rc $out"
! seen "^--user stop.*asctl-tmux.service" "$H2/systemctl.log" && ok "the tmux server unit never stopped" || bad "the tmux server unit never stopped" "  asctl-tmux.service was stopped"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && seen "asctl is not set up: nothing to do" <<<"$out" && ok "setup --remove again: nothing to do" || bad "setup --remove again: nothing to do" "remove again: rc $rc $out"
rm "$SUD/tmux-spawn-.scope.d/asctl.conf"; : > "$F2/fail-enable-asctl-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "setup stopped part way (wrote .*; disabled $IM): systemctl --user enable" <<<"$out" && ! en tmux.service && [ "$(jq -c .disabled "$SJ")" = "$ALL" ] \
	&& jq -s -e 'last | .kind == "failed"' "$H2/.local/state/agent-session-control/events.jsonl" >/dev/null \
	&& ok "setup failing part way: says what it did, logged failed, the disabled unit recorded" || bad "setup failing part way: says what it did, logged failed, the disabled unit recorded" "setup part way: rc $rc $out"
rm "$F2/fail-enable-asctl-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 0 ] && en asctl-tmux.service && ! seen "disable tmux.service" <<<"$out" && ok "setup again finishes it" || bad "setup again finishes it" "  setup again: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && en tmux.service && ! [ -e "$SUD/tmux-spawn-.scope.d/asctl.conf" ] && ! [ -e "$SJ" ] \
	&& ok "then --remove: tmux.service enabled again, the unchanged drop-in removed" || bad "then --remove: tmux.service enabled again, the unchanged drop-in removed" "  remove after: rc $rc $out"
: > "$F2/fail-disable-tmux.service"
out=$(su2 --yes); rc=$?; rm "$F2/fail-disable-tmux.service"
[ "$rc" = 1 ] && seen "disabled envtmux.service; disabled shtmux.service): systemctl --user disable tmux.service" <<<"$out" && ! en envtmux.service && en tmux.service \
	&& [ "$(jq -c .disabled "$SJ")" = "$ALL" ] \
	&& ok "setup, a disable failing part way: the ones before it recorded as disabled" || bad "setup, a disable failing part way: the ones before it recorded as disabled" "setup, disable part way: rc $rc $out"
out=$(su2 --remove --yes); rc=$?
[ "$rc" = 0 ] && en envtmux.service && en shtmux.service && en tmux.service && ! [ -e "$SJ" ] \
	&& ok "--remove after it: those enabled again" || bad "--remove after it: those enabled again" "  remove after part way: rc $rc $out"
: > "$F2/global-tmux.service"
out=$(su2 --yes); rc=$?
[ "$rc" = 1 ] && seen "tmux.service is still enabled (enabled for every user?" <<<"$out" && ! en asctl-tmux.service \
	&& [ "$(jq '.disabled | index("tmux.service")' "$SJ")" = null ] && jq -e '.disabled | index("envtmux.service")' "$SJ" >/dev/null \
	&& ok "setup, a tmux unit a disable does not turn off: stops, says why, and does not record it" || bad "setup, a tmux unit a disable does not turn off: stops, says why, and does not record it" "setup, global unit: rc $rc $out $(cat "$SJ")"
rm "$F2/global-tmux.service"
ud() { HOME="$H2" XDG_CONFIG_HOME="$1" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from asc import setup; print(setup.unit_dir())' "$REPO"; }
[ "$(ud "$T/shellcfg")" = "$H2/.config/systemd/user" ] && echo "XDG_CONFIG_HOME=$H2/mgrcfg" > "$F2/environment" && [ "$(ud "$T/shellcfg")" = "$H2/mgrcfg/systemd/user" ] \
	&& ok "the unit folder follows the manager's XDG_CONFIG_HOME, not the shell's" || bad "the unit folder follows the manager's XDG_CONFIG_HOME, not the shell's" "unit_dir: $(ud "$T/shellcfg")"
rm "$F2/environment"
}

run_cases asc no_tmux_server main shared_stale guards on_gates rc_now rc_menu events rc_slow rc_slow_seen rc_slow_typed new_name restart_name outside outside_hold outside_bg watcher_memory watcher_follow watcher_ended watcher_reasons watcher_others boot asctl_setup

echo "asc: $pass passed, $fail failed"
[ "$fail" = 0 ]
