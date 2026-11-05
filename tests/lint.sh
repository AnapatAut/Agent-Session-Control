#!/usr/bin/env bash
# Static checks: bash syntax and shellcheck for every script in the repo, the suites' checks and
# waits (tests/checklint.py), their mutant lists (tests/mutantlint.py), and the privacy check of
# every tracked file. Fast, changes nothing.
#   tests/lint.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 2
files=(install.sh tests/*.sh tools/install-units.sh
	tools/privacy-check.sh tools/install-hooks.sh .githooks/pre-commit .githooks/commit-msg .githooks/pre-push
	bin/asctl bin/asctl-wrap tests/asc/bin/claude tests/asc/bin/systemctl tests/dash/bin/tailscale tests/dash/bin/ip)
rc=0
for f in "${files[@]}"; do bash -n "$f" || { echo "syntax error: $f"; rc=1; }; done
[ $rc = 0 ] && echo "bash -n: ok (${#files[@]} files)"

# Excluded, on purpose:
#   SC2015  `test && ok … || bad …`: ok/bad only print
#   SC2016  test code in single quotes: chk and wait_for eval it later, where it expands
#   SC2088  a literal `~/…` in test data (the privacy check's cases)
#   SC1091  files sourced by a path known only at run time
#   SC2034  variables the code that is eval'd or sourced uses
#   SC2013  word-splitting grep output: session file paths have no spaces
if command -v shellcheck >/dev/null; then
	shellcheck -x -s bash -e SC2015,SC2016,SC2088,SC1091,SC2034,SC2013 "${files[@]}" && echo "shellcheck: ok" || rc=1
else
	echo "shellcheck: not installed, skipped (e.g. apt install shellcheck, or: uvx --from shellcheck-py shellcheck)"
fi
python3 -I -m py_compile asc/*.py && echo "python: ok (asc/*.py compile)" || rc=1
python3 -I tests/checklint.py --self-test && python3 -I tests/checklint.py tests/asc.sh tests/dash.sh tests/dash/page.js \
	&& echo "checks and waits: ok (one fixed name per check, run once; every wait's status used; no token on a command line)" || rc=1
python3 -I tests/mutantlint.py --self-test && python3 -I tests/mutantlint.py tests/asc.sh tests/dash.sh tests/privacy.sh \
	&& echo "mutants: ok (each old text found once in its file, no line twice, each change parses)" || rc=1
find asc -name __pycache__ -prune -exec rm -r {} + 2>/dev/null
if command -v node >/dev/null; then
	for js in asc/web/app.js asc/web/splash.js tests/dash/page.js; do node --check "$js" && echo "js: ok ($js parses)" || rc=1; done
else
	echo "js: node not installed, skipped"
fi
tools/privacy-check.sh --tree && echo "privacy: ok (tracked files)" || rc=1
exit $rc
