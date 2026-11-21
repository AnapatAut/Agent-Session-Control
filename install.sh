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
# (bin/asctl follows the links), so an upgrade never mixes two; this release, the one current
# pointed at before the run and the last one installed to the end (the marker's) stay, other
# ones go once no process runs them.
# It refuses, changing nothing, when a path it would write is not its own: a folder there
# without its marker, an /usr/local/bin/asctl that is not its link, a unit file it did not
# write; or when a source file is a link or an odd name, the code does not compile or start,
# or a release folder it would use again no longer holds what gave it its id. Every write is a
# rename into place, flushed to disk first (sync); every delete of a folder renames it out of
# the way first. So a run killed at any point leaves what the next run (install or uninstall)
# takes as its own: before any unit is written the marker holds each unit's sha256 as it is
# and as it will be, and what a killed run left half made (a staging folder, temp files, a
# folder renamed to be deleted) goes at the start of the next (tests/install.sh kills a run at
# each step).
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

# The marker: "release <id>" (the last install that ran to its end) and a "unit <path> <sha256>"
# line per unit file written; while a run writes the units, two for a unit it changes (as it was
# and as it will be).
marked() { [ -f "$MARK" ] && ! [ -L "$MARK" ] && head -1 "$MARK" | grep -qx 'agent-session-control install 1'; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
# The sha256s the marker has for a unit path, one a line (none: no marker, or not in it).
recorded() { [ -f "$MARK" ] || return 0; awk -v p="$1" '$1 == "unit" && $2 == p {print $3}' "$MARK"; }
# The unit paths in the marker, each once.
marked_units() { [ -f "$MARK" ] || return 0; awk '$1 == "unit" {print $2}' "$MARK" | sort -u; }
# Its own when the file's sha256 is one the marker has for it.
own_unit() { [ -f "$1" ] && ! [ -L "$1" ] && grep -qxF "$(sha "$1")" <<< "$(recorded "$1")"; }
# PIDs with an argument in a release folder (bin/asctl passes python its folder; asctl-wrap runs
# from it), $1 an extended regex of the folder. Each argument is a line (-z); a folder name
# must end the argument or be followed by "/", so this grep's own argument (the regex) never
# matches itself.
users_of() { grep -lzE -- "^(.*/)?${1#/}(/.*)?\$" /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3 || true; }
STAGE=/opt/.agent-session-control.stage-
# Left by a run that was killed: its staging folder, a half-made $P, folders renamed to be
# deleted ($P itself on uninstall, an old release), temp links, markers and unit files (under
# the lock, so no other run's). Each name is one only this script makes; the temp files and
# links go only as files or links, never a folder by that name.
clean_stale() {
	local d
	for d in "$STAGE"* "$P.new-"* "$P.gone-"* "$P/releases/.new-"* "$P/releases/.gone-"*; do
		if [ -e "$d" ] || [ -L "$d" ]; then rm -rf --one-file-system -- "$d"; fi
	done
	for d in "$P/.current-"* "$P/.mark."* "$UD/.asctl-new."* "$BIN.new-"*; do
		if [ -L "$d" ] || [ -f "$d" ]; then rm -f -- "$d"; fi
	done
}
# The id of a release folder's code: each file outside __pycache__ (path, mode, sha256) in
# order, hashed; the same files give the same id. Run in the folder.
content_id() {
	local f
	find . -name __pycache__ -prune -o -type f -print0 | sort -z | while IFS= read -r -d '' f; do
		printf '%s %s %s\n' "${f#./}" "$(stat -c %a "$f")" "$(sha "$f")"
	done | sha256sum | cut -c1-12
}
ours_dir() {
	[ -d "$P" ] && ! [ -L "$P" ] && [ "$(stat -c %u "$P")" = 0 ] && [ $(( 0$(stat -c %a "$P") & 022 )) = 0 ] && marked
}

if [ "$uninstall" = 1 ]; then
	# First what a killed run left (an uninstall killed after it renamed $P leaves only that).
	clean_stale
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
	while read -r path; do
		[ -f "$path" ] && ! [ -L "$path" ] || continue
		case $path in "$UD"/asctl-*) ;; *) continue ;; esac
		if own_unit "$path"; then rm -f "$path"; echo "removed $path"
		else echo "kept $path: changed since the install"; fi
	done < <(marked_units)
	# Renamed out of the way first (one rename: its marker goes with it), then deleted: a kill in
	# the delete leaves no $P without its marker, only $P.gone-<pid> for the next run to delete.
	mv -T "$P" "$P.gone-$$"
	rm -rf --one-file-system -- "$P.gone-$$"
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
id=$(content_id)
# A unit file there is its own when the marker has its sha256 (two while a run that was killed
# had it pending), or when it holds what this run would write; changed when it is neither.
# Rendered from the staged copy, never from the checkout.
render() { sed "s|@ASCTL@|$ASCTL|g" "$stage/systemd/$1"; }
changed=()
for u in "${units[@]}"; do
	to="$UD/$u"
	[ -e "$to" ] || [ -L "$to" ] || continue
	[ -f "$to" ] && ! [ -L "$to" ] || die "$to is not a plain file: left as it is"
	[ "$(cat "$to")" = "$(render "$u")" ] && continue
	[ -n "$(recorded "$to")" ] || die "$to is there and not written by this installer: left as it is"
	own_unit "$to" || changed+=("$to")
