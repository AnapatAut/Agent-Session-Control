#!/usr/bin/env bash
# Mutation test: each mutant breaks one safeguard in a copy of the repo, and the test that
# guards it must then fail with the expected check among its FAIL lines.
#   CAUGHT    the expected check failed
#   UNCLEAR   the test failed, but not on the expected check (read its log)
#   SURVIVED  the test passed: the safeguard has no check that catches it
#   BROKEN    the mutant cannot run: its text is not there exactly once, the change is a
#             syntax error, or its selection does not hold its expected check (see below)
# Fast mode (the default): a mutant runs only its selection, the case or kill-sweep kinds
# that hold its expected check, each in a fresh container. A CAUGHT there counts only when the
# baseline (both suites run unmodified at the start of this same run, on the same copy, image
# and mirror) shows exactly that check as ok in that selection, the mutant's run ends with its
# machine still sound, and the same check fails in a second run too. Any
# mutant not CAUGHT there runs again on its whole suite, and that run gives the verdict,
# marked "(full)". So the fast mode saves time and never changes a verdict. See tests/README.md.
#   tests/mutants.sh                  all mutants, JOBS (default 4; 2 with MUTANTS_FULL=1) at a time
#   tests/mutants.sh <id>...          only these
#   MUTANTS_FULL=1 tests/mutants.sh   every mutant on its whole suite (the slow mode)
# The mutants are literal code, meant not to expand here:
# shellcheck disable=SC2016
set -uo pipefail
# The run's marker (see stop_all) must be in the environment this process was started with:
# /proc/<pid>/environ shows that one, and a subshell forked later shows it too. So start once
# more with it (exec keeps the PID); TCR_PARENT_PID tells the second start that it is.
# The second start also drops what would change every bash or git it runs: BASH_ENV, ENV,
# shell options (SHELLOPTS, BASHOPTS: nullglob, noclobber, …) and the like, exported
# functions, and every GIT_* variable.
if [ "${TCR_PARENT_PID:-}" != $$ ]; then
	drop=(-u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u GLOBIGNORE -u CDPATH -u POSIXLY_CORRECT -u BASH_COMPAT -u TMOUT)
	while IFS= read -r v; do drop+=(-u "$v"); done < <(env | sed -n 's/^\(BASH_FUNC_[^=]*\)=.*/\1/p; s/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p')
	exec env "${drop[@]}" TCR_PARENT="tcr-mutants-$$-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" TCR_PARENT_PID=$$ bash "$0" "$@"
