# Mutant runs for tests/asc.sh and tests/dash.sh (sourced; they define ok, bad, seen, REPO, T,
# REPO_HOME). Each line on stdin is "file %%% old %%% new": the suite runs again in a copy with
# that one change, and must fail. MUTANT_JOBS copies (default 8) run at a time, and each stops
# at its first FAIL (TEST_FAILFAST): one FAIL is a catch, so neither changes a verdict.
# Each mutant is one check, named "mutant: <file>: <old> => <new>" either way (one old text can be
# changed more than one way); the check that caught it is printed on the line after it (in full), so
# a catch by a flaky check shows. Only a line that starts with "  FAIL  " is a FAIL: the details
# after it are indented further.
#   run_mutants <suite file in tests/> <the suite's mutants switch, cleared in the copies>
run_mutants() {
	local suite=$1 off=$2 jobs=${MUTANT_JOBS:-8} i=0 n m line det ms=()
	mkdir -p "$T/mutants" || exit 2
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		ms[i]=$m
		_mutant "$suite" "$off" "$m" > "$T/mutants/$i" &
		i=$((i + 1))
		while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
	done
	wait
	for n in $(seq 0 $((i - 1))); do
		line='' det=''; { IFS= read -r line; IFS= read -r det; } < "$T/mutants/$n"
		case $line in
		ok:*) ok "${line#ok:}"; echo "        $det" ;;
		bad:*) bad "${line#bad:}" "$det" ;;
		*) bad "$(_mname "${ms[n]}")" "no result: its run was cut off" ;;
		esac
	done
}

_mname() { local f=${1%%' %%% '*} rest=${1#*' %%% '}; printf 'mutant: %s: %s => %s' "$f" "${rest%%' %%% '*}" "${rest#*' %%% '}"; }

_mutant() {
	local suite=$1 off=$2 m=$3 f rest old new d body out name
	f=${m%%' %%% '*}; rest=${m#*' %%% '}; old=${rest%%' %%% '*}; new=${rest#*' %%% '}
	name=$(_mname "$m")
	d=$(mktemp -d -p "$T") || { printf 'bad:%s\n%s\n' "$name" "no temp folder"; return; }
	cp -r "$REPO/asc" "$REPO/bin" "$REPO/systemd" "$REPO/tests" "$d/"
	body=$(<"$d/$f")
	[[ $body == *"$old"* ]] || { printf 'bad:%s\n%s\n' "$name" "does not apply: the old text is not in $f"; rm -rf "$d"; return; }
	printf '%s\n' "${body/"$old"/"$new"}" > "$d/$f"
	out=$(env HOME="$REPO_HOME" "$off=" TEST_FAILFAST=1 bash "$d/tests/$suite" 2>&1)
	if seen '^  FAIL  ' <<<"$out"; then
		printf 'ok:%s\n%s\n' "$name" "caught by: $(grep -m1 '^  FAIL  ' <<<"$out" | cut -c9-)"
	else
		printf 'bad:%s\n%s\n' "$name" "missed: the suite passed with it"
	fi
	rm -rf "$d"
}
