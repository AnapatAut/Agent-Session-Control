#!/usr/bin/env bash
# The HostConfig check of tests/sandbox-lib.sh, with a fake docker (run by tests/lint.sh): the
# expected config gives "same", and each dangerous change, a field more or less, a mask lost, a
# mount, a network, and a docker or jq that fails or a check that dies, gives something else.
# Needs jq; no Docker.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/sandbox-lib.sh
. "$REPO/tests/sandbox-lib.sh"
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); }
# As docker gives it on a host with two CPUs.
BASE=$(jq -cn --argjson h "$SB_HOSTCONFIG" --argjson m "$SB_MASKED" \
	'$h + {MaskedPaths: ($m + ["/sys/devices/system/cpu/cpu0/thermal_throttle", "/sys/devices/system/cpu/cpu1/thermal_throttle"])}')
HC=$BASE MOUNTS='[]' NETS='{"none": {}}'
docker() {
	[ "$1 $3 $4" = "inspect --format [{{json .HostConfig}}, {{json .Mounts}}, {{json .NetworkSettings.Networks}}]" ] || return 9
	printf '[%s, %s, %s]\n' "$HC" "$MOUNTS" "$NETS"
}
# reported <change> <the line it must give>: the config with the change (jq), MOUNTS and NETS as
# set; the answer must not be "same"
reported() {
	local out; HC=$(jq -c "$1" <<<"$BASE"); out=$(sb_hostconfig_diff c); MOUNTS='[]' NETS='{"none": {}}'
	[ "$out" != same ] && [[ $out == *"$2"* ]]
}

out=$(sb_hostconfig_diff c)
[ "$out" = same ] && ok "the expected config, more CPUs masked: same" || bad "the expected config, more CPUs masked: same" "$out"
reported '.Privileged = true' 'Privileged: true, expected false' && ok "privileged: reported" || bad "privileged: reported"
reported '.CapAdd += ["CAP_NET_ADMIN"]' 'CapAdd: ' && ok "a capability added: reported" || bad "a capability added: reported"
reported '.CapDrop -= ["CAP_NET_RAW"]' 'CapDrop: ' && ok "a capability no longer dropped: reported" || bad "a capability no longer dropped: reported"
reported '.PidMode = "host"' 'PidMode: "host"' && ok "the host's pids: reported" || bad "the host's pids: reported"
reported '.IpcMode = "host"' 'IpcMode: "host"' && ok "the host's IPC: reported" || bad "the host's IPC: reported"
reported '.UTSMode = "host"' 'UTSMode: "host"' && ok "the host's UTS: reported" || bad "the host's UTS: reported"
reported '.UsernsMode = "host"' 'UsernsMode: "host"' && ok "the host's user namespace: reported" || bad "the host's user namespace: reported"
reported '.CgroupnsMode = "host"' 'CgroupnsMode: "host"' && ok "the host's cgroup namespace: reported" || bad "the host's cgroup namespace: reported"
reported '.NetworkMode = "host"' 'NetworkMode: "host"' && ok "the host's network: reported" || bad "the host's network: reported"
reported '.Devices = [{"PathOnHost": "/dev/kmsg"}]' 'Devices: ' && ok "a device: reported" || bad "a device: reported"
reported '.Binds = ["/:/host"]' 'Binds: ' && ok "a bind mount: reported" || bad "a bind mount: reported"
reported '.PortBindings = {"22/tcp": [{"HostPort": "2222"}]}' 'PortBindings: ' && ok "a published port: reported" || bad "a published port: reported"
reported '.SecurityOpt -= ["no-new-privileges"]' 'SecurityOpt: ' && ok "new privileges allowed: reported" || bad "new privileges allowed: reported"
reported '.Memory = 0' 'Memory: 0' && ok "no memory cap: reported" || bad "no memory cap: reported"
reported '.MemorySwap = -1' 'MemorySwap: -1' && ok "swap allowed: reported" || bad "swap allowed: reported"
reported '.OomScoreAdj = 0' 'OomScoreAdj: 0' && ok "not first for the OOM killer: reported" || bad "not first for the OOM killer: reported"
reported '.PidsLimit = null' 'PidsLimit: null' && ok "no process limit: reported" || bad "no process limit: reported"
reported '.Sysctls = {"net.ipv4.ip_forward": "1"}' 'Sysctls: {' && ok "a field more (sysctls): reported" || bad "a field more (sysctls): reported"
reported 'del(.ReadonlyPaths)' 'ReadonlyPaths: (none)' && ok "a field gone: reported" || bad "a field gone: reported"
reported '.ReadonlyPaths -= ["/proc/sys"]' 'ReadonlyPaths: ' && ok "/proc/sys writable: reported" || bad "/proc/sys writable: reported"
reported '.MaskedPaths -= ["/proc/kcore"]' 'MaskedPaths: /proc/kcore is not hidden' && ok "a mask lost: reported" || bad "a mask lost: reported"
reported '.MaskedPaths += ["/etc"]' 'MaskedPaths: "/etc" is more than expected' && ok "a mask of another kind: reported" || bad "a mask of another kind: reported"
reported '.MaskedPaths = null' 'MaskedPaths: null, expected a list' && ok "no masks: reported" || bad "no masks: reported"
reported '.MaskedPaths += ["/etc\n/sys/devices/system/cpu/cpu0/thermal_throttle"]' 'is more than expected' \
	&& ok "a mask with a newline in it: reported" || bad "a mask with a newline in it: reported"
reported '.LogConfig.Config = {}' 'LogConfig: ' && ok "the log not capped: reported" || bad "the log not capped: reported"
NETS='{"none": {}, "bridge": {}}'
reported '.' 'Networks: ' && ok "a network besides none: reported" || bad "a network besides none: reported"
NETS='null'
reported '.' 'Networks: null' && ok "no networks at all: reported" || bad "no networks at all: reported"
MOUNTS='[{"Type": "volume", "Destination": "/x"}]'
reported '.' 'Mounts: [' && ok "a volume of the image: reported" || bad "a volume of the image: reported"
jq() { return 137; }  # killed, nothing printed
out=$(sb_hostconfig_diff c)
[ "$out" = "jq (exit 137): " ] && ok "jq killed: not same" || bad "jq killed: not same" "$out"
unset -f jq
# shellcheck disable=SC2154  # unset on purpose: the check dies under set -u, and prints nothing
[ "$( (set -u; sb_hostconfig_diff "$no_such_var") 2>/dev/null)" != same ] && ok "a check that dies half-way: not same" || bad "a check that dies half-way: not same"
docker() { echo "Error: No such object: c" >&2; return 1; }
out=$(sb_hostconfig_diff c)
[[ $out == "docker inspect: Error: No such object: c" ]] && ok "docker inspect fails: reported" || bad "docker inspect fails: reported" "$out"
docker() { echo 'not json'; }
out=$(sb_hostconfig_diff c)
[ -n "$out" ] && [ "$out" != same ] && ok "an answer that is not JSON: reported" || bad "an answer that is not JSON: reported"
echo "sandbox-lib: $pass passed, $fail failed"
[ "$fail" = 0 ]