fi
[[ $TCR_PARENT =~ ^tcr-mutants-[0-9]+-[0-9a-f]{12}$ ]] || { echo "bad TCR_PARENT"; exit 2; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Git variables from the caller (GIT_DIR, GIT_WORK_TREE, …) would point our git calls elsewhere.
while read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars 2>/dev/null)
# shellcheck source=tests/baseline.sh
. "$REPO/tests/baseline.sh"
command -v python3 >/dev/null || { echo "python3 is required (it makes the mutants)"; exit 2; }
# Only the baseline below saves logs (TCR_LOGS); one left in the environment would make every run save them.
unset TCR_LOGS
FULL=${MUTANTS_FULL:-0}
[ "$FULL" = 0 ] || [ "$FULL" = 1 ] || { echo "MUTANTS_FULL must be 0 or 1"; exit 2; }
# The slow mode runs whole suites only: 2 at a time, as before.
JOBS=${JOBS:-$([ "$FULL" = 1 ] && echo 2 || echo 4)}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo "JOBS must be a whole number above 0"; exit 2; }
# The longest a run may take, in seconds: a selection, and three times that for a whole suite.
LIMIT=${MUTANTS_LIMIT:-900}
[[ $LIMIT =~ ^[1-9][0-9]*$ ]] || { echo "MUTANTS_LIMIT must be a whole number of seconds"; exit 2; }
# Where the host's memory figures are read (meminfo, vmstat); another folder only for tests.
PROC=${MUTANTS_PROC:-/proc}
[ -r "$PROC/meminfo" ] && [ -r "$PROC/vmstat" ] || { echo "cannot read $PROC/meminfo and $PROC/vmstat"; exit 2; }
[ "$PROC" = /proc ] || echo "== memory figures from $PROC, not /proc (for the runner's own tests)"
[ -r "$PROC/pressure/cpu" ] || echo "== no $PROC/pressure/cpu (the kernel's PSI is off): CPU pressure is not measured"
# The suites mount this machine's paths: the docker daemon must be local (a unix socket).
h=${DOCKER_HOST:-}; [ -n "$h" ] || h=$(timeout 30 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
[[ $h == unix://* ]] || { echo "docker must be a local daemon (unix socket), not: ${h:-unknown}"; exit 2; }
WORK=$(mktemp -d) || { echo "mktemp failed"; exit 2; }
IMG=""; PW=""
[[ $WORK =~ ^/[A-Za-z0-9._/+-]+$ ]] || { echo "TMPDIR gives a temp path with odd characters: $WORK"; rm -rf "$WORK"; exit 2; }
# Per-mutant files in m/; the suites' own temp folders in tmp/, so that removing the work folder
# removes those of a suite that was killed too.
mkdir -p "$WORK/m" "$WORK/tmp" && export TMPDIR="$WORK/tmp" || { echo "cannot make the work folder"; rm -rf "$WORK"; exit 2; }
# TCR_PARENT (set at the top): every process this run starts has it in its environment, a
# forked subshell too (env -u keeps it), and every container of its suites carries it as a
# label (tests/lib.sh adds it): an interrupt finds them all by it, an orphan of a killed job too.
# The runner's own process group and session: the 3rd and 4th fields after the command name
# in /proc/<pid>/stat.
st=$(cat "/proc/$$/stat") && read -r _ _ ME SID _ <<<"${st##*) }" && [ -n "$SID" ] || { echo "cannot read /proc/$$/stat"; rm -rf "$WORK"; exit 2; }
# ours_procs: the run's processes, by that variable and in the runner's session (a daemon one
# of them started by the way, a gpg-agent for docker's credential helper say, calls setsid: it
# is not the run's), into the caller's arrays: ps (the PIDs), par and grp (each one's parent
# and process group). No file, no pipe: no short-lived helper of this scan is among them, and
# a full disk changes nothing.
ours_procs() {
	local f p pp g sid st
	ps=(); par=(); grp=()
	for f in /proc/[0-9]*/environ; do
		p=${f#/proc/}; p=${p%/environ}
		[ "$p" != $$ ] && grep -qz "^TCR_PARENT=$TCR_PARENT\$" "$f" 2>/dev/null || continue
		st=$(cat "/proc/$p/stat" 2>/dev/null) || continue
		read -r _ pp g sid _ <<<"${st##*) }"
		[ "$sid" = "$SID" ] || continue
		ps+=("$p"); par[$p]=$pp; grp[$p]=$g
	done
}
# ours: the run's containers; fails when docker does not answer.
ours() { timeout 30 docker ps -a --filter "label=tcr-parent=$TCR_PARENT" --format '{{.Names}}' 2>/dev/null; }
# On any exit, an interrupt too (Ctrl-C, TERM, a closed terminal), in this order:
# 1. Stop the run's processes: scan once a second; TERM each one once, if it is in the runner's
#    own process group (its subshells, the sampler), or leads a group of its own that the
#    runner or no process of the run started (the `timeout` of each run: it passes the TERM to
#    its whole group, the suite in it included), or is in a group whose leader is not the
#    run's. Not the rest: a suite gets the TERM from its timeout only (a second one could end
#    it before its cleanup ignores signals), and what a suite starts (its cleanup's `timeout
#    docker …`) is the suite's. At most 90 s, then KILL what is left.
# 2. Remove the run's containers by its label: after an interrupt or a run stopped at its limit
#    until none has appeared for 10 s (a `docker run` in flight creates its container late; at
#    most 60 s). A docker that does not answer, or a removal that fails, never counts as done.
# 3. The image and the work folder.
stop_all() {
	# PIPE too: with the output piped to a reader that is gone, a message must not end it here.
	trap '' INT TERM HUP PIPE
	local c p g q ps=() quiet=0 any=0 deaf=0 t0=$SECONDS
	local -A par=() grp=() sent=()
	while :; do
		ours_procs
		[ ${#ps[@]} -gt 0 ] || break
		any=1
		if [ $((SECONDS - t0)) -ge 90 ]; then
			# Once more for one forked between the scan and the KILL.
			kill -KILL "${ps[@]}" 2>/dev/null; sleep 1; ours_procs; [ ${#ps[@]} = 0 ] || kill -KILL "${ps[@]}" 2>/dev/null
			break
		fi
		for p in "${ps[@]}"; do
			[ -z "${sent[$p]:-}" ] || continue
			g=${grp[$p]}
			if [ "$g" = "$ME" ]; then :
			elif [ "$g" = "$p" ]; then
				q=${grp[${par[$p]}]:-}; [ -z "$q" ] || [ "$q" = "$ME" ] || continue
			else
				[ -z "${grp[$g]:-}" ] || continue
			fi
			kill -TERM "$p" 2>/dev/null; sent[$p]=1
		done
		sleep 1
	done
	grep -qsx '== timed out' "$WORK"/m/*.log* && any=1
	t0=$SECONDS
	while :; do
		deaf=0
		if ! c=$(ours); then quiet=0; deaf=1
		elif [ -n "$c" ]; then quiet=0; xargs -r timeout 60 docker rm -f <<<"$c" >/dev/null 2>&1 || deaf=1
		else quiet=$((quiet + 1)); fi
		[ $any = 1 ] && [ $quiet -lt 10 ] && [ $((SECONDS - t0)) -lt 60 ] || break
		sleep 1
	done
	if [ $deaf = 1 ] || { [ $any = 1 ] && [ $quiet -lt 10 ]; }; then
		echo "== containers of this run may be left (docker did not answer or remove, or they kept coming): docker ps -a --filter label=tcr-parent=$TCR_PARENT" >&2 || :
	fi
	[ -z "$IMG" ] || timeout 60 docker image rm "$IMG" >/dev/null 2>&1
	rm -rf "$WORK"
}
trap stop_all EXIT
IDS=(); declare -A M_FILE M_TEST M_EXPECT M_OLD M_NEW
# mutant <id> <file> <selection> <expected FAIL text> <exact text> <replacement>
#   selection: case:<name>[,<name>] (tests/container.sh cases, not core), sweep:<kind>[,<kind>]
#   (tests/killsweep.sh kinds) or core (container.sh stages 1-8). Its whole suite: every
#   container.sh case but core, the whole kill sweep, or every container.sh case.
mutant() { [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "bad mutant id: $1"; exit 2; }; IDS+=("$1"); M_FILE[$1]=$2; M_TEST[$1]=$3; M_EXPECT[$1]=$4; M_OLD[$1]=$5; M_NEW[$1]=$6; }

mutant manifest-not-first install.sh sweep:install "home byte-identical" \
	'step_manifest() { take_lock; remove_stale_temps; write_manifest "$1"; }' \
	'step_manifest() { take_lock; remove_stale_temps; }'
mutant pending-not-cleared install.sh sweep:install "manifest written without pending" \
	'write_manifest "$(manifest_json "")"' 'write_manifest "$(manifest_json "$KIND")"'
mutant no-temp-cleanup install.sh sweep:write "removed the temp file" \
	'remove_stale_temps() { local f;' 'remove_stale_temps() { return 0; local f;'
mutant write-in-place install.sh sweep:write "config still holds its old bytes" \
	'	cat > "$tmp"
	if [ -n "$mode" ]; then chmod "$mode" "$tmp"' '	cat > "$real"; cp "$real" "$tmp"
	if [ -n "$mode" ]; then chmod "$mode" "$tmp"'
mutant state-dir-kept install.sh case:window "an unrecorded state folder (a kill's leftover) is removed" \
	'	rmdir -- "$STATE" 2>/dev/null || true' '	true'
mutant stale-manifest-dirs-ignored install.sh sweep:write "write-manifest.json: home byte-identical" \
	'done | jq -sc '"'"'add // []'"'"'' 'done | jq -sc '"'"'[]'"'"''
mutant restore-ignored install.sh sweep:install "home byte-identical" \
	'mget .conf.restore | base64 -d > "$out"; action="write"' 'cp "$WORK/plan.nb" "$out"; action="write"'
mutant flag-not-checked install.sh case:signals "the clone finished, the run stopped before the next step" \
	'		if [ "$INTR" = 1 ]; then
			out "  stopped before step' '		if false; then
			out "  stopped before step'
mutant second-interrupt-ignored install.sh case:sig2 "second SIGINT: exit 3 at once" \
	'if [ "$INTR" = 1 ]; then out "  stopped at once' 'if false; then out "  stopped at once'
# No mutant for run_child's own session (setsid): since supervise, no terminal signal reaches
# the worker's process group, so a child in that group is not hit either. It stays as a
# second layer (the guide's rule), and no test can tell it apart.
mutant lock-fd-inherited install.sh case:plain "that server does not hold the lock" \
	'[ "$1" != tmux ] || exec 9<&-;' ''
mutant no-lock install.sh case:pend "lock held: install refused" \
	'flock -n 9 || {' 'true || {'
mutant no-readlink install.sh case:link "still a symlink" \
	'real=$(readlink -f -- "$path"); dir=$(dirname -- "$real")' 'real=$path; dir=$(dirname -- "$real")'
mutant root-allowed install.sh case:refusals "as root: refused" \
	'if [ "$(id -u)" = 0 ]; then refuse' 'if false; then refuse'
mutant pipe-kills install.sh case:link "install | head -n1: exit 0" \
	"out()  { printf '%s\\n' \"\$*\" 2>/dev/null || exec >/dev/null 2>&1; }" "out()  { printf '%s\\n' \"\$*\"; }"
mutant gitdir-kept install.sh case:gitdir "install with GIT_DIR set to another repo: exit 0" \
	'unset $(git rev-parse --local-env-vars)' ': $(git rev-parse --local-env-vars)'
mutant unreachable-manager-allowed install.sh case:refusals "no user manager (user nosd): install refused, exit 1" \
	'have_systemd || refuse "this machine runs systemd' 'true || refuse "this machine runs systemd'
mutant pending-uninstall-allowed install.sh case:pend "install while an uninstall is pending: refused" \
	'[ "$pending" = uninstall ] && refuse' '[ "$pending" = never ] && refuse'
mutant autoremove-dirty install.sh case:keep "a file of the user's is kept" \
	'[ -z "$st" ] || return 1
	# Work of' 'true || return 1
	# Work of'
mutant autoremove-off-pin install.sh case:keep "a plugin off its pin is kept" \
	'[ "$(git "${GITQ[@]}" -C "$d" rev-parse HEAD 2>/dev/null)" = "${PIN[$p]}" ] || return 1' 'true || return 1'
mutant autoremove-still-needed install.sh case:need "a plugin the config still names is kept" \
	'	! conf_needs "$2" "$p"' '	true'
mutant unexpected-error-exit-1 install.sh case:boom "unexpected error in a step: exit 3" \
	'			out "  steps 1 to $((STEP - 1)) are done; rerun the same command to finish it, or run $0 --uninstall"
			exit 3' '			out "  steps 1 to $((STEP - 1)) are done; rerun the same command to finish it, or run $0 --uninstall"
			exit 1'
mutant no-systemd-not-detected install.sh case:nosystemd "no systemd: install=0" \
	'booted_systemd() { [ -d /run/systemd/system ]; }' 'booted_systemd() { true; }'
mutant scope-drop-in-after install.sh core "the save on stop recorded the late claude" \
	'		Before=tmux.service' '		After=tmux.service'
mutant stop-drop-in-direct-save install.sh core "last save unchanged by the crash" \
	'		ExecStop=-$(command -v tmux) run-shell "$(plug_in %h)/tmux-resurrect/scripts/save.sh quiet"' \
	'		ExecStop=-$(plug_in %h)/tmux-resurrect/scripts/save.sh quiet'
mutant without-block-recomputed install.sh case:edit1 "uninstall keeps the user's line" \
	'if [ -n "$M" ] && [ $residual = 0 ]; then nb=$(mget .conf.withoutBlock); fi' \
	'if false; then nb=$(mget .conf.withoutBlock); fi'
mutant broken-block-allowed install.sh case:marks "block without its end line: install refused" \
	'block_broken "$cur" && refuse' 'false && refuse'
mutant residual-pending-ignored install.sh case:resid "a plain --uninstall finishes it" \
	'[ "$AUTOREMOVE" = 0 ] && [ -z "$(mget .pending)" ]; then' '[ "$AUTOREMOVE" = 0 ]; then'
mutant claude-missing-fails install.sh case:noclaude "claude not on PATH: install exits 0" \
	'ok "claude found" || warn "claude not on PATH; restore will fail until it is"' \
	'ok "claude found" || { bad "claude not on PATH; restore will fail until it is"; rc=1; }'
mutant own-service-drop-in install.sh case:ownsvc "no stop drop-in for it" \
	'{ [ "$k" = stop ] && own_tmux_service; } || echo "$k"' 'echo "$k"'
mutant commented-plugin-counts install.sh case:comment "a commented-out @plugin line" \
	'grep -qE "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+['"'"'\"]?((https://|git@)github\.com[:/])?$(sed' \
	'grep -qE "set(-option)?[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+['"'"'\"]?((https://|git@)github\.com[:/])?$(sed'
mutant no-supervisor install.sh case:sigmv "SIGINT during a plain command (mv)" \
	'[ $CMD = check ] || [ $WORKER = 1 ] || supervise "$@"' 'true'
mutant untracked-hidden install.sh case:hidden "showUntrackedFiles=no hides" \
	'status --porcelain --ignored --untracked-files=all' 'status --porcelain --ignored'
mutant local-commits-ignored install.sh case:hidden "a commit of the user's on a local branch" \
	'st=$(git "${GITQ[@]}" -C "$d" rev-list --branches --not --remotes 2>/dev/null) || return 1' 'st=""'
mutant service-created-unhashed install.sh case:svcrec "tmux.service never written: not recorded" \
	'		TSVC=$(jq '"'"'.created = false'"'"' <<<"$TSVC")' '		true'
mutant child-lock-closed install.sh case:sig2 "a rerun while the clone still runs is refused" \
	'[ "$1" != tmux ] || exec 9<&-;' 'exec 9<&-;'
mutant hooks-all-unset install.sh case:ownhook "a resurrect hook of the user's own" \
	'		our_hook "$o" || continue' '		true'
mutant plugin-url-ignored install.sh case:urlplug "keeps the plugin it names" \
	'@plugin[[:space:]]+['"'"'\"]?((https://|git@)github\.com[:/])?tmux-plugins/$2' '@plugin[[:space:]]+['"'"'\"]?tmux-plugins/$2'
mutant sourced-conf-ignored install.sh case:srcconf "a config that sources another file" \
	'	grep -qE "^[[:space:]]*source(-file)?[[:space:]]" "$1" && return 0' '	true'
mutant git-config-trusted install.sh case:fsmon "the user's fsmonitor hook never runs" \
	'GITQ=(-c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false)' 'GITQ=()'
mutant pending-not-set install.sh case:pend "killed install: --check exits 4 and names the command" \
	'mjson=$(manifest_json "$KIND")' 'mjson=$(manifest_json "")'
mutant pending-uninstall-not-set install.sh case:pend "killed uninstall: --check exits 4 and names --uninstall" \
	'step_manifest "$(jq -c '"'"'.pending = "uninstall"'"'"' <<<"$M")"' 'step_manifest "$(jq -c . <<<"$M")"'
mutant conf-was-ignored install.sh sweep:install "rerun of the same command ends with exit 0" \
	'	[ "$now" = "$(mget .was "$CONFREC")" ] || fail' '	false || fail'
mutant conf-edit-overwritten install.sh case:edrun "config edited while install runs" \
	'	[ "$now" = "$(mget .was "$CONFREC")" ] || fail' '	true || fail'
mutant conf-edit-overwritten-uninstall install.sh case:edrun "config edited while uninstall runs" \
	'	[ "$(sha_of "$real")" = "$2" ] || fail' '	true || fail'
mutant xdg-ignored install.sh case:xdg "only the XDG config: install exits 0" \
	'if [ -f "$XDG_CONF" ]; then CONF=$XDG_CONF;' 'if false; then CONF=$XDG_CONF;'
mutant resurrect-load-unchecked install.sh case:xdg "hooks set but tmux-resurrect not loaded" \
	'if resurrect_loaded; then ok "live tmux:' 'if true; then ok "live tmux:'
mutant install-after-move install.sh case:xmove "install refuses (exit 1) and says to uninstall first" \
	'|| refuse "tmux plugins now load as' '|| true "tmux plugins now load as'
mutant uninstall-paths-ignored install.sh case:xback "the plugins in the XDG folder are removed" \
	'	if [ -n "$M" ]; then use_manifest_paths "$M"' '	if false; then use_manifest_paths "$M"'
mutant other-conf-left install.sh case:xback "our lines out of ~/.tmux.conf" \
	'[ "$o" != "$CONF" ] && has_ours "$o" || continue' 'continue'
mutant other-conf-unchecked install.sh case:xback "names both" \
	'if [ "$o" != "$CONF" ] && has_ours "$o"; then bad' 'if false; then bad'
mutant other-conf-plugins-ignored install.sh case:xoth "keeps a plugin the other config file names" \
	'if [ "$o" != "$CONF" ] && conf_needs "${OTHER_AFTER[$o]:-$o}" "$p"; then return 1; fi' 'true'
mutant legacy-block-elsewhere install.sh case:xleg "XDG config now there: install refuses (exit 1)" \
	'if [ "$CONF" != "$HOME_CONF" ] && has_ours "$HOME_CONF"; then' 'if false; then'
mutant tpm-path-kept install.sh case:xmove "tmux still running from the old one: exit 0" \
	'|| must 60 tmux set-environment -gu TMUX_PLUGIN_MANAGER_PATH' '|| true'
mutant plugin-manager-path-allowed install.sh case:xenv "sets TMUX_PLUGIN_MANAGER_PATH: install refuses" \
	'refuse "$f sets TMUX_PLUGIN_MANAGER_PATH' 'true "$f sets TMUX_PLUGIN_MANAGER_PATH'
mutant unsafe-plugin-folder install.sh case:xsp "a plugin folder with a space: install refuses" \
	'|| refuse "the plugin folder $PLUG has characters' '|| true "the plugin folder $PLUG has characters'
mutant resurrect-dir-ignored install.sh case:rdir "@resurrect-dir: --check lists the panes saved there" \
	'	server_up && d=$(tmux show -gqv @resurrect-dir 2>/dev/null)
	[ -n "$d" ] || d=$(conf_opt @resurrect-dir)' '	true'
mutant lib-fixed-path claude-lib.sh case:xdg "the save hook records the claude pane" \
	'_rs=$(tmux show -gqv @resurrect-save-script-path 2>/dev/null); _rs=${_rs%/save.sh}' '_rs=""'

# whole_of <selection>: the whole suite it is part of.
whole_of() { case $1 in core) echo full ;; case:*) echo later ;; sweep:*) echo sweep ;; esac; }
# Host pressure: a sampler notes each second at which the host had less than 15% of its memory
# available, the kernel killed a process for memory, or tasks waited for a CPU 30% of the
# time or more (/proc/pressure/cpu, some avg10: a starved host stretches every wait of the
# suites). A run that overlaps one is not trusted.
# On TERM it ends its own sleep (its only job, from the fork on) and exits: none outlives it.
pressure_watch() {
	local k0 k t a c low=100 high=0
	trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
	k0=$(sed -n 's/^oom_kill //p' "$PROC/vmstat")
	while :; do
		k=$(sed -n 's/^oom_kill //p' "$PROC/vmstat")
		read -r t a < <(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t + 0, a + 0 }' "$PROC/meminfo")
		c=0; [ ! -r "$PROC/pressure/cpu" ] || c=$(sed -n 's/^some avg10=\([0-9]*\).*/\1/p' "$PROC/pressure/cpu")
		if [ "${k:-0}" != "${k0:-0}" ] || [ $((a * 100)) -lt $((t * 15)) ] || [ "${c:-0}" -ge 30 ]; then date +%s >> "$WORK/pressure"; k0=$k; fi
		# For the tally, the lowest share of memory available and the most CPU waiting; a
		# heartbeat: the time of the last sample.
		[ "$t" -le 0 ] || [ $((a * 100 / t)) -ge $low ] || { low=$((a * 100 / t)); echo $low > "$WORK/lowmem"; }
		[ "${c:-0}" -le "$high" ] || { high=$c; echo "$high" > "$WORK/highcpu"; }
		date +%s > "$WORK/sampled.new" && mv -f "$WORK/sampled.new" "$WORK/sampled"
		sleep 1 & wait $!
	done
}
# pressured <start> <end>: first waits for a sample taken after <end> (at most 3 s); a sampler
# that has stopped counts as pressure, never as none.
pressured() {
	local n
	for n in $(seq 30); do [ "$(cat "$WORK/sampled" 2>/dev/null || echo 0)" -gt "$2" ] && break; sleep 0.1; done
	[ "$(cat "$WORK/sampled" 2>/dev/null || echo 0)" -gt "$2" ] || return 0
	[ -f "$WORK/pressure" ] && awk -v s="$1" -v e="$2" '$1 >= s - 1 && $1 <= e + 1 { f = 1 } END { exit !f }' "$WORK/pressure"
}
# run_test <dir> <selection | later | sweep | full | base> <log>. A whole suite unsets the
# selection variables (one left in the environment would make it run part of itself) and runs
# one case at a time: JOBS of them already run side by side (base: the unmodified container.sh,
# 4 at a time). A run longer than its limit is stopped (TERM first: its own cleanup runs);
# that, and host pressure during the run, are marked in the log, and no verdict trusts it.
run_test() {
	local lim=$LIMIT s rc
	case $2 in sweep | later | full | base) lim=$((LIMIT * 3)) ;; esac
	s=$(date +%s)
	case $2 in
	sweep) timeout -k 60 "$lim" env -u TCR_SWEEP "$1/tests/killsweep.sh" ;;
	sweep:*) timeout -k 60 "$lim" env TCR_SWEEP="${2#sweep:}" "$1/tests/killsweep.sh" ;;
	later) timeout -k 60 "$lim" env TCR_JOBS=1 TCR_ONLY=later "$1/tests/container.sh" ;;
	full) timeout -k 60 "$lim" env -u TCR_ONLY TCR_JOBS=1 "$1/tests/container.sh" ;;
	base) timeout -k 60 "$lim" env -u TCR_ONLY TCR_JOBS=4 "$1/tests/container.sh" ;;
	core) timeout -k 60 "$lim" env TCR_ONLY=core "$1/tests/container.sh" ;;
	case:*) timeout -k 60 "$lim" env TCR_ONLY="${2#case:}" "$1/tests/container.sh" ;;
	esac > "$3" 2>&1
	rc=$?
	[ $(($(date +%s) - s)) -lt "$lim" ] || echo "== timed out" >> "$3"
	! pressured "$s" "$(date +%s)" || echo "== host pressure" >> "$3"
	return $rc
}
untrusted() { grep -qxE '== (timed out|host pressure)' "$1"; }
# A copy of the working tree (tracked and new files) plus .git: the tests need its history (the first commit).
# No fsmonitor: a daemon it started would carry the run's marker, and stop_all would end it.
copy_repo() { mkdir -p "$1" && git -C "$REPO" -c core.fsmonitor=false ls-files -z --cached --others --exclude-standard | (cd "$REPO" && xargs -0 cp --parents -t "$1" --) && cp -a "$REPO/.git" "$1/"; }
fails() { grep -cE '^ *FAIL ' "$1"; }
norm() { sed -nE 's/^ *(ok|FAIL) +//p'; }
# hits <log> <checks> <out>: the FAIL lines of the log that are exactly one of the checks, to
# <out>; fails when there is none. (No `grep -q` at the end of a pipe: under pipefail its early
# exit can fail the pipe on a long log, and a match would read as none.)
hits() { grep -E '^ *FAIL ' "$1" | norm | grep -xFf "$2" > "$3"; [ -s "$3" ]; }
# caught_exact <log> <id> <out>: the fast verdict. A FAIL on exactly one of the checks backed
# listed (to <out>), the machine of every selected case (or of the sweep) sound at the end,
# and a run that is trusted.
caught_exact() {
	hits "$1" "$WORK/m/$2.expect" "$3" || return 1
	! untrusted "$1" || return 1
	local c
	while read -r c; do grep -qx "== healthy $c" "$1" || return 1; done < "$WORK/m/$2.healthy"
}
# verdict <line>: print it; record its verdict and mutant id.
verdict() { local v i; echo "$*"; read -r v i _ <<<"$1"; echo "$v ${i%:}" >> "$WORK/verdicts"; }
# The baseline: both suites run unmodified at the start of this run (TCR_LOGS), in both modes.
# Every case must have passed with its machine sound, and the sweep too.
BASE_LOGS="$WORK/baseline"
baseline_ok() {
	grep -qE '^passed [1-9][0-9]* failed 0$' "$BASE_LOGS/$1/result" 2>/dev/null || return 1
	! untrusted "$WORK/base.$1.log" || return 1
	if [ "$1" = killsweep ]; then grep -qx '== healthy sweep' "$WORK/base.killsweep.log"; return; fi
	local c cases
	cases=$(sed -n 's/^CASES=(\(.*\))$/\1/p' "$WORK/base/tests/container.sh")
	[ -n "$cases" ] || return 1
	for c in $cases; do grep -qx "== healthy $c" "$BASE_LOGS/container/case.$c.log" 2>/dev/null || return 1; done
}
# backed <id>: fails, saying why, unless the baseline shows the expected check as ok in the
# mutant's selection, and each selected case or kind ran more than 0 checks there. Writes the
# checks that match to $WORK/<id>.expect (the fast verdict needs a FAIL on one of exactly
# those) and the names whose health line it needs to $WORK/<id>.healthy.
backed() {
	local s=${M_TEST[$1]} e=${M_EXPECT[$1]} x f n xs=() out="$WORK/m/$1.expect"
	: > "$out"; : > "$WORK/m/$1.healthy"
	case $s in
	core | case:*)
		if [ "$s" = core ]; then xs=(core); else IFS=, read -ra xs <<<"${s#case:}"; fi
		for x in "${xs[@]}"; do
			f="$BASE_LOGS/container/case.$x.log"
			[ -f "$f" ] || { echo "no baseline log for case $x"; return 1; }
			n=$(sed -n "s/^== counts $x \([0-9]*\) 0\$/\1/p" "$f")
			[ "${n:-0}" -gt 0 ] || { echo "case $x ran no checks, or failed, in the baseline"; return 1; }
			grep -E '^ *ok ' "$f" | norm | grep -F -- "$e" > "$out.$x"
			# Two checks of one name in a case: a FAIL of the other would count as this one.
			n=$(sort "$out.$x" | uniq -d | head -1)
			[ -z "$n" ] || { echo "the check \"$n\" occurs twice in case $x"; return 1; }
			cat "$out.$x" >> "$out"
			echo "$x" >> "$WORK/m/$1.healthy"
		done
		;;
	sweep:*)
		IFS=, read -ra xs <<<"${s#sweep:}"
		for x in "${xs[@]}"; do
			n=0
			for f in "$BASE_LOGS/killsweep"/res.*; do
				[ -f "$f" ] && [ "$(kind_of "${f##*/res.}")" = "$x" ] || continue
				n=$((n + 1))
				grep '^ok    ' "$f" | norm | grep -F -- "$e" >> "$out"
			done
			[ $n -gt 0 ] || { echo "kind $x has no case in the baseline"; return 1; }
		done
		echo sweep > "$WORK/m/$1.healthy"
		;;
	*) echo "unknown selection: $s"; return 1 ;;
	esac
	[ -s "$out" ] || { echo "no ok check with \"$e\" in the baseline of $s"; return 1; }
}
# full_expect <id>: the same for its whole suite, to $WORK/<id>.fexpect: every check that holds
# the expected text and was ok anywhere in that suite's baseline.
full_expect() {
	local w f out="$WORK/m/$1.fexpect"
	w=$(whole_of "${M_TEST[$1]}"); : > "$out"
	if [ "$w" = sweep ]; then
		for f in "$BASE_LOGS/killsweep"/res.*; do [ -f "$f" ] && grep '^ok    ' "$f" | norm | grep -F -- "${M_EXPECT[$1]}" >> "$out"; done
	else
		for f in "$BASE_LOGS/container"/case.*.log; do
			[ "$w" = full ] || [ "${f##*/}" != case.core.log ] || continue
			grep -E '^ *ok ' "$f" | norm | grep -F -- "${M_EXPECT[$1]}" > "$out.one"
			[ -z "$(sort "$out.one" | uniq -d)" ] || return 1
			cat "$out.one" >> "$out"
		done
	fi
	[ -s "$out" ]
}
# full_hits <log> <id>: each case of the whole-suite log (or "sweep") that failed one of those
# checks and whose machine was sound at its end, in log order; the FAIL lines of that case
# that match go to $WORK/m/<id>.fhit.<case>. Nothing for a run that is not trusted.
full_hits() {
	! untrusted "$1" || return 0
	local f="$WORK/m/$2.fexpect" out="$WORK/m/$2.fhit"
	if [ "$(whole_of "${M_TEST[$2]}")" = sweep ]; then
		if grep -qx '== healthy sweep' "$1" && hits "$1" "$f" "$out.sweep"; then echo sweep; fi
		return 0
	fi
	awk -v ex="$f" -v out="$out" '
		BEGIN { while ((getline l < ex) > 0) want[l] = 1 }
		/^== case / { c = ($3 ~ /^[a-z0-9]+$/) ? $3 : ""; n = 0; next }
		/^ *FAIL / { l = $0; sub(/^ *FAIL +/, "", l); if (c != "" && (l in want)) got[++n] = l; next }
		/^== healthy / { if ($3 == c && n > 0) { for (i = 1; i <= n; i++) print got[i] > (out "." c); close(out "." c); print c } }' "$1"
}
# all_sound <log> <id>: every machine of the whole-suite run sound at its end.
all_sound() {
	local c
	if [ "$(whole_of "${M_TEST[$2]}")" = sweep ]; then grep -qx '== healthy sweep' "$1"; return; fi
	for c in $(sed -n 's/^CASES=(\(.*\))$/\1/p' "$WORK/base/tests/container.sh"); do
		[ "$(whole_of "${M_TEST[$2]}")" = full ] || [ "$c" != core ] || continue
		grep -qx "== healthy $c" "$1" || return 1
	done
}

