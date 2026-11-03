#!/usr/bin/env bash
# Write asctl's systemd user units (systemd/ in this repo) into a unit folder, with this
# checkout's bin/asctl in them. It never runs systemctl: reloading, enabling and starting them is
# a step of its own (it prints the commands). A file there that is not the same is shown as a
# diff and left as it is, unless --force.
#   tools/install-units.sh [--force] [DIR]    DIR: ${XDG_CONFIG_HOME:-~/.config}/systemd/user
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
force=0
[ "${1:-}" = --force ] && { force=1; shift; }
dir=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
[ "${dir#/}" != "$dir" ] || dir="$PWD/$dir"  # relative to where it was run, not to systemd/
asctl="$REPO/bin/asctl"
# The path goes into ExecStart= as it is: no spaces (word splitting), no % (systemd specifiers),
# nothing sed or a unit file reads otherwise.
[[ $asctl =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "install-units: $asctl: only A-Z a-z 0-9 . _ / - in its path" >&2; exit 2; }
[ -x "$asctl" ] || { echo "install-units: $asctl is not there" >&2; exit 2; }
left=0 wrote=()
cd "$REPO/systemd"
while IFS= read -r -d '' f; do
	f=${f#./} to="$dir/$f"
	new=$(sed "s|@ASCTL@|$asctl|g" "$f")
	if [ -L "$to" ] || { [ -e "$to" ] && ! [ -f "$to" ]; }; then
		echo "install-units: $to is not a plain file: left as it is" >&2; left=1; continue
	fi
	if [ -f "$to" ] && [ "$(cat "$to")" = "$new" ]; then
		continue
	fi
	if [ -f "$to" ] && [ "$force" != 1 ]; then
		echo "install-units: $to differs (--force replaces it):" >&2
		diff -u "$to" <(printf '%s\n' "$new") >&2 || true
		left=1; continue
	fi
	mkdir -p "$(dirname "$to")"
	tmp=$(mktemp "$to.XXXXXX")
	printf '%s\n' "$new" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$to" || { rm -f "$tmp"; exit 1; }
	wrote+=("$to")
done < <(find . -type f -print0 | sort -z)
for w in "${wrote[@]}"; do echo "wrote $w"; done
[ ${#wrote[@]} -gt 0 ] || echo "nothing to write: the units there are these"
cat <<EOF
Next, by hand (nothing was enabled or started):
  systemctl --user daemon-reload
  systemctl --user enable asctl-tmux.service asctl-boot.service asctl-watch.timer asctl-dash.socket
EOF
exit "$left"
