#!/usr/bin/env bash
# Install the privacy hooks for this clone and its linked worktrees: pre-commit, commit-msg and
# pre-push in git's own hooks folder (<main .git folder>/hooks: it moves with the clone and
# linked worktrees share it), and copies of tools/privacy-check.sh and tools/privacy-rules in
# <main .git folder>/privacy/. Copies, so a checkout of an older commit (or a branch without
# these files) cannot remove or weaken them. Run it again after changing any of those files:
# the hooks warn while the copies differ. It refuses while core.hooksPath is set (git would not
# run them) or a hook of the same name is someone else's.
#   tools/install-hooks.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
G="$(git rev-parse --path-format=absolute --git-common-dir)"
D=$G/privacy
mark='# privacy-hook: installed by tools/install-hooks.sh'
# An earlier install of ours pointed core.hooksPath at $D/hooks or .githooks: undo that.
if p=$(git config --local --get core.hooksPath); then
	case $p in "$D/hooks"|.githooks) git config --local --unset-all core.hooksPath
		rm -f "$D/hooks/pre-commit" "$D/hooks/commit-msg" "$D/hooks/pre-push"; rmdir "$D/hooks" 2>/dev/null || true ;; esac
fi
if p=$(git config --get core.hooksPath); then
	echo "install-hooks: core.hooksPath is set ($p), so git would not run hooks from $G/hooks: unset it first" >&2; exit 1
fi
for h in pre-commit commit-msg pre-push; do
	[ ! -e "$G/hooks/$h" ] || grep -qxF "$mark" "$G/hooks/$h" ||
		{ echo "install-hooks: $G/hooks/$h exists and is not ours: merge it by hand" >&2; exit 1; }
done
mkdir -p "$D" "$G/hooks"
install -m 755 tools/privacy-check.sh "$D/"
install -m 644 tools/privacy-rules "$D/"
install -m 755 .githooks/pre-commit .githooks/commit-msg .githooks/pre-push "$G/hooks/"
echo "privacy hooks installed in $G/hooks (checker and rules in $D)"
[ -f "$G/privacy-local" ] || echo "note: put this machine's real names in $G/privacy-local, one per line"
