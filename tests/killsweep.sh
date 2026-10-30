#!/usr/bin/env bash
# Kill sweep of install.sh in a throwaway systemd container: the run SIGKILLs itself before
# every step (TCR_FAILPOINT=step:<k>) of install, upgrade and uninstall (plain and with
# --autoremove), and inside the atomic writes (write:<file>). After each kill: the user's own
# config lines are intact, a rerun of the same command ends healthy, and a final
# `--uninstall --autoremove` leaves the home byte-identical to before. See tests/README.md.
#   tests/killsweep.sh          run everything (about 3 min); container and image removed after
#   tests/killsweep.sh --keep   leave the container running to look around
#   TCR_SWEEP=install,write tests/killsweep.sh   only these kinds of case (for tests/mutants.sh)
# Single-quoted code is meant to expand inside the container, not here:
# shellcheck disable=SC2016
set -uo pipefail
TCR_SUITE=sweep
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
JOBS=4
# The user's own config: an option, a comment, no final newline.
OWN_CONF="printf 'set -g mouse on\n# my own comment' > ~/.tmux.conf"
OWN_OK='[ -s ~/.tmux.conf ] && grep -qx "set -g mouse on" ~/.tmux.conf && grep -qx "# my own comment" ~/.tmux.conf'
# The same in the XDG config (TPM then reads only it, and plugins go to ~/.config/tmux/plugins).
XDG_OWN_CONF="mkdir -p ~/.config/tmux && printf 'set -g mouse on\n# my own comment' > ~/.config/tmux/tmux.conf"
XDG_OWN_OK='f=~/.config/tmux/tmux.conf; [ -s $f ] && grep -qx "set -g mouse on" $f && grep -qx "# my own comment" $f && [ ! -e ~/.tmux.conf ]'

# rerun <user> <command>: rerun until exit 0, at most 4 tries; prints the last exit code.
rerun() {
	local rc=1
	for _ in 1 2 3 4; do as "$1" "$2" >/dev/null 2>&1; rc=$?; [ $rc = 0 ] && break; done
	echo $rc
}
# finish <user>: remove everything and stop the user's tmux and user manager.
finish() {
	as "$1" 'bash /opt/tcr/install.sh --uninstall --autoremove' >/dev/null 2>&1; local rc=$?
	as "$1" 'tmux kill-server; systemctl --user stop tmux.service' >/dev/null 2>&1
	return $rc
}
# eq <a> <b>: prints 0 when equal, else 1 (for result).
eq() { if [ "$1" = "$2" ]; then echo 0; else echo 1; fi; }
# result <case> <check> <ok?>: one line per check into the case's result file.
result() { if [ "$3" = 0 ]; then echo "ok    $1: $2"; else echo "FAIL  $1: $2"; fi >> "$STAGE/res.$1"; }

