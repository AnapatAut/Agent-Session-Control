#!/usr/bin/env bash
# tests/mutate.sh on toy repos of its own (run by tests/lint.sh, about 40 s): every verdict
# (CAUGHT in its case, CAUGHT only by the whole suite, SURVIVED, a FAIL elsewhere only, flaky once,
# a case run cut short, a check printed twice, a time limit, memory pressure and no more mutants
# started, an OOM kill, PSI gone, a kill seen only after the run ended, /tmp short of space,
# BROKEN at import), the suites' tmux folder in the work folder, every refusal (a bad list,
# ASC_ONLY, a run id or setting not its own, /tmp short of space or inodes, a baseline with a
# FAIL, a skip or a check not run, a second run), an interrupt in a
# mutant's run and in the baseline, and after each run: no process of it left (refused runs too),
# its work folder gone, and no toy suite's folder left (only its EXIT trap removes it: a suite cut short by a
# SIGKILL, or a second TERM, leaves it). A toy repo holds the real runner and its readers,
# a product (asc/prod.sh) and two small suites with cases; its pressure readings and lock are in a
# folder of its own (ASC_MUT_PROC), so this never reads or locks the machine's. The runs go 6 at a
# time, each in its own toy repo; their checks are printed in order at the end.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; }
T=$(mktemp -d) || exit 2
# stopped itself (a TERM, not a Ctrl-C to the whole process group): a TERM to each toy runner
# still going (its own folder of readings in its environment, its parent not), which ends its
# processes and folder, then the wait for them
stop_runners() {
	local f p q
	for f in $(grep -lzF "ASC_MUT_PROC=$T/" /proc/[0-9]*/environ 2>/dev/null); do
		p=${f#/proc/}; p=${p%/environ}; q=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
		[ -n "$q" ] && ! grep -qzF "ASC_MUT_PROC=$T/" "/proc/$q/environ" 2>/dev/null && kill -TERM "$p" 2>/dev/null
	done
	wait
}
trap 'stop_runners; rm -rf "$T"' EXIT
trap 'exit 130' INT TERM HUP
export HOME="$T/home"
mkdir "$HOME"

# The toy suites: asc has cases one (a is 1, b is 2) and two (no marker: a file case one's mark
# would leave), dash one case. They follow the real suites' rules (tests/checklint.py).
suite() {
	cat <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "$ASC_MUT_PROC/asc-toy-suite.XXXXXX") || exit 2
gone() { rm -rf "$T"; }
trap gone EXIT
pass=0 fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); [ "${TEST_STOP_AT-}" != "$1" ] || exit 1; }
skip() { echo "  skip  $1 ($2)"; }
stop() { echo "  FAIL  setup: $1"; exit 1; }
# shellcheck source=/dev/null
. "$REPO/asc/prod.sh"
# shellcheck source=/dev/null
. "$REPO/tests/cases.sh"
EOF
	if [ "$1" = asc ]; then
		cat <<'EOF'
case_one() {
	[ "$(a)" = 1 ] && ok "a is 1" || bad "a is 1"
	mark "$T"
	[ "$(b)" = 2 ] && ok "b is 2" || bad "b is 2"
	slow
}
case_two() {
	[ ! -e "$T/marker" ] && ok "no marker" || bad "no marker"
}
run_cases asc one two
EOF
	else
		cat <<'EOF'
