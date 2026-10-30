# shellcheck shell=bash
# Shared by tests/container.sh and tests/killsweep.sh: one throwaway systemd container per run.
# Source it (TCR_SUITE=sweep first for the kill sweep), then call start_container.
# Single-quoted code is meant to expand inside the container, not here:
# shellcheck disable=SC2016,SC2034
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# Git variables from the caller (GIT_DIR, GIT_WORK_TREE, …) would point our git calls elsewhere.
while read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars 2>/dev/null)
# Set by the suite that sources this (container.sh: test, killsweep.sh: sweep), never by the caller.
case ${TCR_SUITE:-} in test | sweep) ;; *) echo "TCR_SUITE must be test or sweep"; exit 2 ;; esac
# Never taken from the environment (WSL, for one, exports NAME): two runs must never share a
# name. Every container of this run carries the label tcr-run=$RUN_LABEL; cleanup goes by it.
NAME="tcr-$TCR_SUITE-$$"
MIRROR="${TCR_MIRROR:-}"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
PASS=0; FAIL=0
# Set here, never taken from the environment: the suites set them when it applies.
STARTED=0; DONE=0; UNFINISHED=0; MKUSER_STOPS=0
STAGE=$(mktemp -d) || { echo "mktemp failed"; exit 2; }
# It goes into -v and into bash code as it is: a plain path only (TMPDIR comes from the caller).
[[ $STAGE =~ ^/[A-Za-z0-9._/+-]+$ ]] || { echo "TMPDIR gives a temp path with odd characters: $STAGE"; rm -rf "$STAGE"; exit 2; }
# With a random part: a PID can repeat (another PID namespace on the same daemon, reuse).
RUN_LABEL="$NAME-${STAGE##*.}"
# A shared image and plugin mirror (tests/mutants.sh builds them once per run): used as they
# are, never removed here. Our own image's tag has the same random part.
IMAGE="${TCR_IMAGE:-tcr-$TCR_SUITE:$$-${STAGE##*.}}"; OWN_IMAGE=1; [ -z "${TCR_IMAGE:-}" ] || OWN_IMAGE=0
# tests/mutants.sh puts one label of its own on every container too (TCR_PARENT), to remove
# them all after an interrupt.
LABELS=(--label "tcr-run=$RUN_LABEL"); [ -z "${TCR_PARENT:-}" ] || LABELS+=(--label "tcr-parent=$TCR_PARENT")
FILES=(install.sh claude-lib.sh claude-save.sh claude-restore.sh)
PLUGINS=(tpm tmux-resurrect tmux-continuum)

