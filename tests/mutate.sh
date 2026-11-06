#!/usr/bin/env bash
# The mutant run of tests/asc.sh and tests/dash.sh: each mutant (tests/mutants-asc.txt,
# tests/mutants-dash.txt; read by tests/mutantlint.py) is a change to asctl that its named check
# must catch. Each runs in a copy of its own, on this machine (the container runner comes later).
#   tests/mutate.sh                   every mutant (about 20 min); exit 0 only if all are CAUGHT
#   MUTANT_JOBS=3 tests/mutate.sh     how many runs at a time (default 3: memory)
#   MUTANTS_FULL=1 tests/mutate.sh    every mutant on its whole suite (slow; for comparing)
# First the baseline: every case alone, which must be all ok, no skip, each case done, and show
# exactly the checks of the source, each in its own case (else exit 2: no verdict on a bad
# baseline). Then each mutant: its case alone, stopped at its check (TEST_STOP_AT). A FAIL of
# that check, twice: CAUGHT. Else the whole suite, "(full)": a FAIL of it twice: CAUGHT (full);
# the check ok, every case done, the baseline's checks: SURVIVED (UNCLEAR if its case run had it
# FAIL once, or its case run was cut short: a setup stop, its check not reached); anything else
# UNCLEAR; each verdict is followed by its runs' times. A change not found exactly once, that no
# longer parses, or whose module then fails at import (tests/mutantlint.py): BROKEN. A run counts
# only when trusted: under its time limit, no memory pressure from a second before it to a second
# after (a sampler, each second: available memory under 15%, tasks stalled on memory for 0.1 s or
# more (PSI "full", as asc/memory.py counts it), a kernel OOM kill, a line in earlyoom's kill file
# if one is readable, a stall of more than 3 s between its samples, the clock set back, PSI or the
# OOM count readable at the start and no longer), no check name printed twice; an untrusted run
# makes the mutant UNCLEAR, never a verdict (each mutant's runs are checked at the end, one wait
# for the sampler for all).
# Memory pressure, or the sampler gone, and no more runs start: the rest are UNCLEAR.
# The run restarts itself with a clean environment, holds a lock (one mutant run at a time), works
# in /tmp/asc-mut.<run id> (a copy of the tracked files; the suites' own folders and tmux sockets
# in it too: TMPDIR and TMUX_TMPDIR, so a tmux the suites start never reaches the user's server),
# and on any exit, Ctrl-C too, ends every process it started (each carries the run id in its
# environment) and removes that folder. Refused while a process of an earlier run still runs.
# Exit 0 all CAUGHT, 1 not, 2 refused (bad settings, lists or baseline).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
now() { local t=${EPOCHREALTIME/./}; echo $((t / 1000)); }
started() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
die() { echo "mutate: $*" >&2; exit 2; }

if [ -z "${ASC_MUT_RUN-}" ]; then
	# a mutant run is always every mutant, each case chosen by the run itself
	[ -z "${ASC_ONLY+x}" ] || die "ASC_ONLY is set; a mutant run picks each mutant's case itself"
	# the run id: this process (its pid and start time, the same after the restart) and 8 random
	rid="$$-$(started $$)-$(head -c 512 /dev/urandom | LC_ALL=C tr -dc a-z0-9 | head -c 8)"
	# kept: the user's systemd manager, when there is one (tmux puts each pane in a scope of its
	# own through it, which tests/asc.sh checks: without it that check is a skip, and the baseline
	# refused); and, for tests/mutate-test.sh only and said in the first line: ASC_MUT_PROC, a
	# folder that stands in for /proc's meminfo and vmstat, holds the earlyoom kill file and the
	# lock; ASC_MUT_MINLIMIT, the least time limit of a case (else 240 s: a mutant may make asctl
	# wait its longest, boot's 120 s for claude.ai, twice before its check; a whole suite: 5 times it)
	keep=()
	for v in XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; do [ -z "${!v-}" ] || keep+=("$v=${!v}"); done
	if [ -n "${ASC_MUT_PROC-}" ]; then
		keep+=(ASC_MUT_PROC="$ASC_MUT_PROC")
		[ -z "${ASC_MUT_MINLIMIT-}" ] || keep+=(ASC_MUT_MINLIMIT="$ASC_MUT_MINLIMIT")
	fi
	exec env -i PATH="$PATH" HOME="$HOME" USER="${USER:-$(id -un)}" LANG=C.UTF-8 TZ=UTC \
		MUTANT_JOBS="${MUTANT_JOBS:-3}" MUTANTS_FULL="${MUTANTS_FULL:-0}" ASC_MUT_RUN="$rid" "${keep[@]}" \
		bash "${BASH_SOURCE[0]}" "$@"
