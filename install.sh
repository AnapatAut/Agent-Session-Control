#!/usr/bin/env bash
# tmux-claude-restore installer: run AS the user who should get it (no sudo).
#   install.sh                         install, upgrade or repair; finishes an interrupted run
#   install.sh --check                 show status, change nothing
#   install.sh --uninstall             remove hooks, scripts, our systemd units
#   install.sh --uninstall --autoremove  also remove the tmux plugins and tmux.service that
#                                      install brought in, if unchanged and no longer needed
#   --dry-run (with install or --uninstall)  print the numbered steps, change nothing
# Exit status: 0 done; 1 refused, nothing changed; 2 usage; 3 stopped part-way (rerun the
# same command to finish it, or --uninstall); 4 --check found problems.
# Design (dpkg style): step 1 writes a manifest saying what the run is about to do, with
# "pending"; the last work step rewrites it without. Every file write is atomic. No step is
# ever undone: a failure, an interrupt or a kill leaves a state that a rerun finishes.
# Docs: README.md next to this file.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER="${USER:-$(id -un)}"
DEST="$HOME/.tmux/scripts"
# The config and plugin folder TPM uses, chosen the way TPM chooses them at our pin
# (_get_user_tmux_conf, set_default_tpm_path): the XDG file when it exists, else
# ~/.tmux.conf. tmux itself reads both. An install keeps the ones its manifest names.
HOME_CONF="$HOME/.tmux.conf"
XDG_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
if [ -f "$XDG_CONF" ]; then CONF=$XDG_CONF; PLUG="${XDG_CONF%/tmux.conf}/plugins"
else CONF=$HOME_CONF; PLUG="$HOME/.tmux/plugins"; fi
PICK_CONF=$CONF; PICK_PLUG=$PLUG
# Where a manifest without plugDir (written before there was a choice) has its plugins.
OLD_PLUG="$HOME/.tmux/plugins"
# Same dir tmux-continuum writes tmux.service to.
UNITS="$HOME/.config/systemd/user"
# The manifest: what is installed, and what a run in progress is about to do.
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-claude-restore"
MANIFEST="$STATE/manifest.json"
LAYOUT=1
# Temp files of atomic writes are named .<name>.tcr-tmp.XXXXXX; a killed run can leave one.
TMP_TAG=tcr-tmp
BEGIN='# >>> tmux-claude-restore >>>'
END='# <<< tmux-claude-restore <<<'
SCRIPTS=(claude-lib.sh claude-save.sh claude-restore.sh)
HOOK_SAVE='~/.tmux/scripts/claude-save.sh'
HOOK_RESTORE='~/.tmux/scripts/claude-restore.sh'
# Plugins from github.com/tmux-plugins, pinned to the commits this was tested with:
# claude-lib.sh sources tmux-resurrect internals, so an upstream change can break it.
PLUGINS=(tpm tmux-resurrect tmux-continuum)
declare -A PIN=(
	[tpm]=e261deb1b47614eed3400089ce7197dc68acc4eb
	[tmux-resurrect]=cff343cf9e81983d3da0c8562b01616f12e8d548
	[tmux-continuum]=0698e8f4b17d6454c71bf5212895ec055c578da0
)
# Autosave without an attached client: tmux-continuum saves from the status line,
# which tmux only evaluates while a client is attached.
AUTOSAVE=tmux-claude-autosave
# Drop-ins for tmux-continuum's tmux.service and for every tmux pane scope
# (tmux-spawn-*.scope); see unit_text stop / scope.
DROPIN="$UNITS/tmux.service.d/tmux-claude-restore.conf"
SCOPE_DROPIN="$UNITS/tmux-spawn-.scope.d/tmux-claude-restore.conf"
UNIT_KINDS=(service timer stop scope)
TMUX_SERVICE="$UNITS/tmux.service"
# For every git call: a gitconfig of the user's could make git start a process that outlives
# the run and keeps the lock (an fsmonitor hook such as watchman's, a detached gc or
# maintenance). -c, not exported variables: a tmux server started here keeps its environment.
GITQ=(-c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false)