done
[ ${#changed[@]} = 0 ] || [ "$force" = 1 ] || die "changed since the last install (a drop-in in <unit>.d/ keeps a change; --force replaces them): ${changed[*]}"
# A release folder there already (installed before, or the one to switch back to) is used again
# only while it holds what gave it its id: plain files and folders, the same files.
R="$P/releases/$id"
if [ -e "$R" ] || [ -L "$R" ]; then
	[ -d "$R" ] && ! [ -L "$R" ] && [ -z "$(find "$R" ! -type f ! -type d -print -quit)" ] && [ "$(cd "$R" && content_id)" = "$id" ] \
		|| die "releases/$id has changed since it was installed (its files no longer give its id): left as it is"
	new=0
else
	new=1
	# Compiled, then each module imported, here in the staging folder before anything is written:
	# code that does not compile or start is refused with nothing changed. The imports write no
	# bytecode (-B) and skip a __main__ (it would run).
	python3 -I -m compileall -q -s "$stage" -p "$R" "$stage/asc" >/dev/null || die "the code does not compile with this python3 ($(python3 -V 2>&1))"
	err=$(cd / && python3 -I -B -c 'import importlib, pkgutil, sys
sys.path.insert(0, sys.argv[1])
for m in pkgutil.iter_modules([sys.argv[1] + "/asc"]):
    if m.name != "__main__":
        importlib.import_module("asc." + m.name)' "$stage" 2>&1) \
		|| die "the code does not start with this python3 ($(python3 -V 2>&1)): $(printf '%s\n' "$err" | tail -1)"
	find "$stage/asc" -name __pycache__ -type d -exec chmod 755 {} + && find "$stage/asc" -name '*.pyc' -exec chmod 644 {} +
	chmod 755 "$stage"
	find "$stage" -exec sync -- {} +  # each file and folder on disk before the rename puts it in place
fi
cd /
# Kept when the old releases go: this one, the one current points at before this run, and the
# one the marker names (the last install that ran to its end: after a killed upgrade current
# may already point at this one, and the release before is still the marker's).
last=''
if [ -f "$MARK" ]; then last=$(awk '$1 == "release" {print $2; exit}' "$MARK"); [[ $last =~ ^[0-9a-f]{12}$ ]] || last=''; fi
prev=$(readlink "$P/current" 2>/dev/null || true)

# Every check passed: now its folder (made with its marker, put in place by one rename), the
# release, current, the marker with the units as they are and will be, the units, the link,
# the marker. Each flushed to disk before its rename, its folder after.
if ! [ -e "$P" ]; then
	n="$P.new-$$"
	rm -rf -- "$n"; mkdir -m 755 "$n" "$n/releases"
	printf 'agent-session-control install 1\n' > "$n/.asctl-install"
	sync -- "$n/.asctl-install" "$n/releases" "$n"
	mv -T "$n" "$P"
	sync -- "${P%/*}"
fi
if [ "$new" = 1 ]; then
	mv -T "$stage" "$R"
	sync -- "$P/releases"
else
	rm -rf -- "$stage"
fi
trap - EXIT
render() { sed "s|@ASCTL@|$ASCTL|g" "$R/systemd/$1"; }
if [ "$prev" != "releases/$id" ]; then
	ln -sfn "releases/$id" "$P/.current-$$"
	mv -T "$P/.current-$$" "$P/current"
	sync -- "$P"
fi
# mark FILE: FILE in place as the marker.
mark() { chmod 644 "$1" && sync -- "$1" && mv -f "$1" "$MARK" && sync -- "$P"; }

# Before a unit is written: the marker with each unit's sha256 as it is (the marker's lines)
# and as this run writes it, so a run killed among the units leaves each its own (for the next
# run, and for an uninstall). Its release line stays the last finished install's.
pend=$(mktemp "$P/.mark.XXXXXX")
{
	printf 'agent-session-control install 1\n'
	[ -z "$last" ] || printf 'release %s\n' "$last"
	{
		grep '^unit ' "$MARK" || true
		for u in "${units[@]}"; do
			printf 'unit %s %s\n' "$UD/$u" "$(printf '%s\n' "$(render "$u")" | sha256sum | cut -d' ' -f1)"
		done
	} | sort -u
} > "$pend"
mark "$pend"

# The units, with the installed path in them; then the link on PATH; then the marker.
rec=$(mktemp "$P/.mark.XXXXXX")
printf 'agent-session-control install 1\nrelease %s\n' "$id" > "$rec"
wrote=()
mkdir -p "$UD"  # umask 022: 755
for u in "${units[@]}"; do
	to="$UD/$u" text=$(render "$u")
	if ! [ -f "$to" ] || [ "$(cat "$to")" != "$text" ]; then
		t=$(mktemp "$UD/.asctl-new.XXXXXX")
		printf '%s\n' "$text" > "$t" && chmod 644 "$t" && sync -- "$t" && mv -f "$t" "$to" || { rm -f "$t"; die "writing $to"; }
		wrote+=("$to")
	fi
	printf 'unit %s %s\n' "$to" "$(sha "$to")" >> "$rec"
done
# Units an earlier release had and this one does not: removed when unchanged (their sha256 one
# the marker has).
while read -r path; do
	grep -qF "unit $path " "$rec" && continue
	case $path in "$UD"/asctl-*) ;; *) continue ;; esac
	if own_unit "$path"; then rm -f "$path"; wrote+=("$path (removed)"); fi
done < <(marked_units)
sync -- "$UD"
if ! [ -L "$BIN" ]; then
	ln -sfn "$ASCTL" "$BIN.new-$$" && mv -T "$BIN.new-$$" "$BIN" && sync -- "${BIN%/*}"
fi
mark "$rec"

# Old releases, once nothing runs them: each renamed out of the way first, then deleted (a kill
# in the delete leaves no half release under its id, only releases/.gone-<id> for the next run).
for d in "$P"/releases/*; do
	r=${d##*/}
	[[ $r =~ ^[0-9a-f]{12}$ ]] && [ -d "$d" ] && ! [ -L "$d" ] || continue
	[ "$r" = "$id" ] || [ "releases/$r" = "$prev" ] || [ "$r" = "$last" ] && continue
	[ -z "$(users_of "$d")" ] || continue
	mv -T "$d" "$P/releases/.gone-$r"
	rm -rf --one-file-system -- "$P/releases/.gone-$r"
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