fi
# Every setting checked here, after the restart: the environment is only what it passed. A run id
# that is not this process's was set by a caller, which would skip the restart.
RID=$ASC_MUT_RUN JOBS=${MUTANT_JOBS-} FULL=${MUTANTS_FULL-}
[[ $RID =~ ^[0-9]+-[0-9]+-[a-z0-9]{8}$ && $RID == "$$-$(started $$)-"* ]] || die "ASC_MUT_RUN is set, but not by this run"
[[ $JOBS =~ ^[1-9][0-9]?$ ]] || die "MUTANT_JOBS must be 1 to 99"
[[ $FULL =~ ^[01]$ ]] || die "MUTANTS_FULL must be 0 or 1"
PROC=${ASC_MUT_PROC:-/proc} MIN=${ASC_MUT_MINLIMIT:-240}
[ "$PROC" = /proc ] || [ -d "$PROC" ] || die "ASC_MUT_PROC is not a folder"
[[ $MIN =~ ^[1-9][0-9]*$ ]] || die "ASC_MUT_MINLIMIT must be a whole number of seconds"
KILLS=$PROC/earlyoom-kills; [ "$PROC" != /proc ] || KILLS=/run/earlyoom/kills
W=/tmp/asc-mut.$RID SAMPLER='' LOCKED=0
START=$(now)
# took <since>: the time from then, as "12m05s"
took() { local s=$((($(now) - $1) / 1000)); printf '%dm%02ds' $((s / 60)) $((s % 60)); }
# secs <ms>: as "8.1 s"
secs() { printf '%d.%d s' $(($1 / 1000)) $(($1 % 1000 / 100)); }

# Every process of this run but this shell and the one asking: they carry the run id in their
# environment (one grep over every process's; others' are unreadable and skipped).
mine() {
	local p ps
	ps=$(grep -lzxF -- "ASC_MUT_RUN=$RID" /proc/[0-9]*/environ 2>/dev/null)  # done before the loop:
	for p in $ps; do                                                         # its own processes are
		p=${p#/proc/}; p=${p%/environ}                                       # gone by then
		[ "$p" = $$ ] || [ "$p" = "$BASHPID" ] || [ ! -e "/proc/$p" ] || echo "$p"
	done
}
# Its children among them (the jobs, the sampler), and its own time limits: the `timeout` each
# run1 starts, named by a file in $W/lim (never a suite's own `timeout`, as in its EXIT trap).
children() {
	local p
	for p in $(mine); do
		[ "$p" != "$BASHPID" ] && [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = $$ ] && echo "$p"
	done
}
limits() {
	local f p
	[ "$LOCKED" = 1 ] || return 0
	for f in "$W"/lim/*; do
		p=${f##*/}
		[[ $p =~ ^[0-9]+$ ]] || continue
		[ "$(cat "/proc/$p/comm" 2>/dev/null)" = timeout ] && grep -qzxF -- "ASC_MUT_RUN=$RID" "/proc/$p/environ" 2>/dev/null && echo "$p"
	done
}
cleanup() {
	trap '' INT TERM HUP
	local ps i p sent=' '
	# First the jobs and the sampler, so no run starts; then each time limit, once: it passes the
	# TERM to its suite's process group, and the suite's EXIT trap ends what it started and
	# removes its folder (a second TERM to the suite would cut that short; a time limit started
	# meanwhile gets its TERM on a later pass). Then KILL to anything left, after up to 20 s.
	# shellcheck disable=SC2046  # a list of pids
	kill -TERM $(children) 2>/dev/null
	for i in $(seq 40); do
		for p in $(limits); do
			[[ $sent == *" $p "* ]] || { kill -TERM "$p" 2>/dev/null; sent+="$p "; }
		done
		[ -n "$(mine)" ] || break
		sleep 0.5
	done
	# each checked again just before: a pid of this run that ended meanwhile may be another's now
	for p in $(mine); do grep -qzxF -- "ASC_MUT_RUN=$RID" "/proc/$p/environ" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
	sleep 0.5
	[ "$LOCKED" = 1 ] && rm -rf "$W"
	ps=$(mine)
	[ -z "$ps" ] || echo "mutate: left running: $ps" >&2
	[ ! -e "$W" ] || [ "$LOCKED" != 1 ] || echo "mutate: left: $W" >&2
}
trap cleanup EXIT
trap 'echo "mutate: interrupted" >&2; exit 130' INT TERM HUP