# case_kill <id> <uid> <kind> <failpoint> [then]: one kill and its recovery, on a new user.
#   kind: install | upgrade (from the test "old version") | base (from the first commit,
#         no manifest) | uninstall (--uninstall --autoremove) | keep (plain --uninstall: the
#         plugins and the record of them stay, for a later --autoremove) | xdg (install
#         with the config in ~/.config/tmux)
#   then: rerun (default: rerun the same command, then uninstall) | uninstall (go straight
#         to --uninstall --autoremove on the unfinished run)
case_kill() {
	local id=$1 u="u$2" kind=$3 fp=$4 then=${5:-rerun} rc cmd=install.sh own=$OWN_CONF OWN_OK=$OWN_OK
	[ "$kind" = xdg ] && { own=$XDG_OWN_CONF; OWN_OK=$XDG_OWN_OK; }
	mkuser "$u" "$2" || { result "$id" "user created" 1; return; }
	as "$u" "$own"
	snap "$u" > "$STAGE/$id.before"
	case $kind in
	upgrade) as "$u" 'bash /opt/tcr-old/install.sh' >/dev/null 2>&1 ;;
	base) as "$u" 'bash /opt/tcr-base/install.sh' >/dev/null 2>&1 ;;
	uninstall) as "$u" 'bash /opt/tcr/install.sh' >/dev/null 2>&1; cmd="install.sh --uninstall --autoremove" ;;
	keep) as "$u" 'bash /opt/tcr/install.sh' >/dev/null 2>&1; cmd="install.sh --uninstall" ;;
	esac
	as "$u" "TCR_FAILPOINT=$fp bash /opt/tcr/$cmd" >/dev/null 2>&1; rc=$?
	result "$id" "killed at $fp (exit 137)" "$(eq "$rc" 137)"
	as "$u" "$OWN_OK"; result "$id" "own config lines intact after the kill" $?
	if [ "$then" = uninstall ]; then
		as "$u" 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
		result "$id" "--check reports the unfinished run (exit 4)" "$(eq "$rc" 4)"
		result "$id" "uninstall of the unfinished run ends with exit 0" "$(rerun "$u" 'bash /opt/tcr/install.sh --uninstall --autoremove')"
		as "$u" 'tmux kill-server; systemctl --user stop tmux.service' >/dev/null 2>&1
	else
		result "$id" "rerun of the same command ends with exit 0" "$(rerun "$u" "bash /opt/tcr/$cmd")"
	fi
	as "$u" '! find ~ -name "*.tcr-tmp.*" | grep -q .'; result "$id" "no temp file left after the rerun" $?
	if [ "$kind" = keep ]; then
		as "$u" 'for p in tpm tmux-resurrect tmux-continuum; do [ -d ~/.tmux/plugins/$p ] || exit 1; done'
		result "$id" "the plugins install brought in are kept" $?
		as "$u" '! ls -d ~/.tmux/scripts/claude-* ~/.config/systemd/user/tmux-claude-* ~/.config/systemd/user/*.d/tmux-claude-restore.conf 2>/dev/null | grep -q . && ! grep -q "tmux-claude-restore" ~/.tmux.conf'
		result "$id" "everything else of ours is gone" $?
		as "$u" 'jq -e ".residual == true and .pending == null" ~/.local/state/tmux-claude-restore/manifest.json'
		result "$id" "only the record of what install brought in is left, not pending" $?
		as "$u" 'bash /opt/tcr/install.sh --check' > "$STAGE/$id.check" 2>&1; rc=$?
		result "$id" "--check says not installed (exit 4)" "$(eq "$rc" 4)"
		finish "$u"; result "$id" "then --autoremove exits 0" $?
	elif [ "$kind" != uninstall ] && [ "$then" = rerun ]; then
		as "$u" 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; result "$id" "--check exits 0" $?
		as "$u" '[ "$(jq -r ".pending // \"none\"" ~/.local/state/tmux-claude-restore/manifest.json)" = none ]'
		result "$id" "manifest written without pending" $?
		[ "$kind" = install ] || [ "$kind" = xdg ] || { as "$u" 'grep -qx "OnUnitActiveSec=1min" ~/.config/systemd/user/tmux-claude-autosave.timer && ! grep -q "old version" ~/.tmux/scripts/claude-save.sh'; result "$id" "upgraded to the new version" $?; }
		finish "$u"; result "$id" "final uninstall exits 0" $?
	else
		as "$u" 'tmux kill-server; systemctl --user stop tmux.service' >/dev/null 2>&1
	fi
	as "$u" "$OWN_OK"; result "$id" "own config lines intact at the end" $?
	snap "$u" > "$STAGE/$id.after"
	if [ "$kind" = base ]; then
		# The first version left a backup file, and its plugins and tmux.service carry no
		# record, so they stay; everything ours must still be gone.
		as "$u" '! ls -d ~/.tmux/scripts/claude-* ~/.config/systemd/user/tmux-claude-* ~/.local/state/tmux-claude-restore 2>/dev/null | grep -q . && ! grep -q "tmux-claude-restore >>>" ~/.tmux.conf'
		result "$id" "everything of ours gone after the final uninstall" $?
	else
		cmp -s "$STAGE/$id.before" "$STAGE/$id.after"; result "$id" "home byte-identical to before" $?
		cmp -s "$STAGE/$id.before" "$STAGE/$id.after" || diff "$STAGE/$id.before" "$STAGE/$id.after" | head -5 | sed 's/^/        /' >> "$STAGE/res.$id"
	fi
	rmuser "$u"
	echo end >> "$STAGE/res.$id"
}
# case_write <id> <uid> <file>: killed inside the atomic write of <file>, during install.
case_write() {
	local id=$1 u="u$2" f=$3 before rc
	mkuser "$u" "$2" || { result "$id" "user created" 1; return; }
	as "$u" "$OWN_CONF"
	snap "$u" > "$STAGE/$id.before"
	as "$u" "TCR_FAILPOINT=write:$f bash /opt/tcr/install.sh" >/dev/null 2>&1; rc=$?
	result "$id" "killed inside the write of $f (exit 137)" "$(eq "$rc" 137)"
	as "$u" "find ~ -name '.$f.tcr-tmp.*' | grep -q ."; result "$id" "the temp file is there" $?
	case $f in
	.tmux.conf) as "$u" "$OWN_OK && ! grep -q 'tmux-claude-restore >>>' ~/.tmux.conf"; result "$id" "config still holds its old bytes" $? ;;
	manifest.json) as "$u" '[ ! -e ~/.local/state/tmux-claude-restore/manifest.json ]'; result "$id" "no manifest yet (never a cut one)" $? ;;
	*) as "$u" "! find ~ -name '$f' -not -name '.*' | grep -q ."; result "$id" "$f not there yet (never a cut one)" $? ;;
	esac
	as "$u" 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
	[ "$f" = manifest.json ] || result "$id" "--check reports the unfinished run (exit 4)" "$(eq "$rc" 4)"
	result "$id" "rerun ends with exit 0" "$(rerun "$u" 'bash /opt/tcr/install.sh')"
	as "$u" '! find ~ -name "*.tcr-tmp.*" | grep -q .'; result "$id" "the rerun removed the temp file" $?
	finish "$u"; result "$id" "final uninstall exits 0" $?
	snap "$u" > "$STAGE/$id.after"
	cmp -s "$STAGE/$id.before" "$STAGE/$id.after"; result "$id" "home byte-identical to before" $?
	cmp -s "$STAGE/$id.before" "$STAGE/$id.after" || diff "$STAGE/$id.before" "$STAGE/$id.after" | head -5 | sed 's/^/        /' >> "$STAGE/res.$id"
	rmuser "$u"
	echo end >> "$STAGE/res.$id"
}