# ---------------------------------------------------------------- output
# A closed stdout (`install.sh | head`, a gone terminal) must never stop a run: ignore
# SIGPIPE, and after the first failed write send all output to /dev/null.
trap '' PIPE
out()  { printf '%s\n' "$*" 2>/dev/null || exec >/dev/null 2>&1; }
say()  { out "  $*"; }
ok()   { out "  [ok]   $*"; }
warn() { out "  [warn] $*"; }
bad()  { out "  [FAIL] $*"; }
server_up() { tmux list-sessions >/dev/null 2>&1; }
have_systemd() { systemctl --user show-environment >/dev/null 2>&1; }
# systemd's own test for "booted with systemd" (sd_booted(3)).
booted_systemd() { [ -d /run/systemd/system ]; }
# Value of `set -g <option>` in config $2 (default ~/.tmux.conf; last one wins), quotes stripped.
conf_opt() {
	sed -nE "s/^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+$1[[:space:]]+['\"]?([^'\"[:space:]]*).*/\2/p" "${2:-$CONF}" 2>/dev/null | tail -n1
}
sha_of() { if [ -f "$1" ]; then sha256sum < "$1" | cut -d' ' -f1; fi; }
# $PLUG as the config's run line and the units write it: ~/… (or %h/…) inside the home.
plug_in() { case "$PLUG" in "$HOME"/*) echo "$1/${PLUG#"$HOME"/}" ;; *) echo "$PLUG" ;; esac; }
# tmux-resurrect's save folder, found the way tmux-resurrect finds it (resurrect_dir in
# scripts/helpers.sh at our pin): @resurrect-dir with ~, $HOME and $HOSTNAME expanded, else
# ~/.tmux/resurrect if it exists, else the XDG data folder.
map_dir() {
	local d=""
	server_up && d=$(tmux show -gqv @resurrect-dir 2>/dev/null)
	[ -n "$d" ] || d=$(conf_opt @resurrect-dir)
	if [ -z "$d" ]; then
		if [ -d "$HOME/.tmux/resurrect" ]; then d="$HOME/.tmux/resurrect"
		else d="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"; fi
	fi
	d=${d//\$HOME/$HOME}
	[[ $d != *"\$HOSTNAME"* ]] || d=${d//\$HOSTNAME/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)}
	echo "${d//\~/$HOME}"
}
# Paths from the manifest in $1: the config and plugin folder that install used.
use_manifest_paths() {
	local c
	c=$(jq -r '.conf.path // empty' <<<"$1"); [ -z "$c" ] || CONF=$c
	PLUG=$(jq -r --arg d "$OLD_PLUG" '.plugDir // $d' <<<"$1")
}
# Is tmux-resurrect, in the live server, the one in $PLUG? It sets this option when it loads.
resurrect_loaded() {
	local sp
	sp=$(tmux show -gqv @resurrect-save-script-path 2>/dev/null)
	[ -n "$sp" ] && [ "$(readlink -f -- "$sp")" = "$(readlink -f -- "$PLUG/tmux-resurrect/scripts/save.sh")" ]
}
# JSON string, or null for an empty value.
jstr() { if [ -n "$1" ]; then jq -n --arg v "$1" '$v'; else echo null; fi; }

# ---------------------------------------------------------------- run state and exit
# STEP: 0 while planning (nothing changed yet), else the step running now.
STEP=0; NSTEPS=0; FINAL=""; INTR=0; ERR_CMD=""; CREATED_STATE=(); TS_NEW=0
# Uninstall: the other config file (not the manifest's) -> its bytes once our lines are out.
declare -A OTHER_AFTER=()
TEMPS=(); WORK=""
# Deliberate ends. refuse: before step 1, nothing changed. fail: a step could not finish.
refuse() { out "  refused: $*"; FINAL=1; exit 1; }
fail() {
	out "  FAILED at step $STEP of $NSTEPS: $*"
	out "  steps 1 to $((STEP - 1)) are done; fix the cause and rerun the same command to finish it, or run $0 --uninstall"
	FINAL=3; exit 3
}
on_err() { ERR_CMD="$BASH_COMMAND (line $1)"; }
on_exit() {
	local rc=$?
	[ ${#TEMPS[@]} -gt 0 ] && rm -f -- "${TEMPS[@]}"
	[ -n "$WORK" ] && rm -rf -- "$WORK"
	if [ "$STEP" = 0 ] && [ ${#CREATED_STATE[@]} -gt 0 ]; then
		# Refused or stopped while planning: take back the state folder this run created.
		local i
		for ((i = ${#CREATED_STATE[@]} - 1; i >= 0; i--)); do rmdir "${CREATED_STATE[i]}" 2>/dev/null || break; done
	fi
	if [ -z "$FINAL" ] && [ "$rc" != 0 ]; then
		# An unexpected error (set -e). Before step 1 nothing was changed; after, the
		# manifest says pending and a rerun finishes it.
		if [ "$STEP" -gt 0 ]; then
			out "  FAILED at step $STEP of $NSTEPS: ${ERR_CMD:-unexpected error} (exit $rc)"
			out "  steps 1 to $((STEP - 1)) are done; rerun the same command to finish it, or run $0 --uninstall"
			exit 3
		fi
		out "  error before any change: ${ERR_CMD:-unexpected error} (exit $rc)"
		exit 1
	fi
	exit "${FINAL:-$rc}"
}
# Ctrl-C, SIGTERM, SIGHUP (passed on by supervise as SIGUSR1). The first one stops the run
# after the current step; a second one stops it at once (every write is atomic and the
# manifest came first, so that is safe). While planning, nothing has changed yet: stop at
# once with exit 1. A signal that was ignored on entry (nohup) stays ignored: bash cannot
# trap it.
on_signal() {
	if [ "$STEP" = 0 ]; then out "  interrupted before any change"; FINAL=1; exit 1; fi
	if [ "$INTR" = 1 ]; then out "  stopped at once during step $STEP; rerun the same command to finish it"; FINAL=3; exit 3; fi
	INTR=1
	printf '%s\n' "  interrupted: stopping after the current step (interrupt again to stop at once)" >&2 2>/dev/null || true
}
trap 'on_err $LINENO' ERR
trap on_exit EXIT
trap on_signal INT TERM HUP USR1

# Test hook: TCR_FAILPOINT=step:<k> or write:<file name> makes the run SIGKILL itself
# there, leaving exactly what kill -9 or a power cut would leave.
failpoint() { if [ "${TCR_FAILPOINT:-}" = "$1" ]; then kill -KILL $$ "$BASHPID"; fi; }

# ---------------------------------------------------------------- durable writes
# atomic_write <path> <mode or ""> < content
# Writes a temp file beside the real file (through a symlink: a dotfile manager's link
# stays a link), fsyncs it, renames it over the file, fsyncs the folder. A reader sees the
# old file or the new one, never a cut one. Mode "": keep the old file's, or 0666 - umask.
atomic_write() {
	local path=$1 mode=$2 real dir tmp
	real=$(readlink -f -- "$path"); dir=$(dirname -- "$real")
	tmp=$(mktemp "$dir/.$(basename -- "$real").$TMP_TAG.XXXXXX")
	TEMPS+=("$tmp")
	cat > "$tmp"
	if [ -n "$mode" ]; then chmod "$mode" "$tmp"
	elif [ -e "$real" ]; then chmod --reference="$real" "$tmp"
	else chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp"; fi
	sync -- "$tmp"
	failpoint "write:$(basename -- "$real")"
	mv -f -- "$tmp" "$real"
	sync -- "$dir"
	TEMPS=("${TEMPS[@]:0:${#TEMPS[@]}-1}")
}
remove_file() { [ -e "$1" ] || [ -L "$1" ] || return 0; rm -f -- "$1"; sync -- "$(dirname -- "$1")"; }
# Missing folders on the way to $1, outermost first (they are what a mkdir -p would create).
missing_dirs() {
	local d=$1 list=()
	while [ ! -e "$d" ] && [ "$d" != / ]; do list=("$d" "${list[@]}"); d=$(dirname -- "$d"); done
	[ ${#list[@]} = 0 ] || printf '%s\n' "${list[@]}"
}
# Temp files a killed write left beside the files we write, and half-done plugin clones.
stale_temps() {
	local d p
	for d in "$(dirname -- "$(readlink -f -- "$CONF" 2>/dev/null || echo "$CONF")")" "$DEST" "$UNITS" \
		"$(dirname -- "$DROPIN")" "$(dirname -- "$SCOPE_DROPIN")" "$STATE"; do
		[ -d "$d" ] && find "$d" -maxdepth 1 -type f -name ".*.$TMP_TAG.*" -user "$(id -u)"
	done
	for p in "${PLUGINS[@]}"; do [ -d "$PLUG/.$p.tmp" ] && echo "$PLUG/.$p.tmp"; done
	return 0
}
remove_stale_temps() { local f; while IFS= read -r f; do rm -rf -- "$f"; done < <(stale_temps); }

# ---------------------------------------------------------------- children
# run_child <timeout s> <command...>: for every command that changes something. Own session
# (a terminal's Ctrl-C reaches only this script), no stdin, output to temp files rather
# than a pipe (a pipe would kill the child mid-write if this script exits). It holds the lock
# too, so a child still running after a second interrupt keeps a rerun out until it ends;
# except tmux, whose server would keep the lock for good. An interrupt never kills it; only
# its time limit does (timeout signals the whole process group).
run_child() {
	local limit=$1 o e pid rc seen; shift
	o=$(mktemp "$STATE/.child-out.$TMP_TAG.XXXXXX"); e=$(mktemp "$STATE/.child-err.$TMP_TAG.XXXXXX")
	TEMPS+=("$o" "$e")
	( trap - PIPE INT TERM HUP; [ "$1" != tmux ] || exec 9<&-; exec setsid -w timeout -k 10 "$limit" "$@" ) </dev/null >"$o" 2>"$e" &
	pid=$!
	# wait returns early when a trapped signal arrives; keep waiting while the child runs.
	# After the child has ended, a second wait still returns its saved exit status.
	while :; do
		seen=$INTR
		rc=0; wait "$pid" || rc=$?
		if [ "$rc" -gt 128 ] && [ "$INTR" != "$seen" ]; then continue; fi
		break
	done
	CHILD_OUT=$(cat "$o"); CHILD_ERR=$(cat "$e")
	rm -f -- "$o" "$e"; TEMPS=("${TEMPS[@]:0:${#TEMPS[@]}-2}")
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then CHILD_ERR="timed out after ${limit}s: $*"; fi
	return "$rc"
}
# Same, but a failure fails the step with the child's own message.
must() { run_child "$@" || fail "$(printf '%s\n' "${CHILD_ERR:-$*}" | sed '/^[[:space:]]*$/d' | tail -n3)"; }

# ---------------------------------------------------------------- unit and config texts
unit_path() {
	case "$1" in
	service) echo "$UNITS/$AUTOSAVE.service" ;;
	timer) echo "$UNITS/$AUTOSAVE.timer" ;;
	stop) echo "$DROPIN" ;;
	scope) echo "$SCOPE_DROPIN" ;;
	esac
}

# Text of systemd unit file $1 (see UNIT_KINDS).
# service + timer: the autosave timer. It calls tmux-continuum's own save script,
# which saves only when its interval has passed and holds a lock, so it never
# doubles up with the status-line autosave.
# stop: tmux.service's ExecStop runs tmux-resurrect's save.sh directly. systemd also
# runs ExecStop after the tmux server died (crash, kill -9, OOM kill); save.sh then
# writes an empty save and points `last` at it, so the next start restores nothing.
# Save through the server instead: with no server, `tmux run-shell` fails and
# nothing is written.
# scope: tmux runs each pane in its own tmux-spawn-*.scope, outside tmux.service.
# At shutdown systemd stops those scopes (claude exits on SIGTERM) in parallel with
# tmux.service's save, which then records no claude. Before=tmux.service makes
# systemd stop tmux.service, and so save, while the panes still run.
unit_text() {
	case "$1" in
	service) cat <<-EOF
		# Managed by tmux-claude-restore install.sh; edits here are overwritten.
		[Unit]
		Description=tmux-continuum autosave check without an attached tmux client
		After=tmux.service

		[Service]
		Type=oneshot
		# '-': no tmux server running is not a failure.
		ExecStart=-$(command -v tmux) run-shell -b $(plug_in %h)/tmux-continuum/scripts/continuum_save.sh
		# One run a minute: keep the journal free of its start/finish lines.
		LogLevelMax=notice
		EOF
		;;
	timer) cat <<-EOF
		# Managed by tmux-claude-restore install.sh; edits here are overwritten.
		[Unit]
		Description=tmux-continuum autosave check every minute

		[Timer]
		OnBootSec=1min
		OnUnitActiveSec=1min

		[Install]
		WantedBy=timers.target
		EOF
		;;
	stop) cat <<-EOF
		# Managed by tmux-claude-restore install.sh; edits here are overwritten.
		# Replaces tmux-continuum's ExecStop lines: save only through a live server.
		[Service]
		ExecStop=
		ExecStop=-$(command -v tmux) run-shell "$(plug_in %h)/tmux-resurrect/scripts/save.sh quiet"
		ExecStop=-$(command -v tmux) kill-server
		EOF
		;;
	scope) cat <<-EOF
		# Managed by tmux-claude-restore install.sh; edits here are overwritten.
		# Applies to every tmux pane scope: stop it only after tmux.service has saved.
		[Unit]
		Before=tmux.service
		EOF
		;;
	esac
}

# Managed block for config file $1 (which must already have our old block removed).
# Skips a plugin line the user already has, and any option the user already sets
# (their value wins).
block() {
	local rest="$1" line key
	echo "$BEGIN (managed by $SRC/install.sh; edits here are overwritten)"
	while IFS= read -r line; do
		key=$(awk '{print $3}' <<<"$line")
		if [ "$key" = @plugin ]; then
			# A real `set -g @plugin` line, not one in a comment.
			grep -qE "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+['\"]?((https://|git@)github\.com[:/])?$(sed -E "s/.*@plugin '([^']*)'.*/\1/" <<<"$line")(\.git)?['\"]?([[:space:]]|\$)" "$rest" && continue
		else
			grep -qE "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+${key}[[:space:]]" "$rest" && continue
		fi
		echo "$line"
	done <<-'LINES'
	set -g @plugin 'tmux-plugins/tpm'
	set -g @plugin 'tmux-plugins/tmux-resurrect'
	set -g @plugin 'tmux-plugins/tmux-continuum'
	set -g @resurrect-capture-pane-contents 'on'
	set -g @continuum-save-interval '5'
	set -g @continuum-restore 'on'
	set -g @continuum-boot 'on'
	LINES
	echo "set -g @resurrect-hook-post-save-all '$HOOK_SAVE'"
	echo "set -g @resurrect-hook-post-restore-all '$HOOK_RESTORE'"
	echo "$END"
}

