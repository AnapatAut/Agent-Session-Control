#!/usr/bin/env bash
# asctl in a throwaway container booting real systemd: the host suites on a clean Ubuntu, the
# dashboard as systemd user units (socket activation, idle exit, stop), and a real out-of-memory
# kill kept inside a capped unit. The backend's tests (watcher, tmux unit, boot resurrect,
# setup) grow here. Leaves nothing behind.
#   tests/sandbox.sh            build, run every check, tear down  (about 2 min)
#   KEEP=1 tests/sandbox.sh     same, but leave the container and image up to look around
#   tests/sandbox.sh --down     remove what a finished or killed run left (refused while one runs)
# Needs Docker, and internet for the build only (Ubuntu packages); the test container has none.
#
# Safety, as in the other kits' sandboxes but tighter. The container has no network but
# loopback (an --internal network still gives the host an address on its bridge, where host
# services listening on every address answer), no published ports, no bind mounts, is not
# privileged, gains no new privileges, has fewer capabilities, a 1 GiB memory cap with no swap,
# a process limit, a small /tmp, and the highest OOM score, so the host's OOM killer picks it
# first. The container is made with tests/sandbox-lib.sh's options, and its whole HostConfig is
# compared with the one written there before it starts; the checks from inside follow the start.
# Either aborts the run before any test if it does not hold.
# Root inside is still root on the host with fewer capabilities: systemd needs SYS_ADMIN (and
# a writable /sys/fs/cgroup), and SYS_ADMIN can remount things such as /proc/sys. So this is a
# box for the repo's own code, which runs as an ordinary user (sbuser), never for code from
# elsewhere. The memory cap is a guard rail for the same reason.
# The image is built by a throwaway buildx builder (memory-capped; its build cache goes with
# it) from the repo's tracked files only, so uncommitted edits are tested once git-added. Base
# image and BuildKit are pinned by digest; the Ubuntu packages are current at build time.
# Only objects with the exact names below are ever removed (the BuildKit image only when this
# run pulled it; a sibling kit's sandbox running at the same time may pull it again).
# No pipefail on purpose: checks pipe into grep -q, whose early exit would fail the writer.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/sandbox-lib.sh
. "$REPO/tests/sandbox-lib.sh"
IMAGE=asc-sandbox:latest NET=asc-sandbox-net C=asc-sandbox BUILDER=asc-sandbox-builder
# The builder's daemon image, pinned by tag and digest (a re-pointed tag cannot swap it).
# Bump: docker buildx imagetools inspect moby/buildkit:<version>, its top-level Digest.
BK=moby/buildkit:v0.30.0@sha256:0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f
RUN_DIR=$SB_RUN_DIR
pass=0 fail=0 FAILED=() LOCKED=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
# $2: what was seen, on the lines after the FAIL, each indented (at most 60 of them)
bad() {
	echo "  FAIL  $1"; fail=$((fail + 1)); FAILED+=("$1")
	[ -n "${2-}" ] || return 0
	local n; n=$(printf '%s\n' "$2" | wc -l)
	printf '%s\n' "$2" | head -60 | sed 's/^/        /'
	[ "$n" -le 60 ] || echo "        ($((n - 60)) more lines)"
}
# chk <name> <test> [<what to show on failure>]: both are code, the second run only on failure
# (after any waiting in the test, so it shows the state the test ended on).
chk() { if eval "$2"; then ok "$1"; else bad "$1" "$([ -z "${3:-}" ] || eval "$3" 2>&1)"; fi; }
die() { echo "ABORT: $*" >&2; exit 2; }
# A container that failed the safety check never stays, KEEP=1 or not.
unsafe() { docker rm -f "$C" >/dev/null 2>&1; die "the safety check failed (the container is removed)"; }
wait_for() { local n=$1; shift; for _ in $(seq "$n"); do eval "$*" && return 0; sleep 1; done; return 1; }
x()  { sb_x "$C" "$@"; }
ux() { sb_ux "$C" "$@"; }  # as sbuser, with its user manager's environment
# Put together at run time, so the privacy check does not read them as real ones.
E=@ N=.ts
LOGIN="someone${E}example.com" HOST="machine.example${N}.net"
# A request as tailscale serve passes it to the dashboard socket.
dash_code() { ux curl -s -m 10 -o /dev/null -w '%{http_code}' --unix-socket "$RUN_DIR/asctl/dash.sock" \
	-H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "X-Forwarded-Host: $HOST" \
	-H "X-Forwarded-For: 192.0.2.10" "http://x$1"; }
anon_code() { ux curl -s -m 10 -o /dev/null -w '%{http_code}' --unix-socket "$RUN_DIR/asctl/dash.sock" -H "Host: localhost" "http://x$1"; }
uprop() { ux systemctl --user show "$1" -p "$2" --value; }
journal() { ux journalctl --user -u "$1" -n 5 --no-pager -o cat; }
# A process's start time (field 22 of /proc/<pid>/stat): with the pid, it names one run.
started() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

down() {
	docker rm -f "$C" >/dev/null 2>&1
	# the network records whether this run pulled BuildKit (read it before the network goes)
	local pulled; pulled=$(docker network inspect "$NET" --format '{{index .Labels "asc-sandbox.pulled-buildkit"}}' 2>/dev/null)
	docker network rm "$NET" >/dev/null 2>&1
	docker buildx rm -f "$BUILDER" >/dev/null 2>&1  # the builder container and its whole build cache
	docker rmi "$IMAGE" >/dev/null 2>&1
	[ "$pulled" = 1 ] && docker rmi "$BK" >/dev/null 2>&1  # never one that was here before
	return 0
}
# The run that holds the lock, if it is still running: "<pid>", else "".
live_owner() {
	local pid st
	pid=$(docker network inspect "$NET" --format '{{index .Labels "asc-sandbox.owner"}}' 2>/dev/null) || return 0
	st=$(docker network inspect "$NET" --format '{{index .Labels "asc-sandbox.started"}}' 2>/dev/null)
	[ -n "$pid" ] && [ -n "$st" ] && [ "$(started "$pid")" = "$st" ] && echo "$pid"
}
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker does not answer"
if [ "${1:-}" = "--down" ]; then
	p=$(live_owner); [ -z "$p" ] || die "a sandbox run is still going (pid $p); stop it first, its own exit cleans up"
	down; echo "sandbox removed"; exit 0