# An unknown kind in TCR_SWEEP stops the run before anything starts: a typo must never pass as
# a sweep that ran nothing. (SWEEP_KINDS and kind_of: tests/baseline.sh.)
if [ -n "${TCR_SWEEP:-}" ]; then
	IFS=, read -ra want <<<"$TCR_SWEEP"
	for k in "${want[@]}"; do [[ " ${SWEEP_KINDS[*]} " == *" $k "* ]] || { echo "unknown kind: $k (kinds: ${SWEEP_KINDS[*]})"; exit 2; }; done
fi
start_container
step "Boot"
check "systemd boots" booted || exit 1

# Number of steps of each command, from --dry-run on a user in the same starting state.
mkuser probe 2900 >/dev/null
as probe "$OWN_CONF"
n_install=$(as probe 'bash /opt/tcr/install.sh --dry-run' | grep -c '^  step ')
as probe 'bash /opt/tcr-old/install.sh' >/dev/null 2>&1
n_upgrade=$(as probe 'bash /opt/tcr/install.sh --dry-run' | grep -c '^  step ')
as probe 'bash /opt/tcr/install.sh' >/dev/null 2>&1
n_uninstall=$(as probe 'bash /opt/tcr/install.sh --uninstall --autoremove --dry-run' | grep -c '^  step ')
n_keep=$(as probe 'bash /opt/tcr/install.sh --uninstall --dry-run' | grep -c '^  step ')
rmuser probe
mkuser probe2 2901 >/dev/null
as probe2 "$OWN_CONF"; as probe2 'bash /opt/tcr-base/install.sh' >/dev/null 2>&1
n_base=$(as probe2 'bash /opt/tcr/install.sh --dry-run' | grep -c '^  step ')
rmuser probe2
mkuser probe3 2902 >/dev/null
as probe3 "$XDG_OWN_CONF"
n_xdg=$(as probe3 'bash /opt/tcr/install.sh --dry-run' | grep -c '^  step ')
rmuser probe3
check "step counts read from --dry-run (install $n_install, upgrade $n_upgrade, from first commit $n_base, uninstall $n_uninstall, plain uninstall $n_keep, XDG config $n_xdg)" \
	test "$n_install" -gt 5 -a "$n_upgrade" -gt 2 -a "$n_base" -gt 5 -a "$n_uninstall" -gt 3 -a "$n_keep" -gt 3 -a "$n_xdg" -gt 5

