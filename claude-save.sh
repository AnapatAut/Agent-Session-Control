#!/usr/bin/env bash
# tmux-resurrect post-save-all hook: record which Claude Code conversation runs in
# which tmux pane, so claude-restore.sh can --resume it after a reboot/crash.
# rc column: 1 if remote control was connected (bridgeSessionId set).
# Source: ~/.claude/sessions/<pid>.json (written by every live claude process).
set -u
. "$HOME/.tmux/scripts/claude-lib.sh"
command -v jq >/dev/null || exit 0
# A restore is still launching claudes: the map is the only record, keep it.
[ -e "$CLAUDE_PENDING" ] && exit 0
tmp=$(mktemp "$CLAUDE_MAP.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT
for f in "$HOME"/.claude/sessions/*.json; do
	[ -e "$f" ] || continue
	# Fields joined with \x1f, not tabs: tab is IFS whitespace, so an empty field
	# would collapse and shift the ones after it.
	IFS=$'\x1f' read -r pid sid cwd kind tmuxref rc < <(jq -r '[.pid, .sessionId, .cwd, .kind, (.tmux // ""), (if .bridgeSessionId then 1 else 0 end)] | map(tostring) | join("\u001f")' "$f" 2>/dev/null) || continue
	[ "$kind" = interactive ] && [ -n "$tmuxref" ] && [[ $sid =~ $UUID_RE ]] || continue
	# The map is tab-separated: a tab in the folder name would break the line.
	[[ $cwd == *$'\t'* ]] && continue
	[ "$(cat /proc/"$pid"/comm 2>/dev/null)" = claude ] || continue
	pane_id="${tmuxref##*.}"
	# claude must be the pane's direct child on THIS server (skips nested runs and
	# pane-id collisions with other tmux servers)
	[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" = "$(tmux display -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)" ] || continue
	target=$(tmux display -p -t "$pane_id" '#S:#I.#P' 2>/dev/null) || continue
	printf '%s\t%s\t%s\t%s\n' "$target" "$sid" "$cwd" "$rc" >> "$tmp"
done
mv "$tmp" "$CLAUDE_MAP"
trap - EXIT