case_only() {
	[ "$(b)" = 2 ] && ok "b is 2 here" || bad "b is 2 here"
}
run_cases dash only
EOF
	fi
	printf '%s\n' "echo \"$1: \$pass passed, \$fail failed\"" '[ "$fail" = 0 ]'
}
# toy <name>: a toy repo at $T/<name> with one mutant per list (each caught in its case).
toy() {
	local r=$T/$1
	mkdir -p "$r/asc" "$r/bin" "$r/tests/dash" "$r/proc"
	cp "$REPO"/tests/{mutate.sh,mutantlint.py,checklint.py,bashtree.py,mutjudge.py,cases.sh} "$r/tests/"
	: > "$r/tests/dash/page.js"
	printf '#!/bin/sh\n' > "$r/bin/asctl"; chmod +x "$r/bin/asctl"
	printf '%s\n' '#!/usr/bin/env bash' '# the toy product' 'a() { echo 1; }' 'b() { echo 2; }' 'mark() { :; }' 'slow() { :; }' > "$r/asc/prod.sh"
	suite asc > "$r/tests/asc.sh"
	suite dash > "$r/tests/dash.sh"
	printf '%s\n' 'asc/prod.sh %%% echo 1 %%% echo 9 %%% a is 1 %%% one' > "$r/tests/mutants-asc.txt"
	printf '%s\n' 'asc/prod.sh %%% echo 2 %%% echo 8 %%% b is 2 here %%% only' > "$r/tests/mutants-dash.txt"
	printf '%s\n' 'MemTotal: 1000000 kB' 'MemAvailable: 900000 kB' > "$r/proc/meminfo"
	echo "oom_kill 0" > "$r/proc/vmstat"
	echo "900000 900000" > "$r/proc/disk"
	mkdir "$r/proc/pressure"; psi_total "$r" 0
}
psi_total() { printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=%s\n' "$2" > "$1/proc/pressure/memory"; }
# run <name> [VAR=value...]: the runner in toy repo <name>, its files git-added now; the result
# after it starts it.
PENDING=() NV=0
run() {
	PENDING=("$@")
	(cd "$T/$1" && { git init -q 2>/dev/null; git add -A; }) || { PENDING=(); out="git add failed in $T/$1" rc=none left=''; }
}
# runner <name> [VAR=value...]: its output in $out, exit status in $rc, run id in $rid; then
# left: what of it is still there (none: empty)
runner() {
	local r=$T/$1; shift
	out=$(cd "$r" && env ASC_MUT_PROC="$r/proc" ASC_MUT_MINLIMIT=4 MUTANT_JOBS=2 "$@" bash tests/mutate.sh 2>&1)
	rc=$?
	rid=$(sed -n 's/^mutate: run \([0-9a-z-]*\),.*/\1/p' <<<"$out" | head -1)
	left_of "$rid" "$r/proc"
}
# left_of <rid> <toy proc folder>: what of the run is still there: its processes (by the run id in
# their environment), its folder, and a toy suite's own folder (removed once reported)
left_of() {
	left=$(find "$2" -maxdepth 1 -name 'asc-toy-suite.*' -printf ' %p')
	find "$2" -maxdepth 1 -name 'asc-toy-suite.*' -exec rm -rf {} +
	sleep 0.5
	left+=$(grep -lzxF "ASC_MUT_PROC=$2" /proc/[0-9]*/environ 2>/dev/null | tr '\n' ' ')
	[ -n "$1" ] || return 0
	left+=$(grep -lzxF "ASC_MUT_RUN=$1" /proc/[0-9]*/environ 2>/dev/null | tr '\n' ' ')
	[ ! -e "/tmp/asc-mut.$1" ] || left+=" /tmp/asc-mut.$1"
}
has() { grep -qF -- "$1" <<<"$out"; }
# result <name> <want rc> <text>...: the run's exit status, each text in its output, nothing left.
# The run before it, if one waits, in the background (at most 6 at a time); else the run just
# made here. Its check goes to a file of its own, $T/v.<n>.
result() {
	NV=$((NV + 1))
	if [ "${#PENDING[@]}" -gt 0 ]; then
		local p=("${PENDING[@]}")
		PENDING=()
		while [ "$(jobs -rp | wc -l)" -ge 6 ]; do wait -n; done
		( runner "${p[@]}"; judge "$@" ) > "$T/v.$NV" 2>&1 &
	else
		judge "$@" > "$T/v.$NV" 2>&1
	fi
}
judge() {
	local name=$1 want=$2 t why=''
	shift 2
	[ "$rc" = "$want" ] || why+="exit $rc, not $want; "
	for t; do has "$t" || why+="no \"$t\"; "; done
	[ -z "$left" ] || why+="left: $left; "
	[ -z "$why" ] && ok "$name" || bad "$name" "$why"$'\n'"$out"
}

toy caught; run caught
result "a mutant its check fails in its case, twice: CAUGHT, exit 0, its two runs' times" 0 "caught by: a is 1 (one)" "caught by: b is 2 here (only)" \
	"2 mutants: 2 caught (0 only by the whole suite)" "baseline asc: 3 checks, all ok" "        runs: " " s, "
toy caughtfull; run caughtfull MUTANTS_FULL=1
result "MUTANTS_FULL=1: every mutant on its whole suite" 0 "caught by: a is 1 (one, full)" "caught by: b is 2 here (only, full)"

toy full
printf '%s\n' 'asc/prod.sh %%% mark() { :; } %%% mark() { touch "$1/marker"; } %%% no marker %%% two' > "$T/full/tests/mutants-asc.txt"
run full
result "caught only when an earlier case runs first: CAUGHT by the whole suite" 0 "caught by: no marker (two, full)" "(1 only by the whole suite)"

toy surv
printf '%s\n' 'asc/prod.sh %%% # the toy product %%% # the toy product, changed %%% a is 1 %%% one' > "$T/surv/tests/mutants-asc.txt"
run surv
result "a change its check does not see: SURVIVED, exit 1" 1 "SURVIVED: a is 1 ok, the whole suite as its baseline" "1 survived"

toy else
printf '%s\n' 'asc/prod.sh %%% echo 2 %%% echo 7 %%% a is 1 %%% one' > "$T/else/tests/mutants-asc.txt"
run else
result "a FAIL of another check only: UNCLEAR, never CAUGHT" 1 "UNCLEAR: (full) a is 1 ok, a FAIL elsewhere: b is 2" "1 unclear"

toy flaky
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { if [ -e "$ASC_MUT_PROC/flaked" ]; then echo 1; else touch "$ASC_MUT_PROC/flaked"; echo 9; fi; } %%% a is 1 %%% one' > "$T/flaky/tests/mutants-asc.txt"
run flaky
result "a check that fails in its case once, then passes: UNCLEAR, never SURVIVED" 1 "UNCLEAR: flaky: a is 1 failed in its case once, then passed" "1 unclear"

toy cut
printf '%s\n' 'asc/prod.sh %%% mark() { :; } %%% mark() { [ -z "${ASC_ONLY-}" ] || stop "marked"; } %%% b is 2 %%% one' > "$T/cut/tests/mutants-asc.txt"
run cut
result "a case run cut short (a setup stop before its check), the whole suite as its baseline: UNCLEAR, never SURVIVED" 1 \
	"UNCLEAR: its case run cut short (b is 2 not reached); the whole suite as its baseline" "1 unclear"

toy import
printf 'X = 1\n' > "$T/import/asc/m.py"
printf '%s\n' 'asc/m.py %%% X = 1 %%% X = 1 / 0 %%% a is 1 %%% one' > "$T/import/tests/mutants-asc.txt"
run import
result "a mutant that makes its module fail at import (a catch that tests nothing): BROKEN" 1 "it fails at import: ZeroDivisionError" "1 broken"

toy tmuxdir
sed -i 's|^case_two() {$|case_two() {\n\t[[ $TMUX_TMPDIR == "$TMPDIR" \&\& $TMPDIR == /tmp/asc-mut.*/t ]] \&\& ok "tmux folder" \|\| bad "tmux folder"|' "$T/tmuxdir/tests/asc.sh"
run tmuxdir
result "the suites' tmux folder (TMUX_TMPDIR) and TMPDIR: the run's work folder" 0 "baseline asc: 4 checks, all ok" "2 caught"

toy twice
printf '%s\n' 'asc/prod.sh %%% mark() { :; } %%% mark() { echo "  ok    a is 1"; } %%% a is 1 %%% one' > "$T/twice/tests/mutants-asc.txt"
run twice
result "a check printed twice in its case run: UNCLEAR" 1 "UNCLEAR: its case run printed twice: a is 1"

toy slow
printf '%s\n' 'asc/prod.sh %%% slow() { :; } %%% slow() { sleep 60; } %%% b is 2 %%% one' > "$T/slow/tests/mutants-asc.txt"
run slow
result "a case over its time limit: UNCLEAR" 1 "UNCLEAR: its case went over its time limit ("

toy mem
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { printf "MemTotal: 1000000 kB\nMemAvailable: 1000 kB\n" > "$ASC_MUT_PROC/meminfo"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/mem/tests/mutants-asc.txt"
run mem MUTANT_JOBS=1
result "memory under 15% while a run goes: UNCLEAR, and no more mutants started" 1 "UNCLEAR: pressure: memory: 1000 of 1000000 kB available" \
	"UNCLEAR: not run: pressure: memory: 1000 of 1000000 kB available" "2 unclear"

toy disk
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { echo "500 900000" > "$ASC_MUT_PROC/disk"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/disk/tests/mutants-asc.txt"
run disk MUTANT_JOBS=1
result "/tmp under 1024 MiB free while a run goes: UNCLEAR, and no more mutants started" 1 "UNCLEAR: pressure: disk: 500 MiB free in /tmp (1024 MiB needed)" \
	"UNCLEAR: not run: pressure: disk: 500 MiB free in /tmp (1024 MiB needed)" "2 unclear"

toy oom
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { echo "oom_kill 1" > "$ASC_MUT_PROC/vmstat"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/oom/tests/mutants-asc.txt"
run oom
result "a kernel OOM kill while a run goes: UNCLEAR" 1 "UNCLEAR: pressure: a kernel OOM kill (oom_kill 0 -> 1)"

toy psi
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { sed -i "s/^full\(.*\)total=[0-9]*/full\1total=150000/" "$ASC_MUT_PROC/pressure/memory"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/psi/tests/mutants-asc.txt"
run psi
result "tasks stalled on memory 0.1 s or more (PSI full) while a run goes: UNCLEAR" 1 "UNCLEAR: pressure: tasks stalled on memory for 150 ms (PSI full)"

toy psigone
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { rm -f "$ASC_MUT_PROC/pressure/memory"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/psigone/tests/mutants-asc.txt"
run psigone
result "PSI readable at the start, then no longer, while a run goes: UNCLEAR" 1 "UNCLEAR: pressure: PSI no longer readable"

toy kills
: > "$T/kills/proc/earlyoom-kills"
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { echo killed >> "$ASC_MUT_PROC/earlyoom-kills"; sleep 2; echo 9; } %%% a is 1 %%% one' > "$T/kills/tests/mutants-asc.txt"
run kills
result "a line in earlyoom's kill file while a run goes: UNCLEAR" 1 "UNCLEAR: pressure: a line in earlyoom's kill file"
toy late
: > "$T/late/proc/earlyoom-kills"
printf '%s\n' 'asc/prod.sh %%% a() { echo 1; } %%% a() { echo killed >> "$ASC_MUT_PROC/earlyoom-kills"; echo 9; } %%% a is 1 %%% one' > "$T/late/tests/mutants-asc.txt"
run late
result "a kill the sampler sees only after the run ended: UNCLEAR, never CAUGHT" 1 "UNCLEAR: pressure: a line in earlyoom's kill file"

toy form
printf '%s\n' 'asc/prod.sh %%% echo 1 %%% echo 9 %%% a is 1' > "$T/form/tests/mutants-asc.txt"
run form
result "a list line of four fields: refused, exit 2, nothing run" 2 "asc: its mutant list is refused" "not \"file %%% old %%% new %%% check %%% case\""
toy other
printf '%s\n' 'asc/prod.sh %%% echo 1 %%% echo 9 %%% no marker %%% one' > "$T/other/tests/mutants-asc.txt"
run other
result "a check of another case: refused, exit 2" 2 "no check 'no marker' in case one (it is in case two)"
toy empty
: > "$T/empty/tests/mutants-dash.txt"
run empty
result "an empty list: refused, exit 2" 2 "dash: its mutant list is refused"
toy only
run only ASC_ONLY=one
result "ASC_ONLY set by the caller: refused, exit 2" 2 "ASC_ONLY is set"
run only ASC_MUT_RUN=1-2-abcdefgh
result "a run id set by the caller (it would skip the clean restart): refused, exit 2" 2 "ASC_MUT_RUN is set, but not by this run"
run only MUTANT_JOBS=0
result "MUTANT_JOBS=0: refused, exit 2" 2 "MUTANT_JOBS must be 1 to 99"
run only MUTANTS_FULL=2
result "MUTANTS_FULL=2: refused, exit 2" 2 "MUTANTS_FULL must be 0 or 1"
toy lowmb
echo "1023 900000" > "$T/lowmb/proc/disk"
run lowmb
result "/tmp under 1024 MiB free at the start: refused, exit 2" 2 "mutate: disk: 1023 MiB free in /tmp (1024 MiB needed)"
toy lowino
echo "900000 9999" > "$T/lowino/proc/disk"
run lowino
result "/tmp under 10000 inodes free at the start: refused, exit 2" 2 "mutate: disk: 9999 inodes free in /tmp (10000 needed)"
toy nodisk
rm "$T/nodisk/proc/disk"
run nodisk
result "/tmp's free space not readable at the start: refused, exit 2" 2 "mutate: disk: free space in /tmp not readable"

toy basefail
sed -i 's/\[ "$(b)" = 2 \] && ok "b is 2 here"/[ "$(b)" = 3 ] \&\& ok "b is 2 here"/' "$T/basefail/tests/dash.sh"
run basefail
result "a baseline with a FAIL: refused, exit 2" 2 "baseline dash only: exit 1"
toy baseskip
sed -i 's/^run_cases dash only$/case_more() { skip "c" "not here"; }\nrun_cases dash only more/' "$T/baseskip/tests/dash.sh"
run baseskip
result "a baseline with a skip: refused, exit 2" 2 "case more: skipped: c (not here)"
toy basegone
sed -i 's/^run_cases dash only$/case_more() {\n\tif false; then [ 1 ] \&\& ok "never" || bad "never"; fi\n}\nrun_cases dash only more/' "$T/basegone/tests/dash.sh"
run basegone
result "a check of the source that the baseline never ran: refused, exit 2" 2 "not run: never"

toy lock
exec 8>"$T/lock/proc/asc-mut.lock"; flock -n 8
run lock
result "a second mutant run while one holds the lock: refused, exit 2" 2 "another mutant run is going"
exec 8>&-  # the run's job holds the lock on, as its copy of this file

# Interrupted while a mutant's case runs: a TERM, and a Ctrl-C (SIGINT, as a terminal sends it;
# started with SIGINT at its default, which a background job of this shell would not have); and a
# SIGHUP in the baseline (case two made slow). Their suites' EXIT trap runs a `timeout` of its own,
# as the real suites' do: the runner must leave it alone (TERM only its own time limits), or the
# trap is cut short and the suite's folder left.
for at in TERM:mutants INT:mutants HUP:baseline; do
	sig=${at%:*} at=${at#*:}
	toy "int$sig"; r=$T/int$sig
	cat > "$r/gone.sh" <<'GONE'
gone() { timeout 5 bash -c 'sleep 0.8; rm -rf "$1"' _ "$T"; }
GONE
	sed -i "/^gone() { rm -rf \"\$T\"; }\$/r $r/gone.sh" "$r/tests/asc.sh"
	made=''; grep -qxF "$(<"$r/gone.sh")" "$r/tests/asc.sh" && made=1
	printf '%s\n' 'asc/prod.sh %%% slow() { :; } %%% slow() { sleep 60; } %%% b is 2 %%% one' > "$r/tests/mutants-asc.txt"
	[ "$at" = mutants ] || sed -i 's/^case_two() {$/case_two() {\n\tsleep 60/' "$r/tests/asc.sh"
	(cd "$r" && { git init -q && git add -A; })
	(cd "$r" && exec env ASC_MUT_PROC="$r/proc" ASC_MUT_MINLIMIT=60 python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash", "tests/mutate.sh"])') > "$r/out" 2>&1 &
	mp=$!
	seen=''
	for _ in $(seq 100); do grep -q "^== $at" "$r/out" && { seen=1; break; }; sleep 0.1; done
	sleep 1
	kill -"$sig" "$mp"; wait "$mp"; rc=$?
	out=$(<"$r/out"); rid=$(sed -n 's/^mutate: run \([0-9a-z-]*\),.*/\1/p' <<<"$out" | head -1)
	left_of "$rid" "$r/proc"
	[ -n "$seen" ] || { out="no \"== $at\" within 10 s: the signal did not hit the phase it names"$'\n'"$out" rc=none; }
	[ -n "$made" ] || { out="the toy suite's EXIT trap with a timeout of its own: not made"$'\n'"$out" rc=none; }
	result "SIG$sig while $([ "$at" = mutants ] && echo "a mutant's case runs" || echo "the baseline runs"): exit 130, its processes ended, its folder gone" 130 "mutate: interrupted"
done

wait
for i in $(seq "$NV"); do cat "$T/v.$i"; done
pass=$(cat "$T"/v.* | grep -c '^  ok    ') fail=$(cat "$T"/v.* | grep -c '^  FAIL  ')
[ "$((pass + fail))" = "$NV" ] || { echo "mutate-test: $NV checks, $((pass + fail)) verdicts"; fail=$((fail + 1)); }
echo "mutate-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