# One mutant run at a time on this machine: a lock in the user's own runtime folder.
LOCKDIR=/run/user/$(id -u)
[ "$PROC" = /proc ] || LOCKDIR=$PROC
[ -d "$LOCKDIR" ] && [ -O "$LOCKDIR" ] || die "no runtime folder of yours at $LOCKDIR for the lock"
exec 9>"$LOCKDIR/asc-mut.lock" || die "cannot open the lock"
flock -n 9 || die "another mutant run is going"
if [ "$PROC" = /proc ]; then
	# an earlier run killed (SIGKILL: no cleanup): its jobs may run on, and its folder stays (a
	# toy run of tests/mutate-test.sh, ASC_MUT_PROC, reaches nothing real: not counted)
	old=$(for f in $(grep -lzE '^ASC_MUT_RUN=' /proc/[0-9]*/environ 2>/dev/null); do
		e=$(tr '\0' '\n' 2>/dev/null < "$f") && grep -q '^ASC_MUT_RUN=' <<<"$e" || continue  # ended meanwhile
		grep -qxF -- "ASC_MUT_RUN=$RID" <<<"$e" || grep -q '^ASC_MUT_PROC=' <<<"$e" || { f=${f#/proc/}; echo -n "${f%/environ} "; }
	done)
	[ -z "$old" ] || die "processes of an earlier mutant run still run (pids $old): end them first"
	for d in /tmp/asc-mut.*; do  # a run's own pid and start time still alive: it still goes
		r=${d#/tmp/asc-mut.}
		[[ $r =~ ^([0-9]+)-([0-9]+)-[a-z0-9]{8}$ ]] && [ -O "$d" ] && [ "$(started "${BASH_REMATCH[1]}")" != "${BASH_REMATCH[2]}" ] \
			&& echo "mutate: left by an earlier run (remove it): $d" >&2
	done
fi
mkdir -m 700 "$W" || die "cannot make $W"
LOCKED=1
mkdir "$W/base" "$W/out" "$W/res" "$W/t" "$W/lim" || die "work folder"
(cd "$REPO" && git ls-files -z | xargs -0 cp -P --parents -t "$W/base/") || die "copying the tracked files"
B=$W/base
[ -x "$B/bin/asctl" ] && [ -f "$B/tests/mutants-asc.txt" ] && [ -f "$B/tests/mutants-dash.txt" ] \
	|| die "copying the tracked files: bin/asctl or a mutant list missing (not git-added?)"

# The sampler: a line "<from> <to> <why>" in $W/pressure for each second with memory under 15%,
# 0.1 s or more of PSI "full" (a counter: a squeeze between two samples is seen too), an OOM kill
# or a new line in earlyoom's kill file since its last sample, or more than 3 s since that sample
# (the machine stalled, it may have missed one); $W/beat: its last sample's time.
oom() { awk '$1 == "oom_kill" {print $2}' "$PROC/vmstat" 2>/dev/null; }
psi() { awk '$1 == "full" {for (i = 2; i <= NF; i++) if ($i ~ /^total=[0-9]+$/) print substr($i, 7)}' "$PROC/pressure/memory" 2>/dev/null; }
klines() { [ -r "$KILLS" ] && wc -l < "$KILLS" || echo none; }
sampler() {
	local o0 o k0 k f0 f p t a m
	o0=$(oom) k0=$(klines) f0=$(psi) p=$(now)
	while :; do
		t=$(now)
		[ $((t - p)) -le 3000 ] || echo "$p $t no sample for $(((t - p) / 1000)) s (the machine stalled)" >> "$W/pressure"
		[ "$t" -ge "$p" ] || echo "$t $p the clock was set back" >> "$W/pressure"
		read -r a m < <(awk '$1 == "MemAvailable:" {a = $2} $1 == "MemTotal:" {m = $2} END {print a + 0, m + 0}' "$PROC/meminfo" 2>/dev/null)
		[ "${m:-0}" -gt 0 ] && [ $((a * 100)) -ge $((m * 15)) ] || echo "$t $t memory: ${a:-?} of ${m:-?} kB available" >> "$W/pressure"
		f=$(psi)
		[ -n "$f" ] || [ -z "$f0" ] || echo "$p $t PSI no longer readable" >> "$W/pressure"
		[ -z "$f" ] || [ -z "$f0" ] || [ $((f - f0)) -lt 100000 ] || echo "$p $t tasks stalled on memory for $(((f - f0) / 1000)) ms (PSI full)" >> "$W/pressure"
		[ -z "$f" ] || f0=$f
		o=$(oom); [ -n "$o0" ] || o0=$o  # readable only now: watched from now on
		[ -n "$o" ] || [ -z "$o0" ] || echo "$p $t the OOM kill count no longer readable" >> "$W/pressure"
		[ -z "$o0" ] || [ -z "$o" ] || [ "$o" = "$o0" ] || { echo "$p $t a kernel OOM kill (oom_kill $o0 -> $o)" >> "$W/pressure"; o0=$o; }
		k=$(klines); [ "$k" = "$k0" ] || { echo "$p $t a line in earlyoom's kill file" >> "$W/pressure"; k0=$k; }
		echo "$t" > "$W/beat.new" && mv -f "$W/beat.new" "$W/beat"
		p=$t
		sleep 1
	done
}
earlyoom=none
pgrep -x earlyoom >/dev/null && { [ -r "$KILLS" ] && earlyoom="earlyoom kills read from $KILLS" || earlyoom="earlyoom runs, its kills not seen"; }
[ -n "$(psi)" ] || earlyoom+="; PSI not readable"
[ -n "$(oom)" ] || earlyoom+="; the OOM kill count not readable"
[ "$PROC" = /proc ] || earlyoom+=" (TEST: $PROC, least time limit $MIN s)"
: > "$W/pressure"; now > "$W/beat"
sampler 9>&- & SAMPLER=$!
# pressure <from>: its first line about a time from then on (empty: none)
pressure() { awk -v a="$1" '$2 >= a {$1 = $2 = ""; print substr($0, 3); exit}' "$W/pressure"; }
# settle <t>: the time of the sampler's first sample from t on (waited for, up to 10 s), else of
# its last one
settle() {
	local i b
	for i in $(seq 50); do
		b=$(cat "$W/beat" 2>/dev/null)
		[ -n "$b" ] && [ "$b" -ge "$1" ] && break
		kill -0 "$SAMPLER" 2>/dev/null || break
		sleep 0.2
	done
	echo "${b:-0}"
}
# calm <t0> <t1> <beat>: no pressure from a second before the run to a second after, which the
# sampler's beat (from settle) has seen; else why
calm() {
	local why
	why=$(awk -v a=$(($1 - 1000)) -v b=$(($2 + 1000)) '$1 <= b && $2 >= a {$1 = $2 = ""; print substr($0, 3); exit}' "$W/pressure")
	[ -z "$why" ] || { echo "pressure: $why"; return 1; }
	[ "$3" -ge $(($2 + 1000)) ] || { echo "the pressure sampler stopped"; return 1; }
}
trusted() { calm "$1" "$2" "$(settle $(($2 + 1000)))"; }
# halted <since>: why no more runs may start (memory pressure since then, or the sampler gone or
# stuck: no sample for 5 s)
halted() {
	local why b
	kill -0 "$SAMPLER" 2>/dev/null || { echo "the pressure sampler stopped"; return 0; }
	b=$(cat "$W/beat" 2>/dev/null)
	[ -n "$b" ] && [ $(($(now) - b)) -lt 5000 ] || { echo "the pressure sampler stuck (no sample for 5 s)"; return 0; }
	why=$(pressure "$1")
	[ -n "$why" ] && echo "memory pressure: $why"
}
# untimed <exit> <limit>: why a run's exit leaves it without a verdict (`timeout`: 124 over the
# limit, 137 its KILL after the TERM, 125 to 127 it could not run the suite), else nothing
untimed() {
	case $1 in
	124) echo "went over its time limit ($2 s)" ;;
	137) echo "was killed (SIGKILL: its time limit of $2 s, or else)" ;;
	125|126|127) echo "could not be run (timeout exit $1)" ;;
	*) return 1 ;;
	esac
}
# run1 <copy> <suite> <case or ''> <check to stop at or ''> <limit s> <output>: prints "<exit> <t0> <t1>"
run1() {
	local d=$1 s=$2 c=$3 stop=$4 lim=$5 out=$6 t0 rc p
	t0=$(now)
	(
		cd "$d" || exit 2
		# the suite's own folders and tmux sockets in the work folder: gone with it, even after a
		# SIGKILL; and a tmux started without the suite's socket never reaches the user's server
		export TMPDIR="$W/t" TMUX_TMPDIR="$W/t"
		[ -z "$c" ] || export ASC_ONLY="$c"
		[ -z "$stop" ] || export TEST_STOP_AT="$stop"
		: > "$W/lim/$BASHPID"; echo "$BASHPID" > "$out.pid"  # this process: the time limit
		exec timeout -k 15 "$lim" bash "tests/$s.sh"
	) > "$out" 2>&1 < /dev/null 9>&-
	rc=$?
	p=$(cat "$out.pid" 2>/dev/null); [[ ! $p =~ ^[0-9]+$ ]] || rm -f "$W/lim/$p"
	echo "$rc $t0 $(now)"
}
# runs: how many of its jobs go (the sampler is not one)
runs() { jobs -rp | grep -cvxF "$SAMPLER"; }