# Print config $1 without our managed block (plus the blank line after it) and
# without hand-added copies of our hook lines from before the installer existed.
strip_conf() {
	awk -v b="$BEGIN" -v e="$END" '
		index($0, b) == 1 { skip = 1; next }
		skip && index($0, e) == 1 { skip = 0; eat_blank = 1; next }
		skip { next }
		eat_blank && /^[[:space:]]*$/ { eat_blank = 0; next }
		{ eat_blank = 0 }
		/@resurrect-hook-post-(save|restore)-all .*\.tmux\/scripts\/claude-/ { next }
		/^# Relaunch Claude Code conversations per pane after restore/ { next }
		{ print }' "$1"
}
# Are our block markers in config $1 broken (a begin without an end, an end without a
# begin)? strip_conf would then remove the wrong lines, so install and uninstall refuse.
block_broken() {
	[ -f "$1" ] || return 1
	awk -v b="$BEGIN" -v e="$END" '
		index($0, b) == 1 { if (open) bad = 1; open = 1; next }
		index($0, e) == 1 { if (!open) bad = 1; open = 0 }
		END { exit !(bad || open) }' "$1"
}
# Does config $1 hold anything strip_conf removes?
has_ours() {
	grep -qF "$BEGIN" "$1" 2>/dev/null \
		|| grep -qE '@resurrect-hook-post-(save|restore)-all .*\.tmux/scripts/claude-|^# Relaunch Claude Code conversations per pane after restore' "$1" 2>/dev/null
}
# keep_nl <original> <result>: awk ends every line with a newline. If the original's last
# line had none and is still the result's last line, take that newline off again.
keep_nl() {
	[ -s "$1" ] && [ -s "$2" ] || return 0
	[ -z "$(tail -c1 "$1")" ] && return 0
	[ "$(tail -n1 "$1")" = "$(tail -n1 "$2")" ] && [ -z "$(tail -c1 "$2")" ] && truncate -s -1 "$2"
	return 0
}
# gen_conf <current config> <out>: the config with our current block, in the place TPM needs.
gen_conf() {
	local tmp blk
	tmp="$WORK/gen.rest"
	strip_conf "$1" > "$tmp"
	blk=$(block "$tmp")
	if grep -qE "^[[:space:]]*run(-shell)? .*tpm/tpm" "$tmp"; then
		# Plugin options must come before TPM's run line: insert block above it
		# (and above a comment line directly on top of it).
		awk -v blk="$blk" '
			done { print; next }
			held != "" && /^[[:space:]]*run(-shell)? .*tpm\/tpm/ { print blk; print ""; print held; print; held = ""; done = 1; next }
			held != "" { print held; held = "" }
			/^#/ { held = $0; next }
			/^[[:space:]]*run(-shell)? .*tpm\/tpm/ { print blk; print ""; print; done = 1; next }
			{ print }
			END { if (held != "") print held }' "$tmp" > "$2"
	else
		{ [ -s "$tmp" ] && { cat "$tmp"; echo; }
		  echo "$blk"; echo; echo "# Initialize TPM (keep this line at the very bottom)"; echo "run '$(plug_in '~')/tpm/tpm'"; } > "$2"
	fi
	keep_nl "$1" "$2"
}
# Does config $1 still need plugin $2 (an @plugin line in any form tpm takes, or for tpm
# also its run line)? A config that sources another file may name it there: keep them all.
conf_needs() {
	[ -f "$1" ] || return 1
	grep -qE "^[[:space:]]*source(-file)?[[:space:]]" "$1" && return 0
	grep -qE "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+['\"]?((https://|git@)github\.com[:/])?tmux-plugins/$2(\.git)?['\"]?" "$1" && return 0
	[ "$2" = tpm ] && grep -qE "^[[:space:]]*run(-shell)? .*tpm/tpm" "$1"
}

# ---------------------------------------------------------------- manifest
# Sets M to the manifest's JSON ("" if there is none) and MJ to it or {}. Refuses one that
# is not ours (atomic writes mean it cannot be a cut one).
load_manifest() {
	M=""; MJ='{}'; PLAN_FP=$(sha_of "$MANIFEST")
	[ -e "$MANIFEST" ] || return 0
	jq -e --argjson l "$LAYOUT" 'type == "object" and .layout == $l
		and ((.pending | type) == "string" or .pending == null)' "$MANIFEST" >/dev/null 2>&1 \
		|| refuse "$MANIFEST is not a valid tmux-claude-restore manifest (layout $LAYOUT). Restore it, or move it away and run install.sh again"
	M=$(cat "$MANIFEST"); MJ=$M
}
# Not `jq … | atomic_write`: a pipeline would run the write in a subshell.
# Folders named by a temp manifest that a kill left inside the first manifest write (it is
# complete once synced; a cut one is ignored): with no manifest yet, nothing else records them.
stale_manifest_dirs() {
	local f
	if [ -e "$MANIFEST" ]; then echo '[]'; return 0; fi
	for f in "$STATE"/.manifest.json."$TMP_TAG".*; do
		[ -f "$f" ] && jq -c '.createdDirs // empty' "$f" 2>/dev/null
	done | jq -sc 'add // []'
}
# The JSON is checked first: an empty or cut argument (a jq that failed inside "$(…)", which
# set -e does not see) must never replace the manifest.
write_manifest() {
	local j
	j=$(jq -e 'if type == "object" and .layout then . else error("not a manifest") end' <<<"$1" 2>/dev/null) \
		|| fail "could not build the manifest (out of memory or disk?)"
	atomic_write "$MANIFEST" 0600 <<<"$j"
}
mget() { jq -r "$1 // empty" <<<"${2:-$M}"; }

