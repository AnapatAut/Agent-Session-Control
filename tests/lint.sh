#!/usr/bin/env bash
# Static checks: bash syntax and shellcheck for every script in the repo. Fast, changes nothing.
#   tests/lint.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 2
files=(install.sh claude-lib.sh claude-save.sh claude-restore.sh tests/*.sh tests/sandbox/claude)
rc=0
for f in "${files[@]}"; do bash -n "$f" || { echo "syntax error: $f"; rc=1; }; done
[ $rc = 0 ] && echo "bash -n: ok (${#files[@]} files)"

# Excluded, on purpose:
#   SC2088  '~/.tmux/scripts/…' in hook options: tmux-resurrect evals the hook, so ~ expands there
#   SC2015  `test && ok … || bad …`: ok/bad only print
#   SC1091  claude-lib.sh and the tmux-resurrect files exist only on the installed machine
#   SC2034  CLAUDE_MAP etc. are set in claude-lib.sh and used by the scripts that source it
#   SC2013  word-splitting grep output: session file paths have no spaces
if command -v shellcheck >/dev/null; then
	shellcheck -x -s bash -e SC2088,SC2015,SC1091,SC2034,SC2013 "${files[@]}" && echo "shellcheck: ok" || rc=1
else
	echo "shellcheck: not installed, skipped (e.g. apt install shellcheck, or: uvx --from shellcheck-py shellcheck)"
fi
exit $rc