echo "mutate: run $RID, $JOBS at a time$([ "$FULL" = 1 ] && echo ", every mutant on its whole suite"); $earlyoom"
SUITES=(asc dash)
declare -A CASES LIMIT FLIMIT
NS=() MS=() ML=() MC=() MK=() MN=()
for s in "${SUITES[@]}"; do
	(cd "$B" && python3 -I tests/checklint.py --names "tests/$s.sh" tests/dash/page.js) > "$W/names.$s" || die "$s: the checks of its source cannot be read"
	(cd "$B" && python3 -I tests/mutantlint.py --table "tests/mutants-$s.txt") > "$W/table.$s" || die "$s: its mutant list is refused"
	n=0
	while IFS= read -r -d '' line && IFS= read -r -d '' c && IFS= read -r -d '' k && IFS= read -r -d '' nm; do
		MS+=("$s") ML+=("$line") MC+=("$c") MK+=("$k") MN+=("$nm"); n=$((n + 1))
	done < "$W/table.$s"
	[ "$n" -gt 0 ] || die "$s: no mutant read"
	CASES[$s]=$(awk -F'\t' -v s="tests/$s.sh" '$1 == s {print $2}' "$W/names.$s" | sort -u | paste -sd,)
	[ -n "${CASES[$s]}" ] || die "$s: no case in its source"
	NS+=("$s: $n mutants, cases ${CASES[$s]}")
