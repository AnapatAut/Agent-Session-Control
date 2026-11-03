#!/usr/bin/env bash
# Machine install of Agent-Session-Control, run as root from a checkout of it:
#   sudo ./install.sh                      install, or upgrade to this checkout
#   sudo ./install.sh --uninstall          remove it (refused while a user has its units enabled,
#                                          or a process runs its code)
#   --force                                install: replace unit files changed since the last one;
#                                          uninstall: go ahead despite running processes, or homes
#                                          it cannot read
# The code goes in /opt/agent-session-control/releases/<id>, root's and read-only to users (<id>
# comes from the content, so the same code is the same release). `current` points at the
# release and is switched by one rename; /usr/local/bin/asctl points at current/bin/asctl. The
# units go in /etc/systemd/user with that path in them, enabled for no one: each user who wants
# asctl runs `asctl setup` (asc/setup.py). A running asctl keeps the release it started from
# (bin/asctl follows the links), so an upgrade never mixes two; this release and the one current
# pointed at before the run stay, other ones go once no process runs them.
# It refuses, changing nothing, when a path it would write is not its own: a folder there
# without its marker, an /usr/local/bin/asctl that is not its link, a unit file it did not
# write; or when a source file is a link or an odd name. Every write is a rename into place.
# The whole script is one { … } group, so bash has read all of it before it runs any of it: an
# edit of the file while it runs changes nothing.
{
set -euo pipefail
umask 022
export LC_ALL=C
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
P=/opt/agent-session-control BIN=/usr/local/bin/asctl UD=/etc/systemd/user
MARK="$P/.asctl-install" ASCTL="$P/current/bin/asctl"
uninstall=0 force=0
for a in "$@"; do
	case $a in
	--uninstall) uninstall=1 ;;
	--force) force=1 ;;
	*) echo "usage: sudo ./install.sh [--uninstall] [--force]" >&2; exit 2 ;;
	esac
done
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run it as root: sudo ./install.sh"
# In /run, which only root writes (a lock in the world-writable /run/lock could be a planted link).
exec 9> /run/agent-session-control-install.lock || die "cannot open its lock file"
flock -n 9 || die "another install.sh is running"

