# Mutant runs for tests/asc.sh and tests/dash.sh (sourced; they define ok, bad, seen, REPO, T,
# REPO_HOME). Each line on stdin is "file %%% old %%% new": the suite runs again in a copy with
# that one change, and must fail. MUTANT_JOBS copies (default 8) run at a time, and each stops
# at its first FAIL (TEST_FAILFAST): one FAIL is a catch, so neither changes a verdict.
# The check that caught each mutant is printed after it, so a catch by a flaky check shows.
#   run_mutants <suite file in tests/> <the suite's mutants switch, cleared in the copies>
run_mutants() {
	local suite=$1 off=$2 jobs=${MUTANT_JOBS:-8} i=0 n m line
	mkdir -p "$T/mutants" || exit 2
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		_mutant "$suite" "$off" "$m" > "$T/mutants/$i" &
		i=$((i + 1))
		while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
	done
	wait
	for n in $(seq 0 $((i - 1))); do
		IFS= read -r line < "$T/mutants/$n"
		case $line in ok:*) ok "${line#ok:}" ;; *) bad "${line#bad:}" ;; esac
	done
}

_mutant() {
	local suite=$1 off=$2 m=$3 f rest old new d body out
	f=${m%%' %%% '*}; rest=${m#*' %%% '}; old=${rest%%' %%% '*}; new=${rest#*' %%% '}
	d=$(mktemp -d -p "$T") || { echo "bad:no temp folder for $f: $old"; return; }
	cp -r "$REPO/asc" "$REPO/bin" "$REPO/systemd" "$REPO/tests" "$d/"
	body=$(<"$d/$f")
	[[ $body == *"$old"* ]] || { echo "bad:mutant does not apply: $f: $old"; return; }
	printf '%s\n' "${body/"$old"/"$new"}" > "$d/$f"
	out=$(env HOME="$REPO_HOME" "$off=" TEST_FAILFAST=1 bash "$d/tests/$suite" 2>&1)
	if seen '  FAIL  ' <<<"$out"; then
		echo "ok:mutant caught: $f: $old (by: $(grep -m1 '  FAIL  ' <<<"$out" | cut -c9- | cut -c1-80))"
	else
		echo "bad:mutant missed: $f: $old"
	fi
	rm -rf "$d"
}
