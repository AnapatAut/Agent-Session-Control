# Sourced by tests/sandbox.sh (and the mutant runner): how a test container is made, the check of
# its whole HostConfig before it starts, the checks from inside after, and the waits until its
# systemd and sbuser's user manager answer. Every function takes the container as its first
# argument.

SB_UID=2001 SB_RUN_DIR=/run/user/2001
# No network but loopback, no ports, no mounts, not privileged, no new privileges, fewer
# capabilities (systemd needs SYS_ADMIN), a 1 GiB memory cap with no swap (--memory-swap =
# --memory: a memory test ends in a kill, not in swapping), a process limit, a small /tmp, and
# the highest OOM score, so the host's OOM killer picks it first; its log capped, so its output
# cannot fill the host's disk.
SB_OPTS=(--hostname asc-sandbox --network none
	--cap-add SYS_ADMIN --cap-drop NET_RAW --cap-drop NET_BIND_SERVICE --cap-drop MKNOD
	--security-opt apparmor=unconfined --security-opt no-new-privileges --cgroupns=private
	--tmpfs /run --tmpfs /run/lock --tmpfs '/tmp:size=256m,exec' --memory 1g --memory-swap 1g --pids-limit 1024
	--oom-score-adj 1000 --log-opt max-size=10m -e container=docker --stop-signal SIGRTMIN+3)
SB_INIT=(sh -c 'mount -o remount,rw /sys/fs/cgroup 2>/dev/null; exec /sbin/init')

# The HostConfig docker gives a container made with SB_OPTS (docker 29.5, the json-file log
# driver), every field, written out here and never taken from a container (a wrong one would
# match itself). Any other value, a field missing or a field more, fails the check: a new docker
# or another default then stops the run until this is read again and changed by hand.
# MaskedPaths is the one field held apart: docker adds a path per CPU of the host
# (/sys/devices/system/cpu/cpuN/thermal_throttle), so the check asks for every path below and
# allows more of that kind only: a path more hidden takes nothing away.
SB_HOSTCONFIG='{
  "AutoRemove": false, "Binds": null,
  "BlkioDeviceReadBps": [], "BlkioDeviceReadIOps": [], "BlkioDeviceWriteBps": [], "BlkioDeviceWriteIOps": [],
  "BlkioWeight": 0, "BlkioWeightDevice": [],
  "CapAdd": ["CAP_SYS_ADMIN"], "CapDrop": ["CAP_MKNOD", "CAP_NET_BIND_SERVICE", "CAP_NET_RAW"],
  "Cgroup": "", "CgroupParent": "", "CgroupnsMode": "private", "ConsoleSize": [0, 0], "ContainerIDFile": "",
  "CpuCount": 0, "CpuPercent": 0, "CpuPeriod": 0, "CpuQuota": 0, "CpuRealtimePeriod": 0, "CpuRealtimeRuntime": 0,
  "CpuShares": 0, "CpusetCpus": "", "CpusetMems": "",
  "DeviceCgroupRules": null, "DeviceRequests": null, "Devices": [],
  "Dns": null, "DnsOptions": [], "DnsSearch": [], "ExtraHosts": null, "GroupAdd": null,
  "IOMaximumBandwidth": 0, "IOMaximumIOps": 0, "IpcMode": "private", "Isolation": "", "Links": null,
  "LogConfig": {"Config": {"max-size": "10m"}, "Type": "json-file"},
  "Memory": 1073741824, "MemoryReservation": 0, "MemorySwap": 1073741824, "MemorySwappiness": null,
  "NanoCpus": 0, "NetworkMode": "none", "OomKillDisable": false, "OomScoreAdj": 1000,
  "PidMode": "", "PidsLimit": 1024, "PortBindings": {}, "Privileged": false, "PublishAllPorts": false,
  "ReadonlyPaths": ["/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger"],
  "ReadonlyRootfs": false, "RestartPolicy": {"MaximumRetryCount": 0, "Name": "no"}, "Runtime": "runc",
  "SecurityOpt": ["apparmor=unconfined", "no-new-privileges"], "ShmSize": 67108864,
  "Tmpfs": {"/run": "", "/run/lock": "", "/tmp": "size=256m,exec"},
  "UTSMode": "", "Ulimits": [], "UsernsMode": "", "VolumeDriver": "", "VolumesFrom": null
}'
SB_MASKED='["/proc/acpi", "/proc/asound", "/proc/interrupts", "/proc/kcore", "/proc/keys", "/proc/latency_stats",
  "/proc/sched_debug", "/proc/scsi", "/proc/timer_list", "/proc/timer_stats", "/sys/devices/virtual/powercap",
  "/sys/firmware"]'