done
printf 'mutate: %s\n' "${NS[@]}"

# Baseline: every case alone, JOBS at a time, each limited to 15 min; none started once memory is
# short or the sampler is gone.
echo "== baseline"
# in a copy: whatever a run leaves there never reaches the mutants' copies (of $B)
cp -a "$B" "$W/bl" || die "a copy for the baseline"
since=$(now) stopped=''
for s in "${SUITES[@]}"; do
	mkdir "$W/out/base.$s"
	for c in ${CASES[$s]//,/ }; do
		stopped=$(halted "$since") && break 2
		( r=$(run1 "$W/bl" "$s" "$c" '' 900 "$W/out/base.$s/$c.out"); echo "$r" > "$W/out/base.$s/$c.rc" ) 9>&- &
		while [ "$(runs)" -ge "$JOBS" ]; do wait -n; done
	done
done
while [ "$(runs)" -gt 0 ]; do wait -n; done
[ -z "$stopped" ] || die "baseline stopped: $stopped"
for s in "${SUITES[@]}"; do
	tot=0
	for c in ${CASES[$s]//,/ }; do
		read -r rc t0 t1 < "$W/out/base.$s/$c.rc" || die "baseline $s $c: no result"
		why=$(trusted "$t0" "$t1") || die "baseline $s $c: not trusted: $why"
		[ "$rc" = 0 ] || die "baseline $s $c: exit $rc$(why=$(untimed "$rc" 900) && echo " ($why)")"$'\n'"$(grep -A3 '^  FAIL\|^setup:' "$W/out/base.$s/$c.out" | head -20)"
		sec=$(((t1 - t0 + 999) / 1000)); tot=$((tot + sec))
		LIMIT[$s.$c]=$((sec * 4 > MIN ? sec * 4 : MIN))
	done
	FLIMIT[$s]=$((tot * 3 > MIN * 5 ? tot * 3 : MIN * 5))
	python3 -I "$B/tests/mutjudge.py" baseline "$W/names.$s" "$s" "$W/out/base.$s/"*.out > "$W/base.names.$s" \
		|| die "baseline $s: $(cat "$W/base.names.$s")"
	echo "baseline $s: $(wc -l < "$W/base.names.$s") checks, all ok, in ${CASES[$s]//,/ } ($tot s one after another)"
done
rm -rf "$W/bl"

# One mutant, in its own copy: writes "<verdict>\t<what>\t<t0:t1 of each run>" to $W/res/<i> (its
# runs' trust is checked at the end).
mutant() {
	local i=$1 s=${MS[$1]} c=${MC[$1]} k=${MK[$1]} d=$W/m$1 o=$W/out/m$1 r rc t0 t1 why v n once='' cut='' wins=''
	# no bytecode from the baseline's runs: each copy compiles its own code
	cp -a "$B" "$d" && find "$d" -type d -name __pycache__ -prune -exec rm -rf {} + \
		|| { printf 'UNCLEAR\tno copy\n' > "$W/res/$i"; return; }
	if ! why=$(cd "$d" && python3 -I tests/mutantlint.py --apply "tests/mutants-$s.txt" "${ML[$i]}" 2>&1); then
		printf 'BROKEN\t%s\n' "${why//[$'\n\t']/ }" > "$W/res/$i"; rm -rf "$d"; return
	fi
	v=''
	if [ "$FULL" = 0 ]; then
		for n in 1 2; do
			read -r rc t0 t1 < <(run1 "$d" "$s" "$c" "$k" "${LIMIT[$s.$c]}" "$o.case$n")
			[ -n "$t1" ] || { v="UNCLEAR	its case run gave no result"; break; }
			wins+="$t0:$t1 "
			why=$(untimed "$rc" "${LIMIT[$s.$c]}") && { v="UNCLEAR	its case $why"; break; }
			r=$(python3 -I "$B/tests/mutjudge.py" case "$o.case$n" "$k" "$c")
			case $r in
			FAIL) once=1; [ "$n" = 1 ] || v="CAUGHT	$k ($c)" ;;
			"other: printed twice"*) v="UNCLEAR	its case run ${r#other: }"; break ;;
			ok) break ;;
			*) cut=${r#other: } cut=${cut:-no verdict on it}; break ;;
			esac
		done
	fi
	if [ -z "$v" ]; then
		for n in 1 2; do
			read -r rc t0 t1 < <(run1 "$d" "$s" '' "$k" "${FLIMIT[$s]}" "$o.full$n")
			[ -n "$t1" ] || { v="UNCLEAR	(full) its run gave no result"; break; }
			wins+="$t0:$t1 "
			why=$(untimed "$rc" "${FLIMIT[$s]}") && { v="UNCLEAR	(full) the whole suite $why"; break; }
			r=$(python3 -I "$B/tests/mutjudge.py" full "$o.full$n" "$k" "$W/base.names.$s" "${CASES[$s]}")
			case $r in
			FAIL) [ "$n" = 1 ] || v="CAUGHT	$k ($c, full)" ;;
			same) if [ "$n" = 2 ]; then v="UNCLEAR	(full) flaky: $k failed once, then passed"
				elif [ -n "$once" ]; then v="UNCLEAR	flaky: $k failed in its case once, then passed; the whole suite as its baseline"
				elif [ -n "$cut" ]; then v="UNCLEAR	its case run cut short ($cut); the whole suite as its baseline"
				else v="SURVIVED	$k ok, the whole suite as its baseline"; fi; break ;;
			*) v="UNCLEAR	(full) ${r#other: }$([ "$n" = 2 ] && echo " (its first run had it FAIL: flaky)")"; break ;;
			esac
		done
	fi
	printf '%s\t%s\n' "$v" "$wins" > "$W/res/$i"
	rm -rf "$d"
}