cases=()
uid=3000
for ((k = 1; k <= n_install + 1; k++)); do cases+=("install-$k $((uid++)) install step:$k"); done
for ((k = 1; k <= n_upgrade + 1; k++)); do cases+=("upgrade-$k $((uid++)) upgrade step:$k"); done
for ((k = 1; k <= n_base + 1; k++)); do cases+=("base-$k $((uid++)) base step:$k"); done
for ((k = 1; k <= n_uninstall + 1; k++)); do cases+=("uninstall-$k $((uid++)) uninstall step:$k"); done
for ((k = 1; k <= n_keep + 1; k++)); do cases+=("keep-$k $((uid++)) keep step:$k"); done
for ((k = 1; k <= n_xdg + 1; k++)); do cases+=("xdg-$k $((uid++)) xdg step:$k"); done
# Kills from step 2 on leave a pending manifest: uninstall must finish from there too.
for ((k = 2; k <= n_install; k++)); do cases+=("install-then-uninstall-$k $((uid++)) install step:$k uninstall"); done
for ((k = 2; k <= n_upgrade; k++)); do cases+=("upgrade-then-uninstall-$k $((uid++)) upgrade step:$k uninstall"); done
for ((k = 2; k <= n_xdg; k++)); do cases+=("xdg-then-uninstall-$k $((uid++)) xdg step:$k uninstall"); done
writes=(manifest.json .tmux.conf claude-save.sh tmux-claude-autosave.timer)
# TCR_SWEEP=<kind,…> (checked above): only those kinds of case.
if [ -n "${TCR_SWEEP:-}" ]; then
	picked=()
	for c in "${cases[@]}"; do [[ " ${want[*]} " != *" $(kind_of "${c%% *}") "* ]] || picked+=("$c"); done
	cases=("${picked[@]}")
	[[ " ${want[*]} " == *" write "* ]] || writes=()
fi

step "Kill sweep: ${#cases[@]} kills before a step, ${#writes[@]} inside a write ($JOBS at a time)"
running=0
for c in "${cases[@]}"; do
	# shellcheck disable=SC2086
	case_kill $c &
	running=$((running + 1)); [ $running -ge $JOBS ] && { wait -n; running=$((running - 1)); }
done
for f in "${writes[@]}"; do
	uid=$((uid + 1))
	case_write "write-$f" "$uid" "$f" &
	running=$((running + 1)); [ $running -ge $JOBS ] && { wait -n; running=$((running - 1)); }
done
wait
# Every case started must have ended: a case that died part-way has no "end" line, and only
# its first results, which would otherwise pass.
ids=(); for c in "${cases[@]}"; do ids+=("${c%% *}"); done; for f in "${writes[@]}"; do ids+=("write-$f"); done
for id in "${ids[@]}"; do
	r="$STAGE/res.$id"
	if [ "$(tail -n1 "$r" 2>/dev/null)" != end ]; then FAIL=$((FAIL + 1)); echo "  FAIL  $id: case did not finish"; UNFINISHED=1; fi
	[ -f "$r" ] || continue
	while IFS= read -r line; do
		case $line in
		"ok    "*) PASS=$((PASS + 1)) ;;
		"FAIL  "*) FAIL=$((FAIL + 1)); echo "  $line" ;;
		end) ;;
		*) echo "$line" ;;
		esac
	done < "$r"
done
echo "  (passing checks are counted, not listed)"
mkdir -p "$STAGE/logs"
find "$STAGE" -maxdepth 1 -name 'res.*' -exec cp -t "$STAGE/logs" {} +
# Every case finished and the machine still sound at the end (machine_sound in tests/lib.sh):
# tests/mutants.sh needs it.
[ $UNFINISHED = 0 ] && machine_sound && echo "== healthy sweep"
printf 'passed %d failed %d\n' "$PASS" "$FAIL" > "$STAGE/logs/result"
[ -n "${TCR_SWEEP:-}" ] || save_logs killsweep "$STAGE/logs"
[ $UNFINISHED = 1 ] || DONE=1
summary