fi
p=$(live_owner); [ -z "$p" ] || die "a sandbox run is going (pid $p)"
left="left by an earlier run (KEEP=1, or killed): tests/sandbox.sh --down"
docker container inspect "$C" >/dev/null 2>&1 && die "container $C exists, $left"
docker buildx inspect "$BUILDER" >/dev/null 2>&1 && die "builder $BUILDER exists, $left"
docker image inspect "$BK" >/dev/null 2>&1 && PULLED_BK=0 || PULLED_BK=1
CTX=""
# The traps come first; LOCKED says the lock (and with it everything after) is this run's.
trap 'rm -rf "$CTX"; [ "$LOCKED" = 1 ] && [ "${KEEP:-0}" != 1 ] && down' EXIT
# Ctrl-C, TERM or HUP ends the run (docker exec catches SIGINT, and bash would carry on).
trap 'echo "interrupted" >&2; exit 130' INT TERM HUP
# The network is the run lock (the container is not attached to it): creating it is atomic, so
# a second run stops here and never removes the first one's objects. Its labels name this run.
if ! err=$(docker network create --internal --label "asc-sandbox.pulled-buildkit=$PULLED_BK" \
		--label "asc-sandbox.owner=$$" --label "asc-sandbox.started=$(started $$)" "$NET" 2>&1); then
	p=$(live_owner)
	[ -n "$p" ] && die "a sandbox run is going (pid $p)"
	docker network inspect "$NET" >/dev/null 2>&1 && die "network $NET exists, $left"
	die "cannot create network $NET: $err"
fi
LOCKED=1
CTX="$(mktemp -d)"

echo "== build (ubuntu:24.04, systemd, tmux, the repo's tracked files)"
mkdir -p "$CTX/asc"
# -P: a tracked symlink is copied as a link, never the file it points at.
(cd "$REPO" && git ls-files -z | xargs -0 -I{} cp -P --parents {} "$CTX/asc/") || die "copying the repo"
[ -x "$CTX/asc/bin/asctl" ] || die "copying the repo: no bin/asctl (not a git checkout, or files not git-added?)"
cp "$REPO/tests/sandbox-asc/Dockerfile" "$CTX/"
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt image="$BK" \
	--driver-opt memory=1g --driver-opt memory-swap=1g >/dev/null 2>&1 || die "builder"
out=$(timeout 900 docker buildx build --builder "$BUILDER" --load -t "$IMAGE" "$CTX" 2>&1) || { echo "$out" | tail -20; die "build"; }
docker buildx rm -f "$BUILDER" >/dev/null 2>&1
[ "$PULLED_BK" = 1 ] && docker rmi "$BK" >/dev/null 2>&1
rm -rf "$CTX"; CTX=""

echo "== 0. safety (abort when the container could reach the host)"
docker create --name "$C" "${SB_OPTS[@]}" "$IMAGE" "${SB_INIT[@]}" >/dev/null || die "docker create"
# Before it starts: a container made wrong never boots.
chk "its whole HostConfig is the expected one, no mounts, no network (before it starts)" '[ "$(sb_hostconfig_diff "$C")" = same ]' 'sb_hostconfig_diff "$C"'
[ "$fail" = 0 ] || unsafe
docker start "$C" >/dev/null || die "docker start"
chk "inside: its capabilities, first for the OOM killer, /proc/sys and /sys read-only, loopback only, the host out of reach, no new privileges" \
	'[ "$(sb_inside_diff "$C")" = same ]' 'sb_inside_diff "$C"'
[ "$fail" = 0 ] || unsafe

echo "== 1. systemd and the user's manager"
chk "systemd is PID 1 and running (or degraded)" 'sb_wait 60 sb_system_up "$C"' 'x systemctl --failed --no-legend'
chk "linger starts sbuser's user manager at boot" 'sb_wait 30 sb_user_manager "$C"' 'x systemctl status "user@$SB_UID.service" | tail -5'
chk "its runtime folder is 0700 and its own" '[ "$(x stat -c "%a %u" "$RUN_DIR")" = "700 $SB_UID" ]'
chk "systemctl --user answers" 'sb_wait 20 sb_user_bus "$C"' 'ux systemctl --user --failed --no-legend'

