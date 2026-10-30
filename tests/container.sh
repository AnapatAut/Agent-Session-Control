#!/usr/bin/env bash
# End-to-end test of install.sh and the Claude save/restore hooks in a throwaway systemd
# container: new-machine install, save rules, autosave without a client, crash, upgrade from
# the first version, clean reboot, drift repair, uninstall, refusals, interrupts, the lock,
# pending runs, --autoremove, and a machine without systemd. See tests/README.md.
# The kill sweep (a kill before every step) is tests/killsweep.sh.
# Each case runs in a fresh container of its own, TCR_JOBS (default 4) at a time; stages 1-8
# build on each other and are one case, core. TCR_LOGS=<dir>: a whole run's logs are copied
# there (tests/mutants.sh uses them as its baseline).
#   tests/container.sh                 run every case; containers and image are removed after
#   TCR_ONLY=xdg,ro tests/container.sh only these cases (later: every case but core)
#   TCR_ONLY=ro tests/container.sh --keep   leave that case's container running to look around
# Single-quoted code is meant to expand inside the container, not here:
# shellcheck disable=SC2016
set -uo pipefail
TCR_SUITE="test"
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TSV='~/.local/share/tmux/resurrect/claude-panes.tsv'
RDIR='~/.local/share/tmux/resurrect'
SAVE='"$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet"'
MF='~/.local/state/tmux-claude-restore/manifest.json'

# Hash of ~/.tmux.conf and our unit files; files that do not exist just add nothing.
CONF_HASH='{ cat ~/.tmux.conf ~/.config/systemd/user/tmux-claude-autosave.* ~/.config/systemd/user/*.d/* 2>/dev/null || true; } | md5sum'
same_conf_and_units() { [ "$(as fresh "$CONF_HASH")" = "$(cat "$STAGE/fresh.md5")" ]; }
no_journal_lines() {
	[ "$(docker exec "$NAME" journalctl -q USER_UNIT=tmux-claude-autosave.service | wc -l)" = 0 ]
}
restore_done() { wait_for "$2" "$1" "[ -s $RDIR/claude-restore.log ] && [ ! -e $RDIR/claude-restore.pending ]"; }
same_snap() { [ "$(snap "$1")" = "$(cat "$STAGE/$1.snap")" ]; }
# setup_wait <seconds> <user> <bash code>: wait_for, for a step of the setup that the checks
# after it need (a fake's mark, a lock held). In vain, the host was too slow or the setup is
# wrong: the case ends with no counts line, so it counts as not finished and no check of it
# fails (as mkuser in tests/lib.sh does).
setup_wait() {
	wait_for "$@" && return 0
	echo "  FAIL  user $2: waited $1 s in vain for a step of the setup (the case stops): $3"; exit 1
}
# bg_run <user> <signal plan> <command> [hold]: run the command in its own session, as a terminal
# would, and send the signals to its whole process group. The plan is a list of
# "<seconds>:<signal>" sent after "step 2/" (the first clone) shows in the log, or
# "<file>:<signal>" sent once ~/<file> exists (a fake command marks that it runs); a run that
# ended first gets them too, in vain. Exit code in ~/run.rc, output in ~/run.log. A fake git
# (SLOW_GIT) holds the user's first clone until ~/git.go exists: bg_run makes it after the
# plan, unless "hold" (the case makes it itself).
# setsid -f, not `&`: bash starts a background job with SIGINT ignored, and a signal
# ignored on entry cannot be trapped, so the run would never see the Ctrl-C.
bg_run() {
	local u=$1 plan=$2 cmd=$3 s
	as "$u" "rm -f ~/run.rc ~/run.log ~/run.pid
		setsid -f bash -c 'trap : INT TERM HUP; echo \$\$ > ~/run.pid; PATH=\$HOME/bin:\$PATH $cmd > ~/run.log 2>&1; echo \$? > ~/run.rc' >/dev/null 2>&1"
	setup_wait 20 "$u" 'grep -q "step 2/" ~/run.log || [ -s ~/run.rc ]'
	for s in $plan; do
		# <seconds>:<signal> after a wait; <file>:<signal> once ~/<file> exists.
		if [[ ${s%%:*} =~ ^[0-9.]+$ ]]; then sleep "${s%%:*}"; else setup_wait 30 "$u" "[ -e ~/${s%%:*} ] || [ -s ~/run.rc ]"; fi
		as "$u" "kill -${s#*:} -- -\$(cat ~/run.pid)"
	done
	[ "${4:-}" = hold ] || as "$u" '[ ! -e ~/git.running ] || touch ~/git.go'
	wait_for 90 "$u" '[ -s ~/run.rc ]'
}
# The user's first clone marks ~/git.running, then waits until ~/git.go exists (at most 200 s): a
# signal plan sends on that mark (git.running:<signal>) and the clone goes on only when released
# (see bg_run), so how fast docker is changes nothing.
SLOW_GIT='mkdir -p ~/bin; printf "#!/bin/sh\ncase \"\$*\" in *clone*) [ -e ~/git.running ] || { touch ~/git.running; n=0; while [ ! -e ~/git.go ] && [ \$n -lt 1000 ]; do sleep 0.2; n=\$((n + 1)); done; } ;; esac\nexec /usr/bin/git \"\$@\"\n" > ~/bin/git; chmod +x ~/bin/git'
XC='~/.config/tmux/tmux.conf'
XP='~/.config/tmux/plugins'

