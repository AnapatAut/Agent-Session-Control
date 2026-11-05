# Sourced by tests/asc.sh and tests/dash.sh (they define pass and fail): runs the suite's cases,
# the functions case_<name>, in the order given, each once. ASC_ONLY=<name,...> runs only those,
# and the run says so first. After a case returns: "case done NAME", then "== counts NAME <pass>
# <fail>" (that case's own), NAME from the list, never typed in a case. A case that did not
# return (a stop, a fail-fast exit) prints neither: it is unfinished. Exit 2 before any case
# runs for a name listed twice, a listed name with no function, a case_ function not listed, or
# an ASC_ONLY name that is not a case or given twice.
# Its own variables start with _rc_: a case's variables are the suite's (no local), and bash would
# let a case that sets one of the same name change the runner's.
#   run_cases <suite> <name>...
run_cases() {
	local _rc_suite=$1 _rc_c _rc_p0 _rc_f0 _rc_sel=()
	local -A _rc_listed=() _rc_want=()
	shift
	for _rc_c; do
		[ -z "${_rc_listed[$_rc_c]+x}" ] || { echo "$_rc_suite: case $_rc_c listed twice" >&2; exit 2; }
		declare -F "case_$_rc_c" >/dev/null || { echo "$_rc_suite: case $_rc_c has no function case_$_rc_c" >&2; exit 2; }
		_rc_listed[$_rc_c]=1
	done
	for _rc_c in $(compgen -A function case_); do
		[ -n "${_rc_listed[${_rc_c#case_}]+x}" ] || { echo "$_rc_suite: $_rc_c is not in the list of cases" >&2; exit 2; }
	done
	if [ -n "${ASC_ONLY+x}" ]; then
		IFS=, read -ra _rc_sel <<<"$ASC_ONLY"
		[ ${#_rc_sel[@]} -gt 0 ] || { echo "$_rc_suite: ASC_ONLY names no case" >&2; exit 2; }
		for _rc_c in "${_rc_sel[@]}"; do
			[ -n "${_rc_listed[$_rc_c]+x}" ] || { echo "$_rc_suite: ASC_ONLY: no case $_rc_c" >&2; exit 2; }
			[ -z "${_rc_want[$_rc_c]+x}" ] || { echo "$_rc_suite: ASC_ONLY: case $_rc_c given twice" >&2; exit 2; }
			_rc_want[$_rc_c]=1
		done
		echo "== $_rc_suite: only the cases $ASC_ONLY (ASC_ONLY)"
	fi
	for _rc_c; do
		[ -z "${ASC_ONLY+x}" ] || [ -n "${_rc_want[$_rc_c]+x}" ] || continue
		# shellcheck disable=SC2154  # pass and fail: the suite's counters
		_rc_p0=$pass _rc_f0=$fail
		"case_$_rc_c"
		echo "case done $_rc_c"
		echo "== counts $_rc_c $((pass - _rc_p0)) $((fail - _rc_f0))"
	done
}
