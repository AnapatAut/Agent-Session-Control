# Sourced by tests/asc.sh and tests/dash.sh: their cleanup ends what the run started, by pid.

# The processes under pid $1 that still run (zombies left out), into the array kids. Read from
# /proc without starting a process, so none of this shell's own is among them.
tree_of() {
	local f s p q todo=("$1")
	local -A under=()
	kids=()
	for f in /proc/[0-9]*/stat; do
		{ read -r s < "$f"; } 2>/dev/null || continue
		s=${s##*) }  # past the name, which may hold spaces and parens
		[ "${s%% *}" = Z ] && continue
		s=${s#* }; p=${f#/proc/}; under[${s%% *}]+=" ${p%/stat}"
	done
	while [ ${#todo[@]} -gt 0 ]; do
		q=${todo[0]}; todo=("${todo[@]:1}")
		for p in ${under[$q]-}; do kids+=("$p"); todo+=("$p"); done
	done
}

# Whether pid $1 runs (a zombie has ended).
running() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1; s=${s##*) }; [ "${s%% *}" != Z ]; }

# SIGTERM to each pid given, then SIGKILL to those still running 2 s later.
end_pids() {
	[ $# -gt 0 ] || return 0
	kill -TERM "$@" 2>/dev/null
	local i p left
	for i in $(seq 1 20); do
		left=()
		for p; do running "$p" && left+=("$p"); done
		[ ${#left[@]} -eq 0 ] && return 0
		sleep 0.1
	done
	kill -KILL "${left[@]}" 2>/dev/null
	return 0
}

# The processes under pid $1 (this shell: its jobs and their children) ended, the jobs collected.
reap() { tree_of "$1"; end_pids "${kids[@]}"; wait 2>/dev/null; }
