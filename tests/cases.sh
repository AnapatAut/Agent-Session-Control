# Sourced by tests/asc.sh and tests/dash.sh (they define pass and fail): runs the suite's cases,
# the functions case_<name>, in the order given, each once. ASC_ONLY=<name,...> runs only those,
# and the run says so first. After a case returns: "case done NAME", then "== counts NAME <pass>
# <fail>" (that case's own), NAME from the list, never typed in a case. A case that did not
# return (a stop, a fail-fast exit) prints neither: it is unfinished. Exit 2 before any case
# runs for a name listed twice, a listed name with no function, a case_ function not listed, or
# an ASC_ONLY name that is not a case or given twice.
#   run_cases <suite> <name>...
run_cases() {
	local suite=$1 c p0 f0 sel=()
	local -A listed=() want=()
	shift
	for c; do
		[ -z "${listed[$c]+x}" ] || { echo "$suite: case $c listed twice" >&2; exit 2; }
		declare -F "case_$c" >/dev/null || { echo "$suite: case $c has no function case_$c" >&2; exit 2; }
		listed[$c]=1
	done
	for c in $(compgen -A function case_); do
		[ -n "${listed[${c#case_}]+x}" ] || { echo "$suite: $c is not in the list of cases" >&2; exit 2; }
	done
	if [ -n "${ASC_ONLY+x}" ]; then
		IFS=, read -ra sel <<<"$ASC_ONLY"
		[ ${#sel[@]} -gt 0 ] || { echo "$suite: ASC_ONLY names no case" >&2; exit 2; }
		for c in "${sel[@]}"; do
			[ -n "${listed[$c]+x}" ] || { echo "$suite: ASC_ONLY: no case $c" >&2; exit 2; }
			[ -z "${want[$c]+x}" ] || { echo "$suite: ASC_ONLY: case $c given twice" >&2; exit 2; }
			want[$c]=1
		done
		echo "== $suite: only the cases $ASC_ONLY (ASC_ONLY)"
	fi
	for c; do
		[ -z "${ASC_ONLY+x}" ] || [ -n "${want[$c]+x}" ] || continue
		# shellcheck disable=SC2154  # pass and fail: the suite's counters
		p0=$pass f0=$fail
		"case_$c"
		echo "case done $c"
		echo "== counts $c $((pass - p0)) $((fail - f0))"
	done
}
