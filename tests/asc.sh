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
export HOME="$T/home" XDG_STATE_HOME="" SHELL=/bin/bash
unset TMUX
mkdir -p "$HOME" "$T/fakebash"
cp "$(command -v bash)" "$T/fakebash/claude"
export FAKE_BASH="$T/fakebash/claude"
# Memory as asctl sees it (asc/memory.py): plenty, unless a test says otherwise.
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' "$1" "$2" > "$T/meminfo"; }
export ASC_MEMINFO="$T/meminfo"
mem 32000000 16000000
tm() { tmux -L "$ASC_TMUX_SOCKET" -f /dev/null "$@"; }
cleanup() { tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
asctl() { "$REPO/bin/asctl" "$@"; }
# What asctl writes to stderr (its exit status is checked separately, if at all).
errof() { { "$REPO/bin/asctl" "$@" >/dev/null; } 2>&1; true; }
REG="$HOME/.local/state/agent-session-control/registry.json"
jqe() { jq -r "$1" "$REG"; }
# grep that reads all its input: grep -q stops at the first match, and the writer's broken
# pipe would then fail the pipeline (pipefail), taking the wrong branch of a check.
seen() { grep "$@" >/dev/null; }
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
kill -0 "$pid" 2>/dev/null && bad "claude still runs after off" || ok "claude ended"
[ "$(jqe ".entries[\"$id\"].want_on")" = false ] && ok "want_on false after off" || bad "want_on not false after off"
asctl list | seen "^$id .* off " && ok "list: off" || bad "list: not off"

echo "== on"
asctl on "$id" >/dev/null && ok "on" || bad "on failed"
pid=$(claude_in "das-$id") && ok "claude up in das-$id" || bad "no claude in das-$id"
tail -1 "$HOME/claude-args.log" | grep -q -- "--resume $SID --name das-$id --permission-mode auto" && ok "started with --resume, --name and the mode" || bad "wrong args: $(tail -1 "$HOME/claude-args.log")"
[ "$(jqe ".entries[\"$id\"].want_on")" = true ] && ok "want_on true after on" || bad "want_on not true after on"
asctl on "$id" >/dev/null 2>&1 && bad "a second on accepted" || ok "a second on refused (session exists)"
tm rename-session -t "=das-$id" moved
asctl on "$id" >/dev/null 2>&1 && bad "on accepted while a live claude holds the id" || ok "on refused while a live claude holds the session id"
tm rename-session -t "=moved" "das-$id"

echo "== busy"
touch "$HOME/fake-busy"; sleep 0.6
errof off "$id" | grep -q 'busy: the claude in pane .* is working' && ok "off refused: claude busy" || bad "off not refused while busy"
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
tail -1 "$HOME/claude-args.log" | grep -q -- '--permission-mode bypassPermissions' && ok "mode skip starts with bypassPermissions" || bad "mode skip not passed"
asctl off "$id2" >/dev/null
asctl mode "$id2" sudo >/dev/null 2>&1 && bad "an unknown mode accepted" || ok "an unknown mode refused"

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
asctl on "$id7" >/dev/null && grep -qF "cwd=$W3 " "$HOME/claude-args.log" && ok "claude started in the literal folder (tmux formats not expanded)" || bad "the folder was expanded by tmux: $(tail -1 "$HOME/claude-args.log")"
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
asctl on "$id2" >/dev/null; tail -1 "$HOME/claude-args.log" | seen -- '--remote-control My chat' && ok "started with --remote-control and its title" || bad "rc not passed: $(tail -1 "$HOME/claude-args.log")"
asctl off "$id2" --force >/dev/null
asctl rc "$id2" off >/dev/null; asctl on "$id2" >/dev/null
tail -1 "$HOME/claude-args.log" | seen -- '--remote-control' && bad "rc off still passed --remote-control" || ok "rc off: no --remote-control"
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


# ASC_MUTANTS=1: break asctl one way at a time, in a copy; each must make this test fail.
if [ "${ASC_MUTANTS:-}" = 1 ]; then
	echo "== mutants"
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		f=${m%%' %%% '*}; rest=${m#*' %%% '}; old=${rest%%' %%% '*}; new=${rest#*' %%% '}
		d=$(mktemp -d -p "$T") || exit 2
		cp -r "$REPO/asc" "$REPO/bin" "$REPO/tests" "$d/"
		body=$(<"$d/$f")
		[[ $body == *"$old"* ]] || { bad "mutant does not apply: $f: $old"; continue; }
		printf '%s\n' "${body/"$old"/"$new"}" > "$d/$f"
		out=$(HOME="$REPO_HOME" ASC_MUTANTS='' bash "$d/tests/asc.sh" 2>&1)
		grep -q '  FAIL  ' <<<"$out" && ok "mutant caught: $f: $old" || bad "mutant missed: $f: $old"
	done <<'MUTANTS'
asc/live.py %%% and proc_start is not None and st[2] == str(proc_start) %%% 
asc/live.py %%% st is not None and st[0] == "claude" and %%% st is not None and
asc/live.py %%%                 if s["status"] == "busy": %%%                 if False:
asc/live.py %%%                     return f"pane {p['pane_id']} runs a claude asctl cannot read ({pid})" %%%                     continue
asc/live.py %%%             if name in WRAPPERS: %%%             if True:
asc/live.py %%%             if name == "claude": %%%             if False:
asc/live.py %%% base == str(pid) and %%% 
asc/live.py %%% (raw.get("pidDomain") is None or raw.get("pidDomain") == domain) %%% True
asc/live.py %%%         if (st and st[0] == "claude") or %%%         if False and
asc/cli.py %%%         if away: %%%         if False:
asc/cli.py %%%     return live_in(e, lv) or next( %%%     return live_in(e, lv) or None and next(
asc/cli.py %%%     return (any(l.endswith("No, exit") %%%     return True or (any(l.endswith("No, exit")
asc/tmuxctl.py %%%     return run("has-session", "-t", "=" + name) %%%     return run("has-session", "-t", name)
asc/tmuxctl.py %%% cwd.replace("#", "##") %%% cwd
asc/live.py %%%         if s["live"]: %%%         if s["ok"]:
asc/cli.py %%%             if owner: %%%             if False:
asc/cli.py %%%             if others and not whole: %%%             if False:
asc/cli.py %%%         if live_for(e): %%%         if False:
asc/cli.py %%%             if "❯ Yes, I trust this folder" not in screen: %%%             if False:
asc/cli.py %%% ["--resume", e["session_id"]] if e.get("started") else %%% ["--session-id", e["session_id"]] if e.get("started") else
asc/registry.py %%% fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB) %%% fcntl.LOCK_EX
asc/registry.py %%% MODES = {"auto": "auto", "manual": "manual", "skip": "bypassPermissions"} %%% MODES = {"auto": "auto", "manual": "manual", "skip": "auto"}
asc/registry.py %%%     except ValueError as e: %%%     except ZeroDivisionError as e:
bin/asctl-wrap %%% > "$f.tmp" && mv -f "$f.tmp" "$f" %%% > /dev/null
asc/memory.py %%%     if 100 * avail / total < START_PCT: %%%     if False:
asc/memory.py %%%     if left < LEAVE_PCT: %%%     if False:
asc/cli.py %%%         if not args.force_memory: %%%         if False:
asc/cli.py %%%             e["rc"] = True %%%             pass
asc/cli.py %%%  or (resurrect and e.get("resurrect")) %%%  or False
asc/registry.py %%%     if not t or t.startswith("-"): %%%     if not t:
MUTANTS
fi

echo "asc: $pass passed, $fail failed"
[ "$fail" = 0 ]