one() {
	local id=$1 d="$WORK/m/$1" m="$WORK/m/$1" log="$WORK/m/$1.log" how="" rc hs=() h again="" ok
	# From the copy the baseline ran on, not the live tree: an edit meanwhile changes nothing.
	cp -a "$WORK/base" "$d" || { verdict "BROKEN    $id: cannot copy the files"; rm -rf "$d"; return; }
	python3 -I - "$d/${M_FILE[$id]}" "${M_OLD[$id]}" "${M_NEW[$id]}" <<-'PY' || { verdict "BROKEN    $id: the text does not occur exactly once"; rm -rf "$d"; return; }
	import sys
	path, old, new = sys.argv[1:4]
	s = open(path).read()
	if s.count(old) != 1:
	    sys.exit(1)
	open(path, "w").write(s.replace(old, new))
	PY
	bash -n "$d/${M_FILE[$id]}" || { verdict "BROKEN    $id: syntax error after the change"; rm -rf "$d"; return; }
	if [ "$FULL" = 0 ]; then
		run_test "$d" "${M_TEST[$id]}" "$log"
		if caught_exact "$log" "$id" "$m.hit1"; then
			# Every CAUGHT needs the same check failing in a second run: a one-off failure of the
			# host, of docker or of timing never counts.
			run_test "$d" "${M_TEST[$id]}" "$log.2"
			if caught_exact "$log.2" "$id" "$m.hit2" && grep -qxFf "$m.hit1" "$m.hit2"; then
				verdict "CAUGHT    $id (${M_TEST[$id]}, twice, $(fails "$log") FAIL lines)"; rm -rf "$d"; return
			fi
		fi
		how=" (full)"
	fi
	run_test "$d" "$(whole_of "${M_TEST[$id]}")" "$log"; rc=$?
	mapfile -t hs < <(full_hits "$log" "$id")
	for h in "${hs[@]}"; do
		# The same again in that case (or those kinds of the sweep) alone.
		if [ "$h" = sweep ]; then
			run_test "$d" "sweep:$(sed 's/:.*//' "$m.fhit.sweep" | while read -r x; do kind_of "$x"; done | sort -u | paste -sd,)" "$log.3"
			ok=$(grep -qx '== healthy sweep' "$log.3" && echo y)
		else
			run_test "$d" "case:$h" "$log.3"
			ok=$(grep -qx "== healthy $h" "$log.3" && echo y)
		fi
		if [ -n "$ok" ] && ! untrusted "$log.3" && hits "$log.3" "$m.fhit.$h" "$m.fhit2"; then again=$h; break; fi
	done
	if [ -n "$again" ]; then
		verdict "CAUGHT    $id$how ($again, twice, $(fails "$log") FAIL lines)"
	elif [ ${#hs[@]} -gt 0 ]; then
		verdict "UNCLEAR   $id$how: failed in ${hs[*]}, but not again alone"
	elif grep -qx '== timed out' "$log"; then
		verdict "UNCLEAR   $id$how: the run took more than its limit"
	elif grep -qx '== host pressure' "$log"; then
		verdict "UNCLEAR   $id$how: the host was short of memory or CPU during the run, or not sampled; run it again"
	elif [ $rc = 0 ] && all_sound "$log" "$id"; then
		verdict "SURVIVED  $id$how"
	elif [ $rc = 0 ]; then
		verdict "UNCLEAR   $id$how: it passed, but a machine was not sound at its end; run it again"
	else
		verdict "UNCLEAR   $id$how: expected a FAIL on \"${M_EXPECT[$id]}\" in a sound case; got:"
		grep -E '^ *FAIL ' "$log" | head -3 | sed 's/^/            /'
	fi
	rm -rf "$d"
}

sel=("$@"); [ ${#sel[@]} -gt 0 ] || sel=("${IDS[@]}")
for id in "${sel[@]}"; do [[ $id =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -n "${M_FILE[$id]:-}" ] || { echo "unknown mutant: $id"; exit 2; }; done
[ "$(printf '%s\n' "${sel[@]}" | sort | uniq -d)" = "" ] || { echo "a mutant is named twice"; exit 2; }

# Every run here uses this one copy: the baseline, each mutant, and the image.
copy_repo "$WORK/base" || { echo "cannot copy the working tree"; exit 1; }
# One image and one plugin mirror for every run here, read-only to each; every pin must be in it.
IMG="tcr-mutants:$$-${WORK##*.}"
# Public repos: none of the caller's git config (an insteadOf to ssh, a helper daemon), no prompt;
# only what a clone through a proxy or with a CA of one's own needs. Read from it first, for
# github.com (a key for that URL only counts too), from no repo's config (none at or above the
# empty $WORK/m), and passed in the environment (GIT_CONFIG_COUNT, git 2.31 on) of the clone
# alone: never on a command line, where any local user could read a proxy's password.
gc=(); gn=0
for k in http.proxy http.sslCAInfo http.sslCAPath; do
	v=$(GIT_CEILING_DIRECTORIES=$WORK git -C "$WORK/m" config --get-urlmatch "$k" https://github.com/tmux-plugins/ 2>/dev/null) || continue
	gc+=("GIT_CONFIG_KEY_$gn=$k" "GIT_CONFIG_VALUE_$gn=$v"); gn=$((gn + 1))
done
# In the background and waited for: timeout runs its command in a group of its own, so a Ctrl-C
# reaches only this shell, and a foreground command would let it carry on; `wait` does not.
timeout 1800 docker build -q -t "$IMG" "$WORK/base/tests/sandbox" >/dev/null &
wait $! || { echo "docker build failed"; exit 2; }
for p in tpm tmux-resurrect tmux-continuum; do
	(export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=$gn "${gc[@]}"
		exec timeout 600 git -c credential.helper= clone -q --mirror "https://github.com/tmux-plugins/$p" "$WORK/mirror/$p") &
	wait $! || { echo "cannot clone $p for the mirror"; exit 2; }
done
pins=$(sed -n 's/^\t\[\(.*\)\]=\([0-9a-f]\{40\}\)$/\1 \2/p' "$WORK/base/install.sh" 2>/dev/null)
[ "$(grep -c . <<<"$pins")" = 3 ] || { echo "expected 3 plugin pins in install.sh, found: $pins"; exit 2; }
while read -r p sha; do
	git -C "$WORK/mirror/$p" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "the mirror of $p lacks its pin $sha"; exit 2; }
done <<<"$pins"
chmod -R a+rX "$WORK/mirror"
export TCR_IMAGE=$IMG TCR_MIRROR=$WORK/mirror

# Not a job of this shell (a subshell starts it), so no `wait` here waits for it.
# Its stderr off: stopping its sleep at the end makes bash print "Terminated".
( pressure_watch 2>/dev/null & echo $! > "$WORK/pw" )
PW=$(cat "$WORK/pw")

echo "== unmodified copy must pass first"
# Both suites at once, each case alone in a fresh container: the baseline every verdict is
# checked against, in both modes. Only these two runs save their logs.
mkdir -p "$BASE_LOGS"
TCR_LOGS=$BASE_LOGS run_test "$WORK/base" base "$WORK/base.container.log" &
TCR_LOGS=$BASE_LOGS run_test "$WORK/base" sweep "$WORK/base.killsweep.log" &
wait
for t in container killsweep; do
	baseline_ok $t || { echo "the unmodified copy fails tests, or a machine was not sound ($t); see:"; tail -5 "$WORK/base.$t.log" 2>/dev/null; exit 1; }
	echo "  ok    $t"
done

# Longest first: core, then the kill-sweep kinds, then single cases.
order=()
for id in "${sel[@]}"; do [ "${M_TEST[$id]}" != core ] || order+=("$id"); done
for id in "${sel[@]}"; do [[ ${M_TEST[$id]} != sweep:* ]] || order+=("$id"); done
for id in "${sel[@]}"; do [[ ${M_TEST[$id]} != case:* ]] || order+=("$id"); done
[ ${#order[@]} = ${#sel[@]} ] || { echo "a mutant has an unknown selection"; exit 2; }
echo "== ${#order[@]} mutants, $JOBS at a time$([ "$FULL" = 1 ] && echo ", whole suites")"
: > "$WORK/verdicts"
running=0
for id in "${order[@]}"; do
	# Its whole suite would be every case but core: it would never run the check. Both modes.
	if [[ ${M_TEST[$id]} == case:* ]] && [[ ,${M_TEST[$id]#case:}, == *,core,* ]]; then
		verdict "BROKEN    $id: core is its own selection (core), not case:core"; continue
	fi
	if [ "$FULL" = 0 ] && ! why=$(backed "$id"); then verdict "BROKEN    $id: $why"; continue; fi
	full_expect "$id" || { verdict "BROKEN    $id: no ok check with \"${M_EXPECT[$id]}\" in the baseline of its whole suite, or one of them twice in a case"; continue; }
	one "$id" &
	running=$((running + 1)); [ $running -ge "$JOBS" ] && { wait -n; running=$((running - 1)); }
done
wait
# Only while it is still the sampler (its PID carries the run's marker): a PID freed by a
# sampler that died is not ours to kill.
# It ends its own sleep on TERM (see pressure_watch); wait until it is gone (not a child of
# this shell: `wait` cannot).
if grep -qz "^TCR_PARENT=$TCR_PARENT\$" "/proc/$PW/environ" 2>/dev/null; then
	kill "$PW" 2>/dev/null
	for _ in $(seq 50); do [ -e "/proc/$PW" ] || break; sleep 0.1; done
fi
cpu=$(cat "$WORK/highcpu" 2>/dev/null || echo 0)%; [ -r "$PROC/pressure/cpu" ] || cpu="(not measured)"
echo "== the host: at least $(cat "$WORK/lowmem" 2>/dev/null || echo "?")% of memory available, tasks waited for a CPU at most $cpu of the time (not trusted: below 15%, 30% or more)"
for id in "${order[@]}"; do grep -qx "[A-Z]* $id" "$WORK/verdicts" || echo "NONE      $id: its job ended without a verdict"; done
echo "== $(awk '{print $1}' "$WORK/verdicts" | sort | uniq -c | awk '{printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2}')"
# Exit 0 only when every mutant was caught.
[ "$(awk '$1 != "CAUGHT"' "$WORK/verdicts" | wc -l)" = 0 ] && [ "$(wc -l < "$WORK/verdicts")" = ${#order[@]} ]