# Containers of this run, by label; fails when docker does not answer.
our_containers() { timeout 30 docker ps -a --filter "label=tcr-run=$RUN_LABEL" --format '{{.Names}}' 2>/dev/null; }
cleanup() {
	# A second signal must not cut the cleanup short.
	trap '' INT TERM HUP
	# Jobs still running (an interrupt) first, so none starts a container after the removal;
	# then twice, for one that a job had already asked docker for.
	local j=()
	read -ra j <<<"$(jobs -p | tr '\n' ' ')"
	if [ ${#j[@]} -gt 0 ]; then kill "${j[@]}" 2>/dev/null; wait 2>/dev/null; fi
	if [ $KEEP = 1 ]; then
		echo "kept: container $(our_containers | tr '\n' ' ')(remove with: docker rm -f <name>; docker image rm $IMAGE)"
	else
		our_containers | xargs -r timeout 60 docker rm -f >/dev/null 2>&1
		# A killed job's `docker run` may still create its container: after an interrupt (jobs
		# still running, or containers started and the run not finished), keep removing until
		# none has shown up for 10 s (at most 60 s). A docker that does not answer is not quiet.
		if [ ${#j[@]} -gt 0 ] || { [ $STARTED = 1 ] && [ $DONE = 0 ]; }; then
			local quiet=0 n=0 c
			while [ $quiet -lt 10 ] && [ $n -lt 60 ]; do
				sleep 1; n=$((n + 1))
				if ! c=$(our_containers); then quiet=0
				elif [ -n "$c" ]; then quiet=0; xargs -r timeout 60 docker rm -f <<<"$c" >/dev/null 2>&1
				else quiet=$((quiet + 1)); fi
			done
		fi
		[ $OWN_IMAGE = 0 ] || docker image rm "$IMAGE" >/dev/null 2>&1
	fi
	rm -rf "$STAGE"
}
trap cleanup EXIT
[ -z "${TCR_PARENT:-}" ] || [[ $TCR_PARENT =~ ^[A-Za-z0-9._-]+$ ]] || { echo "TCR_PARENT is not a label value"; exit 2; }
[[ $IMAGE =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?$ ]] || { echo "TCR_IMAGE is not an image name: $IMAGE"; exit 2; }
# A given mirror: a plain path (it goes into -v as it is) holding the 3 bare repos.
if [ -n "$MIRROR" ]; then
	[[ $MIRROR =~ ^/[A-Za-z0-9._/+-]+$ ]] || { echo "TCR_MIRROR must be an absolute path without spaces, : or ,"; exit 2; }
	for p in "${PLUGINS[@]}"; do [ -f "$MIRROR/$p/HEAD" ] || { echo "TCR_MIRROR has no bare repo $p"; exit 2; }; done
fi

step() { printf '\n== %s\n' "$*"; }
# check <description> <command...>: passes when the command exits 0; returns that too.
check() {
	local d=$1; shift
	if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$d"
	else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$d"; return 1; fi
}
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" = 0 ]; }
# as <user> <bash code>: run as that user, with its systemd user bus when it has one.
as() {
	local u=$1 id; shift
	id=$(docker exec "$NAME" id -u "$u")
	docker exec -u "$u" -w "/home/$u" -e HOME="/home/$u" -e USER="$u" -e TERM=xterm-256color \
		-e LANG=C.UTF-8 -e XDG_RUNTIME_DIR="/run/user/$id" \
		-e DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$id/bus" "$NAME" bash -c "$*"
}
# wait_for <seconds> <user> <bash code>: retry once a second until the code exits 0.
wait_for() {
	local n=$1; shift
	for _ in $(seq "$n"); do as "$@" >/dev/null 2>&1 && return 0; sleep 1; done
	return 1
}
booted() {
	for _ in $(seq 90); do
		# The text, not the exit status: is-system-running exits 1 when degraded (pipefail).
		[[ $(docker exec "$NAME" systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]] && return 0
		sleep 1
	done
	return 1
}
# use_mirror <user>: clone the plugins from the local mirror instead of GitHub (same URLs
# in install.sh; git rewrites them), so runs need no network.
use_mirror() {
	local p cmd="git config --global url.file:///opt/mirror/.insteadOf https://github.com/tmux-plugins/"
	for p in "${PLUGINS[@]}"; do cmd+="; git config --global --add safe.directory /opt/mirror/$p"; done
	docker exec -u "$1" -e HOME="/home/$1" "$NAME" bash -c "$cmd"
}
# mkuser <name> <uid>: a new lingering user (its own systemd user manager), plugin mirror on.
# It fails when the user manager never comes up: every check on that user would fail for that
# reason alone. With MKUSER_STOPS=1 (container.sh) it ends the case instead, with no counts
# line, so the case counts as not finished and no check of it fails.
mkuser() {
	if docker exec "$NAME" bash -c "useradd -m -s /bin/bash -u $2 $1 && loginctl enable-linger $1"; then
		for _ in $(seq 30); do docker exec "$NAME" test -S "/run/user/$2/bus" && break; sleep 1; done
		docker exec "$NAME" test -S "/run/user/$2/bus" && use_mirror "$1" && return 0
	fi
	[ $MKUSER_STOPS = 1 ] || return 1
	echo "  FAIL  user $1 has no user manager (the case stops)"; exit 1
}
# rmuser <name>: stop its user manager and processes (tmux included).
# rmuser first notes a user manager that is no longer active: it died during the case (see
# machine_sound). Its teardown then leaves it failed, so the state after says nothing.
rmuser() {
	docker exec "$NAME" bash -c "systemctl is-active -q user@\$(id -u $1).service || echo $1 >> /run/tcr-lost; loginctl disable-linger $1; pkill -KILL -u $1" >/dev/null 2>&1
	return 0
}
# machine_sound: systemd still running (or degraded), no user manager noted as lost by rmuser,
# the manager of every user still lingering active, and no sign in the journal of the host
# running short (journalctl exits 1 when nothing matches; an error is output, so not sound). A container, its systemd or a test
# user's manager that died mid-case fails every later check for that reason alone;
# tests/mutants.sh counts no FAIL as a catch without this.
machine_sound() {
	docker exec "$NAME" bash -c '
		[[ $(systemctl is-system-running) =~ ^(running|degraded)$ ]] && [ ! -s /run/tcr-lost ] || exit 1
		# The host short of inotify instances, open files or memory: a check can fail for that alone.
		e=$(journalctl -q --no-pager -g "Too many open files|Failed to allocate directory watch|Out of memory|oom-kill" 2>&1)
		[ -z "$e" ] || exit 1
		for u in /var/lib/systemd/linger/*; do
			[ -e "$u" ] || continue
			systemctl is-active -q "user@$(id -u "${u##*/}").service" || exit 1
		done' 2>/dev/null
}
# snap <user>: every path in the home with type, mode and content hash, minus saves and
# logs (~/.local/share, ~/.claude, claude-args.log) and ~/.local itself, which holds them.
snap() {
	as "$1" 'cd ~ && find . -mindepth 1 \( -path ./.local/share -o -path ./.claude -o -name claude-args.log \) -prune -o -printf "%y %m %p\n" \
		| grep -vxE "d [0-9]+ \./\.local" | LC_ALL=C sort | while read -r t m p; do
			case $t in
			f) echo "$t $m $p $(sha256sum < "$p" | cut -c1-16)" ;;
			l) echo "$t $p -> $(readlink "$p")" ;;
			*) echo "$t $m $p" ;;
			esac
		done'
}
# lacks <user> <file> <pattern>: the file exists and has no line matching the pattern
# (a plain `! grep` would also pass when the file is missing).
lacks() { as "$1" "[ -f $2 ] && ! grep -q -- '$3' $2"; }

# shellcheck source=tests/baseline.sh
. "$HERE/baseline.sh"
# save_logs <suite> <dir>: with TCR_LOGS set (tests/mutants.sh, for its baseline), copy a whole
# run's logs to $TCR_LOGS/<suite>.
save_logs() {
	[ -n "${TCR_LOGS:-}" ] || return 0
	cp -r "$2" "$TCR_LOGS/${1:?}" || { echo "cannot save the logs to $TCR_LOGS"; exit 2; }
}

# prepare: stage the code under test, a plugin mirror, the first commit and a test "old
# version"; build the image. boot_container: start $NAME from it.
prepare() {
	command -v docker >/dev/null || { echo "docker is required"; exit 2; }
	# The -v paths are this machine's: the docker daemon must be too (a local socket).
	local h=${DOCKER_HOST:-}
	[ -n "$h" ] || h=$(timeout 30 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
	[[ $h == unix://* ]] || { echo "docker must be a local daemon (unix socket), not: ${h:-unknown}"; exit 2; }
	mkdir -p "$STAGE/new" "$STAGE/base" "$STAGE/old"
	local f p
	for f in "${FILES[@]}"; do cp "$REPO/$f" "$STAGE/new/" && cp "$REPO/$f" "$STAGE/old/" || { echo "cannot stage $f"; exit 2; }; done
	# The "old version" for upgrade tests: one unit and one script differ.
	sed -i 's/^\(\t\t\)OnUnitActiveSec=1min$/\1OnUnitActiveSec=2min/' "$STAGE/old/install.sh"
	echo '# old version' >> "$STAGE/old/claude-save.sh"
	PINS=$(sed -n 's/^\t\[\(.*\)\]=\([0-9a-f]\{40\}\)$/\1 \2/p' "$REPO/install.sh")
	# The upgrade from the first version needs the first commit: the whole history.
	[ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" = false ] || { echo "the tests need the repo with its whole history (a git clone, not shallow)"; exit 2; }
	BASE=$(git -C "$REPO" rev-list --max-parents=0 HEAD 2>/dev/null | tail -n1)
	[ -n "$BASE" ] || { echo "cannot find the first commit"; exit 2; }
	if [ -n "$BASE" ]; then
		for f in "${FILES[@]}"; do git -C "$REPO" show "$BASE:$f" > "$STAGE/base/$f" || { echo "cannot stage $f of the first commit"; exit 2; }; done
	fi
	if [ -z "$MIRROR" ]; then
		MIRROR="$STAGE/mirror"
		for p in "${PLUGINS[@]}"; do
			git -c credential.helper= clone -q --mirror "https://github.com/tmux-plugins/$p" "$MIRROR/$p" || { echo "cannot clone $p for the mirror"; exit 2; }
		done
	fi
	chmod -R a+rX "$STAGE"
	if [ $OWN_IMAGE = 1 ]; then
		docker build -q -t "$IMAGE" "$HERE/sandbox" >/dev/null || { echo "docker build failed"; exit 2; }
	fi
}
boot_container() {
	docker run -d -t --pull never --name "$NAME" "${LABELS[@]}" --hostname tcr-test -e container=docker --cgroupns=private \
		--cap-add SYS_ADMIN --security-opt apparmor=unconfined --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
		-v "$STAGE/new:/opt/tcr:ro" -v "$STAGE/base:/opt/tcr-base:ro" -v "$STAGE/old:/opt/tcr-old:ro" \
		-v "$MIRROR:/opt/mirror:ro" "$IMAGE" >/dev/null
}
start_container() { prepare; STARTED=1; boot_container || { echo "docker run failed"; exit 2; }; }
