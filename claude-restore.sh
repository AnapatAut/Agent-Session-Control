#!/usr/bin/env bash
# tmux-resurrect post-restore-all hook: relaunch the Claude Code conversations
# recorded by claude-save.sh, each in its original pane, in auto permission mode.
# Remote control is turned on only where it was on at last save.
# Detaches so the restore itself is not held up.
set -u
. "$HOME/.tmux/scripts/claude-lib.sh"
[ -s "$CLAUDE_MAP" ] || exit 0
# True if a live claude process (not a stale file left by a crash) holds session $1.
claude_live() {
	local f pid
	for f in $(grep -ls "\"sessionId\":\"$1\"" "$HOME"/.claude/sessions/*.json); do
		pid=$(jq -r .pid "$f" 2>/dev/null)
		[ "$(cat /proc/"$pid"/comm 2>/dev/null)" = claude ] && return 0
	done
	return 1
}
touch "$CLAUDE_PENDING"
(
	trap 'rm -f "$CLAUDE_PENDING"' EXIT
	# At boot the network may lag the user manager; rc needs it. Give up after 2 min.
	for _ in $(seq 60); do getent hosts api.anthropic.com >/dev/null && break; sleep 2; done
	while IFS=$'\t' read -r target sid cwd rc; do
		[[ $sid =~ $UUID_RE ]] || { clog "skip $target: bad session id"; continue; }
		# Wait for resurrect's 'cat <contents>; exec bash' to settle into a shell.
		cmd=""
		for _ in $(seq 15); do
			cmd=$(tmux display -p -t "$target" '#{pane_current_command}' 2>/dev/null) || { cmd=MISSING; break; }
			case "$cmd" in bash|zsh|sh|fish) break ;; esac
			sleep 1
		done
		case "$cmd" in
			bash|zsh|sh|fish) ;;
			MISSING) clog "skip $target: pane missing"; continue ;;
			*) clog "skip $target: busy ($cmd)"; continue ;;
		esac
		line="cd $(printf %q "$cwd") && claude --permission-mode auto --resume $sid"
		[ "${rc:-0}" = 1 ] && line+=" --settings '{\"remoteControlAtStartup\":true}'"
		tmux send-keys -t "$target" "$line" Enter
		clog "restored $target: $line"
		# Claude never persists trust for $HOME, so a home-dir pane stops at the
		# trust prompt every boot. Accept it only if it names the recorded cwd.
		for _ in $(seq 30); do
			sleep 1
			claude_live "$sid" && break
			screen=$(tmux capture-pane -p -t "$target" 2>/dev/null) || break
			if grep -q 'Yes, I trust this folder' <<<"$screen"; then
				if grep -qxF " $cwd" <<<"$screen"; then
					tmux send-keys -t "$target" Down; sleep 0.5
					if tmux capture-pane -p -t "$target" | grep -q '❯ Yes, I trust this folder'; then
						tmux send-keys -t "$target" Enter
						clog "trusted $cwd for $target"
					else
						clog "trust prompt in $target: 'Yes' not selected; left for user"
					fi
				else
					clog "trust prompt in $target not for $cwd; left for user"
				fi
				break
			fi
		done
	done < "$CLAUDE_MAP"
) </dev/null >/dev/null 2>&1 &
disown
