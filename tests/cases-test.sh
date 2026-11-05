#!/usr/bin/env bash
# tests/cases.sh's run_cases on small suites of its own (run by tests/lint.sh): the order, the
# selection, the lines after each case, and each refusal (exit 2 before any case runs).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); }
# suite <body>: a suite with cases a (two checks: ok, FAIL), b (one ok) and the body, run in bash
# of its own with ASC_ONLY as set; prints its output, then "exit N"
suite() {
	bash -c '
		pass=0 fail=0
		ok() { echo "  ok    $1"; pass=$((pass + 1)); }
		bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
		. "$1/tests/cases.sh"
		case_a() { ok "a1"; bad "a2"; }
		case_b() { ok "b1"; }
		eval "$2"' _ "$REPO" "$1" 2>&1
	echo "exit $?"
}
want() { [ "$got" = "$(printf '%s\n' "$@")" ]; }

unset ASC_ONLY
got=$(suite 'run_cases t a b')
want "  ok    a1" "  FAIL  a2" "case done a" "== counts a 1 1" "  ok    b1" "case done b" "== counts b 1 0" "exit 0" \
	&& ok "every case in order, each with its own counts" || bad "every case in order, each with its own counts" "$got"
got=$(ASC_ONLY=b suite 'run_cases t a b')
want "== t: only the cases b (ASC_ONLY)" "  ok    b1" "case done b" "== counts b 1 0" "exit 0" \
	&& ok "ASC_ONLY runs only its cases, and says so" || bad "ASC_ONLY runs only its cases, and says so" "$got"
got=$(ASC_ONLY=b,a suite 'run_cases t a b')
want "== t: only the cases b,a (ASC_ONLY)" "  ok    a1" "  FAIL  a2" "case done a" "== counts a 1 1" "  ok    b1" "case done b" "== counts b 1 0" "exit 0" \
	&& ok "ASC_ONLY keeps the list's order" || bad "ASC_ONLY keeps the list's order" "$got"
got=$(suite 'case_c() { c=x p0=9 f0=9 suite=x sel=x; ok c1; }; run_cases t c a b')
want "  ok    c1" "case done c" "== counts c 1 0" "  ok    a1" "  FAIL  a2" "case done a" "== counts a 1 1" "  ok    b1" "case done b" "== counts b 1 0" "exit 0" \
	&& ok "a case's variables do not change the runner's" || bad "a case's variables do not change the runner's" "$got"
got=$(suite 'case_c() { ok c1; exit 1; }; run_cases t c a b')
want "  ok    c1" "exit 1" && ok "a case that does not return: no case done, nothing after" || bad "a case that does not return: no case done, nothing after" "$got"
# each refused before any case runs: exit 2, no check printed
refused() { got=$(suite "$1"); [[ $got == *"$2"* ]] && [[ $got == *"exit 2" ]] && [[ $got != *"  ok  "* ]]; }
refused 'run_cases t a b a' 'case a listed twice' && ok "a case listed twice: refused" || bad "a case listed twice: refused" "$got"
refused 'run_cases t a b c' 'case c has no function' && ok "a case with no function: refused" || bad "a case with no function: refused" "$got"
refused 'run_cases t a' 'case_b is not in the list' && ok "a case function not listed: refused" || bad "a case function not listed: refused" "$got"
ASC_ONLY=c refused 'run_cases t a b' 'ASC_ONLY: no case c' && ok "ASC_ONLY naming no case: refused" || bad "ASC_ONLY naming no case: refused" "$got"
ASC_ONLY=a,a refused 'run_cases t a b' 'case a given twice' && ok "ASC_ONLY naming a case twice: refused" || bad "ASC_ONLY naming a case twice: refused" "$got"
ASC_ONLY='' refused 'run_cases t a b' 'ASC_ONLY names no case' && ok "ASC_ONLY empty: refused" || bad "ASC_ONLY empty: refused" "$got"
echo "cases: $pass passed, $fail failed"
[ "$fail" = 0 ]
