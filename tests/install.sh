#!/usr/bin/env bash
# install.sh, the machine install, run as root in a namespace of its own: installs, upgrades,
# each refusal, uninstall, and a kill at every step it takes (then the next run must end as one
# that was never killed).
#   tests/install.sh                       about 1 min
#   ASC_ONLY=<case,...> tests/install.sh   only those cases (tests/cases.sh)
# Its mutants (changes to install.sh each check must catch) are in tests/mutants-install.txt,
# run by tests/mutate.sh. TEST_STOP_AT=<check>: exit right after that check's FAIL.
#
# How. unshare starts this script again in a user namespace where it is root (its root is the
# user who runs it, no more: it can change nothing that user could not), a mount namespace and a
# pid namespace of its own. There, before anything else, tmpfs over /opt, /usr/local/bin,
# /etc/systemd/user, /run, /home and /var/lib/systemd/linger, and a passwd of its own; the
# checkout's files are copied in first (/home hides it). install.sh runs from those copies as it
# is: the machine's own folders, homes and processes are never seen, and all of it goes with the
# namespace, even after a SIGKILL. Needs user namespaces open to users (on Ubuntu:
# kernel.apparmor_restrict_unprivileged_userns = 0); without them, one FAIL and no check.
# Not real root: what needs it (a folder that is not root's, a user who is not root) is in
# tests/sandbox.sh.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
# One check, one fixed name: `ok NAME` or `bad NAME [DETAILS]`, the same NAME both ways, never a
# value in it, and run once: not in a loop or a function (tests/checklint.py, run by
# tests/lint.sh). DETAILS, what was seen, go on the lines after the FAIL, each indented.
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); [ "${TEST_STOP_AT-}" != "$1" ] || exit 1; }
skip() { echo "  skip  $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; }
# A setup step that did not come: one FAIL, "setup: NAME", and the suite ends there. Its exit must
# end the suite: never inside ( ), $( ), <( ), a pipeline or an & job.
stop() { echo "  FAIL  setup: $1"; [ -z "${2-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; fail=$((fail + 1)); echo "install: $pass passed, $fail failed (stopped at a setup step)"; exit 1; }
# Waits, as in tests/asc.sh: CMD... every 0.1 s until it succeeds (poll) or fails (poll_gone), at
# most LIMIT whole seconds; non-zero at the limit.
poll()      { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" && return 0; sleep 0.1; done; "${@:2}"; }
poll_gone() { local _poll_i; for ((_poll_i = 0; _poll_i < $1 * 10; _poll_i++)); do "${@:2}" || return 0; sleep 0.1; done; ! "${@:2}"; }
. "$REPO/tests/cases.sh"

# --- the namespace
if [ -z "${ASC_INSTALL_NS-}" ]; then
	[ "$(id -u)" != 0 ] || stop "run as a user, not root (as root its mounts would be the machine's)"
	out=$(unshare --map-root-user --mount --pid --fork --mount-proc true 2>&1) || stop "a namespace of its own (unshare as this user)" "$out"
	# --kill-child: when unshare goes (a time limit's TERM), everything in the namespace goes too
	exec unshare --map-root-user --mount --pid --fork --mount-proc --kill-child env ASC_INSTALL_NS=1 bash "${BASH_SOURCE[0]}" "$@"
fi
# Before any mount: pid 1 of a pid namespace, root only of a user namespace that is not the
# machine's (whose map is "0 0 4294967295"). Else nothing is mounted and nothing runs.
[ "$$" = 1 ] && [ "$(id -u)" = 0 ] && ! grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$' /proc/self/uid_map \
	|| stop "in a namespace of its own (pid 1, root of its own user namespace)" "pid $$, uid $(id -u), uid_map $(cat /proc/self/uid_map)"
T=/mnt
mount -t tmpfs -o mode=755 asc-install-t "$T" || stop "a tmpfs of its own on /mnt"
mkdir "$T/repo" "$T/src" "$T/shim" "$T/save" || stop "its folders"
cp -a "$REPO/install.sh" "$REPO/asc" "$REPO/bin" "$REPO/systemd" "$T/repo/" || stop "a copy of the checkout"
find "$T/repo" -name __pycache__ -prune -exec rm -rf {} + || stop "the copy without __pycache__"
for d in /opt /usr/local/bin /etc/systemd/user /run /home /var/lib/systemd/linger; do
	mount -t tmpfs -o mode=755 asc-install "$d" || stop "a tmpfs over each folder install.sh reads or writes" "$d"
done
mkdir -m 700 "$T/root" || stop "root's home (in its own tmpfs)"
mkdir -m 755 /home/sbuser || stop "a user's home"
# Its own users, read through files only: root, a user, and (for one check) a user whose home it
# cannot read: the machine's /root, root's and closed (a namespace's root has no right over it).
PW="$T/passwd"
users() {
	printf '%s\n' 'root:x:0:0:root:/mnt/root:/bin/bash' 'sbuser:x:1000:1000::/home/sbuser:/bin/bash' > "$PW"
	[ "${1-}" != sealed ] || printf '%s\n' 'sealed:x:1001:1001::/root:/bin/bash' >> "$PW"
}
users
printf '%s\n' 'passwd: files' 'group: files' 'shadow: files' > "$T/nsswitch"
mount --bind "$PW" /etc/passwd && mount --bind "$T/nsswitch" /etc/nsswitch.conf || stop "its own passwd"
[ "$(getent passwd | cut -d: -f1 | paste -sd,)" = root,sbuser ] || stop "only its own users" "$(getent passwd)"
# The top mount on each (the last listed; /run may be a tmpfs of the machine's below it) is ours.
for d in /opt /usr/local/bin /etc/systemd/user /run /home /var/lib/systemd/linger; do
	[ "$(findmnt -n -o FSTYPE,SOURCE --mountpoint "$d" | tail -1 | awk '{print $1, $2}')" = "tmpfs asc-install" ] || stop "each folder a tmpfs of its own before install.sh runs" "$d: $(findmnt -n -o FSTYPE,SOURCE --mountpoint "$d")"
done

P=/opt/agent-session-control UD=/etc/systemd/user BIN=/usr/local/bin/asctl
MARK=$P/.asctl-install LOCK=/run/agent-session-control-install.lock
UNITS="asctl-boot.service asctl-dash.service asctl-dash.socket asctl-tmux.service asctl-watch.service asctl-watch.timer"
HELD=()

# --- helpers (no check in them: tests/checklint.py)
# Back to nothing installed: the folders empty, no process of a test left.
fresh() {
	local p
	for p in ${HELD[@]+"${HELD[@]}"}; do { kill -9 "$p"; wait "$p"; } 2>/dev/null; done
	HELD=()
	find /opt /usr/local/bin /etc/systemd/user /run /var/lib/systemd/linger /home -mindepth 1 -delete
	mkdir -m 755 /home/sbuser
	users
}
# co NAME: a checkout to install from, $T/src/NAME, a copy of this one's; the caller changes it.
co() { rm -rf "$T/src/$1"; cp -a "$T/repo" "$T/src/$1"; }
# inst NAME [ARG...]: install.sh of that checkout; its output in out, its exit in rc.
inst() { out=$("$T/src/$1/install.sh" "${@:2}" 2>&1); rc=$?; }
has() { grep -q -- "$1" <<< "$out"; }
# What install.sh leaves: every path (kind, mode, link target) and each file's sha256, but only
# the names of compiled files (they hold the time their source was copied).
snap() {
	find /opt /etc/systemd/user /usr/local/bin -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort
	find /opt /etc/systemd/user /usr/local/bin -type f ! -path '*/__pycache__/*' -exec sha256sum {} + | LC_ALL=C sort -k2
}
# Nothing at all in the folders it writes.
empty() { [ -z "$(find /opt /etc/systemd/user /usr/local/bin -mindepth 1 -print -quit)" ]; }
rel() { readlink "$P/current"; }
# A process with a release's asctl-wrap as its first argument, as a session's wrapper has.
hold() { (exec -a "$P/releases/$1/bin/asctl-wrap" sleep 600) </dev/null >/dev/null 2>&1 & HELD+=($!); }
# save NAME / back NAME: the folders install.sh writes, kept and put back (tar keeps modes and links).
save() { tar -C / -cf "$T/save/$1.tar" opt etc/systemd/user usr/local/bin; }
back() { find /opt /etc/systemd/user /usr/local/bin /run -mindepth 1 -delete; tar -C / -xpf "$T/save/$1.tar"; }

# The shims: mv, rm, ln, mktemp and sync first on PATH, each a call counted and logged to
# $T/shim/log; at call SHIM_AT, the installer's whole process group is killed (SIGKILL), as a
# kill comes: between two steps. SHIM_PARTIAL=1: a kill inside a delete instead (an rm's last
# argument, a folder: its marker, or else its first file, deleted first).
for c in mv rm ln mktemp sync; do
	real=$(command -v "$c") && [ -x "$real" ] || stop "the real mv, rm, ln, mktemp and sync"
	cat > "$T/shim/$c" <<EOF || stop "the shims"
#!/bin/bash
n=\$((\$(cat "$T/shim/n") + 1)); echo "\$n" > "$T/shim/n"
{ printf '%s %s' "\$n" "$c"; printf ' %s' "\$@"; echo; } >> "$T/shim/log"
if [ "\$n" = "\${SHIM_AT:-0}" ]; then
	if [ "\${SHIM_PARTIAL-}" = 1 ]; then
		for a; do t=\$a; done
		if [ -d "\$t" ] && ! [ -L "\$t" ]; then
			if [ -f "\$t/.asctl-install" ]; then f=\$t/.asctl-install; else f=\$(find "\$t" -type f | LC_ALL=C sort | head -1); fi
			[ -z "\$f" ] || $(command -v rm) -f -- "\$f"
		fi
	fi
	kill -9 -- "-\$SHIM_PG"
	sleep 10
fi
exec "$real" "\$@"
EOF
	chmod 755 "$T/shim/$c"
done
# shimmed NAME [ARG...]: install.sh of that checkout in a session (its own process group) with
# the shims; SHIM_AT and SHIM_PARTIAL from the caller. Exit and output as inst's; calls in
# $T/shim/n.
shimmed() {
	echo 0 > "$T/shim/n"; : > "$T/shim/log"
	# setsid without -w: called from a process that leads no group, it does not fork, so the
	# installer is this process, its group its own, and a kill's exit (137) is seen as it is
	out=$(SHIM_AT=${SHIM_AT:-0} SHIM_PARTIAL=${SHIM_PARTIAL-} setsid bash -c 'SHIM_PG=$$ PATH="$0:$PATH" exec "$@"' "$T/shim" "$T/src/$1/install.sh" "${@:2}" 2>&1); rc=$?
}

# sweep SETUP RUN AFTER...: the kill at each step. SETUP brings the state a run starts from
# (saved once, as "s0"). RUN is the run killed: "install NAME" or "uninstall NAME". First it runs
# whole (the reference: its calls counted, its end state saved as "ref"); then for each call k:
# from s0, killed at call k (it must end by that kill), the state saved as "killed", and each
# AFTER run from there. An AFTER is a function: it returns 0 when right, else prints why.
# SWEEP_PARTIAL=1: only the calls that are an rm of a folder, each killed inside its delete.
# Prints "<calls> <kills>" and, for each k that went wrong, "k=<k> (<call>): <why>".
sweep() {
	local setup=$1 run=$2 k n calls=() a why kills=0 rest
	shift 2
	fresh; $setup; save s0
	SHIM_AT=0 SHIM_PARTIAL='' shimmed_run "$run"
	[ "$rc" = 0 ] || { echo "0 0"; echo "the whole run: exit $rc: $out"; return; }
	save ref; n=$(cat "$T/shim/n")
	mapfile -t calls < "$T/shim/log"
	# A kill after the marker's last rename comes once that run is done but for deleting old
	# releases: the next run is a second one, and ends as an unbroken run and a rerun do ("ref2").
	fin=$(grep -n " mv -f [^ ]*/\.mark\.[^ ]* $MARK\$" "$T/shim/log" | tail -1 | cut -d: -f1)
	SHIM_AT=0 shimmed_run "$run"; save ref2
	rest=()
	for ((k = 1; k <= n; k++)); do
		KAFTER=0; [ -z "$fin" ] || [ "$k" -le "$fin" ] || KAFTER=1
		if [ "${SWEEP_PARTIAL-}" = 1 ]; then [[ ${calls[k - 1]} =~ ^[0-9]+\ rm\ -rf ]] || continue; fi
		back s0
		SHIM_AT=$k SHIM_PARTIAL=${SWEEP_PARTIAL-} shimmed_run "$run"
		[ "$rc" = 137 ] || { rest+=("k=$k (${calls[k - 1]}): the killed run ended with exit $rc, not the kill: $out"); continue; }
		kills=$((kills + 1))
		save killed
		for a; do
			back killed
			why=$($a 2>&1) || rest+=("k=$k (${calls[k - 1]}): $a: ${why:-wrong}")
		done
	done
	echo "$n $kills"
	printf '%s\n' ${rest[@]+"${rest[@]}"}
}
shimmed_run() {
	case $1 in
	install\ *) shimmed "${1#install }" ;;
	uninstall\ *) shimmed "${1#uninstall }" --uninstall ;;
	esac
}
# The AFTERs. Each prints what it saw when wrong.
same_as_ref() {
	local a b want=ref
	[ "$KAFTER" = 0 ] || want=ref2
	a=$(snap); back "$want"; b=$(snap)
	[ "$a" = "$b" ] || { echo "not as $want:"; diff <(echo "$b") <(echo "$a") | head -8; return 1; }
}
rerun_a() { inst a; [ "$rc" = 0 ] || { echo "exit $rc: $out"; return 1; }; }
rerun_c() { inst c; [ "$rc" = 0 ] || { echo "exit $rc: $out"; return 1; }; }
after_install_a() { rerun_a && same_as_ref; }
after_upgrade_c() { rerun_c && same_as_ref; }
after_back_to_b() { inst b; [ "$rc" = 0 ] || { echo "exit $rc: $out"; return 1; }; }
after_uninstall() {
	inst a --uninstall
	[ "$rc" = 0 ] || { echo "exit $rc: $out"; return 1; }
	empty || { find /opt /etc/systemd/user /usr/local/bin -mindepth 1 | head -8; return 1; }
}
setup_none() { :; }
setup_ab() { inst a >/dev/null; inst b >/dev/null; }
setup_a() { inst a >/dev/null; }
# The checkouts: a (this one), b (a code change and a unit's text changed), c (both again).
co a
co b; echo '# b' >> "$T/src/b/asc/events.py"; echo '# b' >> "$T/src/b/systemd/asctl-watch.timer"
co c; echo '# c' >> "$T/src/c/asc/events.py"; echo '# c' >> "$T/src/c/systemd/asctl-watch.timer"
V=$(cat "$T/src/a/asc/VERSION")
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || stop "setup: asc/VERSION is N.N.N" "$V"

case_fresh() {
echo "== install, again, uninstall"
fresh
inst a
R=$(rel)
[ "$rc" = 0 ] && [[ $R =~ ^releases/[0-9a-f]{12}$ ]] && has "release ${R#releases/} installed in $P" && [ "$(readlink "$BIN")" = "$P/current/bin/asctl" ] \
	&& ok "install: a release, current at it, asctl on PATH" || bad "install: a release, current at it, asctl on PATH" "exit $rc, current $R: $out"
u=0; for f in $UNITS; do [ "$(cat "$UD/$f")" = "$(sed "s|@ASCTL@|$P/current/bin/asctl|g" "$T/src/a/systemd/$f")" ] && u=$((u + 1)); done
[ "$u" = 6 ] && grep -qx "ExecStart=$P/current/bin/asctl tmux-server" "$UD/asctl-tmux.service" && ! grep -rq '@ASCTL@' "$UD" && [ -z "$(find "$UD" -mindepth 1 ! -name 'asctl-*')" ] && ok "each unit in /etc/systemd/user, with the installed path in it" || bad "each unit in /etc/systemd/user, with the installed path in it" "$u of 6: $(ls -a "$UD")"
[ "$(head -2 "$MARK")" = "agent-session-control install 1"$'\n'"release ${R#releases/}" ] && [ "$(grep -c '^unit /etc/systemd/user/asctl-[a-z]*\.[a-z]* [0-9a-f]\{64\}$' "$MARK")" = 6 ] \
	&& ok "the marker: its release and each unit's sha256" || bad "the marker: its release and each unit's sha256" "$(cat "$MARK")"
[ -z "$(find /opt /etc/systemd/user /usr/local/bin ! -type l -perm /022)" ] && [ -z "$(find "$P/$R" -type f -perm /111 ! -path "*/bin/*")" ] && [ -n "$(find "$P/$R/asc/__pycache__" -name 'cli.*.pyc')" ] \
	&& ok "nothing writable by others, only bin/ runs, compiled" || bad "nothing writable by others, only bin/ runs, compiled" "$(find /opt /etc/systemd/user /usr/local/bin ! -type l -perm /022 | head -3)"
[ -z "$(find /opt /etc/systemd/user /usr/local/bin -mindepth 1 \( -name '.*' ! -name .asctl-install -o -name '*.new-*' -o -name '*.stage-*' \))" ] \
	&& ok "nothing else left: no staging folder, temp file or link" || bad "nothing else left: no staging folder, temp file or link" "$(find /opt /etc/systemd/user /usr/local/bin -mindepth 1 -name '.*')"
grep -q '^usage: asctl' <<< "$("$BIN" --help 2>&1)" && ok "asctl on PATH runs from the release" || bad "asctl on PATH runs from the release" "$("$BIN" --help 2>&1 | head -3)"
grep -qx "asctl $V: $BIN" <<< "$out" && ! has "^version " && ok "install: says the version it installed" || bad "install: says the version it installed" "$out"
[ "$("$BIN" --version 2>&1)" = "asctl $V (release ${R#releases/})" ] && ok "asctl --version: the version and its release" || bad "asctl --version: the version and its release" "$("$BIN" --version 2>&1)"
S1=$(snap)
inst a
[ "$rc" = 0 ] && has "release ${R#releases/}: installed already" && ! has "^wrote" && [ "$(snap)" = "$S1" ] \
	&& ok "install again: installed already, nothing written or changed" || bad "install again: installed already, nothing written or changed" "exit $rc: $out"
! has "^version " && ok "install again: no version change said" || bad "install again: no version change said" "$out"
inst a --uninstall
[ "$rc" = 0 ] && empty && has "removed $P" && ok "uninstall: nothing left" || bad "uninstall: nothing left" "exit $rc: $out; $(find /opt /etc/systemd/user /usr/local/bin -mindepth 1 | head)"
inst a --uninstall
[ "$rc" = 0 ] && has "not installed: nothing to do" && ok "uninstall again: nothing to do" || bad "uninstall again: nothing to do" "exit $rc: $out"
inst a --bogus
[ "$rc" = 2 ] && has "usage: sudo ./install.sh" && empty && ok "an unknown option: usage, nothing done" || bad "an unknown option: usage, nothing done" "exit $rc: $out"
}

case_upgrade() {
echo "== upgrades, switching back, units dropped and added"
fresh
inst a; RA=$(rel)
inst b; RB=$(rel)
[ "$rc" = 0 ] && [ "$RB" != "$RA" ] && has "installed in $P (was ${RA#releases/})" && [ -d "$P/$RA" ] && has "^wrote $UD/asctl-watch.timer$" && [ "$(printf '%s\n' "$out" | grep -c '^wrote')" = 1 ] \
	&& ok "upgrade: current switched, the release before kept, only the changed unit written" || bad "upgrade: current switched, the release before kept, only the changed unit written" "exit $rc: $out"
grep -qx '# b' "$UD/asctl-watch.timer" && grep -qF "unit $UD/asctl-watch.timer $(sha256sum < "$UD/asctl-watch.timer" | cut -d' ' -f1)" "$MARK" && grep -qx "release ${RB#releases/}" "$MARK" \
	&& ok "the marker has the new release and the unit's new sha256" || bad "the marker has the new release and the unit's new sha256" "$(cat "$MARK")"
hold "${RA#releases/}"
inst c; RC=$(rel)
[ "$rc" = 0 ] && [ -d "$P/$RA" ] && [ -d "$P/$RB" ] && [ -d "$P/$RC" ] && ok "an older release a process runs is kept" || bad "an older release a process runs is kept" "exit $rc: $(ls "$P/releases")"
kill -9 "${HELD[0]}"; wait "${HELD[0]}" 2>/dev/null; HELD=()
inst c
[ "$rc" = 0 ] && ! [ -e "$P/$RA" ] && ! [ -e "$P/$RB" ] && [ -d "$P/$RC" ] && [ -z "$(find "$P/releases" -mindepth 1 -maxdepth 1 -name '.*')" ] \
	&& ok "once nothing runs them, the others go (this one stays); nothing left of them" || bad "once nothing runs them, the others go (this one stays); nothing left of them" "exit $rc: $(ls -a "$P/releases")"
inst b; RB2=$(rel)
inst a; inst b
[ "$rc" = 0 ] && [ "$(rel)" = "$RB2" ] && has "switched back to it" && grep -qx '# b' "$UD/asctl-watch.timer" \
	&& ok "switching back to a release still there: it is used again, its units written" || bad "switching back to a release still there: it is used again, its units written" "exit $rc: $out"
fresh
inst a
co d; rm "$T/src/d/systemd/asctl-watch.timer" "$T/src/d/systemd/asctl-boot.service"
# a release that drops units drops them from install.sh's list too
sed -i 's/^for u in asctl-boot.service \(.*\) asctl-watch.timer; do$/for u in \1; do/' "$T/src/d/install.sh"
grep -qx 'for u in asctl-dash.service asctl-dash.socket asctl-tmux.service asctl-watch.service; do' "$T/src/d/install.sh" || stop "setup: a release without two units"
echo '# kept' >> "$UD/asctl-boot.service"
inst d
[ "$rc" = 0 ] && ! [ -e "$UD/asctl-watch.timer" ] && has "^wrote $UD/asctl-watch.timer (removed)$" && grep -qx '# kept' "$UD/asctl-boot.service" && ! grep -q 'asctl-watch.timer\|asctl-boot.service' "$MARK" \
	&& ok "a unit the new release drops: removed when unchanged, kept when changed; neither in the marker" || bad "a unit the new release drops: removed when unchanged, kept when changed; neither in the marker" "exit $rc: $out; $(ls "$UD")"
fresh
inst a
co e; cp "$T/src/e/systemd/asctl-watch.service" "$T/src/e/systemd/asctl-extra.service"
inst e
[ "$rc" = 0 ] && [ -f "$UD/asctl-extra.service" ] && grep -qF "unit $UD/asctl-extra.service " "$MARK" && ok "a unit the new release adds: written and in the marker" || bad "a unit the new release adds: written and in the marker" "exit $rc: $out"
inst e --uninstall
[ "$rc" = 0 ] && empty && ok "uninstall removes it too" || bad "uninstall removes it too" "exit $rc: $out"
# An upgrade to c killed once current points at it (at the marker's first rename), then another
# checkout installed: the release current pointed at (c) and the marker's (b) both stay.
fresh; inst a; RA=$(rel); inst b; RB=$(rel)
SHIM_AT=0 shimmed c
k=$(grep -m1 " mv -f [^ ]*/\.mark\.[^ ]* $MARK\$" "$T/shim/log" | cut -d' ' -f1)
fresh; inst a; inst b
SHIM_AT=${k:-0} shimmed c; krc=$rc; RC=$(rel)
co g; echo '# g' >> "$T/src/g/asc/events.py"
inst g
[ -n "$k" ] && [ "$krc" = 137 ] && [ "$RC" != "$RB" ] && [ "$rc" = 0 ] && [ -d "$P/$RB" ] && [ -d "$P/$RC" ] && ! [ -e "$P/$RA" ] \
	&& ok "an upgrade killed, then another: the one current pointed at and the marker's kept, older ones go" || bad "an upgrade killed, then another: the one current pointed at and the marker's kept, older ones go" "kill at ${k:-none} (exit $krc), current then $RC; exit $rc: $out; $(ls "$P/releases")"
}

case_versions() {
echo "== the version before and after: newer, older, the same, none"
fresh
inst a
co h; printf '99.0.0\n' > "$T/src/h/asc/VERSION"
inst h
[ "$rc" = 0 ] && grep -qx "version $V -> 99.0.0" <<< "$out" && ok "a newer version: said, before and after" || bad "a newer version: said, before and after" "exit $rc: $out"
inst a
[ "$rc" = 0 ] && grep -qx "version 99.0.0 -> $V: an older version" <<< "$out" && ok "an older version: installed, said to be older" || bad "an older version: installed, said to be older" "exit $rc: $out"
inst b
[ "$rc" = 0 ] && grep -qx "version $V, as before (other code)" <<< "$out" && ok "the same version, other code: said" || bad "the same version, other code: said" "exit $rc: $out"
# a release from before versions (no asc/VERSION): its version unknown
rm "$P/$(rel)/asc/VERSION"
inst a
[ "$rc" = 0 ] && grep -qx "version unknown -> $V" <<< "$out" && ok "from a release before versions: unknown, then this one" || bad "from a release before versions: unknown, then this one" "exit $rc: $out"
}

case_refuse() {
echo "== refusals: each leaves everything as it was"
fresh
inst a; S1=$(snap)
flock "$LOCK" sleep 600 & HELD+=($!)
poll_gone 5 flock -n "$LOCK" true || stop "another holder of the lock"
inst a
[ "$rc" = 1 ] && has "another install.sh is running" && [ "$(snap)" = "$S1" ] && ok "another install.sh running: refused" || bad "another install.sh running: refused" "exit $rc: $out"
fresh
mkdir -p "$T/notmux"; cp -s /usr/bin/* "$T/notmux/" 2>/dev/null; rm -f "$T/notmux/tmux"
out=$(PATH="$T/notmux" "$T/src/a/install.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && has "tmux is not installed" && empty && ok "a command it needs missing: refused" || bad "a command it needs missing: refused" "exit $rc: $out"
mkdir -p "$T/oldpy"
printf '#!/bin/bash\ncase $* in *version_info*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$T/oldpy/python3"; chmod 755 "$T/oldpy/python3"
out=$(PATH="$T/oldpy:$PATH" "$T/src/a/install.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && has "python3 is older than 3.9" && empty && ok "python3 older than 3.9: refused" || bad "python3 older than 3.9: refused" "exit $rc: $out"
mkdir "$P"
inst a
[ "$rc" = 1 ] && has "is there but not this installer's" && [ -z "$(find "$P" -mindepth 1)" ] && [ -z "$(find "$UD" "${BIN%/*}" -mindepth 1)" ] \
	&& ok "its folder there without the marker: refused" || bad "its folder there without the marker: refused" "exit $rc: $out"
fresh; mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$P"
inst a
[ "$rc" = 1 ] && has "is there but not this installer's" && [ -z "$(find "$T/elsewhere" -mindepth 1)" ] && ok "its folder a link: refused" || bad "its folder a link: refused" "exit $rc: $out"
rm "$P"; rmdir "$T/elsewhere"
inst a; chmod 777 "$P"; S1=$(snap)
inst a
[ "$rc" = 1 ] && has "is there but not this installer's" && [ "$(snap)" = "$S1" ] && ok "its folder writable by others: refused" || bad "its folder writable by others: refused" "exit $rc: $out"
fresh; echo '#!/bin/sh' > "$BIN"
inst a
[ "$rc" = 1 ] && has "not this installer's link" && ! [ -e "$P" ] && [ "$(find "$UD" -mindepth 1)" = "" ] && ok "an /usr/local/bin/asctl not its link: refused" || bad "an /usr/local/bin/asctl not its link: refused" "exit $rc: $out"
fresh; mkdir "$UD/asctl-dash.service"
inst a
[ "$rc" = 1 ] && has "asctl-dash.service is not a plain file" && ! [ -e "$P" ] && ok "a unit path that is a folder: refused" || bad "a unit path that is a folder: refused" "exit $rc: $out"
fresh; echo '# mine' > "$UD/asctl-boot.service"
inst a
[ "$rc" = 1 ] && [ "$out" = "install.sh: $UD/asctl-boot.service is there and not written by this installer: left as it is" ] && ! [ -e "$P" ] && [ "$(cat "$UD/asctl-boot.service")" = '# mine' ] \
	&& ok "a unit file it did not write: refused, left" || bad "a unit file it did not write: refused, left" "exit $rc: $out"
fresh; inst a
echo '# an edit' >> "$UD/asctl-watch.timer"; S1=$(snap)
inst a
[ "$rc" = 1 ] && has "changed since the last install" && [ "$(snap)" = "$S1" ] && ok "a unit file changed since: refused" || bad "a unit file changed since: refused" "exit $rc: $out"
inst a --force
[ "$rc" = 0 ] && ! grep -q 'an edit' "$UD/asctl-watch.timer" && has "^wrote $UD/asctl-watch.timer$" && ok "--force puts it back" || bad "--force puts it back" "exit $rc: $out"
fresh
co l; ln -s /etc/passwd "$T/src/l/asc/web/x.js"
inst l
[ "$rc" = 1 ] && has "asc/web/x.js is a symbolic link" && empty && ok "a link in the checkout: refused" || bad "a link in the checkout: refused" "exit $rc: $out"
co o; : > "$T/src/o/asc/a b.py"
inst o
[ "$rc" = 1 ] && has "an odd file name" && empty && ok "an odd file name in the checkout: refused" || bad "an odd file name in the checkout: refused" "exit $rc: $out"
co f; mkfifo "$T/src/f/asc/pipe"
inst f
[ "$rc" = 1 ] && has "asc/pipe is not a plain file" && empty && ok "a fifo in the checkout: refused" || bad "a fifo in the checkout: refused" "exit $rc: $out"
co w; rm "$T/src/w/bin/asctl-wrap"
inst w
[ "$rc" = 1 ] && has "is not a checkout of agent-session-control" && empty && ok "not a checkout (bin/asctl-wrap missing): refused" || bad "not a checkout (bin/asctl-wrap missing): refused" "exit $rc: $out"
co u; rm "$T/src/u/systemd/asctl-watch.service"
inst u
[ "$rc" = 1 ] && has "systemd/asctl-watch.service is missing: not a whole release" && empty && ok "a unit file missing: refused" || bad "a unit file missing: refused" "exit $rc: $out"
co v; rm "$T/src/v/asc/VERSION"
inst v
[ "$rc" = 1 ] && has "asc/VERSION is missing or not N.N.N" && empty && ok "asc/VERSION missing: refused" || bad "asc/VERSION missing: refused" "exit $rc: $out"
co v; printf '1.1\n' > "$T/src/v/asc/VERSION"
inst v
[ "$rc" = 1 ] && has "asc/VERSION is missing or not N.N.N" && empty && ok "asc/VERSION not N.N.N: refused" || bad "asc/VERSION not N.N.N: refused" "exit $rc: $out"
co s; printf 'def broken(:\n' > "$T/src/s/asc/broken.py"
inst s
[ "$rc" = 1 ] && has "does not compile" && empty && [ -z "$(find /opt -mindepth 1)" ] && ok "code that does not compile: refused" || bad "code that does not compile: refused" "exit $rc: $out"
co i; sed -i '1i import asc_no_such_module' "$T/src/i/asc/cli.py"
inst a; S1=$(snap)
inst i
[ "$rc" = 1 ] && has "does not start" && has "asc_no_such_module" && [ "$(snap)" = "$S1" ] && ok "code that compiles but does not start: refused, nothing changed" || bad "code that compiles but does not start: refused, nothing changed" "exit $rc: $out"
fresh; inst a
R=$(rel); echo '# changed' >> "$P/$R/asc/events.py"; S1=$(snap)
inst a
[ "$rc" = 1 ] && has "${R#releases/} has changed since it was installed" && [ "$(snap)" = "$S1" ] && ok "a release there that is no longer what it was: refused, left" || bad "a release there that is no longer what it was: refused, left" "exit $rc: $out"
fresh; inst a
R=$(rel); ln -s /etc/passwd "$P/$R/asc/web/x.js"; S1=$(snap)
inst a
[ "$rc" = 1 ] && has "${R#releases/} has changed since it was installed" && [ "$(snap)" = "$S1" ] && ok "a link put in it: refused, left" || bad "a link put in it: refused, left" "exit $rc: $out"
fresh
co m; printf '%s\n' 'open("/run/main-ran", "w").close()' > "$T/src/m/asc/__main__.py"
inst m
[ "$rc" = 0 ] && ! [ -e /run/main-ran ] && ok "an asc/__main__.py is not run when the code is tried" || bad "an asc/__main__.py is not run when the code is tried" "exit $rc: $out"
}

case_uninstall() {
echo "== uninstall: who and what stops it, what it keeps"
fresh; mkdir "$P"
inst a --uninstall
[ "$rc" = 1 ] && has "is not this installer's" && [ -d "$P" ] && ok "uninstall: a folder without the marker is left" || bad "uninstall: a folder without the marker is left" "exit $rc: $out"
fresh; inst a
mkdir -p /home/sbuser/.config/systemd/user/default.target.wants
ln -s "$UD/asctl-tmux.service" /home/sbuser/.config/systemd/user/default.target.wants/asctl-tmux.service
S1=$(snap)
inst a --uninstall
[ "$rc" = 1 ] && has "asctl is set up for: sbuser" && [ "$(snap)" = "$S1" ] && ok "uninstall while a user has its units enabled: refused, the user named" || bad "uninstall while a user has its units enabled: refused, the user named" "exit $rc: $out"
rm -r /home/sbuser/.config
mkdir "$UD/default.target.wants"; ln -s ../asctl-tmux.service "$UD/default.target.wants/asctl-tmux.service"
inst a --uninstall
[ "$rc" = 1 ] && has "every user" && [ -d "$P" ] && ok "enabled for every user: refused" || bad "enabled for every user: refused" "exit $rc: $out"
rm -r "$UD/default.target.wants"
users sealed
[ -e /root ] && ! [ -r /root ] || stop "a home it cannot read (/root as seen from here)"
inst a --uninstall
[ "$rc" = 1 ] && has "cannot read the homes of: sealed" && [ -d "$P" ] && ok "a home it cannot read: refused" || bad "a home it cannot read: refused" "exit $rc: $out"
users
R=$(rel); hold "${R#releases/}"
inst a --uninstall
[ "$rc" = 1 ] && has "processes still run its code" && [ -d "$P" ] && ok "a process runs its code: refused" || bad "a process runs its code: refused" "exit $rc: $out"
echo '# mine now' >> "$UD/asctl-dash.socket"
inst a --uninstall --force
[ "$rc" = 0 ] && ! [ -e "$P" ] && ! [ -L "$BIN" ] && has "kept $UD/asctl-dash.socket: changed since the install" && [ "$(find "$UD" -mindepth 1)" = "$UD/asctl-dash.socket" ] \
	&& ok "--force: removed, but a unit changed since is kept" || bad "--force: removed, but a unit changed since is kept" "exit $rc: $out"
}

case_kill_install() {
echo "== a fresh install killed at each step"
fresh
r=$(sweep setup_none "install a" after_install_a after_uninstall)
read -r n k <<< "$(head -1 <<< "$r")"
[ "${n:-0}" -ge 10 ] && [ "$k" = "$n" ] && ok "fresh install: killed at each of its steps (the kill seen each time)" || bad "fresh install: killed at each of its steps (the kill seen each time)" "$r"
! grep -q after_install_a <<< "$(tail -n +2 <<< "$r")" && ok "then a plain rerun ends as an install never killed" || bad "then a plain rerun ends as an install never killed" "$(grep after_install_a <<< "$(tail -n +2 <<< "$r")")"
! grep -q after_uninstall <<< "$(tail -n +2 <<< "$r")" && ok "then uninstall leaves nothing" || bad "then uninstall leaves nothing" "$(grep after_uninstall <<< "$(tail -n +2 <<< "$r")")"
}

case_kill_upgrade() {
echo "== an upgrade (a unit changed, an old release pruned) killed at each step"
fresh
r=$(sweep setup_ab "install c" after_upgrade_c after_back_to_b after_uninstall)
read -r n k <<< "$(head -1 <<< "$r")"
[ "${n:-0}" -ge 10 ] && [ "$k" = "$n" ] && ok "upgrade: killed at each of its steps (the kill seen each time)" || bad "upgrade: killed at each of its steps (the kill seen each time)" "$r"
! grep -q after_upgrade_c <<< "$(tail -n +2 <<< "$r")" && ok "then a plain rerun ends as an upgrade never killed" || bad "then a plain rerun ends as an upgrade never killed" "$(grep after_upgrade_c <<< "$(tail -n +2 <<< "$r")")"
! grep -q after_back_to_b <<< "$(tail -n +2 <<< "$r")" && ok "then the release before installs again, no --force" || bad "then the release before installs again, no --force" "$(grep after_back_to_b <<< "$(tail -n +2 <<< "$r")")"
! grep -q after_uninstall <<< "$(tail -n +2 <<< "$r")" && ok "then uninstall leaves nothing (each unit still known)" || bad "then uninstall leaves nothing (each unit still known)" "$(grep after_uninstall <<< "$(tail -n +2 <<< "$r")")"
}

case_kill_uninstall() {
echo "== uninstall killed at each step, and inside its delete"
fresh
r=$(sweep setup_a "uninstall a" after_uninstall)
read -r n k <<< "$(head -1 <<< "$r")"
[ "${n:-0}" -ge 3 ] && [ "$k" = "$n" ] && [ -z "$(tail -n +2 <<< "$r")" ] && ok "uninstall killed at each step: a rerun leaves nothing" || bad "uninstall killed at each step: a rerun leaves nothing" "$r"
r=$(SWEEP_PARTIAL=1 sweep setup_a "uninstall a" after_uninstall)
read -r n k <<< "$(head -1 <<< "$r")"
[ "${k:-0}" -ge 1 ] && [ -z "$(tail -n +2 <<< "$r")" ] && ok "uninstall killed inside its delete (the marker gone first): a rerun leaves nothing" || bad "uninstall killed inside its delete (the marker gone first): a rerun leaves nothing" "$r"
}

case_kill_prune() {
echo "== an old release's delete killed halfway"
fresh
r=$(SWEEP_PARTIAL=1 sweep setup_ab "install c" after_upgrade_c after_back_to_b after_uninstall)
read -r n k <<< "$(head -1 <<< "$r")"
[ "${k:-0}" -ge 1 ] && [ -z "$(tail -n +2 <<< "$r")" ] && ok "upgrade killed inside an old release's delete: rerun, the release before, uninstall all as unbroken" || bad "upgrade killed inside an old release's delete: rerun, the release before, uninstall all as unbroken" "$r"
# The release a, its delete cut short by the upgrade to c, then installed again: whole.
fresh; inst a; RA=$(rel)
WHOLE=$(cd "$P/$RA" && find . -type f ! -path '*/__pycache__/*' -exec sha256sum {} + | LC_ALL=C sort -k2)
inst b
SHIM_AT=0 shimmed c
k=$(grep -m1 "^[0-9]* rm -rf.*${RA#releases/}" "$T/shim/log" | cut -d' ' -f1)
fresh; inst a; inst b
SHIM_AT=${k:-0} SHIM_PARTIAL=1 shimmed c; krc=$rc
inst a
[ -n "$k" ] && [ "$krc" = 137 ] && [ "$rc" = 0 ] && [ "$(rel)" = "$RA" ] && [ "$(cd "$P/$RA" && find . -type f ! -path '*/__pycache__/*' -exec sha256sum {} + | LC_ALL=C sort -k2)" = "$WHOLE" ] \
	&& ok "a release whose delete was cut short installs again whole" || bad "a release whose delete was cut short installs again whole" "kill at call ${k:-none} (exit $krc); exit $rc: $out; $(ls -a "$P/releases")"
}

case_sync() {
echo "== each write on disk before its rename puts it in place"
fresh
SHIM_AT=0 shimmed a
# From the calls in order: each file or folder renamed into place (a temp marker or unit file,
# the staging folder, the new $P; not a link, nor a rename to be deleted) was flushed before,
# a folder with its files; each folder renamed into, flushed after its last such rename.
r=$(awk '
	$2 == "sync" { for (i = 3; i <= NF; i++) if ($i != "--") s[$i] = NR; next }
	$2 == "mv" {
		src = $(NF - 1); dst = $NF
		if (dst ~ /\.gone-[0-9a-f]+$/) next
		if (src ~ /\/\.mark\.|\/\.asctl-new\.|\.stage-[0-9]+$|agent-session-control\.new-[0-9]+$/) {
			n++
			if (!(src in s)) print "not flushed before its rename: " src
			if (src ~ /\.stage-/ && !((src "/asc/cli.py") in s && (src "/asc") in s)) print "its files and folders not flushed: " src
			if (src ~ /\.new-/ && !((src "/.asctl-install") in s)) print "its marker not flushed: " src
		}
		d = dst; sub(/\/[^\/]*$/, "", d); want[d] = NR
	}
	END {
		for (d in want) if (!(d in s) || s[d] < want[d]) print "a folder not flushed after its last rename into it: " d
		print "renames checked: " n + 0
	}' "$T/shim/log")
[ "$rc" = 0 ] && [ "$(grep -c . <<< "$r")" = 1 ] && [ "$(grep -o '[0-9]*$' <<< "$r")" -ge 10 ] \
	&& ok "install: each file flushed to disk before its rename, each folder after" || bad "install: each file flushed to disk before its rename, each folder after" "exit $rc; $r"
}

run_cases install fresh upgrade versions refuse uninstall kill_install kill_upgrade kill_uninstall kill_prune sync

echo "install: $pass passed, $fail failed"
[ "$fail" = 0 ]