echo "== 2. the host suites on a clean Ubuntu"
# As sbuser with its user manager's bus, as a user runs them (tmux then puts each pane in a scope
# of its own, which asc.sh checks), and node there for the page's own checks: a suite that skips
# anything here fails, so a check cannot quietly stop being run.
for suite in asc dash; do
	out=$(timeout 900 docker exec -u sbuser -e XDG_RUNTIME_DIR="$RUN_DIR" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN_DIR/bus" \
		-w /opt/asc "$C" bash "tests/$suite.sh" 2>&1); rc=$?  # ux's options: timeout runs commands, not functions
	chk "tests/$suite.sh: every check passed" \
		'[ "$rc" = 0 ] && printf "%s\n" "$out" | tail -1 | grep -qE "^$suite: [1-9][0-9]* passed, 0 failed$"' \
		'echo "exit $rc"; printf "%s\n" "$out" | awk '"'"'/^  FAIL  /{p=1; print; next} p && /^        /{print; next} {p=0}'"'"''
	printf '        %s\n' "$(printf '%s\n' "$out" | tail -1)"  # the suite's counts
	chk "tests/$suite.sh: nothing skipped" '! printf "%s\n" "$out" | grep -q "^  skip  "' 'printf "%s\n" "$out" | grep "^  skip  "'
done

echo "== 3. the dashboard as systemd user units"
# As the install will write them: socket activation, the socket and its folder private, the
# socket file removed with the unit (systemd leaves it otherwise), and a stop that waits for a
# running action (KillMode=mixed: SIGTERM to the server only).
ux sh -ec 'u=~/.config/systemd/user c=~/.config/agent-session-control
mkdir -p "$u" "$c"
printf "%s\n" "[Socket]" "ListenStream=%t/asctl/dash.sock" "SocketMode=0600" "DirectoryMode=0700" "RemoveOnStop=yes" \
	"[Install]" "WantedBy=sockets.target" > "$u/asctl-dash.socket"
printf "%s\n" "[Unit]" "Requires=asctl-dash.socket" "[Service]" "ExecStart=/opt/asc/bin/asctl dash --idle 5" \
	"Environment=PATH=/opt/asc/tests/dash/bin:/usr/bin:/bin" "KillMode=mixed" "TimeoutStopSec=120" > "$u/asctl-dash.service"
printf "{\"login\": \"%s\", \"host\": \"%s\"}\n" "$1" "$2" > "$c/dash.json"; chmod 600 "$c/dash.json"; chmod 700 "$c"
systemctl --user daemon-reload && systemctl --user enable --now asctl-dash.socket' _ "$LOGIN" "$HOST" >/dev/null 2>&1
chk "the socket unit listens" '[ "$(uprop asctl-dash.socket ActiveState)" = active ]' 'ux systemctl --user status asctl-dash.socket | tail -5'
chk "socket 0600 in a 0700 folder, both sbuser's" \
	'[ "$(x stat -c "%a %u" "$RUN_DIR/asctl/dash.sock" "$RUN_DIR/asctl" | tr "\n" " ")" = "600 $SB_UID 700 $SB_UID " ]' 'x ls -la "$RUN_DIR/asctl"'
chk "no server before the first request (the unit is loaded, not running)" \
	'[ "$(uprop asctl-dash.service LoadState) $(uprop asctl-dash.service ActiveState)" = "loaded inactive" ]'
chk "the first request starts the server: 200" '[ "$(dash_code /api/state)" = 200 ]' 'journal asctl-dash'
inv1=$(uprop asctl-dash.service InvocationID)
chk "the server runs as a unit" '[ "$(uprop asctl-dash.service ActiveState)" = active ] && [ -n "$inv1" ]'
chk "a request without the login: 403" '[ "$(anon_code /api/state)" = 403 ]'
chk "the app files without the login: 200" '[ "$(anon_code /manifest.json)" = 200 ]'
# Idle 5 s: inactive, a clean exit, and not before 4 s (a crash at once would also be inactive).
ran_us() { echo $(( $(uprop asctl-dash.service InactiveEnterTimestampMonotonic) - $(uprop asctl-dash.service ActiveEnterTimestampMonotonic) )); }
chk "idle: the server exits after 5 s, cleanly" \
	'wait_for 20 "[ \"\$(uprop asctl-dash.service ActiveState)\" = inactive ]" && [ "$(uprop asctl-dash.service Result)" = success ] && [ "$(ran_us)" -ge 4000000 ]' \
	'echo "$(uprop asctl-dash.service ActiveState) $(uprop asctl-dash.service Result) ran $(ran_us) us"; journal asctl-dash'
chk "and the socket stays with systemd" '[ "$(uprop asctl-dash.socket ActiveState)" = active ] && x test -S "$RUN_DIR/asctl/dash.sock"'
chk "the next request starts a new server: 200" \
	'[ "$(dash_code /api/state)" = 200 ] && inv2=$(uprop asctl-dash.service InvocationID) && [ -n "$inv2" ] && [ "$inv2" != "$inv1" ]'
chk "it runs before the stop" '[ "$(uprop asctl-dash.service ActiveState)" = active ]'
ux systemctl --user stop asctl-dash.service 2>/dev/null  # (it warns that the socket can start it again)
chk "systemctl stop: that server exits cleanly" \
	'[ "$(uprop asctl-dash.service ActiveState) $(uprop asctl-dash.service Result)" = "inactive success" ] && [ "$(uprop asctl-dash.service InvocationID)" = "${inv2:-}" ]' \
	'journal asctl-dash'
ux systemctl --user stop asctl-dash.socket
chk "stopping the socket unit removes the socket" 'x sh -c "! test -e $RUN_DIR/asctl/dash.sock"'

echo "== 4. a real out-of-memory kill, kept inside its unit"
# The watcher must tell an OOM kill from other ends; this proves the sandbox can make one.
# MemoryMax 64M on a unit that wants 400 MB: the kernel kills it there, the container (1 GiB)
# and the host are never short.
chk "the user manager may set memory limits (memory delegated)" \
	'x grep -qw memory "/sys/fs/cgroup/user.slice/user-$SB_UID.slice/user@$SB_UID.service/cgroup.subtree_control"' \
	'x cat "/sys/fs/cgroup/user.slice/user-$SB_UID.slice/user@$SB_UID.service/cgroup.subtree_control"'
ux systemd-run --user --unit=asc-hog -p MemoryMax=64M -p MemorySwapMax=0 \
	python3 -c 'b = [bytearray(1 << 20) for _ in range(400)]; import time; time.sleep(30)' >/dev/null 2>&1
chk "the hog ends as oom-kill" '[ "$(uprop asc-hog.service LoadState)" = loaded ] && wait_for 20 "[ \"\$(uprop asc-hog.service Result)\" = oom-kill ]"' \
	'echo "$(uprop asc-hog.service LoadState) $(uprop asc-hog.service ActiveState) $(uprop asc-hog.service Result)"'
chk "the kernel counted the kill in that unit" \
	'ux journalctl --user -u asc-hog --no-pager -o cat | grep -qiE "out of memory|oom"' 'journal asc-hog'
chk "the user manager is still up" 'x systemctl is-active --quiet user@$SB_UID.service'

echo "== 5. the watcher: a favorite's claude killed by the kernel for memory"
# The tmux server runs in a unit capped at 200 MB (as asctl-tmux.service will hold it); the fake
# claude of a favorite fills that up (fake-hog), the kernel's OOM killer ends it (SIGKILL, 137),
# and the watcher, from its samples, tells that end from others and starts it again in place.
ux sh -ec 'mkdir -p ~/fb ~/w ~/.config/systemd/user && cp /bin/bash ~/fb/claude && echo ~/w > ~/fake-trusted
printf "MemTotal: 32000000 kB\nMemAvailable: 16000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n" > ~/meminfo
u=~/.config/systemd/user
# as asctl will set it (plan): a kernel OOM kill of one claude must not stop its pane scope
mkdir -p "$u/tmux-spawn-.scope.d"
printf "%s\n" "[Scope]" "OOMPolicy=continue" "MemoryMax=200M" "MemorySwapMax=0" > "$u/tmux-spawn-.scope.d/asctl-test.conf"
printf "%s\n" "[Service]" "Type=oneshot" "ExecStart=/opt/asc/bin/asctl watch" "Environment=ASC_BY=watch ASC_TMUX_SOCKET=oom ASC_MEMINFO=%h/meminfo" > "$u/asctl-watch.service"
printf "%s\n" "[Timer]" "OnActiveSec=1s" "OnUnitActiveSec=30s" "AccuracySec=1s" "[Install]" "WantedBy=timers.target" > "$u/asctl-watch.timer"
systemctl --user daemon-reload' >/dev/null 2>&1
OE="ASC_TMUX_SOCKET=oom ASC_CLAUDE=/opt/asc/tests/asc/bin/claude FAKE_BASH=/home/sbuser/fb/claude ASC_MEMINFO=/home/sbuser/meminfo"
# shellcheck disable=SC2086  # the variable is a list of NAME=value words
oux() { ux env $OE "$@"; }
ux systemd-run --user --unit=asc-oomtmux -p Type=forking -p MemoryMax=200M -p MemorySwapMax=0 -p OOMPolicy=continue \
	-E FAKE_BASH=/home/sbuser/fb/claude -E HOME=/home/sbuser \
	tmux -L oom -f /dev/null new-session -d -s keep \; set -g exit-empty off >/dev/null 2>&1
chk "a tmux server in a unit capped at 200 MB" 'wait_for 10 "oux tmux -L oom has-session -t =keep 2>/dev/null"' 'journal asc-oomtmux'
OS=dddddddd-0000-4000-8000-0000000000aa
oux tmux -L oom new-session -d -s c -c /home/sbuser/w -- /opt/asc/tests/asc/bin/claude --session-id "$OS"
cpid() { oux /opt/asc/bin/asctl live | awk -v s="$OS" '$2 == s {print $1}'; }
chk "a fake claude is up in it" 'wait_for 15 "[ -n \"\$(cpid)\" ]"' 'oux /opt/asc/bin/asctl live'
oux /opt/asc/bin/asctl fav "$(cpid)" --name oomc >/dev/null 2>&1
OID=$(ux jq -r '.entries[] | select(.name == "oomc") | .id4' /home/sbuser/.local/state/agent-session-control/registry.json)
oux /opt/asc/bin/asctl off "$OID" >/dev/null 2>&1; oux /opt/asc/bin/asctl on "$OID" >/dev/null 2>&1
p1=$(cpid)
chk "its claude is in a 200 MB cgroup that goes on after an OOM kill" \
	'cg=$(ux cat "/proc/$p1/cgroup" | cut -d: -f3); u=$(basename "$cg"); [ "$(uprop "$u" MemoryMax)" = 209715200 ] && [ "$(uprop "$u" OOMPolicy)" = continue ]' \
	'ux cat "/proc/$p1/cgroup"'
chk "the favorite runs under asctl-wrap" '[ -n "$p1" ] && ux cat "/proc/$(ux ps -o ppid= -p "$p1" | tr -d " ")/cmdline" | tr "\0" " " | grep -q asctl-wrap'
oux /opt/asc/bin/asctl auto-restart on >/dev/null
# 6 min of steady samples (the fake meminfo says 50%), then the watcher's own sample before the end
oux python3 -I -c 'import sys, time; sys.path.insert(0, "/opt/asc"); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 30 * i) for i in range(12, 0, -1)])'
ux systemctl --user start asctl-watch.timer
chk "asctl-watch.timer runs the watcher (a sample kept, the run clean)" \
	'wait_for 10 "[ \"\$(uprop asctl-watch.service Result)\" = success ] && [ \"\$(uprop asctl-watch.service ExecMainStatus)\" = 0 ] && ux jq -e \"length >= 13\" /home/sbuser/.local/state/agent-session-control/memory.json >/dev/null"' 'journal asctl-watch'
ux systemctl --user stop asctl-watch.timer
sleep 1.2; ux touch /home/sbuser/fake-hog
chk "the kernel ends the claude for memory: exit 137" \
	'wait_for 30 "ux grep -q \"^137 \" /home/sbuser/.local/state/agent-session-control/exit/$OID"' \
	'ux cat /home/sbuser/.local/state/agent-session-control/exit/$OID; journal asc-oomtmux'
chk "the tmux unit is still up (the claude was killed, not the server)" 'oux tmux -L oom has-session -t "=oomc-$OID"'
sleep 1.2; oux env ASC_BY=watch /opt/asc/bin/asctl watch
EV=/home/sbuser/.local/state/agent-session-control/events.jsonl
chk "the watcher: ended, exit 137, memory pressure seen" \
	'ux jq -s -e "map(select(.kind == \"ended\")) | last | .text | test(\"exit 137 \\\\(a signal\\\\).*memory: .*(OOM kill|stalled|swapped|available)\")" $EV >/dev/null' \
	'ux jq -s -c "map(select(.kind == \"ended\" or .kind == \"waiting\" or .kind == \"failed\")) | .[-3:]" $EV'
chk "and started it again, in the same session" \
	'ux jq -s -e "map(select(.kind == \"restarted\")) | length == 1" $EV >/dev/null && wait_for 15 "p2=\$(cpid); [ -n \"\$p2\" ] && [ \"\$p2\" != \"$p1\" ]"' \
	'ux jq -s -c ".[-4:]" $EV'
ux systemctl --user stop asc-oomtmux 2>/dev/null

echo "== 6. the units as installed (a checkout's own): the tmux server unit, boot resurrect"
# tools/install-units.sh writes them. Drop-ins point them at the fake claude and memory, and
# claude.ai at a closed port (no network here; boot's wait for it cut to 2 s). The tmux server is
# the default one now, as on a real machine.
U=/home/sbuser/.config/systemd/user
out=$(ux /opt/asc/tools/install-units.sh 2>&1); rc=$?
chk "install-units: a unit there that is not the same is shown and left" \
	'[ "$rc" = 1 ] && printf "%s\n" "$out" | grep -q "asctl-dash.service differs" && ux grep -q "idle 5" $U/asctl-dash.service' 'echo "rc $rc"; printf "%s\n" "$out" | head -20'
out=$(ux /opt/asc/tools/install-units.sh --force 2>&1); rc=$?
chk "install-units --force: written, with this checkout's asctl, nothing enabled" \
	'[ "$rc" = 0 ] && ux grep -qx "ExecStart=/opt/asc/bin/asctl tmux-server" $U/asctl-tmux.service && ux test -f $U/tmux-spawn-.scope.d/asctl.conf && [ "$(ux systemctl --user is-enabled asctl-tmux.service 2>/dev/null)" != enabled ]' \
	'echo "rc $rc"; printf "%s\n" "$out" | head -20'
ux sh -ec 'u=~/.config/systemd/user; rm -f "$u/tmux-spawn-.scope.d/asctl-test.conf"; mkdir -p "$u/asctl-tmux.service.d" "$u/asctl-boot.service.d"
printf "%s\n" "[Service]" "Environment=FAKE_BASH=%h/fb/claude" > "$u/asctl-tmux.service.d/test.conf"
printf "%s\n" "[Service]" "Environment=ASC_CLAUDE=/opt/asc/tests/asc/bin/claude ASC_MEMINFO=%h/meminfo ASC_NET=127.0.0.1:9" \
	"ExecStart=" "ExecStart=/opt/asc/bin/asctl boot --net-wait 2 --wait 300" > "$u/asctl-boot.service.d/test.conf"
systemctl --user daemon-reload && systemctl --user enable asctl-tmux.service asctl-boot.service' >/dev/null 2>&1
DE="ASC_CLAUDE=/opt/asc/tests/asc/bin/claude FAKE_BASH=/home/sbuser/fb/claude ASC_MEMINFO=/home/sbuser/meminfo"
# shellcheck disable=SC2086  # the variable is a list of NAME=value words
dux() { ux env $DE "$@"; }
spid() { dux tmux display -p '#{pid}' 2>/dev/null; }
cgof() { ux cat "/proc/$1/cgroup" 2>/dev/null | cut -d: -f3; }
ux systemctl --user start asctl-tmux.service
chk "asctl-tmux.service: up, its main process the tmux server, kept with no session" \
	'[ "$(uprop asctl-tmux.service ActiveState)" = active ] && [ -n "$(spid)" ] && [ "$(uprop asctl-tmux.service MainPID)" = "$(spid)" ] && [ -z "$(dux tmux ls 2>/dev/null)" ]' \
	'echo "$(uprop asctl-tmux.service ActiveState) main $(uprop asctl-tmux.service MainPID) server $(spid)"; journal asctl-tmux'
chk "it has OOMPolicy=continue and refuses a manual stop (the server stays)" \
	'[ "$(uprop asctl-tmux.service OOMPolicy) $(uprop asctl-tmux.service RefuseManualStop)" = "continue yes" ] && ! ux systemctl --user stop asctl-tmux.service 2>/dev/null && [ "$(uprop asctl-tmux.service ActiveState)" = active ]'
# The day of the switch: a server another unit started runs. The start succeeds, no second one.
dux tmux kill-server; wait_for 10 '[ "$(uprop asctl-tmux.service ActiveState)" = inactive ]'
ux systemd-run --user --unit=asc-oldtmux -p Type=forking tmux new-session -d -s old >/dev/null 2>&1
wait_for 10 '[ -n "$(spid)" ]'; old=$(spid)
ux systemctl --user start asctl-tmux.service; rc=$?
chk "with another unit's server up: the start succeeds and starts no second server" \
	'[ "$rc" = 0 ] && [ "$(spid)" = "$old" ] && [ "$(uprop asctl-tmux.service ActiveState)" = inactive ] && [ "$(uprop asctl-tmux.service Result)" = success ]' \
	'echo "rc $rc server $(spid) (was $old) $(uprop asctl-tmux.service ActiveState) $(uprop asctl-tmux.service Result)"; journal asctl-tmux'
ux systemctl --user stop asc-oldtmux 2>/dev/null; wait_for 10 '[ -z "$(spid)" ]'
# A favorite, then On with no server running: On starts asctl-tmux.service, which owns the server.
BS=dddddddd-0000-4000-8000-0000000000bb
ux systemctl --user start asctl-tmux.service
dux tmux new-session -d -s b -c /home/sbuser/w -- /opt/asc/tests/asc/bin/claude --session-id "$BS"
bpid() { dux /opt/asc/bin/asctl live | awk -v s="$BS" '$2 == s {print $1}'; }
wait_for 15 '[ -n "$(bpid)" ]'
dux /opt/asc/bin/asctl fav "$(bpid)" --name bootc >/dev/null 2>&1
BID=$(ux jq -r '.entries[] | select(.name == "bootc") | .id4' /home/sbuser/.local/state/agent-session-control/registry.json)
dux /opt/asc/bin/asctl off "$BID" >/dev/null 2>&1; dux tmux kill-server 2>/dev/null; wait_for 10 '[ -z "$(spid)" ]'
out=$(dux /opt/asc/bin/asctl on "$BID" 2>&1); rc=$?
chk "On with no tmux server: it starts asctl-tmux.service, the server is that unit's" \
	'[ "$rc" = 0 ] && [ -n "$(spid)" ] && cgof "$(spid)" | grep -q "/asctl-tmux.service$"' 'echo "rc $rc: $out"; echo "server $(spid): $(cgof "$(spid)")"; journal asctl-tmux'
chk "its claude is in a tmux scope that goes on after an OOM kill (the installed drop-in)" \
	'wait_for 15 "[ -n \"\$(bpid)\" ]" && u=$(basename "$(cgof "$(bpid)")") && [ "${u#tmux-spawn-}" != "$u" ] && [ "$(uprop "$u" OOMPolicy)" = continue ]' \
	'echo "claude $(bpid): $(cgof "$(bpid)")"'
dux /opt/asc/bin/asctl resurrect "$BID" on >/dev/null
echo "== 7. the machine install (sudo ./install.sh), and asctl setup by a second user"
# sbuser2 has the old setup as tmux-continuum leaves it: its own tmux.service (enabled, its
# server up) and continuum's boot on. Setup refuses until that is off, then retires the unit
# (disabled, its server left alone) and turns on the machine's units; the reboot below must
# then bring sbuser2's favorite back from the installed code.
OPT=/opt/agent-session-control R2=/run/user/2002 H2=/home/sbuser2
u2() { docker exec -u sbuser2 -e XDG_RUNTIME_DIR="$R2" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$R2/bus" -w "$H2" "$C" "$@"; }
u2prop() { u2 systemctl --user show "$1" -p "$2" --value; }
D2="ASC_CLAUDE=/opt/asc/tests/asc/bin/claude FAKE_BASH=$H2/fb/claude ASC_MEMINFO=$H2/meminfo"
# shellcheck disable=SC2086  # the variable is a list of NAME=value words
d2() { u2 env $D2 "$@"; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
out=$(ux /opt/asc/install.sh 2>&1); rc=$?
chk "install.sh as a user: refused" '[ "$rc" = 1 ] && has "run it as root"' 'echo "rc $rc: $out"'
x sh -c 'echo "#!/bin/sh" > /usr/local/bin/asctl'
out=$(x /opt/asc/install.sh 2>&1); rc=$?
chk "a /usr/local/bin/asctl not its own: refused, nothing written" \
	'[ "$rc" = 1 ] && has "not this installer.s link" && ! x test -e $OPT && ! x test -e /etc/systemd/user/asctl-tmux.service' 'echo "rc $rc: $out"'
x rm /usr/local/bin/asctl
out=$(x /opt/asc/install.sh 2>&1); rc=$?
REL=$(x readlink $OPT/current)
chk "install: a release, current at it, asctl on PATH, the units in /etc/systemd/user (no scope drop-in)" \
	'[ "$rc" = 0 ] && [[ $REL =~ ^releases/[0-9a-f]{12}$ ]] && [ "$(x readlink /usr/local/bin/asctl)" = $OPT/current/bin/asctl ] && x grep -qx "ExecStart=$OPT/current/bin/asctl tmux-server" /etc/systemd/user/asctl-tmux.service && x test -f /etc/systemd/user/asctl-dash.socket && ! x test -e /etc/systemd/user/tmux-spawn-.scope.d' \
	'echo "rc $rc: $out"'
chk "  all of it root's and not writable by others, compiled; enabled for no one" \
	'[ -z "$(x find $OPT /etc/systemd/user ! -type l \( ! -user root -o -perm /022 \) -print)" ] && [ -n "$(x find $OPT/$REL/asc/__pycache__ -name "cli.*.pyc")" ] && [ "$(u2 systemctl --user is-enabled asctl-tmux.service 2>&1)" = disabled ]' \
	'x find $OPT /etc/systemd/user ! -type l \( ! -user root -o -perm /022 \) -print | head; u2 systemctl --user is-enabled asctl-tmux.service'
out=$(x /opt/asc/install.sh 2>&1); rc=$?
chk "install again: installed already, nothing written" '[ "$rc" = 0 ] && has "installed already" && ! has "^wrote"' 'echo "rc $rc: $out"'
x sh -c 'echo "# an edit" >> /etc/systemd/user/asctl-watch.timer'
out=$(x /opt/asc/install.sh 2>&1); rc=$?
chk "a unit file changed since: refused; --force puts it back" \
	'[ "$rc" = 1 ] && has "changed since the last install" && x /opt/asc/install.sh --force >/dev/null 2>&1 && ! x grep -q "an edit" /etc/systemd/user/asctl-watch.timer' 'echo "rc $rc: $out"'
x ln -s /etc/shadow /opt/asc/asc/web/x.js
out=$(x /opt/asc/install.sh 2>&1); rc=$?
x rm /opt/asc/asc/web/x.js
chk "a link in the checkout: refused" '[ "$rc" = 1 ] && has "x.js is a symbolic link" && [ "$(x readlink $OPT/current)" = "$REL" ]' 'echo "rc $rc: $out"'
x ln -s /root /opt/asc/asc/rootlink
out=$(x /opt/asc/install.sh 2>&1); rc=$?
x rm /opt/asc/asc/rootlink
chk "  a link to a folder too; no staging folder left behind" \
	'[ "$rc" = 1 ] && has "asc/rootlink is a symbolic link" && [ -z "$(x sh -c "ls -d /opt/.agent-session-control.stage-* 2>/dev/null")" ]' 'echo "rc $rc: $out"; x ls -a /opt'
# Upgrades: the release before stays, and an older one while a process runs it; then it goes.
up() { x sh -c "echo '# upgrade $1' >> /opt/asc/asc/events.py" && x /opt/asc/install.sh >/dev/null 2>&1; x readlink $OPT/current; }
REL1=$(up 1)
HOLD=$(x bash -c "(exec -a $OPT/$REL/bin/asctl-wrap sleep 600) </dev/null >/dev/null 2>&1 & echo \$!")
REL2=$(up 2)
chk "upgrades: current switched, the release before kept, an older one a process runs kept" \
	'[ "$REL1" != "$REL" ] && [ "$REL2" != "$REL1" ] && x test -d $OPT/$REL1 && x test -d $OPT/$REL' 'x ls $OPT/releases'
x kill "$HOLD"
REL3=$(up 3)
chk "  once nothing runs it, the older one is gone (the newest two stay)" \
	'! x test -e $OPT/$REL && ! x test -e $OPT/$REL1 && x test -d $OPT/$REL2 && x test -d $OPT/$REL3' 'x ls $OPT/releases'
x sed -i '/^# upgrade [123]$/d' /opt/asc/asc/events.py; x /opt/asc/install.sh >/dev/null 2>&1
u2 sh -ec 'mkdir -p ~/fb ~/w ~/.config/systemd/user && cp /bin/bash ~/fb/claude && echo ~/w > ~/fake-trusted
printf "MemTotal: 32000000 kB\nMemAvailable: 16000000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n" > ~/meminfo
echo "set -g @continuum-boot '\''on'\''" > ~/.tmux.conf
u=~/.config/systemd/user
printf "%s\n" "[Unit]" "Description=tmux default session (detached)" "[Service]" "Type=forking" "Environment=FAKE_BASH=%h/fb/claude" \
	"ExecStart=/usr/bin/tmux new-session -d -s old" "ExecStop=/usr/bin/tmux kill-server" "KillMode=control-group" "[Install]" "WantedBy=default.target" > "$u/tmux.service"
mkdir -p "$u/asctl-tmux.service.d" "$u/asctl-boot.service.d"
printf "%s\n" "[Service]" "Environment=FAKE_BASH=%h/fb/claude" > "$u/asctl-tmux.service.d/test.conf"
printf "%s\n" "[Service]" "Environment=ASC_CLAUDE=/opt/asc/tests/asc/bin/claude ASC_MEMINFO=%h/meminfo ASC_NET=127.0.0.1:9" \
	"ExecStart=" "ExecStart=/opt/agent-session-control/current/bin/asctl boot --net-wait 2 --wait 300" > "$u/asctl-boot.service.d/test.conf"
systemctl --user daemon-reload && systemctl --user enable --now tmux.service' >/dev/null 2>&1
s2pid() { d2 tmux display -p '#{pid}' 2>/dev/null; }
chk "sbuser2's old tmux.service: enabled, its server up" \
	'wait_for 10 "d2 tmux has-session -t =old 2>/dev/null" && [ "$(u2 systemctl --user is-enabled tmux.service)" = enabled ]' 'u2 systemctl --user status tmux.service | tail -5'
OLDSRV=$(s2pid)
out=$(u2 asctl setup --yes 2>&1); rc=$?
chk "asctl setup with continuum's boot on: refused (the config line and the server)" \
	'[ "$rc" = 1 ] && has "$H2/.tmux.conf:1: @continuum-boot" && has "the running tmux server: @continuum-boot on" && [ "$(u2 systemctl --user is-enabled tmux.service)" = enabled ]' 'echo "rc $rc: $out"'
u2 sed -i "s/'on'/'off'/" "$H2/.tmux.conf"; d2 tmux set -g @continuum-boot off
out=$(u2 asctl setup 2>&1 </dev/null); rc=$?
chk "asctl setup, no terminal and no --yes: the plan and the warning, nothing changed" \
	'[ "$rc" = 1 ] && has "disable tmux.service, which runs tmux" && has "the running tmux server is tmux.service.s and stays so until the next boot" && [ "$(u2 systemctl --user is-enabled asctl-tmux.service 2>&1)" = disabled ]' \
	'echo "rc $rc: $out"'
out=$(u2 asctl setup --yes 2>&1); rc=$?
chk "asctl setup --yes: tmux.service disabled but not stopped (its server still up)" \
	'[ "$rc" = 0 ] && [ "$(u2 systemctl --user is-enabled tmux.service)" = disabled ] && [ "$(u2prop tmux.service ActiveState)" = active ] && [ "$(s2pid)" = "$OLDSRV" ]' 'echo "rc $rc: $out"'
chk "  the machine's units on for sbuser2 (not for sbuser), the timer up, the drop-in written" \
	'[ "$(x readlink -f "$(u2prop asctl-tmux.service FragmentPath)")" = /etc/systemd/user/asctl-tmux.service ] && [ "$(u2 systemctl --user is-enabled asctl-boot.service)" = enabled ] && [ "$(u2prop asctl-watch.timer ActiveState)" = active ] && u2 test -f $H2/.config/systemd/user/tmux-spawn-.scope.d/asctl.conf && [ "$(ux systemctl --user is-enabled asctl-watch.timer 2>&1)" != enabled ]' \
	'echo "$(u2prop asctl-tmux.service FragmentPath) $(u2prop asctl-watch.timer ActiveState)"; echo "$out"'
S2S=dddddddd-0000-4000-8000-0000000000cc
c2pid() { d2 /opt/asc/bin/asctl live | awk -v s="$S2S" '$2 == s {print $1}'; }
d2 tmux new-session -d -s c2 -c "$H2/w" -- /opt/asc/tests/asc/bin/claude --session-id "$S2S"
wait_for 15 '[ -n "$(c2pid)" ]'
d2 asctl fav "$(c2pid)" --name mach >/dev/null 2>&1
MID=$(u2 jq -r '.entries[] | select(.name == "mach") | .id4' "$H2/.local/state/agent-session-control/registry.json")
d2 asctl off "$MID" >/dev/null 2>&1; d2 asctl on "$MID" >/dev/null 2>&1; d2 asctl resurrect "$MID" on >/dev/null 2>&1
wrapof() { u2 cat "/proc/$(u2 ps -o ppid= -p "$1" | tr -d " ")/cmdline" 2>/dev/null | tr "\0" " "; }
chk "its favorite runs from the installed release (asctl-wrap there), resurrect on" \
	'wait_for 15 "[ -n \"\$(c2pid)\" ]" && wrapof "$(c2pid)" | grep -q " $OPT/releases/[0-9a-f]*/bin/asctl-wrap " && [ "$(u2 jq -r ".entries[\"$MID\"].resurrect" "$H2/.local/state/agent-session-control/registry.json")" = true ]' \
	'echo "claude $(c2pid): $(wrapof "$(c2pid)")"'
u2 env ASC_MEMINFO="$H2/meminfo" python3 -I -c 'import sys, time; sys.path.insert(0, "/opt/asc"); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 30 * i) for i in range(12, -1, -1)])'
echo "== 8. the reboot (both users)"
# Steady memory before the reboot (the host kernel's boot id stays: a container restart is a
# boot of its systemd only), then the reboot: shutdown stops the units, the next boot runs them.
ux env ASC_MEMINFO=/home/sbuser/meminfo python3 -I -c 'import sys, time; sys.path.insert(0, "/opt/asc"); from asc import memory, registry
s = memory.sample(); now = int(time.time())
registry.write_private(registry.state_dir() + "/memory.json", [dict(s, t=now - 30 * i) for i in range(12, -1, -1)])'
docker restart -t 60 "$C" >/dev/null 2>&1
chk "the reboot: systemd and sbuser's manager up again, still no network" \
	'wait_for 60 "x systemctl is-system-running 2>/dev/null | grep -qE \"running|degraded\"" && wait_for 30 "ux systemctl --user is-system-running 2>/dev/null | grep -qE \"running|degraded\"" && [ "$(x ls /sys/class/net)" = lo ]' \
	'x systemctl --failed --no-legend; x ls /sys/class/net'
chk "asctl-boot.service ran and ended cleanly" \
	'wait_for 60 "[ \"\$(uprop asctl-boot.service ActiveState) \$(uprop asctl-boot.service Result) \$(uprop asctl-boot.service ExecMainStatus)\" = \"inactive success 0\" ]"' \
	'echo "$(uprop asctl-boot.service ActiveState) $(uprop asctl-boot.service Result) $(uprop asctl-boot.service ExecMainStatus)"; journal asctl-boot'
EV=/home/sbuser/.local/state/agent-session-control/events.jsonl
chk "the favorite is back in its tmux session, by boot, with rc" \
	'dux tmux has-session -t "=bootc-$BID" && wait_for 15 "[ -n \"\$(bpid)\" ]" && ux jq -s -e "map(select(.kind == \"on\")) | last | .by == \"boot\" and .rc == true" $EV >/dev/null' \
	'journal asctl-boot; ux jq -s -c ".[-4:]" $EV'
chk "claude.ai not answering: boot waited 2 s, said so, started anyway" \
	'ux jq -s -e "map(select(.kind == \"waiting\" and (.text | test(\"127.0.0.1:9 did not answer in 2 s\")))) | length == 1" $EV >/dev/null' 'ux jq -s -c "map(select(.kind == \"waiting\"))" $EV'
chk "its server is asctl-tmux.service's (enabled, up at boot)" \
	'[ "$(uprop asctl-tmux.service ActiveState)" = active ] && cgof "$(spid)" | grep -q "/asctl-tmux.service$"' 'echo "server $(spid): $(cgof "$(spid)")"'
cg2() { u2 cat "/proc/$1/cgroup" 2>/dev/null | cut -d: -f3; }
chk "sbuser2 after the reboot: the old tmux.service did not start; the server is asctl-tmux.service's" \
	'wait_for 30 "[ -n \"\$(s2pid)\" ]" && [ "$(u2prop tmux.service ActiveState)" = inactive ] && cg2 "$(s2pid)" | grep -q "/asctl-tmux.service$"' \
	'echo "tmux.service $(u2prop tmux.service ActiveState); server $(s2pid): $(cg2 "$(s2pid)")"'
chk "  its favorite is back, by boot, from the installed release" \
	'wait_for 60 "d2 tmux has-session -t =mach-$MID 2>/dev/null" && wait_for 15 "[ -n \"\$(c2pid)\" ]" && wrapof "$(c2pid)" | grep -q "$OPT/releases/" && u2 jq -s -e "map(select(.kind == \"on\")) | last | .by == \"boot\"" "$H2/.local/state/agent-session-control/events.jsonl" >/dev/null' \
	'u2 journalctl --user -u asctl-boot -n 8 --no-pager -o cat'

echo "== 9. asctl setup --remove, then install.sh --uninstall"
out=$(x /opt/asc/install.sh --uninstall 2>&1); rc=$?
chk "uninstall while sbuser2 has it set up: refused, the user named" '[ "$rc" = 1 ] && has "asctl is set up for: sbuser2" && x test -d $OPT' 'echo "rc $rc: $out"'
out=$(u2 asctl setup --remove --yes 2>&1); rc=$?
chk "asctl setup --remove: its units off, tmux.service enabled again, the server left as it is" \
	'[ "$rc" = 0 ] && [ "$(u2 systemctl --user is-enabled asctl-tmux.service 2>&1)" = disabled ] && [ "$(u2 systemctl --user is-enabled tmux.service)" = enabled ] && [ "$(u2prop asctl-tmux.service ActiveState)" = active ] && [ "$(u2prop asctl-watch.timer ActiveState)" = inactive ] && ! u2 test -e $H2/.config/systemd/user/tmux-spawn-.scope.d/asctl.conf' \
	'echo "rc $rc: $out"'
out=$(x /opt/asc/install.sh --uninstall 2>&1); rc=$?
chk "uninstall while a pane still runs its asctl-wrap: refused" '[ "$rc" = 1 ] && has "processes still run its code"' 'echo "rc $rc: $out"'
out=$(x /opt/asc/install.sh --uninstall --force 2>&1); rc=$?
chk "uninstall --force: its folder, link and units gone; sbuser's own units kept" \
	'[ "$rc" = 0 ] && ! x test -e $OPT && ! x test -L /usr/local/bin/asctl && ! x test -e /etc/systemd/user/asctl-tmux.service && ux test -f /home/sbuser/.config/systemd/user/asctl-tmux.service' 'echo "rc $rc: $out"'
chk "  sbuser2's session and its claude still run" 'd2 tmux has-session -t "=mach-$MID" && [ -n "$(c2pid)" ]'
out=$(x /opt/asc/install.sh --uninstall 2>&1); rc=$?
chk "uninstall again: nothing to do" '[ "$rc" = 0 ] && has "not installed: nothing to do"' 'echo "rc $rc: $out"'

echo
echo "sandbox: $pass passed, $fail failed"
[ "$fail" = 0 ] || printf '  failed: %s\n' "${FAILED[@]}"
[ "${KEEP:-0}" = 1 ] && echo "KEEP=1: container and image left; remove them with tests/sandbox.sh --down"
[ "$fail" = 0 ]