# What differs between container $1's HostConfig and the expected one, a line per field, or
# "same" when nothing does. Also no mounts at all (the image's volumes would show there, not in
# Binds), and no network but "none". Only a finished check prints "same": a caller tests for that
# word, never for no output, so a check that dies half-way (a variable unset under set -u, jq
# killed) fails.
sb_hostconfig_diff() {
	local got out rc
	got=$(docker inspect "$1" --format '[{{json .HostConfig}}, {{json .Mounts}}, {{json .NetworkSettings.Networks}}]' 2>&1) \
		|| { echo "docker inspect: $got"; return 1; }
	out=$(jq -rn --argjson want "$SB_HOSTCONFIG" --argjson masked "$SB_MASKED" --argjson hm "$got" '
		def show($o; $k): if $o | has($k) then $o[$k] | tojson else "(none)" end;
		$hm[0] as $got | $hm[1] as $mounts | $hm[2] as $nets | $got.MaskedPaths as $m
		| (([$got, $want] | map(keys) | add | unique - ["MaskedPaths"])[] as $k
		   | select(($got | has($k)) != ($want | has($k)) or $got[$k] != $want[$k])
		   | "\($k): \(show($got; $k)), expected \(show($want; $k))"),
		  (if ($m | type) != "array" then "MaskedPaths: \($m | tojson), expected a list"
		   else (($masked - $m)[] | "MaskedPaths: \(.) is not hidden"),
		        (($m - $masked)[] | select(type != "string" or contains("\n")
		                                   or (test("^/sys/devices/system/cpu/cpu[0-9]+/thermal_throttle$") | not))
		         | "MaskedPaths: \(tojson) is more than expected")
		   end),
		  (if $mounts != [] then "Mounts: \($mounts | tojson), expected none" else empty end),
		  (if ($nets | type) != "object" or ($nets | keys) != ["none"] then "Networks: \($nets | tojson), expected none only" else empty end)' 2>&1)
	rc=$?
	if [ "$rc" != 0 ]; then echo "jq (exit $rc): $out"; return 1; fi
	[ -n "$out" ] && { printf '%s\n' "$out"; return 1; }
	echo same
}

sb_x()  { local c=$1; shift; docker exec "$c" "$@"; }
# As sbuser, with its user manager's environment (systemctl --user works).
sb_ux() { local c=$1; shift; docker exec -u sbuser -e XDG_RUNTIME_DIR="$SB_RUN_DIR" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$SB_RUN_DIR/bus" -w /opt/asc "$c" "$@"; }

# What is wrong inside started container $1, a line each, or "same" when all holds (as above:
# only a finished check prints it): PID 1's capability bounding set (docker's defaults with
# SYS_ADMIN added and NET_RAW, NET_BIND_SERVICE and MKNOD dropped: bits 0, 1, 3-8, 18, 21, 29,
# 31), its OOM score, /proc/sys and /sys read-only, only loopback, the host's Docker bridge and
# its ssh port out of reach, no new privileges for PID 1.
sb_inside_diff() {
	local c=$1 v gw probs=()
	v=$(sb_x "$c" sed -n 's/^CapBnd:\t//p' /proc/1/status 2>&1); [ "$v" = 00000000a02401fb ] || probs+=("CapBnd of PID 1: $v, expected 00000000a02401fb")
	v=$(sb_x "$c" cat /proc/1/oom_score_adj 2>&1); [ "$v" = 1000 ] || probs+=("oom_score_adj of PID 1: $v, expected 1000")
	v=$(sb_x "$c" awk '$5 == "/sys" || $5 == "/proc/sys" {print $5, substr($6, 1, 3)}' /proc/self/mountinfo 2>&1 | sort)
	[ "$v" = "$(printf '/proc/sys ro,\n/sys ro,')" ] || probs+=("/proc/sys and /sys: ${v//$'\n'/; }, expected both read-only")
	v=$(sb_x "$c" ls /sys/class/net 2>&1); [ "$v" = lo ] || probs+=("network devices: ${v//$'\n'/ }, expected lo only")
	gw=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
	if [ -z "$gw" ]; then probs+=("the host's Docker bridge address: not found, so its reach is not checked")
	elif sb_x "$c" timeout 3 bash -c "echo > /dev/tcp/$gw/22" 2>/dev/null; then probs+=("the host's ssh port on its Docker bridge answers"); fi
	v=$(sb_x "$c" sed -n 's/^NoNewPrivs:\t//p' /proc/1/status 2>&1); [ "$v" = 1 ] || probs+=("NoNewPrivs of PID 1: $v, expected 1")
	[ ${#probs[@]} = 0 ] && { echo same; return 0; }
	printf '%s\n' "${probs[@]}"; return 1
}

# The waits until container $1 is ready, each for at most its seconds: 0 when it came.
sb_wait() { local n=$1 i; shift; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 1; done; "$@"; }
sb_system_up() { sb_x "$1" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; }
sb_user_manager() { sb_x "$1" systemctl is-active --quiet "user@$SB_UID.service"; }
sb_user_bus() { sb_ux "$1" systemctl --user is-system-running 2>/dev/null | grep -qE 'running|degraded'; }