case_core() {
step "Build the image and boot systemd"
check "systemd boots" booted || exit 1
check "user managers run for the lingering users" wait_for 30 fresh 'systemctl --user is-system-running | grep -qE "running|degraded"' || exit 1
if ! use_mirror old || ! use_mirror nosd; then echo "  FAIL  plugin mirror set up for users old and nosd"; exit 1; fi

step "New machine: install with tmux off (user fresh, plugins from GitHub)"
# Under tests/mutants.sh (TCR_MIRROR set) from the mirror instead: a GitHub outage must not
# fail a mutant's checks, and the baseline then does the same.
[ -z "${TCR_MIRROR:-}" ] || use_mirror fresh || exit 1
# A value of the user's own that must win; also keeps the autosave test short.
as fresh "echo \"set -g @continuum-save-interval '1'\" > ~/.tmux.conf"
as fresh 'bash /opt/tcr/install.sh' > "$STAGE/fresh.log" 2>&1; rc=$?
check "install exits 0" test $rc = 0
check "install prints no FAIL" bash -c "! grep -q FAIL '$STAGE/fresh.log'"
while read -r p sha; do
	check "plugin $p cloned at its pin" as fresh "[ \"\$(git -C ~/.tmux/plugins/$p rev-parse HEAD)\" = $sha ]"
done <<<"$PINS"
check "the user's own value wins" as fresh '[ "$(tmux show -gv @continuum-save-interval)" = 1 ]'
check "tmux runs as tmux.service" as fresh 'systemctl --user is-active -q tmux.service && tmux ls'
check "autosave timer active" as fresh 'systemctl --user is-active -q tmux-claude-autosave.timer'
check "tmux.service loaded the stop drop-in" as fresh 'systemctl --user show tmux.service -p DropInPaths --value | grep -q tmux-claude-restore.conf'
check "stop save goes through tmux run-shell" as fresh 'systemctl --user show tmux.service -p ExecStop --value | grep -q run-shell'
check "systemd-analyze verify passes on our units" as fresh 'systemd-analyze --user verify ~/.config/systemd/user/tmux-claude-autosave.service ~/.config/systemd/user/tmux-claude-autosave.timer'
check "--check exits 0" as fresh 'bash /opt/tcr/install.sh --check'
check "manifest written, nothing pending" as fresh "[ \"\$(jq -r '.pending // \"none\"' $MF)\" = none ]"
check "state folder 0700, manifest 0600" as fresh "[ \"\$(stat -c %a ~/.local/state/tmux-claude-restore) \$(stat -c %a $MF)\" = '700 600' ]"
check "manifest records the plugins and tmux.service install brought in" as fresh "jq -e '(.plugins | map(.cloned) | all) and .tmuxService.created and (.tmuxService.sha256 | length == 64)' $MF"
check "no backup file of the config" as fresh '! ls ~/.tmux.conf.bak.* 2>/dev/null | grep -q .'
as fresh "$CONF_HASH" > "$STAGE/fresh.md5"
as fresh 'bash /opt/tcr/install.sh' > "$STAGE/fresh2.log" 2>&1
check "a re-run changes nothing" same_conf_and_units
check "a re-run says so and takes no step" bash -c "grep -q 'nothing changed' '$STAGE/fresh2.log' && ! grep -q '^step ' '$STAGE/fresh2.log'"

step "Claude panes and the save hook (user fresh)"
as fresh '
	mkdir -p ~/"proj with space" ~/proj2 ~/late
	tmux new-session -d -s work -c ~/"proj with space"; tmux split-window -t work -c ~/proj2
	tmux new-session -d -s home -c ~; tmux new-session -d -s nested -c ~/proj2
	sleep 1
	tmux send-keys -t work:0.0 "FAKE_RC=1 claude" Enter
	tmux send-keys -t work:0.1 claude Enter
	tmux send-keys -t home claude Enter
	tmux send-keys -t nested "sh -c \"claude; :\"" Enter'
check "home pane stops at the trust prompt" wait_for 10 fresh 'tmux capture-pane -p -t home | grep -q "Yes, I trust this folder"'
as fresh 'tmux send-keys -t home Down; sleep 0.5; tmux send-keys -t home Enter'
check "4 claudes running" wait_for 10 fresh '[ "$(ls ~/.claude/sessions/*.json | wc -l)" = 4 ]'
check "pane scopes loaded the scope drop-in" as fresh 's=$(systemctl --user list-units --type=scope --no-legend --plain "tmux-spawn-*" | awk "NR == 1 {print \$1}"); systemctl --user show "$s" -p DropInPaths --value | grep -q tmux-claude-restore.conf'
as fresh "tmux run-shell $SAVE"
check "pane list has the 3 direct claudes" as fresh "[ \$(wc -l < $TSV) = 3 ]"
check "rc pane in a folder with a space: rc=1" as fresh "grep -qP '^work:0\\.0\\t[0-9a-f-]{36}\\t/home/fresh/proj with space\\t1\$' $TSV"
check "plain pane: rc=0" as fresh "grep -qP '^work:0\\.1\\t[0-9a-f-]{36}\\t/home/fresh/proj2\\t0\$' $TSV"
check "home pane recorded" as fresh "grep -qP '^home:0\\.0\\t[0-9a-f-]{36}\\t/home/fresh\\t0\$' $TSV"
check "nested claude not recorded" lacks fresh "$TSV" '^nested'
as fresh "p=\$(pgrep -u fresh -x claude | head -n1)
	jq -c '.tmux = \"\" | .sessionId = \"77777777-7777-4777-8777-777777777777\" | .bridgeSessionId = \"b\"' ~/.claude/sessions/\$p.json > ~/.claude/sessions/9\$p.json
	tmux run-shell $SAVE; rm ~/.claude/sessions/9\$p.json"
check "session file with an empty tmux field is skipped" bash -c "$(declare -f as lacks); NAME=$NAME; lacks fresh '$TSV' 77777777 && as fresh '[ \$(wc -l < $TSV) = 3 ]'"
check "pending lock blocks the save hook" as fresh "touch $RDIR/claude-restore.pending; m=\$(stat -c %y $TSV); sleep 1
	tmux run-shell $SAVE; r=\$(stat -c %y $TSV); rm $RDIR/claude-restore.pending; [ \"\$m\" = \"\$r\" ]"
check "--check exits 0 with panes" as fresh 'bash /opt/tcr/install.sh --check'

step "Autosave with no client attached (interval 1 min; waits up to 4 min)"
check "no client attached" as fresh '[ "$(tmux list-clients | wc -l)" = 0 ]'
t0=$(as fresh 'tmux show -gqv @continuum-save-last-timestamp')
check "the timer saved" wait_for 240 fresh "[ \"\$(tmux show -gqv @continuum-save-last-timestamp)\" -gt ${t0:-0} ]"
t1=$(as fresh 'tmux show -gqv @continuum-save-last-timestamp')
# continuum runs the save in the background: wait for the hook to rewrite the list.
check "the save rewrote the pane list" wait_for 30 fresh "[ \$(stat -c %Y $TSV) -ge ${t1:-0} ] && [ \$(wc -l < $TSV) = 3 ]"
check "the per-minute runs leave no journal lines" no_journal_lines

step "Crash: kill -9 the tmux server, start it again (user fresh)"
as fresh "tmux run-shell $SAVE; : > ~/claude-args.log; rm -f $RDIR/claude-restore.log"
last_info="l=\$(readlink $RDIR/last); echo \"\$l \$(stat -c %s $RDIR/\$l)\""
before=$(as fresh "$last_info")
as fresh 'p=$(tmux display -p "#{pid}"); [ "$p" -gt 1 ] && kill -9 "$p"'
# Until systemd has seen the crash and run ExecStop (the save that must write nothing).
setup_wait 30 fresh '[[ $(systemctl --user show -p ActiveState --value tmux.service) =~ ^(inactive|failed)$ ]]'
after=$(as fresh "$last_info")
echo "  last save before and after the crash: $before / $after"
check "last save unchanged by the crash" test "$before" = "$after"
check "last save is not empty" test "${after##* }" -gt 0
check "tmux.service not left failed" as fresh '! systemctl --user is-failed -q tmux.service'
as fresh 'pkill -u fresh -x claude; sleep 1; systemctl --user start tmux.service'
check "restore ran" restore_done fresh 60
check "3 claudes relaunched with --resume" wait_for 30 fresh '[ "$(grep -c -- "--resume" ~/claude-args.log)" = 3 ]'
check "home trust prompt answered by the restore" wait_for 10 fresh 'grep -q "trust: yes" ~/claude-args.log'

if [ -n "$BASE" ]; then
	step "Upgrade from the first version, which had no manifest (user old: own config, tmux running)"
	as old "cat > ~/.tmux.conf <<'EOF'
set -g mouse on
set -g @continuum-save-interval '10'
set -g @plugin 'tmux-plugins/tmux-resurrect'
# Relaunch Claude Code conversations per pane after restore
set -g @resurrect-hook-post-restore-all '~/.tmux/scripts/claude-restore.sh'

# my tpm
run '~/.tmux/plugins/tpm/tpm'
EOF"
	as old 'bash /opt/tcr-base/install.sh' >/dev/null 2>&1
	as old 'mkdir -p ~/w; tmux new-session -d -s w -c ~/w; sleep 1; tmux send-keys -t w "FAKE_RC=1 claude" Enter'
	setup_wait 30 old 'ls ~/.claude/sessions/*.json'
	as old 'cp ~/.tmux.conf ~/conf.v1; ls ~/.tmux.conf.bak.* 2>/dev/null | wc -l > ~/bak.count'
	as old 'bash /opt/tcr/install.sh' > "$STAGE/old.log" 2>&1; rc=$?
	check "upgrade exits 0" test $rc = 0
	check "--check exits 0 after the upgrade" as old 'bash /opt/tcr/install.sh --check'
	check "only the block's header line changed" as old '[ "$(diff ~/conf.v1 ~/.tmux.conf | grep -c "^[<>]")" = 2 ] && diff ~/conf.v1 ~/.tmux.conf | grep -q "^> .*managed by /opt/tcr/install.sh"'
	check "no new backup file" as old '[ "$(ls ~/.tmux.conf.bak.* 2>/dev/null | wc -l)" = "$(cat ~/bak.count)" ]'
	check "manifest: the config to restore is the old one without our parts" as old "jq -r .conf.restore $MF | base64 -d | grep -qx 'set -g mouse on' && ! jq -r .conf.restore $MF | base64 -d | grep -qE 'tmux-claude-restore|claude-restore.sh'"
	check "manifest: plugins from before the manifest are not marked as brought in" as old "jq -e '.plugins | map(.cloned) | any | not' $MF"
	check "the user's own value wins" as old '[ "$(tmux show -gv @continuum-save-interval)" = 10 ]'
	check "existing plugin line not added twice" as old '[ "$(grep -c "tmux-plugins/tmux-resurrect" ~/.tmux.conf)" = 1 ]'
	check "hand-added hook line replaced" bash -c "$(declare -f as lacks); NAME=$NAME; lacks old '~/.tmux.conf' '^# Relaunch Claude Code' && as old '[ \"\$(grep -c @resurrect-hook-post-restore-all ~/.tmux.conf)\" = 1 ]'"
	check "first save recorded the rc pane" as old "grep -qP '^w:0\\.0\\t[0-9a-f-]{36}\\t/home/old/w\\t1\$' $TSV"
fi

step "Clean reboot"
# Started after the last save: only the save on stop can record it.
as fresh 'tmux new-session -d -s late -c ~/late; sleep 0.5; tmux send-keys -t late "FAKE_RC=1 claude" Enter'
setup_wait 30 fresh 'grep -l "\"tmux\":\"late:" ~/.claude/sessions/*.json'
as fresh 'for f in ~/.claude/sessions/*.json; do jq -r "select(.tmux | test(\"^(work|home|late):\")) | [.sessionId, (if .bridgeSessionId then 1 else 0 end)] | @tsv" "$f"; done' \
	| sort > "$STAGE/expect"
check "4 claudes to bring back" test "$(wc -l < "$STAGE/expect")" = 4
for u in fresh old; do as $u ": > ~/claude-args.log; rm -f $RDIR/claude-restore.log" 2>/dev/null; done
docker restart -t 120 "$NAME" >/dev/null
check "systemd boots again" booted || exit 1
check "tmux.service started at boot without a login" wait_for 60 fresh 'systemctl --user is-active -q tmux.service'
check "restore finished" restore_done fresh 120
check "the save on stop recorded the late claude" as fresh "grep -q '^late:0\\.0' $TSV"
while read -r sid rc; do
	if [ "$rc" = 1 ]; then
		check "claude ${sid:0:8} resumed, remote control on" as fresh "grep -- '--resume $sid' ~/claude-args.log | grep -q remoteControlAtStartup"
	else
		check "claude ${sid:0:8} resumed, remote control off" as fresh "grep -- '--resume $sid' ~/claude-args.log | grep -vq remoteControlAtStartup"
	fi
done < "$STAGE/expect"
check "folder with a space restored" as fresh 'grep -q "cwd=/home/fresh/proj with space args=--permission-mode auto --resume" ~/claude-args.log'
check "home trust prompt answered" as fresh 'grep -q "trust: yes" ~/claude-args.log'
if [ -n "$BASE" ]; then
	check "upgraded user restored too" restore_done old 60
	check "upgraded user's claude resumed with remote control" wait_for 10 old 'grep -- "--resume" ~/claude-args.log | grep -q remoteControlAtStartup'
fi

step "--check catches drift, install repairs it (user fresh)"
as fresh 'sed -i s/1min/7min/ ~/.config/systemd/user/tmux-claude-autosave.timer'
as fresh 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
check "--check exits 4 on a changed timer file" test $rc = 4
as fresh 'bash /opt/tcr/install.sh' >/dev/null 2>&1
check "install repairs it" as fresh 'bash /opt/tcr/install.sh --check'
as fresh 'systemctl --user stop tmux-claude-autosave.timer'
as fresh 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
check "--check exits 4 on a stopped timer" test $rc = 4
as fresh 'bash /opt/tcr/install.sh' >/dev/null 2>&1
check "install restarts it" as fresh 'bash /opt/tcr/install.sh --check'

step "Uninstall and reinstall (user fresh)"
as fresh 'bash /opt/tcr/install.sh --uninstall' > "$STAGE/un.log" 2>&1; rc=$?
check "uninstall exits 0" test $rc = 0
check "config restored byte for byte" as fresh "[ \"\$(cat ~/.tmux.conf)\" = \"set -g @continuum-save-interval '1'\" ]"
check "our units and drop-ins removed" as fresh '! ls -d ~/.config/systemd/user/tmux-claude-autosave.* ~/.config/systemd/user/tmux.service.d ~/.config/systemd/user/tmux-spawn-.scope.d 2>/dev/null | grep -q .'
check "timer gone from systemd" as fresh '! systemctl --user is-active -q tmux-claude-autosave.timer'
check "hooks unset in running tmux" as fresh '[ -z "$(tmux show -gqv @resurrect-hook-post-save-all)" ]'
check "scripts removed" as fresh '! ls ~/.tmux/scripts/claude-*.sh 2>/dev/null | grep -q .'
check "tmux.service and plugins kept (no --autoremove)" as fresh '[ -e ~/.config/systemd/user/tmux.service ] && [ -d ~/.tmux/plugins/tmux-resurrect ]'
check "they are listed as no longer needed, with the command" grep -q -- '--uninstall --autoremove' "$STAGE/un.log"
check "only the record of them stays in the manifest" as fresh "jq -e '.residual and (has(\"files\") | not)' $MF"
as fresh 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
check "--check says not installed (exit 4)" test $rc = 4
check "a second uninstall is harmless" as fresh 'bash /opt/tcr/install.sh --uninstall'
as fresh 'bash /opt/tcr/install.sh' >/dev/null 2>&1
check "reinstall: --check exits 0" as fresh 'bash /opt/tcr/install.sh --check'
check "reinstall keeps the plugins marked as brought in" as fresh "jq -e '.plugins | map(.cloned) | all' $MF"
}
case_refusals() {
step "Refusals change nothing"
as nosd 'echo "set -g mouse on" > ~/.tmux.conf'; snap nosd > "$STAGE/nosd.snap"
as nosd 'bash /opt/tcr/install.sh' > "$STAGE/nosd.log" 2>&1; rc=$?
check "systemd runs, but no user manager (user nosd): install refused, exit 1" test $rc = 1
check "  it names the fix" grep -q "login session" "$STAGE/nosd.log"
check "  nothing changed" same_snap nosd
docker exec -u root -e HOME=/root "$NAME" bash /opt/tcr/install.sh > "$STAGE/root.log" 2>&1; rc=$?
check "as root: refused, exit 1, saying why" bash -c "[ $rc = 1 ] && grep -q 'running as root' '$STAGE/root.log'"
check "  nothing written for root" docker exec "$NAME" bash -c '[ ! -e /root/.tmux ] && [ ! -e /root/.local/state/tmux-claude-restore ]'
}
case_ro() {
mkuser ro 5001
as ro 'mkdir ~/ro; printf "set -g mouse on\n" > ~/ro/tmux.conf; ln -s ro/tmux.conf ~/.tmux.conf; chmod a-w ~/ro'
snap ro > "$STAGE/ro.snap"
as ro 'bash /opt/tcr/install.sh' >/dev/null 2>&1; rc=$?
check "config in a read-only folder: refused, exit 1" test $rc = 1
check "  nothing changed" same_snap ro
as ro 'bash /opt/tcr/install.sh --dry-run' > "$STAGE/dry.log" 2>&1; rc=$?
as ro 'chmod u+w ~/ro'; snap ro > "$STAGE/ro.snap"
as ro 'bash /opt/tcr/install.sh --dry-run' > "$STAGE/dry.log" 2>&1; rc=$?
check "--dry-run lists the steps and exits 0" bash -c "[ $rc = 0 ] && grep -q '^  step 1: write the manifest' '$STAGE/dry.log'"
check "  nothing changed" same_snap ro
as ro 'bash /opt/tcr/install.sh --uninstall --dry-run' >/dev/null 2>&1; rc=$?
check "uninstall --dry-run when not installed: exit 0, nothing changed" bash -c "[ $rc = 0 ] && $(declare -f as snap same_snap); NAME=$NAME STAGE=$STAGE same_snap ro"
as ro 'bash /opt/tcr/install.sh --bogus' >/dev/null 2>&1; rc=$?
check "unknown option: exit 2" test $rc = 2
rmuser ro
}
case_boom() {
mkuser boom 5004
as boom 'mkdir ~/.tmux; : > ~/.tmux/scripts'
as boom 'bash /opt/tcr/install.sh' > "$STAGE/boom.log" 2>&1; rc=$?
check "unexpected error in a step: exit 3" bash -c "[ $rc = 3 ] && grep -q 'FAILED at step' '$STAGE/boom.log'"
as boom 'bash /opt/tcr/install.sh --check' >/dev/null 2>&1; rc=$?
check "  --check reports the unfinished run (exit 4)" test $rc = 4
check "  after fixing the cause, a rerun finishes it" as boom 'rm ~/.tmux/scripts && bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
rmuser boom
}
case_link() {
step "Config through a symlink, closed pipe, inherited GIT_DIR (new users)"
mkuser link 5002
as link 'mkdir ~/dots; printf "set -g mouse on\n" > ~/dots/tmux.conf; ln -s dots/tmux.conf ~/.tmux.conf'
snap link > "$STAGE/link.snap"
as link 'bash /opt/tcr/install.sh | head -n1; echo "${PIPESTATUS[0]}" > ~/pipe.rc' >/dev/null 2>&1
check "install | head -n1: exit 0" as link '[ "$(cat ~/pipe.rc)" = 0 ]'
as link 'rm ~/pipe.rc'
check "  and the install is complete" as link 'bash /opt/tcr/install.sh --check'
check "the config is still a symlink, its target got the block" as link '[ -L ~/.tmux.conf ] && grep -q "tmux-claude-restore >>>" ~/dots/tmux.conf'
as link 'bash /opt/tcr/install.sh --uninstall --autoremove | head -n1; echo "${PIPESTATUS[0]}" > ~/pipe.rc' >/dev/null 2>&1
check "uninstall --autoremove | head -n1: exit 0" as link '[ "$(cat ~/pipe.rc)" = 0 ]'
as link 'rm ~/pipe.rc; tmux kill-server; systemctl --user stop tmux.service' >/dev/null 2>&1
check "  and the home is byte-identical to before" same_snap link
rmuser link
}
case_gitdir() {
mkuser gitdir 5003
as gitdir 'git init -q ~/other && git -C ~/other -c user.name=t -c user.email=t@t commit -q --allow-empty -m one && git -C ~/other rev-parse HEAD > ~/other.head'
as gitdir 'GIT_DIR=$HOME/other/.git GIT_WORK_TREE=$HOME/other bash /opt/tcr/install.sh' >/dev/null 2>&1; rc=$?
check "install with GIT_DIR set to another repo: exit 0" test $rc = 0
while read -r p sha; do
	check "  plugin $p at its pin" as gitdir "[ \"\$(git -C ~/.tmux/plugins/$p rev-parse HEAD)\" = $sha ]"
done <<<"$PINS"
check "  the other repo is unchanged" as gitdir '[ "$(git -C ~/other rev-parse HEAD)" = "$(cat ~/other.head)" ] && [ -z "$(git -C ~/other status --porcelain)" ] && [ "$(git -C ~/other rev-list --all | wc -l)" = 1 ]'
rmuser gitdir
}
case_signals() {
step "Interrupts (signals to the process group, as a terminal sends them; new users)"
uid=5010
for sig in INT TERM HUP; do
	u="sig$sig"; mkuser "$u" $((uid++)); as "$u" "$SLOW_GIT"
	bg_run "$u" "git.running:$sig" 'bash /opt/tcr/install.sh'
	check "first SIG$sig during the clone: exit 3" as "$u" '[ "$(cat ~/run.rc)" = 3 ]'
	check "  the clone finished, the run stopped before the next step (SIG$sig)" as "$u" '[ -d ~/.tmux/plugins/tpm ] && [ ! -d ~/.tmux/plugins/tmux-resurrect ] && grep -q "stopped before step 3" ~/run.log'
	check "  --check reports the unfinished run, exit 4 (SIG$sig)" as "$u" 'bash /opt/tcr/install.sh --check >/dev/null; [ $? = 4 ]'
	check "  rerun finishes it (SIG$sig)" as "$u" 'bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
	rmuser "$u"
done
}
case_sig2() {
mkuser sig2 5013; as sig2 "$SLOW_GIT"; as sig2 'echo "set -g mouse on" > ~/.tmux.conf'
snap sig2 > "$STAGE/sig2.snap"
bg_run sig2 "git.running:INT 0.5:INT" 'bash /opt/tcr/install.sh' hold
check "second SIGINT: exit 3 at once" as sig2 '[ "$(cat ~/run.rc)" = 3 ] && grep -q "stopped at once" ~/run.log'
check "  a rerun while the clone still runs is refused (exit 1): the clone holds the lock" as sig2 'pgrep -u sig2 -x git >/dev/null && { bash /opt/tcr/install.sh > ~/rerun.log 2>&1; rc=$?; rm -f ~/rerun.log; [ $rc = 1 ]; }'
as sig2 'touch ~/git.go'
check "  the clone was not killed: it ends on its own" wait_for 30 sig2 '[ -d ~/.tmux/plugins/.tpm.tmp/.git ] && ! pgrep -u sig2 -x git >/dev/null'
check "  rerun finishes it" as sig2 'bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
check "  then uninstall leaves the home as before" as sig2 'bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null; tmux kill-server; systemctl --user stop tmux.service; rm -f ~/run.rc ~/run.log ~/run.pid ~/git.running ~/git.go; true'
check "  byte for byte" same_snap sig2
rmuser sig2
}
case_signohup() {
mkuser signohup 5014; as signohup "$SLOW_GIT"
bg_run signohup "git.running:HUP" 'nohup bash /opt/tcr/install.sh'
check "under nohup, SIGHUP is ignored and the run completes (exit 0)" as signohup '[ "$(cat ~/run.rc)" = 0 ] && bash /opt/tcr/install.sh --check'
rmuser signohup
}
case_sigmv() {
# A short plain command, not a child run in its own session: a slow fake mv (the clone's
# last move, then every atomic write) is running when the SIGINT reaches the group.
# The SIGINT goes once the fake mv runs (it marks that), not after a set time: under load the
# run may not have reached it yet.
mkuser sigmv 5015; as sigmv 'mkdir -p ~/bin; printf "#!/bin/sh\ntouch ~/mv.running\nsleep 2\nexec /usr/bin/mv \"\$@\"\n" > ~/bin/mv; chmod +x ~/bin/mv'
bg_run sigmv "mv.running:INT" 'bash /opt/tcr/install.sh'
check "SIGINT during a plain command (mv): it finishes, the run stops before the next step" as sigmv '[ "$(cat ~/run.rc)" = 3 ] && grep -q "stopped before step" ~/run.log && ! grep -q FAILED ~/run.log'
check "  rerun finishes it" as sigmv 'rm -f ~/bin/mv; bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
rmuser sigmv
}
case_pend() {
step "Pending runs and the lock (new users)"
mkuser pend 5020
as pend 'echo "set -g mouse on" > ~/.tmux.conf'
as pend 'TCR_FAILPOINT=step:3 bash /opt/tcr/install.sh' >/dev/null 2>&1
as pend 'bash /opt/tcr/install.sh --check' > "$STAGE/pend.log" 2>&1; rc=$?
check "killed install: --check exits 4 and names the command that finishes it" bash -c "[ $rc = 4 ] && grep -q 'an earlier install did not finish (fix: /opt/tcr/install.sh' '$STAGE/pend.log'"
as pend 'bash /opt/tcr/install.sh' >/dev/null 2>&1
as pend 'TCR_FAILPOINT=step:3 bash /opt/tcr/install.sh --uninstall' >/dev/null 2>&1
as pend 'bash /opt/tcr/install.sh --check' > "$STAGE/pend.log" 2>&1; rc=$?
check "killed uninstall: --check exits 4 and names --uninstall" bash -c "[ $rc = 4 ] && grep -q 'an uninstall did not finish (fix: /opt/tcr/install.sh --uninstall)' '$STAGE/pend.log'"
snap pend > "$STAGE/pend.snap"
as pend 'bash /opt/tcr/install.sh' > "$STAGE/pend.log" 2>&1; rc=$?
check "install while an uninstall is pending: refused, exit 1" bash -c "[ $rc = 1 ] && grep -q 'an uninstall did not finish' '$STAGE/pend.log'"
check "  nothing changed" same_snap pend
check "uninstall finishes it" as pend 'bash /opt/tcr/install.sh --uninstall >/dev/null && [ "$(cat ~/.tmux.conf)" = "set -g mouse on" ]'
as pend 'bash /opt/tcr/install.sh' >/dev/null 2>&1
as pend 'sed -i s/1min/3min/ ~/.config/systemd/user/tmux-claude-autosave.timer'
snap pend > "$STAGE/pend.snap"
# Held until rmuser below; the runs start once it is held.
as pend 'flock ~/.local/state/tmux-claude-restore sleep 120 >/dev/null 2>&1 &'
setup_wait 30 pend '! flock -n ~/.local/state/tmux-claude-restore true'
as pend 'bash /opt/tcr/install.sh' > "$STAGE/lock.log" 2>&1; rc=$?
check "lock held: install refused, exit 1" bash -c "[ $rc = 1 ] && grep -q 'another tmux-claude-restore run is working' '$STAGE/lock.log'"
as pend 'bash /opt/tcr/install.sh --uninstall' >/dev/null 2>&1; rc=$?
check "lock held: uninstall refused, exit 1" test $rc = 1
check "  nothing changed" same_snap pend
rmuser pend
}
case_plain() {
mkuser plain 5021
as plain "printf \"set -g @continuum-boot 'off'\n\" > ~/.tmux.conf"
as plain 'bash /opt/tcr/install.sh' >/dev/null 2>&1; rc=$?
check "@continuum-boot off: install starts a plain tmux server, exit 0" bash -c "[ $rc = 0 ] && $(declare -f as); NAME=$NAME; as plain 'tmux ls && ! systemctl --user is-active -q tmux.service'"
check "  that server does not hold the lock" as plain 'flock -n ~/.local/state/tmux-claude-restore true'
rmuser plain
}
case_keep() {
step "--autoremove removes only what install brought in, unchanged and no longer needed"
mkuser keep 5030
as keep 'bash /opt/tcr/install.sh' >/dev/null 2>&1
as keep 'cd ~/.tmux/plugins && git -C tmux-resurrect checkout -q HEAD~1 && touch tmux-continuum/mine && mv tpm ~/tpm-real && ln -s ~/tpm-real tpm'
as keep 'bash /opt/tcr/install.sh --uninstall --autoremove' >/dev/null 2>&1; rc=$?
check "uninstall --autoremove exits 0" test $rc = 0
check "a plugin off its pin is kept" as keep '[ -d ~/.tmux/plugins/tmux-resurrect ]'
check "a plugin with a file of the user's is kept" as keep '[ -e ~/.tmux/plugins/tmux-continuum/mine ]'
check "a plugin that is a symlink is kept, its target untouched" as keep '[ -L ~/.tmux/plugins/tpm ] && [ -e ~/tpm-real/tpm ]'
check "tmux.service is kept while tmux-continuum stays" as keep '[ -e ~/.config/systemd/user/tmux.service ]'
rmuser keep
}
case_need() {
mkuser need 5031
as need "printf \"set -g @plugin 'tmux-plugins/tmux-resurrect'\n\" > ~/.tmux.conf"
as need 'bash /opt/tcr/install.sh' >/dev/null 2>&1
as need 'bash /opt/tcr/install.sh --uninstall --autoremove' >/dev/null 2>&1
check "a plugin the config still names is kept" as need '[ -d ~/.tmux/plugins/tmux-resurrect ]'
check "the others are removed, with tmux.service" as need '[ ! -e ~/.tmux/plugins/tmux-continuum ] && [ ! -e ~/.tmux/plugins/tpm ] && [ ! -e ~/.config/systemd/user/tmux.service ]'
rmuser need
}
case_window() {
mkuser window 5032
# A kill between creating the state folder and the first manifest write leaves it empty and
# unrecorded; the folder is ours by name, so uninstall removes it anyway.
as window 'mkdir -p -m 0700 ~/.local/state/tmux-claude-restore'
as window 'bash /opt/tcr/install.sh >/dev/null 2>&1; bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
check "an unrecorded state folder (a kill's leftover) is removed by uninstall" as window '[ ! -e ~/.local/state/tmux-claude-restore ]'
rmuser window
}
case_edit1() {
step "Edge cases from the review (new users)"
mkuser edit1 5040
as edit1 'bash /opt/tcr/install.sh >/dev/null 2>&1; echo "set -g mouse on" >> ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1'
check "config created by install, edited, install rerun: uninstall keeps the user's line" as edit1 'grep -qx "set -g mouse on" ~/.tmux.conf && ! grep -q "tmux-claude-restore >>>" ~/.tmux.conf'
rmuser edit1
}
case_edit2() {
mkuser edit2 5041
as edit2 'echo "set -g status off" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; echo "bind x kill-pane" >> ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1'
check "own config edited after install, install rerun: uninstall keeps both lines" as edit2 'grep -qx "set -g status off" ~/.tmux.conf && grep -qx "bind x kill-pane" ~/.tmux.conf && ! grep -q "tmux-claude-restore" ~/.tmux.conf'
rmuser edit2
}
case_marks() {
mkuser marks 5042
as marks 'bash /opt/tcr/install.sh >/dev/null 2>&1; sed -i "/^# <<< tmux-claude-restore <<</d" ~/.tmux.conf; echo "bind y kill-pane" >> ~/.tmux.conf'
snap marks > "$STAGE/marks.snap"
as marks 'bash /opt/tcr/install.sh' > "$STAGE/marks.log" 2>&1; rc=$?
check "block without its end line: install refused, exit 1, saying why" bash -c "[ $rc = 1 ] && grep -q 'begin line without an end line' '$STAGE/marks.log'"
as marks 'bash /opt/tcr/install.sh --uninstall' >/dev/null 2>&1; rc=$?
check "  uninstall refused too, exit 1" test $rc = 1
check "  nothing changed" same_snap marks
check "  the user's line after the block kept" as marks 'grep -qx "bind y kill-pane" ~/.tmux.conf'
rmuser marks
}
case_resid() {
mkuser resid 5043
as resid 'bash /opt/tcr/install.sh >/dev/null 2>&1; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1; TCR_FAILPOINT=step:2 bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
as resid 'bash /opt/tcr/install.sh --check' > "$STAGE/resid.log" 2>&1; rc=$?
check "killed --autoremove after a plain uninstall: --check reports it (exit 4)" bash -c "[ $rc = 4 ] && grep -q 'an uninstall did not finish' '$STAGE/resid.log'"
check "  a plain --uninstall finishes it" as resid "bash /opt/tcr/install.sh --uninstall >/dev/null && [ \"\$(jq -r '.pending // \"none\"' $MF)\" = none ]"
check "  then install works again" as resid 'bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
rmuser resid
}
case_noclaude() {
mkuser noclaude 5044
as noclaude 'PATH=/usr/bin:/bin bash /opt/tcr/install.sh' > "$STAGE/noclaude.log" 2>&1; rc=$?
check "claude not on PATH: install exits 0 with a warning" bash -c "[ $rc = 0 ] && grep -q 'claude not on PATH' '$STAGE/noclaude.log'"
check "  nothing pending" as noclaude "[ \"\$(jq -r '.pending // \"none\"' $MF)\" = none ]"
rmuser noclaude
}
case_race() {
mkuser race 5045
as race 'for i in 1 2; do setsid -f bash -c "bash /opt/tcr/install.sh > ~/race$i.log 2>&1; echo \$? > ~/race$i.rc"; done'
wait_for 120 race '[ -s ~/race1.rc ] && [ -s ~/race2.rc ]'
check "two first installs at once: each exits 0 or 1 (refused), never 3" as race 'for i in 1 2; do case "$(cat ~/race$i.rc)" in 0|1) ;; *) for j in 1 2; do echo "run $j: exit $(cat ~/race$j.rc)"; cat ~/race$j.log; done; exit 1 ;; esac; done'
check "  and the result is healthy" as race 'bash /opt/tcr/install.sh >/dev/null && bash /opt/tcr/install.sh --check'
rmuser race
}
case_ownsvc() {
mkuser ownsvc 5046
as ownsvc 'mkdir -p ~/.config/systemd/user; printf "[Unit]\nDescription=my own tmux\n[Service]\nType=forking\nExecStart=/usr/bin/tmux -L svc new-session -d\nExecStop=/usr/bin/tmux -L svc kill-server\n[Install]\nWantedBy=default.target\n" > ~/.config/systemd/user/tmux.service; sha256sum ~/.config/systemd/user/tmux.service > ~/svc.sha'
as ownsvc 'bash /opt/tcr/install.sh' > "$STAGE/ownsvc.log" 2>&1; rc=$?
check "the user's own tmux.service: install exits 0 and says it is left alone" bash -c "[ $rc = 0 ] && grep -q 'is your own' '$STAGE/ownsvc.log'"
check "  no stop drop-in for it, the unit file unchanged" as ownsvc '[ ! -e ~/.config/systemd/user/tmux.service.d/tmux-claude-restore.conf ] && sha256sum -c --quiet ~/svc.sha'
check "  --check exits 0" as ownsvc 'bash /opt/tcr/install.sh --check'
check "  uninstall --autoremove keeps it, unchanged" as ownsvc 'bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null && sha256sum -c --quiet ~/svc.sha'
rmuser ownsvc
}
case_comment() {
mkuser comment 5047
as comment "printf \"# set -g @plugin 'tmux-plugins/tmux-resurrect'\n\" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1"
check "a commented-out @plugin line: the block still names the plugin" as comment "grep -qx \"set -g @plugin 'tmux-plugins/tmux-resurrect'\" ~/.tmux.conf"
rmuser comment
}
case_hidden() {
mkuser hidden 5048
as hidden 'bash /opt/tcr/install.sh >/dev/null 2>&1; git config --global status.showUntrackedFiles no; echo mine > ~/.tmux/plugins/tpm/my-notes'
as hidden 'cd ~/.tmux/plugins/tmux-resurrect && pin=$(git rev-parse HEAD) && git checkout -q -b mine && echo x > mine.txt && git add mine.txt && git -c user.name=t -c user.email=t@t commit -qm mine && git checkout -q --detach "$pin"'
as hidden 'bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
check "--autoremove keeps a plugin with a file of the user's that showUntrackedFiles=no hides" as hidden 'grep -qx mine ~/.tmux/plugins/tpm/my-notes'
check "  and one with a commit of the user's on a local branch" as hidden '[ -d ~/.tmux/plugins/tmux-resurrect ] && git -C ~/.tmux/plugins/tmux-resurrect rev-parse -q --verify mine'
rmuser hidden
}
case_ownhook() {
mkuser ownhook 5050
as ownhook 'bash /opt/tcr/install.sh >/dev/null 2>&1; tmux set -g @resurrect-hook-post-save-all "echo mine"; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1'
check "uninstall leaves a resurrect hook of the user's own in the running tmux" as ownhook '[ "$(tmux show -gqv @resurrect-hook-post-save-all)" = "echo mine" ]'
rmuser ownhook
}
case_urlplug() {
mkuser urlplug 5051
as urlplug "echo \"set -g @plugin 'https://github.com/tmux-plugins/tmux-resurrect'\" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1"
check "an @plugin line as a URL counts: no second line for that plugin" as urlplug '[ "$(grep -c "@plugin.*tmux-resurrect" ~/.tmux.conf)" = 1 ]'
check "  and --autoremove keeps the plugin it names" as urlplug 'bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1; [ -d ~/.tmux/plugins/tmux-resurrect ] && [ ! -e ~/.tmux/plugins/tmux-continuum ]'
rmuser urlplug
}
case_srcconf() {
mkuser srcconf 5052
as srcconf 'echo "set -g mouse on" > ~/.tmux.extra; echo "source-file ~/.tmux.extra" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
check "a config that sources another file: --autoremove keeps every plugin" as srcconf 'for p in tpm tmux-resurrect tmux-continuum; do [ -d ~/.tmux/plugins/$p ] || exit 1; done'
rmuser srcconf
}
case_bytes() {
# A config with a Latin-1 byte, CRLF lines and no final newline, under a UTF-8 locale: with
# mawk (Ubuntu's awk) and with gawk (Fedora's, Arch's), uninstall gives back the same bytes,
# and also after an edit (then only our block is taken out).
uid=5053
for a in mawk gawk; do
	u="bytes$a"; mkuser "$u" $((uid++))
	as "$u" "mkdir -p ~/awk; ln -s /usr/bin/$a ~/awk/awk; printf 'set -g status-left \"caf\\351\"\\r\\nbind y kill-pane\\r\\nlast' > ~/.tmux.conf; cp ~/.tmux.conf ~/conf.orig"
	as "$u" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=~/awk:$PATH; bash /opt/tcr/install.sh >/dev/null 2>&1 && bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1'
	check "$a, a Latin-1 byte, CRLF, no final newline: uninstall gives back the same bytes" as "$u" 'cmp -s ~/.tmux.conf ~/conf.orig'
	as "$u" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=~/awk:$PATH; bash /opt/tcr/install.sh >/dev/null 2>&1; printf "\nset -g mouse on\n" >> ~/.tmux.conf; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1'
	check "  and after an edit, only our block is taken out" as "$u" 'head -c "$(stat -c %s ~/conf.orig)" ~/.tmux.conf | cmp -s - ~/conf.orig && grep -qx "set -g mouse on" ~/.tmux.conf && ! grep -q tmux-claude-restore ~/.tmux.conf'
	rmuser "$u"
done
}
case_fsmon() {
# A gitconfig of the user's whose fsmonitor hook leaves a process running (as a watchman
# setup does): our git calls must not run it, or that process would keep the lock.
mkuser fsmon 5055
as fsmon 'printf "#!/bin/sh\necho called >> \$HOME/fsm.calls\nsleep 300 &\nexit 1\n" > ~/fsm.sh; chmod +x ~/fsm.sh; git config --global core.fsmonitor ~/fsm.sh'
as fsmon 'bash /opt/tcr/install.sh >/dev/null 2>&1; echo mine > ~/.tmux/plugins/tpm/my-notes; bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
check "the user's fsmonitor hook never runs from our git calls" as fsmon '[ ! -e ~/fsm.calls ]'
check "  so nothing holds the lock afterwards: install runs again" as fsmon 'bash /opt/tcr/install.sh >/dev/null 2>&1 && bash /opt/tcr/install.sh --check >/dev/null'
rmuser fsmon
}
case_edrun() {
# The user saves an edit to ~/.tmux.conf while a run is going: the run must stop rather than
# write over it. Slow fakes hold the run open: mv (every write) for install, systemctl
# (the timer step, before the config step) for uninstall.
mkuser edrun 5056
as edrun 'mkdir -p ~/bin; printf "#!/bin/sh\nsleep 2\nexec /usr/bin/mv \"\$@\"\n" > ~/bin/mv; chmod +x ~/bin/mv; echo "set -g status off" > ~/.tmux.conf'
as edrun 'setsid -f bash -c "PATH=\$HOME/bin:\$PATH bash /opt/tcr/install.sh > ~/run.log 2>&1; echo \$? > ~/run.rc" >/dev/null 2>&1'
setup_wait 30 edrun 'grep -q "step 2/" ~/run.log || [ -s ~/run.rc ]'
as edrun 'echo "bind z kill-pane" >> ~/.tmux.conf'
wait_for 120 edrun '[ -s ~/run.rc ]'
check "config edited while install runs: the run stops (exit 3) and the edit is kept" as edrun '[ "$(cat ~/run.rc)" = 3 ] && grep -q "changed while this run was going" ~/run.log && grep -qx "bind z kill-pane" ~/.tmux.conf'
check "  a rerun plans again and finishes, with the edit" as edrun 'rm -f ~/bin/mv ~/run.rc; bash /opt/tcr/install.sh >/dev/null 2>&1 && grep -qx "bind z kill-pane" ~/.tmux.conf && bash /opt/tcr/install.sh --check >/dev/null'
as edrun 'printf "#!/bin/sh\nsleep 3\nexec /usr/bin/systemctl \"\$@\"\n" > ~/bin/systemctl; chmod +x ~/bin/systemctl'
as edrun 'setsid -f bash -c "PATH=\$HOME/bin:\$PATH bash /opt/tcr/install.sh --uninstall > ~/run.log 2>&1; echo \$? > ~/run.rc" >/dev/null 2>&1'
setup_wait 60 edrun 'grep -q "step 2/" ~/run.log || [ -s ~/run.rc ]'
as edrun 'echo "bind w kill-pane" >> ~/.tmux.conf'
wait_for 120 edrun '[ -s ~/run.rc ]'
check "config edited while uninstall runs: it stops (exit 3) and the edit is kept" as edrun '[ "$(cat ~/run.rc)" = 3 ] && grep -q "changed while this run was going" ~/run.log && grep -qx "bind w kill-pane" ~/.tmux.conf'
check "  a rerun finishes: both edits kept, our block gone" as edrun 'rm -f ~/bin/systemctl; bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1 && grep -qx "bind z kill-pane" ~/.tmux.conf && grep -qx "bind w kill-pane" ~/.tmux.conf && ! grep -q tmux-claude-restore ~/.tmux.conf'
rmuser edrun
}
case_svcrec() {
mkuser svcrec 5049
pre=""; while read -r p sha; do pre+="git clone -q https://github.com/tmux-plugins/$p ~/.tmux/plugins/$p && git -C ~/.tmux/plugins/$p checkout -q $sha && "; done <<<"$PINS"
# Plugins loaded (so install only sets the hooks), @continuum-boot off until our block.
as svcrec "printf \"set -g @plugin 'tmux-plugins/tpm'\nset -g @plugin 'tmux-plugins/tmux-resurrect'\nset -g @plugin 'tmux-plugins/tmux-continuum'\nrun '~/.tmux/plugins/tpm/tpm'\n\" > ~/.tmux.conf; ${pre}tmux new-session -d && tmux set -g @continuum-save-interval 15"
as svcrec 'bash /opt/tcr/install.sh >/dev/null 2>&1'
check "tmux running, plugins loaded, tmux.service never written: not recorded as brought in" as svcrec "[ ! -e ~/.config/systemd/user/tmux.service ] && jq -e '.tmuxService.created == false' $MF"
rmuser svcrec
}
case_xdg() {
step "Config in ~/.config/tmux: the files TPM uses (new users)"
mkuser xdg 5060
as xdg "mkdir -p ~/.config/tmux ~/p; printf 'set -g mouse on\n# mine' > $XC"
snap xdg > "$STAGE/xdg.snap"
as xdg 'bash /opt/tcr/install.sh' > "$STAGE/xdg.log" 2>&1; rc=$?
check "only the XDG config: install exits 0, no FAIL" bash -c "[ $rc = 0 ] && ! grep -q FAIL '$STAGE/xdg.log'"
check "  the block and TPM's run line are in the XDG file; no ~/.tmux.conf" as xdg "grep -qF 'tmux-claude-restore >>>' $XC && grep -qx \"run '$XP/tpm/tpm'\" $XC && grep -qx 'set -g mouse on' $XC && [ ! -e ~/.tmux.conf ]"
check "  plugins cloned into the XDG plugin folder, none in ~/.tmux/plugins" as xdg "for p in tpm tmux-resurrect tmux-continuum; do [ -d $XP/\$p/.git ] || exit 1; done; [ ! -e ~/.tmux/plugins ]"
check "  tmux-resurrect loaded from there (its save key bound)" as xdg "[ \"\$(tmux show -gv @resurrect-save-script-path)\" = \$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh ] && tmux list-keys | grep -q '.config/tmux/plugins/tmux-resurrect/scripts/save.sh'"
check "  the units run the plugins from there" as xdg 'grep -q "%h/.config/tmux/plugins/tmux-continuum/" ~/.config/systemd/user/tmux-claude-autosave.service && grep -q "%h/.config/tmux/plugins/tmux-resurrect/" ~/.config/systemd/user/tmux.service.d/tmux-claude-restore.conf'
check "  the manifest records both paths" as xdg "jq -e '.conf.path == \"'\$HOME'/.config/tmux/tmux.conf\" and .plugDir == \"'\$HOME'/.config/tmux/plugins\"' $MF"
as xdg 'bash /opt/tcr/install.sh --check' > "$STAGE/xdgc.log" 2>&1; rc=$?
check "  --check exits 0 and says tmux-resurrect is loaded" bash -c "[ $rc = 0 ] && grep -q 'tmux-resurrect loaded from' '$STAGE/xdgc.log'"
as xdg 'tmux new-session -d -s w -c ~/p; sleep 1; tmux send-keys -t w claude Enter'
setup_wait 30 xdg '[ "$(ls ~/.claude/sessions/*.json 2>/dev/null | wc -l)" = 1 ]'
as xdg "tmux run-shell \"\$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh quiet\""
check "  the save hook records the claude pane" as xdg "grep -qP '^w:0\\.0\\t[0-9a-f-]{36}\\t/home/xdg/p\\t0\$' $TSV"
as xdg 'tmux set -gu @resurrect-save-script-path'
as xdg 'bash /opt/tcr/install.sh --check' > "$STAGE/xdgc2.log" 2>&1; rc=$?
check "hooks set but tmux-resurrect not loaded: --check exits 4 and says nothing is saved" bash -c "[ $rc = 4 ] && grep -q 'tmux-resurrect not loaded' '$STAGE/xdgc2.log'"
check "  install repairs it (loads the config)" as xdg 'bash /opt/tcr/install.sh >/dev/null 2>&1 && bash /opt/tcr/install.sh --check'
as xdg 'bash /opt/tcr/install.sh --uninstall --autoremove' > "$STAGE/xdgu.log" 2>&1; rc=$?
# The test's own claude pane: its bash writes ~/.bash_history when tmux exits.
as xdg 'tmux kill-server; systemctl --user stop tmux.service; sleep 1; rm -f ~/.bash_history' >/dev/null 2>&1
check "  uninstall --autoremove exits 0; the home is byte-identical to before" bash -c "[ $rc = 0 ] && $(declare -f as snap same_snap); NAME=$NAME STAGE=$STAGE same_snap xdg"
rmuser xdg
}
case_xmove() {
mkuser xmove 5061
as xmove 'echo "set -g mouse on" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; mkdir -p ~/.config/tmux; echo "set -g status off" > ~/.config/tmux/tmux.conf'
as xmove 'bash /opt/tcr/install.sh --check' > "$STAGE/xmove.log" 2>&1; rc=$?
check "the user moves to the XDG config after install: --check exits 4 and names the fix" bash -c "[ $rc = 4 ] && grep -q 'now load as' '$STAGE/xmove.log'"
snap xmove > "$STAGE/xmove.snap"
as xmove 'bash /opt/tcr/install.sh' > "$STAGE/xmove2.log" 2>&1; rc=$?
check "  install refuses (exit 1) and says to uninstall first" bash -c "[ $rc = 1 ] && grep -q 'run .*--uninstall, then' '$STAGE/xmove2.log'"
check "  nothing changed" same_snap xmove
check "  uninstall --autoremove works from the manifest's paths: ~/.tmux.conf back as it was" as xmove "bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1 && [ \"\$(cat ~/.tmux.conf)\" = 'set -g mouse on' ] && [ ! -e ~/.tmux/plugins ] && [ \"\$(cat $XC)\" = 'set -g status off' ]"
as xmove 'bash /opt/tcr/install.sh' > "$STAGE/xmove3.log" 2>&1; rc=$?
check "  then install into the XDG config, tmux still running from the old one: exit 0" bash -c "[ $rc = 0 ] && ! grep -q FAIL '$STAGE/xmove3.log'"
check "  tmux-resurrect now loaded from the XDG folder; --check exits 0" as xmove "[ \"\$(tmux show -gv @resurrect-save-script-path)\" = \$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh ] && bash /opt/tcr/install.sh --check >/dev/null && ! grep -q tmux-claude-restore ~/.tmux.conf"
rmuser xmove
}
case_xback() {
mkuser xback 5067
as xback "mkdir -p ~/.config/tmux; printf 'set -g mouse on\n# mine' > $XC; bash /opt/tcr/install.sh >/dev/null 2>&1; mv $XC ~/.tmux.conf"
as xback 'bash /opt/tcr/install.sh --check' > "$STAGE/xback.log" 2>&1; rc=$?
check "the user moves the XDG config to ~/.tmux.conf after install: --check exits 4, names both" bash -c "[ $rc = 4 ] && grep -q 'now load as' '$STAGE/xback.log' && grep -q 'holds lines of ours too' '$STAGE/xback.log'"
as xback 'bash /opt/tcr/install.sh --uninstall --autoremove' > "$STAGE/xback2.log" 2>&1; rc=$?
check "  uninstall --autoremove exits 0: our lines out of ~/.tmux.conf, the user's kept byte for byte" bash -c "[ $rc = 0 ] && $(declare -f as); NAME=$NAME; as xback '[ \"\$(od -c ~/.tmux.conf)\" = \"\$(printf \"set -g mouse on\n# mine\" | od -c)\" ]'"
check "  the plugins in the XDG folder are removed" as xback "[ ! -e $XP ] && [ ! -e ~/.tmux/plugins ]"
check "  --check: not installed" as xback 'bash /opt/tcr/install.sh --check | grep -q "not installed"'
rmuser xback
}
case_xleg() {
mkuser xleg 5063
as xleg 'bash /opt/tcr/install.sh >/dev/null 2>&1; rm -r ~/.local/state/tmux-claude-restore; mkdir -p ~/.config/tmux; echo "set -g status off" > ~/.config/tmux/tmux.conf'
snap xleg > "$STAGE/xleg.snap"
as xleg 'bash /opt/tcr/install.sh' > "$STAGE/xleg.log" 2>&1; rc=$?
check "our block in ~/.tmux.conf without a manifest, XDG config now there: install refuses (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'earlier install is in /home/xleg/.tmux.conf' '$STAGE/xleg.log'"
check "  nothing changed" same_snap xleg
check "  uninstall finds the block in ~/.tmux.conf and removes it" as xleg "bash /opt/tcr/install.sh --uninstall >/dev/null 2>&1 && ! grep -q tmux-claude-restore ~/.tmux.conf && [ \"\$(cat $XC)\" = 'set -g status off' ]"
rmuser xleg
}
case_xenv() {
mkuser xenv 5064
as xenv 'echo "set-environment -g TMUX_PLUGIN_MANAGER_PATH ~/myplugins/" > ~/.tmux.conf'
snap xenv > "$STAGE/xenv.snap"
as xenv 'bash /opt/tcr/install.sh' > "$STAGE/xenv.log" 2>&1; rc=$?
check "a config that sets TMUX_PLUGIN_MANAGER_PATH: install refuses (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'TMUX_PLUGIN_MANAGER_PATH' '$STAGE/xenv.log'"
check "  nothing changed" same_snap xenv
rmuser xenv
}
case_xoth() {
mkuser xoth 5065
as xoth "mkdir -p ~/.config/tmux; echo 'set -g status off' > $XC; echo \"set -g @plugin 'tmux-plugins/tmux-resurrect'\" > ~/.tmux.conf"
as xoth 'bash /opt/tcr/install.sh >/dev/null 2>&1 && bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1'
check "--autoremove keeps a plugin the other config file names (tmux reads both)" as xoth "[ -d $XP/tmux-resurrect ] && [ ! -e $XP/tpm ] && [ ! -e $XP/tmux-continuum ]"
rmuser xoth
}
case_xsp() {
mkuser xsp 5066
as xsp 'mkdir -p ~/"my config"/tmux; echo "set -g status off" > ~/"my config"/tmux/tmux.conf'
snap xsp > "$STAGE/xsp.snap"
as xsp 'XDG_CONFIG_HOME=~/"my config" bash /opt/tcr/install.sh' > "$STAGE/xsp.log" 2>&1; rc=$?
check "a plugin folder with a space: install refuses (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'a space' '$STAGE/xsp.log'"
check "  nothing changed" same_snap xsp
rmuser xsp
}
case_rdir() {
mkuser rdir 5062
as rdir "mkdir ~/p; echo \"set -g @resurrect-dir '~/rs'\" > ~/.tmux.conf; bash /opt/tcr/install.sh >/dev/null 2>&1; tmux new-session -d -s w -c ~/p; sleep 1; tmux send-keys -t w claude Enter"
setup_wait 30 rdir '[ "$(ls ~/.claude/sessions/*.json 2>/dev/null | wc -l)" = 1 ]'
as rdir "tmux run-shell $SAVE"
as rdir 'bash /opt/tcr/install.sh --check' > "$STAGE/rdir.log" 2>&1
check "@resurrect-dir: --check lists the panes saved there" grep -q 'tracked panes (/home/rdir/rs/claude-panes.tsv)' "$STAGE/rdir.log"
as rdir 'bash /opt/tcr/install.sh --uninstall' > "$STAGE/rdir2.log" 2>&1
check "  uninstall names that folder as kept" grep -q 'kept: /home/rdir/rs ' "$STAGE/rdir2.log"
rmuser rdir
}
case_nosystemd() {
step "A machine without systemd (a second container, no init)"
docker run --rm --pull never "${LABELS[@]}" -u 2001 -e HOME=/home/fresh -e USER=fresh -e LANG=C.UTF-8 -w /home/fresh \
	-v "$STAGE/new:/opt/tcr:ro" -v "$MIRROR:/opt/mirror:ro" --entrypoint bash "$IMAGE" -c '
	git config --global url.file:///opt/mirror/.insteadOf https://github.com/tmux-plugins/
	for p in tpm tmux-resurrect tmux-continuum; do git config --global --add safe.directory /opt/mirror/$p; done
	echo "set -g mouse on" > ~/.tmux.conf
	s() { find ~ -mindepth 1 -path ~/.local/share -prune -o -printf "%y %m %p\n" | grep -vx "d [0-9]* /home/fresh/.local" | sort; md5sum ~/.tmux.conf; }
	s > /tmp/before
	bash /opt/tcr/install.sh > /tmp/log 2>&1; echo "install=$?"
	grep -q "does not run systemd" /tmp/log && echo "warned=yes"
	tmux ls >/dev/null 2>&1 && echo "tmux=yes"
	[ -e ~/.config/systemd ] || echo "units=none"
	bash /opt/tcr/install.sh --check >/dev/null 2>&1; echo "check=$?"
	bash /opt/tcr/install.sh --uninstall --autoremove >/dev/null 2>&1; echo "uninstall=$?"
	tmux kill-server 2>/dev/null; s > /tmp/after
	cmp -s /tmp/before /tmp/after && echo "identical=yes"
	echo "end=yes"' > "$STAGE/nosystemd.out" 2>&1
for want in install=0 warned=yes tmux=yes units=none check=0 uninstall=0 identical=yes; do
	check "no systemd: $want" grep -qx "$want" "$STAGE/nosystemd.out"
done
}

# ---------------------------------------------------------------- runner
CASES=(core refusals ro boom link gitdir signals sig2 signohup sigmv pend plain keep need window edit1 edit2 marks resid noclaude race ownsvc comment hidden ownhook urlplug srcconf bytes fsmon edrun svcrec xdg xmove xback xleg xenv xoth xsp rdir nosystemd)
# Every case function is in CASES, and only those: a case left out would never run.
[ "$(printf '%s\n' "${CASES[@]}" | sort)" = "$(declare -F | sed -n 's/^declare -f case_//p' | sort)" ] || { echo "CASES and the case_ functions differ"; exit 2; }
CJOBS=${TCR_JOBS:-4}
[[ $CJOBS =~ ^[1-9][0-9]*$ ]] || { echo "TCR_JOBS must be a whole number above 0"; exit 2; }
RUN=$NAME
# A user without a user manager ends its case (see mkuser in tests/lib.sh).
MKUSER_STOPS=1
# run_case <case>: the case in a fresh container named $RUN-<case> (nosystemd starts its own).
# Prints a header, the case's lines and a last line "== counts <case> <passed> <failed>".
run_case() {
	local c=$1
	NAME="$RUN-$c"; PASS=0; FAIL=0
	echo "== case $c"
	if [ "$c" != nosystemd ]; then
		if ! boot_container; then
			echo "  FAIL  container for case $c started"; echo "== counts $c 0 1"; return
		fi
		# core checks these itself.
		if [ "$c" != core ]; then
			if ! booted || ! wait_for 30 fresh 'systemctl --user is-system-running | grep -qE "running|degraded"'; then
				echo "  FAIL  systemd boots (case $c)"; echo "== counts $c 0 1"; return
			fi
			if ! use_mirror old || ! use_mirror nosd; then
				echo "  FAIL  plugin mirror set up (case $c)"; echo "== counts $c 0 1"; return
			fi
		fi
	fi
	"case_$c"
	echo "== counts $c $PASS $FAIL"
	# Whether the case's machine was still sound at the end (machine_sound in tests/lib.sh):
	# tests/mutants.sh needs this line to trust a FAIL.
	if [ "$c" = nosystemd ]; then grep -qx 'end=yes' "$STAGE/nosystemd.out" 2>/dev/null && echo "== healthy $c"
	elif machine_sound; then echo "== healthy $c"; fi
	# By this run's label and the name together: never a container of someone else's.
	[ $KEEP = 1 ] || [ "$c" = nosystemd ] || docker ps -aq --filter "label=tcr-run=$RUN_LABEL" --filter "name=^$NAME\$" | xargs -r docker rm -f >/dev/null 2>&1
}

sel=()
case "${TCR_ONLY:-}" in
"") sel=("${CASES[@]}") ;;
later) for c in "${CASES[@]}"; do [ "$c" = core ] || sel+=("$c"); done ;;
*)
	IFS=, read -ra sel <<<"$TCR_ONLY"
	for c in "${sel[@]}"; do declare -F "case_$c" >/dev/null || { echo "unknown case: $c (cases: ${CASES[*]})"; exit 2; }; done
	[ "$(printf '%s\n' "${sel[@]}" | sort | uniq -d)" = "" ] || { echo "a case is named twice in TCR_ONLY"; exit 2; }
	;;