# The marker: "release <id>" and one "unit <path> <sha256>" line per unit file written.
marked() { [ -f "$MARK" ] && ! [ -L "$MARK" ] && head -1 "$MARK" | grep -qx 'agent-session-control install 1'; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
recorded_sha() { awk -v p="$1" '$1 == "unit" && $2 == p {print $3}' "$MARK" 2>/dev/null; }
# PIDs with an argument in a release folder (bin/asctl passes python its folder; asctl-wrap runs
# from it), $1 an extended regex of the folder. Each argument is a line (-z); a folder name
# must end the argument or be followed by "/", so this grep's own argument (the regex) never
# matches itself.
users_of() { grep -lzE -- "^(.*/)?${1#/}(/.*)?\$" /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3 || true; }
STAGE=/opt/.agent-session-control.stage-
# Left by a run that was killed: its staging folder, a half-made $P, temp links and markers
# (under the lock, so no other run's).
clean_stale() {
	local d
	for d in "$STAGE"* "$P.new-"* "$P/releases/.new-"* "$P/.current-"* "$P/.mark."*; do
		if [ -e "$d" ] || [ -L "$d" ]; then rm -rf --one-file-system -- "$d"; fi
	done
}
ours_dir() {
	[ -d "$P" ] && ! [ -L "$P" ] && [ "$(stat -c %u "$P")" = 0 ] && [ $(( 0$(stat -c %a "$P") & 022 )) = 0 ] && marked
}

if [ "$uninstall" = 1 ]; then
	[ -e "$P" ] || [ -L "$P" ] || { echo "not installed: nothing to do"; exit 0; }
	ours_dir || die "$P is not this installer's (no marker, or not root's): left as it is"
	# Users whose units are enabled (asctl setup): their enable links lead into $UD (often through
	# /etc/xdg/systemd/user, a link to it). A user's own units (tools/install-units.sh, in their
	# home) are theirs and do not count.
	# The homes: every user getent lists, every lingering user (a directory service may not list
	# its users), and every folder in /home.
	users=() unread=()
	while IFS=: read -r name home; do
		[ -n "$home" ] || continue
		[ -d "$home/.config/systemd/user" ] || { [ -e "$home" ] && ! [ -r "$home" ] && unread+=("$name"); continue; }
		for l in "$home"/.config/systemd/user/*.wants/asctl-*; do
			[ -L "$l" ] && case $(readlink -f "$l") in "$UD"/*) users+=("$name"); break ;; esac
		done
	done < <({ getent passwd | cut -d: -f1,6
		for n in /var/lib/systemd/linger/*; do [ -e "$n" ] && getent passwd "${n##*/}" | cut -d: -f1,6; done
		for h in /home/*/; do [ -d "$h" ] && echo "${h%/}:${h%/}" | sed 's|^/home/||'; done; } | sort -t: -k2,2 -u)
	for l in "$UD"/*.wants/asctl-*; do [ -L "$l" ] && users+=("(every user: $l)") && break; done
	[ ${#users[@]} = 0 ] || die "asctl is set up for: ${users[*]}. Each runs asctl setup --remove first"
	[ ${#unread[@]} = 0 ] || [ "$force" = 1 ] || die "cannot read the homes of: ${unread[*]} (--force removes it anyway)"
	pids=$(users_of "$P/releases/[0-9a-f]{12}")
	[ -z "$pids" ] || [ "$force" = 1 ] || die "processes still run its code: $(for p in $pids; do printf '%s (%s) ' "$p" "$(cat "/proc/$p/comm" 2>/dev/null)"; done)(--force removes it anyway)"
	if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$ASCTL" ]; then rm -f "$BIN"; echo "removed $BIN"; fi
	while read -r kind path sum; do
		[ "$kind" = unit ] && [ -f "$path" ] && ! [ -L "$path" ] || continue
		case $path in "$UD"/asctl-*) ;; *) continue ;; esac
		if [ "$(sha "$path")" = "$sum" ]; then rm -f "$path"; echo "removed $path"
		else echo "kept $path: changed since the install"; fi
	done < "$MARK"
	clean_stale
	rm -rf --one-file-system -- "$P"
	echo "removed $P"
	echo "Users' managers still hold the units until their next daemon-reload or login."
	exit 0
fi

# Install. What it needs, then what it would write.
for c in python3 tmux systemctl flock sha256sum; do command -v "$c" >/dev/null || die "$c is not installed"; done
python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "python3 is older than 3.9"
if [ -e "$P" ] || [ -L "$P" ]; then
	ours_dir || die "$P is there but not this installer's (no marker, a link, not root's, or writable by others): left as it is"
fi
if [ -e "$BIN" ] || [ -L "$BIN" ]; then
	[ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$ASCTL" ] || die "$BIN is there and not this installer's link: left as it is"
fi
clean_stale

# The release, staged by root in a folder only root can enter, next to $P (one file system, so
# it moves in by a rename). Copied by a walk through folder handles that refuses a link at any
# level and opens nothing by a path name the checkout's owner could swap underneath it; from here
# on nothing is read from the checkout again.
stage="$STAGE$$"
rm -rf -- "$stage"; mkdir -m 700 "$stage"
trap 'rm -rf -- "$stage"' EXIT
python3 -I - "$REPO" "$stage" <<'PY' || die "the checkout was not copied (above: why)"
import os, re, stat, sys
src, dst = sys.argv[1], sys.argv[2]
NAME = re.compile(r"[A-Za-z0-9._-]+")
DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
def fail(m):
    print(f"install.sh: {m}", file=sys.stderr)
    sys.exit(1)
def walk(dfd, rel):
    for name in sorted(os.listdir(dfd)):
        if name == "__pycache__":
            continue
        p = rel + name
        if not NAME.fullmatch(name):
            fail(f"an odd file name in the checkout: {p!r}")
        st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if stat.S_ISLNK(st.st_mode):
            fail(f"{p} is a symbolic link: refused (it could point anywhere)")
        if stat.S_ISDIR(st.st_mode):
            try:
                fd = os.open(name, DIR, dir_fd=dfd)
            except OSError as x:
                fail(f"{p}: {x.strerror} (changed while it was copied?)")
            try:
                os.mkdir(os.path.join(dst, p), 0o755)
                walk(fd, p + "/")
            finally:
                os.close(fd)
        elif stat.S_ISREG(st.st_mode):
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dfd)
            except OSError as x:
                fail(f"{p}: {x.strerror} (changed while it was copied?)")
            with os.fdopen(fd, "rb") as r:
                if not stat.S_ISREG(os.fstat(r.fileno()).st_mode):
                    fail(f"{p} changed into another kind of file while it was copied")
                with open(os.path.join(dst, p), "xb") as w:
                    while True:
                        b = r.read(1 << 16)
                        if not b:
                            break
                        w.write(b)
        else:
            fail(f"{p} is not a plain file")
try:
    root = os.open(src, DIR)
    for top in ("asc", "bin", "systemd"):
        try:
            fd = os.open(top, DIR, dir_fd=root)
        except OSError as x:
            fail(f"{src}/{top}: {x.strerror} (not a checkout of agent-session-control, or a link)")
        os.mkdir(os.path.join(dst, top), 0o755)
        walk(fd, top + "/")
        os.close(fd)
except OSError as x:
    fail(f"copying {src}: {x}")
PY
cd "$stage"
[ -f bin/asctl ] && [ -f bin/asctl-wrap ] && [ -f asc/cli.py ] && [ -f systemd/asctl-tmux.service ] || die "$REPO is not a checkout of agent-session-control"
find . -type d -exec chmod 755 {} + && find . -type f -exec chmod 644 {} + && chmod 755 bin/*
files=() units=()
while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(find . -type f -print0 | sort -z)
for f in "${files[@]}"; do case $f in systemd/*.service | systemd/*.timer | systemd/*.socket) units+=("${f#systemd/}") ;; esac; done
[ ${#units[@]} -ge 4 ] || die "systemd/ has fewer than the 4 units"
id=$(for f in "${files[@]}"; do printf '%s %s %s\n' "$f" "$(stat -c %a "$f")" "$(sha "$f")"; done | sha256sum | cut -c1-12)
# A unit file there is its own when the marker has it, or when it holds what this run would
# write (a run stopped before it rewrote the marker); changed when it is neither. Rendered from
# the staged copy, never from the checkout.
render() { sed "s|@ASCTL@|$ASCTL|g" "$stage/systemd/$1"; }
changed=()
for u in "${units[@]}"; do
	to="$UD/$u"
	[ -e "$to" ] || [ -L "$to" ] || continue
	[ -f "$to" ] && ! [ -L "$to" ] || die "$to is not a plain file: left as it is"
	[ "$(cat "$to")" = "$(render "$u")" ] && continue
	was=$(recorded_sha "$to")
	[ -n "$was" ] || die "$to is there and not written by this installer: left as it is"
	[ "$(sha "$to")" = "$was" ] || changed+=("$to")
done
[ ${#changed[@]} = 0 ] || [ "$force" = 1 ] || die "changed since the last install (a drop-in in <unit>.d/ keeps a change; --force replaces them): ${changed[*]}"
cd /

# Every check passed: now its folder (made with its marker, put in place by one rename), the
# release, the link, the units, the marker.
if ! [ -e "$P" ]; then
	n="$P.new-$$"
	rm -rf -- "$n"; mkdir -m 755 "$n" "$n/releases"
	printf 'agent-session-control install 1\n' > "$n/.asctl-install"
	mv -T "$n" "$P"
fi
if [ -d "$P/releases/$id" ]; then
	new=0
	rm -rf -- "$stage"
else
	new=1
	python3 -I -m compileall -q -s "$stage" -p "$P/releases/$id" "$stage/asc" >/dev/null || die "the code does not compile with this python3 ($(python3 -V 2>&1))"
	find "$stage/asc" -name __pycache__ -type d -exec chmod 755 {} + && find "$stage/asc" -name '*.pyc' -exec chmod 644 {} +
	chmod 755 "$stage"
	mv -T "$stage" "$P/releases/$id"
fi
trap - EXIT
render() { sed "s|@ASCTL@|$ASCTL|g" "$P/releases/$id/systemd/$1"; }
prev=$(readlink "$P/current" 2>/dev/null || true)
if [ "$prev" != "releases/$id" ]; then
	ln -sfn "releases/$id" "$P/.current-$$"
	mv -T "$P/.current-$$" "$P/current"
fi

# The units, with the installed path in them; then the link on PATH; then the marker.
rec=$(mktemp "$P/.mark.XXXXXX")
printf 'agent-session-control install 1\nrelease %s\n' "$id" > "$rec"
wrote=()
mkdir -p "$UD"  # umask 022: 755
for u in "${units[@]}"; do
	to="$UD/$u" text=$(render "$u")
	if ! [ -f "$to" ] || [ "$(cat "$to")" != "$text" ]; then
		t=$(mktemp "$to.XXXXXX")
		printf '%s\n' "$text" > "$t" && chmod 644 "$t" && mv -f "$t" "$to" || { rm -f "$t"; die "writing $to"; }
		wrote+=("$to")
	fi
	printf 'unit %s %s\n' "$to" "$(sha "$to")" >> "$rec"
done
# Units an earlier release had and this one does not: removed when unchanged.
while read -r kind path sum; do
	[ "$kind" = unit ] || continue
	grep -qF "unit $path " "$rec" && continue
	case $path in "$UD"/asctl-*) ;; *) continue ;; esac
	if [ -f "$path" ] && ! [ -L "$path" ] && [ "$(sha "$path")" = "$sum" ]; then rm -f "$path"; wrote+=("$path (removed)"); fi
done < <(cat "$MARK")
if ! [ -L "$BIN" ]; then
	ln -sfn "$ASCTL" "$BIN.new-$$" && mv -T "$BIN.new-$$" "$BIN"
fi
chmod 644 "$rec" && mv -f "$rec" "$MARK"

# Releases other than this one and the one before it, once nothing runs them.
for d in "$P"/releases/*; do
	r=${d##*/}
	[[ $r =~ ^[0-9a-f]{12}$ ]] && [ -d "$d" ] && ! [ -L "$d" ] || continue
	[ "releases/$r" = "releases/$id" ] || [ "releases/$r" = "$prev" ] && continue
	[ -z "$(users_of "$d")" ] && rm -rf --one-file-system -- "$d"
done

if [ "$prev" = "releases/$id" ]; then echo "release $id: installed already"
elif [ "$new" = 1 ]; then echo "release $id installed in $P${prev:+ (was ${prev#releases/})}"
else echo "release $id: switched back to it${prev:+ (was ${prev#releases/})}"; fi
for w in ${wrote[@]+"${wrote[@]}"}; do echo "wrote $w"; done
echo "asctl: $BIN"
cat <<EOF
Nothing is enabled for anyone. Each user who wants asctl runs, as themselves:
  asctl setup
EOF
[ ${#wrote[@]} = 0 ] || echo "Users who have it set up: systemctl --user daemon-reload (the units changed)."
[ -z "$prev" ] || [ "$prev" = "releases/$id" ] || echo "Running dashboards keep the old code until they next start (after 10 idle minutes)."
exit
}