echo "mutate: baseline took $(took "$START")"

# Each mutant, JOBS at a time; none started once memory is short or the sampler is gone.
echo "== mutants"
N=${#MS[@]} since=$(now) stopped=''
for ((i = 0; i < N; i++)); do
	stopped=$(halted "$since") && break
	mutant "$i" 9>&- &
	while [ "$(runs)" -ge "$JOBS" ]; do wait -n; done
done
while [ "$(runs)" -gt 0 ]; do wait -n; done
echo "mutate: mutants took $(took "$since")"
if [ -n "$stopped" ]; then
	echo "mutate: no more mutants started: $stopped" >&2
	for ((; i < N; i++)); do printf 'UNCLEAR\tnot run: %s\n' "$stopped" > "$W/res/$i"; done
fi

# Each run's trust: one wait for the sampler's sample from a second after the last run ended.
last=0
for ((i = 0; i < N; i++)); do
	for w in $(cut -f3 "$W/res/$i" 2>/dev/null); do [[ ! ${w#*:} =~ ^[0-9]+$ ]] || [ "${w#*:}" -le "$last" ] || last=${w#*:}; done
done
beat=$(settle $((last + 1000)))

declare -A COUNT=([CAUGHT]=0 [SURVIVED]=0 [UNCLEAR]=0 [BROKEN]=0)
full=0
for ((i = 0; i < N; i++)); do
	v='' what='' wins=''
	IFS=$'\t' read -r v what wins < "$W/res/$i" 2>/dev/null || v=UNCLEAR what="no result: its run was cut off"
	for w in $wins; do
		why=$(calm "${w%:*}" "${w#*:}" "$beat") || { what="$why (its $v: $what)" v=UNCLEAR; break; }
	done
	[ -n "${COUNT[$v]+x}" ] || { what="$v $what" v=UNCLEAR; }
	COUNT[$v]=$((COUNT[$v] + 1))
	if [ "$v" = CAUGHT ]; then
		echo "  ok    ${MN[$i]}"; echo "        caught by: $what"
		[[ $what != *", full)" ]] || full=$((full + 1))
	else
		echo "  FAIL  ${MN[$i]}"; echo "        $v: $what"
	fi
	# each run's time, in order (its case, then the whole suite if that ran): where the time goes
	spent=''
	for w in $wins; do [[ ${w%:*} =~ ^[0-9]+$ && ${w#*:} =~ ^[0-9]+$ ]] && spent+="${spent:+, }$(secs $((${w#*:} - ${w%:*})))"; done
	[ -z "$spent" ] || echo "        runs: $spent"
done
[ "$FULL" = 1 ] && full="each on the whole suite" || full="$full only by the whole suite"
echo "mutate: $N mutants: ${COUNT[CAUGHT]} caught ($full), ${COUNT[SURVIVED]} survived, ${COUNT[UNCLEAR]} unclear, ${COUNT[BROKEN]} broken; $(took "$START") in all"
[ "${COUNT[CAUGHT]}" = "$N" ]