# ---------------------------------------------------------------- the plan
# add_step <description> <function> [args...]: one numbered step. Every step is safe to run
# twice: a rerun repeats the step that failed, and maybe one a kill cut short.
STEP_DESC=(); STEP_CMD=()
add_step() { STEP_DESC+=("$1"); shift; STEP_CMD+=("$(printf '%q ' "$@")"); }
run_steps() {
	NSTEPS=${#STEP_DESC[@]}
	local k
	for ((k = 1; k <= NSTEPS; k++)); do
		if [ "$INTR" = 1 ]; then
			out "  stopped before step $k of $NSTEPS; rerun the same command to finish it"
			FINAL=3; exit 3
		fi
		failpoint "step:$k"
		STEP=$k
		out "step $k/$NSTEPS: ${STEP_DESC[k-1]}"
		eval "${STEP_CMD[k-1]}"
	done
	failpoint "step:$((NSTEPS + 1))"
}
print_plan() {
	local k
	out "Would run (--dry-run; nothing changed):"
	for ((k = 1; k <= ${#STEP_DESC[@]}; k++)); do out "  step $k: ${STEP_DESC[k-1]}"; done
	[ ${#STEP_DESC[@]} -gt 0 ] || out "  nothing to do"
}

# Common start of install and uninstall: refusals that need no plan, then the lock.
# Root would write root-owned files into the user's home, or install for root.
preflight() {
	if [ "$(id -u)" = 0 ]; then refuse "running as root; run it as the user who should get it, without sudo"; fi
	local c
	for c in "$@"; do command -v "$c" >/dev/null || refuse "$c is required"; done
	if command -v git >/dev/null; then
		# Run from a git hook or a vcsh/yadm shell, these would point git at another repository.
		# shellcheck disable=SC2046
		unset $(git rev-parse --local-env-vars)
	fi
	SD=none
	if booted_systemd; then
		have_systemd || refuse "this machine runs systemd, but your systemd user manager is not reachable from this shell (a su shell, or ssh without a login session?); run it from a login session of $USER"
		SD=user
	fi
	WORK=$(mktemp -d)
}
# Part of step 1, so a kill before step 1 leaves nothing behind. Planning runs unlocked;
# if another run changed the manifest meanwhile, refuse rather than act on a stale plan.
# Both refusals change nothing: on_exit removes the state folders created here (STEP=0).
take_lock() {
	local d
	# A refusal takes back only the folders this run made: a run racing this one may make one first.
	while IFS= read -r d; do
		if mkdir -m 0700 -- "$d" 2>/dev/null; then CREATED_STATE+=("$d")
		elif [ ! -d "$d" ]; then STEP=0; refuse "cannot create $d"; fi
	done < <(missing_dirs "$STATE")
	exec 9<"$STATE"
	# Lost the lock: the run that holds it works in these folders (and recorded them when it
	# planned), so they are not taken back.
	flock -n 9 || { CREATED_STATE=(); STEP=0; refuse "another tmux-claude-restore run is working for $USER"; }
	# Locked a folder another run removed just before: the lock would guard nothing.
	[ "$(stat -c %d:%i -- "$STATE" 2>/dev/null)" = "$(stat -L -c %d:%i /proc/$BASHPID/fd/9)" ] \
		|| { CREATED_STATE=(); STEP=0; refuse "another run changed the install while this one was planning; run it again"; }
	[ "$(sha_of "$MANIFEST")" = "$PLAN_FP" ] || { STEP=0; refuse "another run changed the install while this one was planning; run it again"; }
}

# ---------------------------------------------------------------- install
plan_install() {
	load_manifest
	local pending residual=0
	pending=$(mget .pending)
	[ "$pending" = uninstall ] && refuse "an uninstall did not finish; run $0 --uninstall to finish it, then install"
	[ -n "$M" ] && [ "$(mget .residual)" = true ] && residual=1
	[ -n "$pending" ] && out "  an earlier run ($pending) did not finish; finishing it"
	PREV=null; KIND=install
	if [ -n "$M" ] && [ $residual = 0 ]; then
		# The user moved to the other config file since: the block, the plugins and the
		# records are all at the old place. Uninstall works from the manifest's paths.
		use_manifest_paths "$M"
		[ "$CONF" = "$PICK_CONF" ] && [ "$PLUG" = "$PICK_PLUG" ] \
			|| refuse "tmux plugins now load as $PICK_CONF says (from $PICK_PLUG), but this install is in $CONF ($PLUG); run $0 --uninstall, then $0"
		KIND=${pending:-upgrade}
		if [ -n "$pending" ]; then PREV=$(jq -c '.previous // null' <<<"$M")
		else PREV=$(jq -c 'del(.pending)' <<<"$M"); fi
	fi
	local changed=0 f s k sha
	# A block of ours, or our hand-added hook lines, in the config TPM does not read.
	if [ "$CONF" != "$HOME_CONF" ] && has_ours "$HOME_CONF"; then
		refuse "an earlier install is in $HOME_CONF, but tmux plugins now load as $CONF says; run $0 --uninstall, then $0"
	fi
	# TPM would load the plugins from that folder instead; not supported.
	for f in "$HOME_CONF" "$XDG_CONF"; do
		if grep -qE '^[[:space:]]*(set-environment|setenv)[[:space:]].*TMUX_PLUGIN_MANAGER_PATH' "$f" 2>/dev/null; then
			refuse "$f sets TMUX_PLUGIN_MANAGER_PATH; plugins in a folder of your own are not supported"
		fi
	done
	# The run line and the units name the folder unquoted (tmux's sh -c, systemd's ExecStart).
	[[ $(plug_in '~') =~ ^[~A-Za-z0-9._/+@-]+$ ]] || refuse "the plugin folder $PLUG has characters (a space?) the config's run line and the systemd units cannot hold"
	# A residual record is of plugins in its own folder; with another one now, it is dropped.
	if [ $residual = 1 ] && [ "$(jq -r --arg d "$OLD_PLUG" '.plugDir // $d' <<<"$M")" != "$PLUG" ]; then
		warn "plugins kept by an earlier uninstall in $(jq -r --arg d "$OLD_PLUG" '.plugDir // $d' <<<"$M") are no longer tracked; remove them by hand if you do not use them"
		MJ=$(jq -c '.plugins = {}' <<<"$MJ")
	fi

	# Plugins: cloned when missing. "cloned" marks what install brought in (for --autoremove).
	PLUGREC='{}'
	local p cloned fresh=0
	for p in "${PLUGINS[@]}"; do
		cloned=$(jq -r --arg p "$p" '.plugins[$p].cloned // false' <<<"$MJ")
		if [ ! -d "$PLUG/$p" ]; then cloned=true; add_step "clone plugin $p at ${PIN[$p]:0:7}" step_clone "$p"; changed=1; fresh=1; fi
		PLUGREC=$(jq --arg p "$p" --arg pin "${PIN[$p]}" --argjson c "$cloned" '.[$p] = {pin: $pin, cloned: $c}' <<<"$PLUGREC")
	done

	# Scripts and unit files: ours; written whenever their hash differs.
	FILES='{}'
	local -a wfiles=()
	for s in "${SCRIPTS[@]}"; do
		cp "$SRC/$s" "$WORK/$s"; wfiles+=("$DEST/$s|$WORK/$s|0755")
	done
	if [ "$SD" = user ]; then
		while IFS= read -r k; do unit_text "$k" > "$WORK/unit.$k"; wfiles+=("$(unit_path "$k")|$WORK/unit.$k|0644"); done < <(unit_kinds)
		own_tmux_service && warn "$TMUX_SERVICE is your own (not tmux-continuum's): not adding our stop drop-in to it"
	fi
	local spec path srcf mode
	for spec in "${wfiles[@]}"; do
		IFS='|' read -r path srcf mode <<<"$spec"
		sha=$(sha_of "$srcf")
		FILES=$(jq --arg p "$path" --arg s "$sha" --arg m "$mode" --argjson w "$(jstr "$(sha_of "$path")")" \
			'.[$p] = {sha256: $s, mode: $m, was: $w}' <<<"$FILES")
		if [ "$(sha_of "$path")" != "$sha" ] || [ "$(stat -c %a "$path" 2>/dev/null)" != "${mode#0}" ]; then
			add_step "write $path" step_write "$path" "$srcf" "$mode"; changed=1
		fi
	done

	# The config. Records for uninstall come from the first install and are carried over.
	local real cur new existed original restore
	real=$(readlink -f -- "$CONF" 2>/dev/null) || refuse "$CONF is a link into a folder that does not exist"
	[ -w "$(dirname -- "$real")" ] || refuse "cannot write $(dirname -- "$real") (the folder $CONF lives in); is it read-only?"
	cur="$WORK/conf.cur"; new="$WORK/conf.new"
	if [ -e "$real" ]; then cp "$real" "$cur"; else : > "$cur"; fi
	gen_conf "$cur" "$new"
	if [ -n "$M" ] && [ $residual = 0 ]; then
		existed=$(jq -c '.conf.existed' <<<"$M"); original=$(jq -c '.conf.original' <<<"$M"); restore=$(jq -c '.conf.restore' <<<"$M")
	elif [ ! -e "$real" ]; then
		existed=false; original=null; restore=null
	elif has_ours "$cur"; then
		# Installed before there was a manifest: the original is the config without our parts.
		strip_conf "$cur" > "$WORK/conf.orig"; keep_nl "$cur" "$WORK/conf.orig"
		existed=true; original=$(jstr "$(base64 -w0 < "$WORK/conf.orig")"); restore=$original
		[ -s "$WORK/conf.orig" ] || { original='""'; restore='""'; }
	else
		existed=true; original=$(jq -n --arg v "$(base64 -w0 < "$cur")" '$v'); restore=$original
	fi
	local was_conf="" nb=""; [ -e "$real" ] && was_conf=$(sha_of "$real")
	block_broken "$cur" && refuse "the tmux-claude-restore block in $CONF has a begin line without an end line (or the reverse); fix the markers by hand"
	strip_conf "$new" > "$WORK/conf.nb"
	# What the config said outside our block at the first install. Uninstall writes back the
	# original bytes only while that still holds, so later edits of the user's are kept.
	if [ -n "$M" ] && [ $residual = 0 ]; then nb=$(mget .conf.withoutBlock); fi
	[ -n "$nb" ] || nb=$(sha_of "$WORK/conf.nb")
	CONFREC=$(jq -n --arg p "$CONF" --argjson e "${existed:-true}" --argjson o "$original" --argjson r "$restore" \
		--arg s "$(sha_of "$new")" --argjson w "$(jstr "$was_conf")" --arg nb "$nb" \
		'{path: $p, existed: $e, original: $o, restore: $r, sha256: $s, was: $w, withoutBlock: $nb}')
	if [ "$was_conf" != "$(sha_of "$new")" ]; then add_step "write $CONF" step_conf "$new"; changed=1; fi

	# tmux.service: tmux-continuum writes it on its first load with @continuum-boot 'on'.
	# It counts as brought in only with the hash of the file a run saw appear: a record
	# without one would later take in whatever tmux.service is there, even the user's.
	local created ts_sha
	created=$(jq -r '.tmuxService.created // false' <<<"$MJ"); ts_sha=$(jq -c '.tmuxService.sha256 // null' <<<"$MJ")
	if [ "$SD" = user ] && [ ! -e "$TMUX_SERVICE" ] && [ "$(conf_opt @continuum-boot "$new")" = on ]; then created=true; TS_NEW=1; fi
	# A killed run that planned it may have seen it appear and died before recording the hash.
	if [ -n "$pending" ] && [ "$created" = true ] && [ "$ts_sha" = null ] && [ -e "$TMUX_SERVICE" ] && ! own_tmux_service; then TS_NEW=1; fi
	if [ "$created" = true ] && [ "$ts_sha" = null ] && [ $TS_NEW = 0 ]; then created=false; fi
	TSVC=$(jq -n --argjson c "$created" --argjson s "$ts_sha" '{created: $c, sha256: $s}')

	# Folders this run creates, plus those an earlier run recorded.
	DIRS=$(jq -c --argjson s "$(stale_manifest_dirs)" '(.createdDirs // []) + $s | unique' <<<"$MJ")
	local d
	for d in "$STATE" "$PLUG" "$DEST" "$(dirname -- "$DROPIN")" "$(dirname -- "$SCOPE_DROPIN")" "$UNITS/timers.target.wants" "$UNITS/default.target.wants"; do
		case "$d" in "$UNITS"*) [ "$SD" = user ] || continue ;; esac
		while IFS= read -r f; do DIRS=$(jq -c --arg d "$f" 'if index([$d]) then . else . + [$d] end' <<<"$DIRS"); done \
			< <(missing_dirs "$d")
	done
	DIRS=$(jq -c 'unique' <<<"$DIRS")
	SOURCE=$(jq -n --argjson c "$(jstr "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)")" \
		--arg h "$(cat "${SCRIPTS[@]/#/$SRC/}" "$WORK"/unit.* 2>/dev/null | sha256sum | cut -d' ' -f1)" '{commit: $c, hash: $h}')

	# systemd: reload and (re)start the timer when units changed, or it is not running.
	if [ "$SD" = user ]; then
		if [ $changed = 1 ] || ! systemctl --user is-enabled -q "$AUTOSAVE.timer" 2>/dev/null \
			|| ! systemctl --user is-active -q "$AUTOSAVE.timer" 2>/dev/null \
			|| ! drop_ins_loaded; then
			add_step "systemd: reload units, enable and start $AUTOSAVE.timer" step_systemd; changed=1
		fi
	fi
	# tmux: hooks live in a running server, or a server started the way boot does.
	if server_up; then
		# Plugins not loaded from $PLUG (never loaded, or from the other config's folder): the
		# step loads the whole config, as for a first install.
		local load=$fresh; resurrect_loaded || load=1
		if [ $changed = 1 ] || [ $load = 1 ] || [ "$(tmux show -gqv @resurrect-hook-post-save-all)" != "$HOOK_SAVE" ] \
			|| [ "$(tmux show -gqv @resurrect-hook-post-restore-all)" != "$HOOK_RESTORE" ]; then
			add_step "running tmux: load the hooks, then save once" step_tmux_live "$load"; changed=1
		fi
	else
		add_step "start tmux (as tmux.service when possible)" step_tmux_start; changed=1
	fi

	local mjson
	mjson=$(manifest_json "$KIND")
	if [ $changed = 0 ] && [ -z "$pending" ] && [ "$(jq -c 'del(.pending)' <<<"$M" 2>/dev/null)" = "$(manifest_json "" | jq -c .)" ]; then
		STEP_DESC=(); STEP_CMD=(); return 0
	fi
	# Before the final manifest: once that is written, the previous version is forgotten.
	if [ "$PREV" != null ] && [ -n "$(obsolete_files)" ]; then
		add_step "tidy: remove files the previous version had and this one does not" step_tidy
	fi
	# Step 1 first: the whole intent on disk before anything else changes.
	local -a d2=("${STEP_DESC[@]}") c2=("${STEP_CMD[@]}")
	STEP_DESC=("write the manifest (pending: $KIND)" "${d2[@]}" "post-check" "write the manifest (done)")
	STEP_CMD=("$(printf '%q ' step_manifest "$mjson")" "${c2[@]}" "step_postcheck" "step_manifest_final")
}
# The manifest for pending $1 ("" = done: no pending, was or previous).
manifest_json() {
	jq -n --argjson l "$LAYOUT" --arg pending "$1" --argjson source "$SOURCE" --argjson files "$FILES" \
		--argjson conf "$CONFREC" --argjson plugins "$PLUGREC" --argjson ts "$TSVC" --argjson dirs "$DIRS" \
		--argjson prev "$PREV" --arg plug "$PLUG" '
		{layout: $l} + (if $pending == "" then {} else {pending: $pending} end)
		+ {source: $source, files: $files, conf: $conf, plugDir: $plug, plugins: $plugins, tmuxService: $ts, createdDirs: $dirs}
		+ (if $pending == "" or $prev == null then {} else {previous: $prev} end)
		| if $pending == "" then (.files |= map_values(del(.was))) | (.conf |= del(.was)) else . end'
}
# Only these paths are ever removed as "our files", whatever a manifest lists.
ours_path() {
	case "$1" in
	"$DEST"/claude-*.sh | "$UNITS/$AUTOSAVE".* | "$DROPIN" | "$SCOPE_DROPIN") return 0 ;;
	esac
	return 1
}
# A tmux.service the user wrote, not tmux-continuum's (which stops with resurrect's save.sh):
# our stop drop-in would change how it stops, so it is left alone.
own_tmux_service() { [ -e "$TMUX_SERVICE" ] && ! grep -qE '^ExecStop=.*tmux-resurrect/scripts/save\.sh' "$TMUX_SERVICE"; }
# Unit kinds this install writes.
unit_kinds() { local k; for k in "${UNIT_KINDS[@]}"; do { [ "$k" = stop ] && own_tmux_service; } || echo "$k"; done; }
drop_ins_loaded() {
	[ -e "$TMUX_SERVICE" ] && ! own_tmux_service || return 0
	[[ "$(systemctl --user show tmux.service -p DropInPaths --value 2>/dev/null)" == *"$DROPIN"* ]]
}
obsolete_files() { jq -r --argjson now "$FILES" '(.files // {}) | keys[] | select(. as $k | $now | has($k) | not)' <<<"$PREV"; }

step_manifest() { take_lock; remove_stale_temps; write_manifest "$1"; }
step_write() {
	mkdir -p -- "$(dirname -- "$1")"
	[ "$(sha_of "$1")" = "$(sha_of "$2")" ] && [ "$(stat -c %a "$1")" = "${3#0}" ] && return 0
	atomic_write "$1" "$3" < "$2"
}
step_conf() {
	local real now
	real=$(readlink -f -- "$CONF"); now=$(sha_of "$real")
	[ "$now" = "$(sha_of "$1")" ] && return 0
	[ "$now" = "$(mget .was "$CONFREC")" ] || fail "$CONF changed while this run was going; rerun to plan again"
	atomic_write "$CONF" "" < "$1"
}
# Fresh clone of plugin $1 at its pinned commit. Cloned beside the target and
# moved into place last, so a failed clone never looks installed.
step_clone() {
	local p="$1" tmp="$PLUG/.$1.tmp"
	[ -d "$PLUG/$p" ] && return 0
	mkdir -p -- "$PLUG"; rm -rf -- "$tmp"
	must 300 env GIT_TERMINAL_PROMPT=0 git "${GITQ[@]}" -c core.hooksPath=/dev/null clone -q "https://github.com/tmux-plugins/$p" "$tmp"
	must 60 git "${GITQ[@]}" -C "$tmp" -c advice.detachedHead=false -c core.hooksPath=/dev/null checkout -q "${PIN[$p]}"
	[ "$(git "${GITQ[@]}" -C "$tmp" rev-parse HEAD)" = "${PIN[$p]}" ] || fail "plugin $p is not at its pin after checkout"
	sync -f -- "$tmp"
	[ ! -e "$PLUG/$p" ] || fail "$PLUG/$p appeared while cloning (tpm's install?); rerun"
	mv -T -- "$tmp" "$PLUG/$p"; sync -- "$PLUG"
}
step_systemd() {
	must 60 systemctl --user daemon-reload
	must 60 systemctl --user enable -q "$AUTOSAVE.timer"
	must 60 systemctl --user restart "$AUTOSAVE.timer"
}
step_tmux_live() {
	if [ "$1" = 1 ] || [ -z "$(tmux show -gqv @continuum-save-interval)" ]; then
		# TPM sets its folder once per server and keeps it. Set while another config was the
		# one TPM read, it would load the plugins from there again. No config of the user's
		# sets it (plan_install refuses those), so TPM sets it again.
		local tp
		tp=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH 2>/dev/null) || tp=""
		case "$tp" in
		TMUX_PLUGIN_MANAGER_PATH=*) [ "${tp#*=}" = "$PLUG/" ] || must 60 tmux set-environment -gu TMUX_PLUGIN_MANAGER_PATH ;;
		esac
		must 60 tmux source-file "$CONF"
	else
		must 60 tmux set -g @resurrect-hook-post-save-all "$HOOK_SAVE"
		must 60 tmux set -g @resurrect-hook-post-restore-all "$HOOK_RESTORE"
	fi
	# A full tmux-resurrect save: creates the save dir on a first install and
	# runs the save hook, so the pane list is current.
	must 120 tmux run-shell "$PLUG/tmux-resurrect/scripts/save.sh quiet"
	record_tmux_service
}
# No tmux server: start one, the way boot does, so hooks and autosave are live
# now. With systemd, start it as tmux.service (so a clean shutdown saves); if the
# unit does not exist yet, let tmux-continuum's own script write and enable it,
# as it would on the first tmux start. Like a boot, this restores the last save.
step_tmux_start() {
	server_up && return 0
	local enable="$PLUG/tmux-continuum/scripts/handle_tmux_automatic_start/systemd_enable.sh"
	if [ "$SD" = user ] && [ ! -e "$TMUX_SERVICE" ] && [ "$(conf_opt @continuum-boot)" = on ] \
		&& [ -z "$(conf_opt @continuum-systemd-start-cmd)" ]; then
		run_child 60 "$enable" || true
	fi
	if [ "$SD" = user ] && systemctl --user is-enabled -q tmux.service 2>/dev/null \
		&& run_child 60 systemctl --user start tmux.service; then
		ok "started tmux.service"
	else
		must 60 tmux new-session -d
		ok "started a detached tmux server"
	fi
	record_tmux_service
}
# tmux-continuum has just written tmux.service: record its hash in the pending manifest at
# once, so --autoremove can tell it is unchanged even if this run is killed before the end.
record_tmux_service() {
	[ "$TS_NEW" = 1 ] && [ -e "$TMUX_SERVICE" ] && [ -z "$(mget .sha256 "$TSVC")" ] || return 0
	TSVC=$(jq --arg s "$(sha_of "$TMUX_SERVICE")" '.sha256 = $s' <<<"$TSVC")
	write_manifest "$(manifest_json "$KIND")"
}
step_postcheck() {
	out ""
	do_check post || fail "the post-check found problems (see [FAIL] above)"
}
step_manifest_final() {
	if [ "$TS_NEW" = 1 ] && [ -e "$TMUX_SERVICE" ] && [ -z "$(mget .sha256 "$TSVC")" ]; then
		TSVC=$(jq --arg s "$(sha_of "$TMUX_SERVICE")" '.sha256 = $s' <<<"$TSVC")
	fi
	# Planned, but tmux-continuum never wrote it (tmux was already running): not ours.
	if [ "$(mget .created "$TSVC")" = true ] && [ -z "$(mget .sha256 "$TSVC")" ]; then
		TSVC=$(jq '.created = false' <<<"$TSVC")
	fi
	write_manifest "$(manifest_json "")"
}
step_tidy() {
	local f
	while IFS= read -r f; do
		ours_path "$f" || { warn "not removing $f: not a path of ours"; continue; }
		remove_file "$f" || warn "could not remove $f; remove it by hand"
	done < <(obsolete_files)
	return 0
}

do_install() {
	out "Installing tmux-claude-restore for $USER from $SRC"
	preflight tmux jq git
	command -v claude >/dev/null || warn "claude not on PATH; restore will fail until it is"
	[ "$SD" = none ] && warn "this machine does not run systemd: no autosave without an attached client, no start at boot"
	plan_install
	if [ "$DRY" = 1 ]; then print_plan; FINAL=0; exit 0; fi
	if [ ${#STEP_DESC[@]} = 0 ]; then
		ok "already installed and up to date; nothing changed"
		out ""; do_check post && { FINAL=0; exit 0; }
		FINAL=4; exit 4
	fi
	run_steps
	FINAL=0
}

# ---------------------------------------------------------------- uninstall
plan_uninstall() {
	load_manifest
	# The config and plugin folder install used, which may not be the ones TPM uses now. With
	# no manifest, the config that holds our lines.
	if [ -n "$M" ]; then use_manifest_paths "$M"
	elif ! has_ours "$CONF" && has_ours "$HOME_CONF"; then CONF=$HOME_CONF; PLUG=$OLD_PLUG; fi
	block_broken "$CONF" && refuse "the tmux-claude-restore block in $CONF has a begin line without an end line (or the reverse); fix the markers by hand"
	local residual=0 f k p
	[ -n "$M" ] && [ "$(mget .residual)" = true ] && residual=1
	if [ -z "$M" ]; then
		# Installed before there was a manifest, or not at all: records from the fixed names.
		local files='{}'
		for f in "${SCRIPTS[@]/#/$DEST/}" "$(unit_path service)" "$(unit_path timer)" "$DROPIN" "$SCOPE_DROPIN"; do
			[ -e "$f" ] && files=$(jq --arg p "$f" '.[$p] = {}' <<<"$files")
		done
		if [ "$files" = '{}' ] && ! has_ours "$CONF" && [ -z "$(stale_temps)" ]; then
			STEP_DESC=(); STEP_CMD=()
			# A kill between removing the manifest and its folder left the folder, empty.
			if [ -d "$STATE" ] && [ -z "$(ls -A -- "$STATE")" ]; then add_step "remove the empty $STATE" rmdir -- "$STATE"; fi
			return 0
		fi
		M=$(jq -n --argjson l "$LAYOUT" --argjson f "$files" --arg c "$CONF" \
			--argjson d "$({ missing_dirs "$STATE" | jq -R . | jq -sc .; stale_manifest_dirs; } | jq -sc 'add | unique')" \
			--arg plug "$PLUG" '{layout: $l, files: $f, conf: {path: $c, existed: true, original: null, restore: null, withoutBlock: null},
			  plugDir: $plug, plugins: {}, tmuxService: {created: false}, createdDirs: $d}')
	fi
	KEPT=()
	if [ $residual = 1 ] && [ "$AUTOREMOVE" = 0 ] && [ -z "$(mget .pending)" ]; then
		for p in "${PLUGINS[@]}"; do plugin_removable "$p" "$CONF" && KEPT+=("plugin $PLUG/$p"); done
		[ "$(mget .tmuxService.created)" = true ] && [ -e "$TMUX_SERVICE" ] && KEPT+=("$TMUX_SERVICE")
		STEP_DESC=(); STEP_CMD=(); return 0
	fi
	add_step "write the manifest (pending: uninstall)" step_manifest "$(jq -c '.pending = "uninstall"' <<<"$M")"
	if [ "$SD" = user ] && { [ -e "$(unit_path timer)" ] || systemctl --user is-active -q "$AUTOSAVE.timer" 2>/dev/null; }; then
		add_step "stop and disable $AUTOSAVE.timer" step_timer_off
	fi
	if server_up && { our_hook @resurrect-hook-post-save-all || our_hook @resurrect-hook-post-restore-all; }; then
		add_step "running tmux: unset the hooks" step_hooks_off
	fi
	# The config as uninstall leaves it. The other config file, which tmux reads too, holds
	# lines of ours when the user moved or copied the config after install: it gets the same.
	local after="$WORK/conf.after" o n=0
	if [ $residual = 0 ]; then
		plan_conf "$CONF" "$after"
		for o in "$HOME_CONF" "$XDG_CONF"; do
			[ "$o" != "$CONF" ] && has_ours "$o" || continue
			n=$((n + 1)); plan_conf "$o" "$WORK/other$n.after"; OTHER_AFTER[$o]="$WORK/other$n.after"
		done
	elif [ -e "$CONF" ]; then cp "$(readlink -f -- "$CONF")" "$after"
	else : > "$after"; fi
	# Our files: the manifest's, plus the fixed names (a pending install named them all).
	local units_gone=0
	while IFS= read -r f; do
		ours_path "$f" || continue
		[ -e "$f" ] || [ -L "$f" ] || continue
		add_step "remove $f" remove_file "$f"
		case "$f" in "$UNITS"/*) units_gone=1 ;; esac
	done < <({ jq -r '((.files // {}) + (.previous.files // {})) | keys[]' <<<"$M"; printf '%s\n' "${SCRIPTS[@]/#/$DEST/}" "$(unit_path service)" "$(unit_path timer)" "$DROPIN" "$SCOPE_DROPIN"; } | sort -u)
	# Dependencies install brought in: removed with --autoremove (the apt way), else listed.
	local gone_continuum=0
	for p in "${PLUGINS[@]}"; do
		if plugin_removable "$p" "$after"; then
			if [ "$AUTOREMOVE" = 1 ]; then
				add_step "autoremove plugin $p" step_rm_plugin "$p"
				[ "$p" = tmux-continuum ] && gone_continuum=1
			else KEPT+=("plugin $PLUG/$p"); fi
		fi
	done
	[ -d "$PLUG/tmux-continuum" ] || gone_continuum=1
	if [ "$(mget .tmuxService.created)" = true ] && [ -e "$TMUX_SERVICE" ] \
		&& [ "$(sha_of "$TMUX_SERVICE")" = "$(mget .tmuxService.sha256)" ]; then
		if [ "$AUTOREMOVE" = 1 ] && [ $gone_continuum = 1 ]; then
			add_step "autoremove $TMUX_SERVICE (tmux keeps running until it exits)" step_rm_tmux_service; units_gone=1
		elif [ "$AUTOREMOVE" = 0 ]; then KEPT+=("$TMUX_SERVICE"); fi
	fi
	if [ "$SD" = user ] && [ $units_gone = 1 ]; then add_step "systemd: reload units" must 60 systemctl --user daemon-reload; fi
	if [ ${#KEPT[@]} -gt 0 ]; then
		add_step "keep the record of what install brought in (for --autoremove)" step_residual
	else
		add_step "remove the manifest and the empty folders install created" step_forget
	fi
}
# plan_conf <config> <out>: the step that leaves the config as uninstall wants it, and the
# bytes it will then hold in <out>: those from before the first install if only our block
# differs (no file, if install created it), else the file without our lines.
plan_conf() {
	local c=$1 out=$2 cur="$WORK/plan.cur" nb action=""
	if [ ! -e "$c" ]; then : > "$out"; return 0; fi
	block_broken "$c" && refuse "the tmux-claude-restore block in $c has a begin line without an end line (or the reverse); fix the markers by hand"
	cp "$(readlink -f -- "$c")" "$cur"
	strip_conf "$cur" > "$WORK/plan.nb"; nb=$(sha_of "$WORK/plan.nb")
	# An upgrade changes only our block, so this record holds while one is pending too.
	if [ "$nb" = "$(mget .conf.withoutBlock)" ]; then
		if [ "$(jq -r '.conf.restore == null' <<<"$M")" = true ]; then
			action="remove"; : > "$out"
		else
			mget .conf.restore | base64 -d > "$out"; action="write"
		fi
	elif has_ours "$cur"; then
		cp "$WORK/plan.nb" "$out"; keep_nl "$cur" "$out"; action="write"
	fi
	[ -n "$action" ] || cp "$cur" "$out"
	if [ "$action" = write ] && cmp -s "$out" "$cur"; then action=""; fi
	case "$action" in
	write) add_step "restore $c" step_conf_restore "$out" "$(sha_of "$cur")" "$c" ;;
	remove) add_step "remove $c (install created it)" step_conf_remove "$(sha_of "$cur")" "$c" ;;
	esac
}
# plugin_removable <name> <config after uninstall>: brought in by install, unchanged, and
# nothing needs it any more. Never a symlink, never followed.
plugin_removable() {
	local p=$1 d="$PLUG/$1" st
	[ "$(jq -r --arg p "$p" '.plugins[$p].cloned // false' <<<"$M")" = true ] || return 1
	[ -d "$d" ] && [ ! -L "$d" ] && [ ! -L "$PLUG" ] || return 1
	[ "$(git "${GITQ[@]}" -C "$d" rev-parse HEAD 2>/dev/null)" = "${PIN[$p]}" ] || return 1
	# --untracked-files=all: status.showUntrackedFiles=no in a gitconfig would hide the user's files.
	st=$(git "${GITQ[@]}" -C "$d" status --porcelain --ignored --untracked-files=all 2>/dev/null) || return 1
	[ -z "$st" ] || return 1
	# Work of the user's that status does not show: a stash, or commits only on a local branch.
	! git "${GITQ[@]}" -C "$d" rev-parse -q --verify refs/stash >/dev/null 2>&1 || return 1
	st=$(git "${GITQ[@]}" -C "$d" rev-list --branches --not --remotes 2>/dev/null) || return 1
	[ -z "$st" ] || return 1
	! conf_needs "$2" "$p" || return 1
	# tmux reads the other config file too: a plugin named there stays.
	local o
	for o in "$HOME_CONF" "$XDG_CONF"; do
		if [ "$o" != "$CONF" ] && conf_needs "${OTHER_AFTER[$o]:-$o}" "$p"; then return 1; fi
	done
	return 0
}
step_timer_off() {
	if [ -e "$(unit_path timer)" ]; then must 60 systemctl --user disable -q "$AUTOSAVE.timer"; fi
	if systemctl --user is-active -q "$AUTOSAVE.timer" 2>/dev/null; then must 60 systemctl --user stop "$AUTOSAVE.timer"; fi
}
# Does live option $1 run one of our scripts? A hook of the user's own is left alone.
our_hook() { case "$(tmux show -gqv "$1" 2>/dev/null)" in *.tmux/scripts/claude-save.sh* | *.tmux/scripts/claude-restore.sh*) return 0 ;; esac; return 1; }
# A server that has exited meanwhile has no hooks left to unset.
step_hooks_off() {
	local o
	for o in @resurrect-hook-post-save-all @resurrect-hook-post-restore-all; do
		our_hook "$o" || continue
		run_child 60 tmux set -gu "$o" || ! server_up || fail "could not unset $o in the running tmux: $CHILD_ERR"
	done
}
# step_conf_restore <bytes to write> <hash planned on> [config, default $CONF]: only over
# the config that was planned on, so an edit saved while this run goes is never overwritten.
step_conf_restore() {
	local c=${3:-$CONF} real; real=$(readlink -f -- "$c")
	cmp -s "$1" "$real" && return 0
	[ "$(sha_of "$real")" = "$2" ] || fail "$c changed while this run was going; rerun to plan again"
	atomic_write "$c" "" < "$1"
}
step_conf_remove() {
	local c=${2:-$CONF} real; real=$(readlink -f -- "$c")
	[ -e "$real" ] || return 0
	[ "$(sha_of "$real")" = "$1" ] || fail "$c changed while this run was going; rerun to plan again"
	remove_file "$real"
}
# Moved aside first, then deleted: a kill mid-delete leaves only .<name>.tmp, which the next
# run's step 1 removes, never a half-deleted plugin that looks installed.
step_rm_plugin() {
	local d="$PLUG/$1" tmp="$PLUG/.$1.tmp"
	if [ -d "$d" ]; then
		[ ! -L "$d" ] || fail "$d is a symlink; not removed"
		plugin_removable "$1" "$CONF" || fail "$d or $CONF changed while this run was going; rerun to plan again"
		rm -rf -- "$tmp"; mv -- "$d" "$tmp"; sync -- "$PLUG"
	fi
	rm -rf -- "$tmp"; sync -- "$PLUG"
}
step_rm_tmux_service() {
	if [ -e "$TMUX_SERVICE" ]; then must 60 systemctl --user disable -q tmux.service; fi
	remove_file "$TMUX_SERVICE"
}
# Only the record of what install brought in stays, so a later --autoremove knows it.
step_residual() {
	write_manifest "$(jq -c --arg d "$PLUG" '{layout, residual: true, plugDir: $d, plugins: (.plugins // {}),
		tmuxService: (.tmuxService // {created: false}), createdDirs: (.createdDirs // [])}' <<<"$M")"
	rmdirs_except_state
}
# The folders first and the manifest last, so a kill leaves the record of what is left. The
# state folder and the folders around it can only go after the manifest.
step_forget() {
	rmdirs_except_state
	remove_file "$MANIFEST"
	rmdir -- "$STATE" 2>/dev/null || true
	rmdirs_except_state
}
# Folders install created, deepest first, when empty. The state folder is ours by name.
rmdirs_except_state() {
	local d
	while IFS= read -r d; do
		[ "$d" = "$STATE" ] && [ -e "$MANIFEST" ] && continue
		rmdir -- "$d" 2>/dev/null || true
	done < <(jq -r '(.createdDirs // [])[]' <<<"$M" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
}

do_uninstall() {
	out "Uninstalling tmux-claude-restore for $USER"
	preflight jq
	KEPT=()
	plan_uninstall
	if [ "$DRY" = 1 ]; then print_plan; FINAL=0; exit 0; fi
	if [ ${#STEP_DESC[@]} = 0 ]; then
		if [ ${#KEPT[@]} -gt 0 ]; then
			ok "not installed; kept what install brought in: ${KEPT[*]}"
			say "remove them with: $0 --uninstall --autoremove"
		else
			# An empty state folder is a kill's leftover from before the first manifest
			# write: ours by name, so remove it.
			if [ -d "$STATE" ] && [ -z "$(ls -A "$STATE")" ]; then rmdir -- "$STATE"; fi
			ok "not installed; nothing to do"
		fi
		FINAL=0; exit 0
	fi
	run_steps
	if [ ${#KEPT[@]} -gt 0 ]; then
		say "no longer needed (install brought them in): ${KEPT[*]}"
		say "remove them with: $0 --uninstall --autoremove"
	fi
	say "kept: $(map_dir) (saves, claude-panes.tsv, claude-restore.log)"
	FINAL=0
}

# ---------------------------------------------------------------- status
# do_check [post]: 0 healthy, 1 problems. "post" is the install's own post-check: the run
# in progress is its own pending state, so that is not a problem there.
do_check() {
	local rc=0 mode=${1:-} m="" pending=""
	out "tmux-claude-restore status for $USER:"
	if [ -e "$MANIFEST" ]; then
		if m=$(jq -e --argjson l "$LAYOUT" 'select(type == "object" and .layout == $l)' "$MANIFEST" 2>/dev/null); then
			pending=$(jq -r '.pending // empty' <<<"$m")
			if [ -z "$pending" ] && [ "$(jq -r '.residual // false' <<<"$m")" = true ]; then
				bad "not installed (uninstalled; kept what install brought in: remove with $0 --uninstall --autoremove)"; return 1
			fi
		else
			bad "$MANIFEST is not a valid manifest (restore it, or move it away and run install.sh)"; rc=1
		fi
	fi
	if [ -n "$pending" ] && [ "$mode" != post ]; then
		if [ "$pending" = uninstall ]; then bad "an uninstall did not finish (fix: $0 --uninstall)"
		else bad "an earlier $pending did not finish (fix: $0, or $0 --uninstall)"; fi
		rc=1
	fi
	if [ -n "$m" ]; then use_manifest_paths "$m"
	elif ! has_ours "$CONF" && has_ours "$HOME_CONF"; then CONF=$HOME_CONF; PLUG=$OLD_PLUG; fi
	if [ -z "$m" ] && ! has_ours "$CONF" && [ ! -e "$DEST/claude-save.sh" ]; then
		bad "not installed (fix: $0)"; return 1
	fi
	if [ "$CONF" != "$PICK_CONF" ] || [ "$PLUG" != "$PICK_PLUG" ]; then
		bad "installed in $CONF ($PLUG), but tmux plugins now load as $PICK_CONF says (from $PICK_PLUG) (fix: $0 --uninstall, then $0)"; rc=1
	fi
	local o
	for o in "$HOME_CONF" "$XDG_CONF"; do
		if [ "$o" != "$CONF" ] && has_ours "$o"; then bad "$o holds lines of ours too, and tmux reads it (fix: $0 --uninstall, then $0)"; rc=1; fi
	done
	[ -z "$m" ] && [ -e "$DEST/claude-save.sh" ] && warn "installed by a version without a manifest (re-run install.sh to upgrade)"
	local t
	while IFS= read -r t; do warn "temp file left by a killed run: $t (the next install or uninstall removes it)"; done < <(stale_temps)
	local c
	for c in tmux jq git; do
		command -v "$c" >/dev/null && ok "$c found" || { bad "$c missing"; rc=1; }
	done
	command -v claude >/dev/null && ok "claude found" || warn "claude not on PATH; restore will fail until it is"
	local p head
	for p in "${PLUGINS[@]}"; do
		head=$(git "${GITQ[@]}" -C "$PLUG/$p" rev-parse HEAD 2>/dev/null) || head=""
		if [ ! -d "$PLUG/$p" ]; then bad "plugin $p missing"; rc=1
		elif [ "$head" != "${PIN[$p]}" ]; then
			warn "plugin $p at ${head:-unknown commit}, not the tested ${PIN[$p]} (fix: git -C $PLUG/$p fetch -q origin && git -C $PLUG/$p checkout -q ${PIN[$p]})"
		else ok "plugin $p (pinned ${PIN[$p]:0:7})"; fi
	done
	local s
	for s in "${SCRIPTS[@]}"; do
		if [ ! -x "$DEST/$s" ]; then bad "$DEST/$s missing"; rc=1
		elif ! cmp -s "$SRC/$s" "$DEST/$s"; then warn "$DEST/$s differs from $SRC (re-run install.sh to upgrade)"
		else ok "$DEST/$s"; fi
	done
	if block_broken "$CONF"; then bad "$CONF: the managed block's begin and end lines do not match (fix them by hand)"; rc=1
	elif grep -qF "$BEGIN" "$CONF" 2>/dev/null; then ok "$CONF has managed block"
	else bad "$CONF has no managed block"; rc=1; fi
	if server_up; then
		[ "$(tmux show -gqv @resurrect-hook-post-save-all)" = "$HOOK_SAVE" ] && ok "live tmux: save hook set" || { bad "live tmux: save hook not set"; rc=1; }
		[ "$(tmux show -gqv @resurrect-hook-post-restore-all)" = "$HOOK_RESTORE" ] && ok "live tmux: restore hook set" || { bad "live tmux: restore hook not set"; rc=1; }
		# The hooks are plain options: they are set even when TPM loaded no plugin.
		if resurrect_loaded; then ok "live tmux: tmux-resurrect loaded from $PLUG"
		else
			bad "live tmux: tmux-resurrect not loaded from $PLUG, so nothing is saved (fix: re-run install.sh; see README if it stays)"; rc=1
		fi
	else
		warn "no tmux server running (hooks load when tmux starts)"
	fi
	if ! booted_systemd; then
		warn "this machine does not run systemd: no autosave without an attached client, no start at boot"
	elif ! have_systemd; then
		bad "your systemd user manager is not reachable from this shell (fix: run from a login session of $USER)"; rc=1
	else
		systemctl --user is-enabled tmux.service >/dev/null 2>&1 && ok "tmux.service enabled (starts at boot)" \
			|| warn "tmux.service not enabled yet (tmux-continuum creates it the next time tmux loads $CONF)"
		local k units_ok=1
		# By hash, not cmp: cmp stops reading at the first difference, and unit_text's writer
		# then fails on the closed pipe (SIGPIPE is ignored) with a "write error".
		while IFS= read -r k; do
			[ "$(unit_text "$k" | sha256sum | cut -d' ' -f1)" = "$(sha_of "$(unit_path "$k")")" ] || units_ok=0
		done < <(unit_kinds)
		if [ $units_ok = 0 ]; then
			bad "systemd units missing or outdated: $UNITS/$AUTOSAVE.{service,timer}, $DROPIN, $SCOPE_DROPIN (fix: re-run install.sh)"; rc=1
		else
			local scope
			scope=$(systemctl --user list-units --type=scope --no-legend --plain 'tmux-spawn-*' 2>/dev/null | awk 'NR == 1 {print $1}')
			if [ -n "$scope" ]; then
				[[ "$(systemctl --user show "$scope" -p DropInPaths --value 2>/dev/null)" == *"$SCOPE_DROPIN"* ]] \
					&& ok "tmux panes stop only after tmux.service saved ($SCOPE_DROPIN)" \
					|| { bad "tmux pane scopes have not loaded $SCOPE_DROPIN (fix: re-run install.sh)"; rc=1; }
			fi
			if systemctl --user is-active -q "$AUTOSAVE.timer" 2>/dev/null; then
				ok "$AUTOSAVE.timer active (saves without an attached client)"
			else
				bad "$AUTOSAVE.timer not active (fix: re-run install.sh)"; rc=1
			fi
			if own_tmux_service; then
				warn "$TMUX_SERVICE is your own (not tmux-continuum's): our stop drop-in is not added to it"
			elif [ -e "$TMUX_SERVICE" ]; then
				drop_ins_loaded && ok "tmux.service saves on stop only while tmux runs ($DROPIN)" \
					|| { bad "tmux.service has not loaded $DROPIN (fix: re-run install.sh)"; rc=1; }
			fi
		fi
		[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] && ok "linger on (user services start at boot without login)" \
			|| warn "linger off: tmux only starts after $USER logs in (fix: sudo loginctl enable-linger $USER)"
	fi
	local mdir; mdir=$(map_dir)
	if [ -e "$mdir/claude-panes.tsv" ]; then
		local age interval
		age=$(( $(date +%s) - $(stat -c %Y "$mdir/claude-panes.tsv") ))
		interval=$(tmux show -gqv @continuum-save-interval 2>/dev/null) || true
		if server_up && [ "$age" -gt $(( ${interval:-5} * 60 + 180 )) ]; then
			warn "last save $((age / 60)) min ago, expected every ${interval:-5} min"
		else
			ok "last save $((age / 60)) min ago"
		fi
	fi
	if [ -s "$mdir/claude-panes.tsv" ]; then
		say "tracked panes ($mdir/claude-panes.tsv): target / session / cwd / rc"
		local line
		while IFS= read -r line; do out "    $line"; done < "$mdir/claude-panes.tsv"
	else
		say "tracked panes: none yet (first save runs within 5 min, or press prefix + Ctrl-s)"
	fi
	return $rc
}

# ---------------------------------------------------------------- main
# A terminal sends Ctrl-C and a hangup to its whole foreground process group, which would
# kill whatever short command (jq, mv, rm) a step is running. So install and uninstall run
# as a worker in a session of their own, which no terminal signal reaches. This parent stays
# in the terminal's group and passes each INT, TERM or HUP on to the worker as SIGUSR1. One
# it ignored on entry (nohup) is not passed on. A kill -9 of this parent leaves the worker
# to finish alone, as nohup would.
supervise() {
	local pid="" rc n=0 missed=0 seen
	# From here every signal counts; one that comes before the worker exists is sent after.
	trap 'n=$((n + 1)); if [ -n "$pid" ]; then kill -USR1 "$pid" 2>/dev/null || true; else missed=$((missed + 1)); fi' INT TERM HUP
	trap - ERR EXIT
	command -v setsid >/dev/null || { out "  refused: setsid is required"; exit 1; }
	TCR_WORKER=1 setsid "$BASH" "$SRC/$(basename -- "${BASH_SOURCE[0]}")" "$@" </dev/null &
	pid=$!
	while [ "$missed" -gt 0 ]; do missed=$((missed - 1)); kill -USR1 "$pid" 2>/dev/null || true; done
	# As in run_child: a trapped signal ends wait early; a second wait returns the saved status.
	while :; do
		seen=$n
		rc=0; wait "$pid" || rc=$?
		if [ "$rc" -gt 128 ] && [ "$n" != "$seen" ]; then continue; fi
		break
	done
	# Killed by SIGUSR1: it came before the worker set its traps, so before any change.
	if [ "$rc" = $((128 + 10)) ]; then out "  interrupted before any change"; exit 1; fi
	exit "$rc"
}
WORKER=0
if [ "${TCR_WORKER:-}" = 1 ]; then WORKER=1; unset TCR_WORKER; fi
usage() {
	out "usage: $0 [--dry-run] | --check | --uninstall [--autoremove] [--dry-run]"
	out "exit status: 0 done; 1 refused, nothing changed; 2 usage; 3 stopped part-way (rerun the same command, or --uninstall); 4 --check found problems"
	FINAL=2; exit 2
}
CMD=install; DRY=0; AUTOREMOVE=0
for a in "$@"; do
	case "$a" in
	--check) [ $CMD = install ] && [ $DRY = 0 ] || usage; CMD=check ;;
	--uninstall) [ $CMD = install ] || usage; CMD=uninstall ;;
	--autoremove) AUTOREMOVE=1 ;;
	--dry-run) [ $CMD != check ] || usage; DRY=1 ;;
	*) usage ;;
	esac
done
[ $AUTOREMOVE = 0 ] || [ $CMD = uninstall ] || usage
[ $CMD = check ] || [ $WORKER = 1 ] || supervise "$@"
case $CMD in
	install) do_install ;;
	uninstall) do_uninstall ;;
	check) if do_check; then FINAL=0; else FINAL=4; fi; exit "$FINAL" ;;
esac
