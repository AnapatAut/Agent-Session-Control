#!/usr/bin/env bash
# asctl in a throwaway container booting real systemd: the host suites on a clean Ubuntu, the
# dashboard as systemd user units (socket activation, idle exit, stop), and a real out-of-memory
# kill kept inside a capped unit. The backend's tests (watcher, tmux unit, boot resurrect,
# setup) grow here. Leaves nothing behind.
#   tests/sandbox.sh            build, run every check, tear down  (a few minutes)
#   KEEP=1 tests/sandbox.sh     same, but leave the container and image up to look around
#   tests/sandbox.sh --down     remove everything a run left: container, network, builder, image
# Needs Docker, and internet for the build only (Ubuntu packages); the test container has none.
#
# Safety, as in the other kits' sandboxes: one container on an --internal network (no route
# out), no published ports, no bind mounts, not privileged, memory and process limits (the
# memory cap is a guard rail, not a boundary: systemd needs /sys/fs/cgroup writable). The check
# before any test aborts the run if that does not hold. The image is built by a throwaway buildx
# builder (its build cache goes with it) from the repo's tracked files only, so uncommitted
# edits are tested once git-added. Only objects with the exact names below are ever removed.
# No pipefail on purpose: checks pipe into grep -q, whose early exit would fail the writer.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=asc-sandbox:latest NET=asc-sandbox-net C=asc-sandbox BUILDER=asc-sandbox-builder
# The builder's daemon image, pinned by tag and digest (a re-pointed tag cannot swap it).
# Bump: docker buildx imagetools inspect moby/buildkit:<version>, its top-level Digest.
BK=moby/buildkit:v0.30.0@sha256:0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f
SB_UID=2001 RUN_DIR=/run/user/2001
pass=0 fail=0 FAILED=()
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1${2:+  -- $(printf '%s' "$2" | head -20 | tr '\n' ' ')}"; fail=$((fail + 1)); FAILED+=("$1"); }
chk() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
die() { echo "ABORT: $*" >&2; exit 2; }
wait_for() { local n=$1; shift; for _ in $(seq "$n"); do eval "$*" && return 0; sleep 1; done; return 1; }
x()  { docker exec "$C" "$@"; }
# As sbuser, with its user manager's environment (systemctl --user works).
ux() { docker exec -u sbuser -e XDG_RUNTIME_DIR="$RUN_DIR" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN_DIR/bus" -w /opt/asc "$C" "$@"; }
# Put together at run time, so the privacy check does not read them as real ones.
E=@ N=.ts
LOGIN="someone${E}example.com" HOST="machine.example${N}.net"
# A request as tailscale serve passes it to the dashboard socket.
dash_code() { ux curl -s -o /dev/null -w '%{http_code}' --unix-socket "$RUN_DIR/asctl/dash.sock" \
	-H "Tailscale-User-Login: $LOGIN" -H "Host: localhost" -H "X-Forwarded-Host: $HOST" \
	-H "X-Forwarded-For: 192.0.2.10" "http://x$1"; }
uprop() { ux systemctl --user show "$1" -p "$2" --value; }

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
[ "${1:-}" = "--down" ] && { down; echo "sandbox removed"; exit 0; }
command -v docker >/dev/null || die "docker not found"
docker container inspect "$C" >/dev/null 2>&1 && die "container $C exists (another run?). Clean up: tests/sandbox.sh --down"
docker buildx inspect "$BUILDER" >/dev/null 2>&1 && die "builder $BUILDER exists (another run?). Clean up: tests/sandbox.sh --down"
docker image inspect "$BK" >/dev/null 2>&1 && PULLED_BK=0 || PULLED_BK=1
# The network is the run lock: creating it is atomic, so a second run stops here, before it
# sets a trap that could remove the first run's container.
docker network create --internal --label "asc-sandbox.pulled-buildkit=$PULLED_BK" "$NET" >/dev/null 2>&1 \
	|| die "network $NET exists (another run?). Clean up: tests/sandbox.sh --down"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"; [ "${KEEP:-0}" = 1 ] || down' EXIT
# Ctrl-C or TERM ends the run (docker exec catches SIGINT, and bash would carry on).
trap 'echo "interrupted" >&2; exit 130' INT TERM

echo "== build (ubuntu:24.04, systemd, tmux, the repo's tracked files)"
mkdir -p "$CTX/asc"
(cd "$REPO" && git ls-files -z | xargs -0 -I{} cp --parents {} "$CTX/asc/") || die "copying the repo"
[ -x "$CTX/asc/bin/asctl" ] || die "copying the repo: no bin/asctl (not a git checkout, or files not git-added?)"
cp "$REPO/tests/sandbox-asc/Dockerfile" "$CTX/"
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt image="$BK" >/dev/null 2>&1 || die "builder"
out=$(docker buildx build --builder "$BUILDER" --load -t "$IMAGE" "$CTX" 2>&1) || { echo "$out" | tail -20; die "build"; }
docker buildx rm -f "$BUILDER" >/dev/null 2>&1
[ "$PULLED_BK" = 1 ] && docker rmi "$BK" >/dev/null 2>&1
rm -rf "$CTX"

echo "== start the systemd container"
# --memory-swap = --memory: no swap, so a memory test ends in a kill, not in swapping.
docker run -d --name "$C" --hostname asc-sandbox --network "$NET" \
	--cap-add SYS_ADMIN --security-opt apparmor=unconfined --cgroupns=private \
	--tmpfs /run --tmpfs /run/lock --memory 1g --memory-swap 1g --pids-limit 1024 -e container=docker \
	--stop-signal SIGRTMIN+3 \
	"$IMAGE" sh -c 'mount -o remount,rw /sys/fs/cgroup 2>/dev/null; exec /sbin/init' >/dev/null || die "docker run"

echo "== 0. safety (abort when the container could reach the host)"
chk "no host mounts, no published ports, not privileged" \
	'[ "$(docker inspect "$C" --format "{{len .Mounts}} {{len .HostConfig.PortBindings}} {{.HostConfig.Privileged}}")" = "0 0 false" ]'
chk "memory capped at 1 GiB, no swap, process limit" \
	'[ "$(docker inspect "$C" --format "{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}}")" = "1073741824 1073741824 1024" ]'
chk "/proc/sys and /sys read-only inside" \
	'x sh -c "grep -E \" /proc/sys \" /proc/self/mountinfo | grep -qE \" ro[ ,]\" && grep -E \" /sys \" /proc/self/mountinfo | grep -qE \" ro[ ,]\""'
chk "no default route" 'rt=$(x cat /proc/net/route) && [ -n "$rt" ] && ! printf "%s\n" "$rt" | awk "NR > 1 && \$2 == \"00000000\"" | grep -q .' "$(x cat /proc/net/route)"
[ "$fail" = 0 ] || die "the safety check failed"

echo "== 1. systemd and the user's manager"
chk "systemd is PID 1 and running (or degraded)" \
	'wait_for 60 "x systemctl is-system-running 2>/dev/null | grep -qE \"running|degraded\""' "$(x systemctl --failed --no-legend 2>&1)"
chk "linger starts sbuser's user manager at boot" 'wait_for 30 "x systemctl is-active --quiet user@$SB_UID.service"' "$(x systemctl status "user@$SB_UID.service" 2>&1 | tail -5)"
chk "its runtime folder is 0700 and its own" '[ "$(x stat -c "%a %u" "$RUN_DIR")" = "700 $SB_UID" ]'
chk "systemctl --user answers" 'wait_for 20 "ux systemctl --user is-system-running 2>/dev/null | grep -qE \"running|degraded\""' "$(ux systemctl --user --failed --no-legend 2>&1)"

echo "== 2. the host suites on a clean Ubuntu"
for suite in asc dash; do
	out=$(ux bash "tests/$suite.sh" 2>&1)
	chk "tests/$suite.sh: $(printf '%s\n' "$out" | tail -1)" 'printf "%s\n" "$out" | tail -1 | grep -qE " 0 failed$"' \
		"$(printf '%s\n' "$out" | grep '  FAIL  ')"
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
printf "{\"login\": \"%s\", \"host\": \"%s\"}\n" "$1" "$2" > "$c/dash.json"; chmod 600 "$c/dash.json"
systemctl --user daemon-reload && systemctl --user enable --now asctl-dash.socket' _ "$LOGIN" "$HOST" >/dev/null 2>&1
chk "the socket unit listens" '[ "$(uprop asctl-dash.socket ActiveState)" = active ]' "$(ux systemctl --user status asctl-dash.socket 2>&1 | tail -5)"
chk "socket 0600 in a 0700 folder, both sbuser's" \
	'[ "$(x stat -c "%a %u" "$RUN_DIR/asctl/dash.sock" "$RUN_DIR/asctl" | tr "\n" " ")" = "600 $SB_UID 700 $SB_UID " ]' "$(x ls -la "$RUN_DIR/asctl")"
chk "no server before the first request" '[ "$(uprop asctl-dash.service ActiveState)" = inactive ]'
chk "the first request starts the server: 200" '[ "$(dash_code /api/state)" = 200 ]' "$(ux journalctl --user -u asctl-dash -n 5 --no-pager -o cat 2>&1)"
chk "the server runs as a unit" '[ "$(uprop asctl-dash.service ActiveState)" = active ]'
chk "a request without the login: 403" \
	'[ "$(ux curl -s -o /dev/null -w "%{http_code}" --unix-socket "$RUN_DIR/asctl/dash.sock" -H "Host: localhost" http://x/api/state)" = 403 ]'
chk "the app files without the login: 200" '[ "$(ux curl -s -o /dev/null -w "%{http_code}" --unix-socket "$RUN_DIR/asctl/dash.sock" -H "Host: localhost" http://x/manifest.json)" = 200 ]'
chk "idle: the server exits after 5 s, cleanly" \
	'wait_for 20 "[ \"\$(uprop asctl-dash.service ActiveState)\" = inactive ]" && [ "$(uprop asctl-dash.service Result)" = success ]' \
	"$(uprop asctl-dash.service ActiveState) $(uprop asctl-dash.service Result)"
chk "and the socket stays with systemd" '[ "$(uprop asctl-dash.socket ActiveState)" = active ] && x test -S "$RUN_DIR/asctl/dash.sock"'
chk "the next request starts it again: 200" '[ "$(dash_code /api/state)" = 200 ]'
ux systemctl --user stop asctl-dash.service 2>/dev/null  # (it warns that the socket can start it again)
chk "systemctl stop: a clean exit" '[ "$(uprop asctl-dash.service Result)" = success ]' "$(ux journalctl --user -u asctl-dash -n 5 --no-pager -o cat 2>&1)"
ux systemctl --user stop asctl-dash.socket
chk "stopping the socket unit removes the socket" '! x test -e "$RUN_DIR/asctl/dash.sock"'

echo "== 4. a real out-of-memory kill, kept inside its unit"
# The watcher must tell an OOM kill from other ends; this proves the sandbox can make one.
# MemoryMax 64M on a unit that wants 400 MB: the kernel kills it there, the container (1 GiB)
# and the host are never short.
chk "the user manager may set memory limits (memory delegated)" \
	'x grep -qw memory "/sys/fs/cgroup/user.slice/user-$SB_UID.slice/user@$SB_UID.service/cgroup.subtree_control"' \
	"$(x cat "/sys/fs/cgroup/user.slice/user-$SB_UID.slice/user@$SB_UID.service/cgroup.subtree_control" 2>&1)"
ux systemd-run --user --unit=asc-hog -p MemoryMax=64M -p MemorySwapMax=0 \
	python3 -c 'b = [bytearray(1 << 20) for _ in range(400)]; import time; time.sleep(30)' >/dev/null 2>&1
chk "the hog ends as oom-kill" 'wait_for 20 "[ \"\$(uprop asc-hog.service Result)\" = oom-kill ]"' \
	"$(uprop asc-hog.service ActiveState) $(uprop asc-hog.service Result)"
chk "the kernel counted the kill in that unit" \
	'ux journalctl --user -u asc-hog --no-pager -o cat | grep -qiE "out of memory|oom"' "$(ux journalctl --user -u asc-hog --no-pager -o cat 2>&1 | tail -3)"
chk "the user manager is still up" 'x systemctl is-active --quiet user@$SB_UID.service'

echo
echo "sandbox: $pass passed, $fail failed"
[ "$fail" = 0 ] || printf '  failed: %s\n' "${FAILED[@]}"
[ "${KEEP:-0}" = 1 ] && echo "KEEP=1: container and image left; remove them with tests/sandbox.sh --down"
[ "$fail" = 0 ]
