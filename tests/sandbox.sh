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
# first. The check before any test aborts the run if that does not hold.
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
IMAGE=asc-sandbox:latest NET=asc-sandbox-net C=asc-sandbox BUILDER=asc-sandbox-builder
# The builder's daemon image, pinned by tag and digest (a re-pointed tag cannot swap it).
# Bump: docker buildx imagetools inspect moby/buildkit:<version>, its top-level Digest.
BK=moby/buildkit:v0.30.0@sha256:0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f
SB_UID=2001 RUN_DIR=/run/user/2001
pass=0 fail=0 FAILED=() LOCKED=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1${2:+  -- $(printf '%s' "$2" | head -20 | tr '\n' ' ')}"; fail=$((fail + 1)); FAILED+=("$1"); }
# chk <name> <test> [<what to show on failure>]: both are code, the second run only on failure
# (after any waiting in the test, so it shows the state the test ended on).
chk() { if eval "$2"; then ok "$1"; else bad "$1" "$([ -z "${3:-}" ] || eval "$3" 2>&1)"; fi; }
die() { echo "ABORT: $*" >&2; exit 2; }
wait_for() { local n=$1; shift; for _ in $(seq "$n"); do eval "$*" && return 0; sleep 1; done; return 1; }
x()  { docker exec "$C" "$@"; }
# As sbuser, with its user manager's environment (systemctl --user works).
ux() { docker exec -u sbuser -e XDG_RUNTIME_DIR="$RUN_DIR" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN_DIR/bus" -w /opt/asc "$C" "$@"; }
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

echo "== start the systemd container"
# --memory-swap = --memory: no swap, so a memory test ends in a kill, not in swapping.
docker run -d --name "$C" --hostname asc-sandbox --network none \
	--cap-add SYS_ADMIN --cap-drop NET_RAW --cap-drop NET_BIND_SERVICE --cap-drop MKNOD \
	--security-opt apparmor=unconfined --security-opt no-new-privileges --cgroupns=private \
	--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:size=256m,exec --memory 1g --memory-swap 1g --pids-limit 1024 \
	--oom-score-adj 1000 -e container=docker --stop-signal SIGRTMIN+3 \
	"$IMAGE" sh -c 'mount -o remount,rw /sys/fs/cgroup 2>/dev/null; exec /sbin/init' >/dev/null || die "docker run"

echo "== 0. safety (abort when the container could reach the host)"
chk "no host mounts, no published ports, not privileged" \
	'[ "$(docker inspect "$C" --format "{{len .Mounts}} {{len .HostConfig.PortBindings}} {{.HostConfig.Privileged}}")" = "0 0 false" ]'
chk "memory capped at 1 GiB, no swap, process limit, first for the OOM killer" \
	'[ "$(docker inspect "$C" --format "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}}")" = "1073741824 1073741824 1024" ] && [ "$(x cat /proc/1/oom_score_adj)" = 1000 ]'
chk "/proc/sys and /sys read-only inside" \
	'[ "$(x awk "\$5 == \"/sys\" || \$5 == \"/proc/sys\" {print \$5, substr(\$6, 1, 3)}" /proc/self/mountinfo | sort)" = "$(printf "/proc/sys ro,\n/sys ro,")" ]' \
	'x awk "\$5 == \"/sys\" || \$5 == \"/proc/sys\"" /proc/self/mountinfo'
chk "no network but loopback" '[ "$(docker inspect "$C" --format "{{.HostConfig.NetworkMode}}")" = none ] && [ "$(x ls /sys/class/net)" = lo ]' 'x ls /sys/class/net'
# The host's address on Docker's default bridge (read here, never written down), its ssh port.
GW=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
chk "the host cannot be reached (its Docker bridge, ssh)" '[ -n "$GW" ] && x sh -c "! timeout 3 bash -c \"echo > /dev/tcp/$GW/22\" 2>/dev/null"' 'echo "bridge gateway: ${GW:-none}"'
chk "no new privileges, no raw sockets or device nodes" \
	'[ "$(x sed -n "s/^NoNewPrivs:\t//p" /proc/1/status)" = 1 ] && docker inspect "$C" --format "{{.HostConfig.CapDrop}}" | grep -q NET_RAW && docker inspect "$C" --format "{{.HostConfig.CapDrop}}" | grep -q MKNOD' \
	'x grep NoNewPrivs /proc/1/status; docker inspect "$C" --format "{{.HostConfig.CapDrop}}"'
[ "$fail" = 0 ] || die "the safety check failed"

echo "== 1. systemd and the user's manager"
chk "systemd is PID 1 and running (or degraded)" \
	'wait_for 60 "x systemctl is-system-running 2>/dev/null | grep -qE \"running|degraded\""' 'x systemctl --failed --no-legend'
chk "linger starts sbuser's user manager at boot" 'wait_for 30 "x systemctl is-active --quiet user@$SB_UID.service"' 'x systemctl status "user@$SB_UID.service" | tail -5'
chk "its runtime folder is 0700 and its own" '[ "$(x stat -c "%a %u" "$RUN_DIR")" = "700 $SB_UID" ]'
chk "systemctl --user answers" 'wait_for 20 "ux systemctl --user is-system-running 2>/dev/null | grep -qE \"running|degraded\""' 'ux systemctl --user --failed --no-legend'

echo "== 2. the host suites on a clean Ubuntu"
for suite in asc dash; do
	out=$(timeout 900 docker exec -u sbuser -w /opt/asc "$C" bash "tests/$suite.sh" 2>&1); rc=$?
	chk "tests/$suite.sh: $(printf '%s\n' "$out" | tail -1)" \
		'[ "$rc" = 0 ] && printf "%s\n" "$out" | tail -1 | grep -qE "^$suite: [1-9][0-9]* passed, 0 failed$"' \
		'echo "exit $rc"; printf "%s\n" "$out" | grep "  FAIL  "'
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

echo
echo "sandbox: $pass passed, $fail failed"
[ "$fail" = 0 ] || printf '  failed: %s\n' "${FAILED[@]}"
[ "${KEEP:-0}" = 1 ] && echo "KEEP=1: container and image left; remove them with tests/sandbox.sh --down"
[ "$fail" = 0 ]