esac
[ ${#sel[@]} -gt 0 ] || { echo "no case selected"; exit 2; }
[ $KEEP = 0 ] || [ ${#sel[@]} = 1 ] || { echo "--keep needs exactly one case (TCR_ONLY=<case>)"; exit 2; }
prepare
LOGS="$STAGE/logs"; mkdir -p "$LOGS"
echo "${#sel[@]} cases, $CJOBS at a time"
STARTED=1
running=0
for c in "${sel[@]}"; do
	( run_case "$c" ) > "$LOGS/case.$c.log" 2>&1 &
	running=$((running + 1)); [ $running -ge "$CJOBS" ] && { wait -n; running=$((running - 1)); }
done
wait
# In the order of CASES, whatever order they finished in. A case without its counts line
# stopped early: that is a failure, never a pass.
for c in "${sel[@]}"; do
	cat "$LOGS/case.$c.log"
	p=""; f=""
	read -r p f < <(sed -n "s/^== counts $c \([0-9]*\) \([0-9]*\)\$/\1 \2/p" "$LOGS/case.$c.log") || true
	if [ -z "$p" ]; then echo "  FAIL  case $c did not finish"; FAIL=$((FAIL + 1)); UNFINISHED=1
	elif [ $((p + f)) = 0 ]; then echo "  FAIL  case $c ran no checks"; FAIL=$((FAIL + 1))
	else PASS=$((PASS + p)); FAIL=$((FAIL + f)); fi
done
printf 'passed %d failed %d\n' "$PASS" "$FAIL" > "$LOGS/result"
[ -n "${TCR_ONLY:-}" ] || save_logs container "$LOGS"
# A case that did not finish may have left a `docker run` in flight: then cleanup waits (lib.sh).
[ $UNFINISHED = 1 ] || DONE=1
summary
