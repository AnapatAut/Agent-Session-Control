#!/usr/bin/env bash
# Privacy check: refuse text that names a machine, its users, their sessions or a credential.
#   tools/privacy-check.sh --tree          every tracked file and its name (tests/lint.sh runs this)
#   tools/privacy-check.sh --staged        what `git commit` is about to record (pre-commit hook)
#   tools/privacy-check.sh --msg FILE      a commit message, comment lines too (commit-msg hook)
#   tools/privacy-check.sh --range [--have F] ARGS…  each commit `git log ARGS` lists: names, emails,
#                                          message, file names, added lines (pre-push hook)
#   tools/privacy-check.sh --tag SHA       an annotated tag: tagger and message (pre-push hook)
#   tools/privacy-check.sh --text LABEL S  one string, e.g. a ref name (pre-push hook)
# The hooks run an installed copy of this script and its rules (tools/install-hooks.sh puts them
# in <main .git folder>/privacy), so a checkout of an older commit cannot remove or weaken them.
# Rules: privacy-rules next to this script (generic, tracked), and <git dir>/privacy-local: this
# machine's real names (host, users, logins, addresses), one fixed string per line, matched in
# any case where no letter or digit touches it (so `_` and `-` count as edges). It sits in the
# main .git folder (shared by linked worktrees), so it can never be committed.
# A binary file is refused too: it cannot be scanned. Exit 0 clean, 1 found, 2 usage.
set -uo pipefail
# Check the objects a push sends, not what `git replace` shows in their place.
export GIT_NO_REPLACE_OBJECTS=1
# The repo: the one this script sits in (tools/), or for the installed copy the one git runs
# the hook in. The user's git config must not hide anything from the commands below.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES=$HERE/privacy-rules
if [ "${HERE##*/}" = tools ]; then REPO="$(cd "$HERE/.." && pwd)"; else REPO="$(git rev-parse --show-toplevel)" || exit 2; fi
cd "$REPO" || exit 2
git() { command git -c diff.noprefix=false -c diff.mnemonicPrefix=false \
	-c diff.relative=false -c log.showSignature=false "$@"; }
LOCAL="$(git rev-parse --path-format=absolute --git-common-dir)/privacy-local" || exit 2
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

# All generic rules as one regex: grep -P takes a single pattern. The test containers' users
# (their names are made up; every tests/sandbox*/Dockerfile) may appear in home paths.
users=$( { grep -ohE '\bmkuser [a-z0-9]+' tests/*.sh 2>/dev/null | cut -d' ' -f2
	grep -oE 'useradd [^&;|]* [a-z0-9]+( |$)' tests/sandbox*/Dockerfile 2>/dev/null | awk '{ print $NF }'; } | sort -u | paste -sd'|')
[ -n "$users" ] || users=fresh
grep -v -e '^#' -e '^[[:space:]]*$' "$RULES" | sed "s/@TESTUSERS@/$users/; s/.*/(?:&)/" | paste -sd'|' > "$tmp/rule" || exit 2
[ -s "$tmp/rule" ] || { echo "privacy: no rules in $RULES" >&2; exit 2; }
: > "$tmp/local"
# Each local name as \Q…\E (taken literally), with no letter or digit on either side.
[ -f "$LOCAL" ] && { grep -v -e '^#' -e '^[[:space:]]*$' "$LOCAL" |
	sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\\E//g; /^$/d; s/.*/(?<![[:alnum:]])\\Q&\\E(?![[:alnum:]])/' | paste -sd'|' > "$tmp/local"; }

# Lines "label<TAB>text" on stdin; the label (a path, a commit) is checked too.
# A grep that fails (a bad rule, no -P) stops the check with exit 2: it must never pass.
scan() {
	cat > "$tmp/text" || exit 2
	: > "$tmp/hits"
	find_hits -P -e "$(cat "$tmp/rule")"
	grep -q . "$tmp/local" && find_hits -i -P -e "$(cat "$tmp/local")"
	find_hits -P '^[^\t]*\tBINARY '
	sort -u -o "$tmp/hits" "$tmp/hits"
	report
}
find_hits() {
	grep -a "$@" "$tmp/text" >> "$tmp/hits"
	[ $? -le 1 ] || { echo "privacy: grep failed (a bad rule in $RULES or $LOCAL?)" >&2; exit 2; }
}
report() {
	[ -s "$tmp/hits" ] || return 0
	echo "privacy: refused, found:" >&2
	cut -c1-200 "$tmp/hits" | sed 's/\t/: /; s/^/  /' >&2
	echo "privacy: remove it, or for a false alarm adjust tools/privacy-rules (then tools/install-hooks.sh) or $LOCAL" >&2
	return 1
}

# Added lines of a diff on stdin, as "label path<TAB>text"; a binary file as a BINARY line.
# "+++ " names the file only in a file's header (between "diff --git" and its first "@@"):
# inside a hunk it is an added line that starts with "++ ".
added() {
	awk -v c="$1" '
		/^diff --git /           { h = 1; next }
		/^@@ /                   { h = 0; next }
		h && /^\+\+\+ /          { f = substr($0, 7); next }
		h && /^Binary files /    { print c "\tBINARY " $0; next }
		!h && /^\+/              { print c f "\t" substr($0, 2) }'
}
# NUL-separated names on stdin, one "label<TAB>name" line each (a tab or newline in a name
# cannot hide it).
names() { tr '\0' '\n' | sed "s/^/$1\t/"; }

# Every git command's output goes to a file first and its status is checked: a git that fails
# part way (a missing object, a promisor remote out of reach) must stop the check, not shorten it.
die() { echo "privacy: $* failed: nothing checked, refused" >&2; exit 2; }
in=$tmp/in
: > "$in"
case "${1:-}" in
--tree)
	git ls-files -z > "$tmp/files" || die "git ls-files"
	names path < "$tmp/files" >> "$in"
	while IFS= read -r -d '' f; do
		[ -L "$f" ] && { printf '%s\tlink to %s\n' "$f" "$(readlink "$f")" >> "$in"; continue; }
		[ -f "$f" ] || continue
		grep -Iq '' "$f" || { [ -s "$f" ] && printf '%s\tBINARY file\n' "$f" >> "$in"; continue; }
		awk -v f="$f" '{ print f ":" FNR "\t" $0 }' "$f" >> "$in" || die "reading $f"
	done < "$tmp/files"
	scan < "$in" ;;
--staged)
	a=$(git var GIT_AUTHOR_IDENT) && c=$(git var GIT_COMMITTER_IDENT) || die "git var"
	printf 'author\t%s\ncommitter\t%s\n' "$a" "$c" >> "$in"
	git diff --cached --name-only -z --no-renames > "$tmp/files" || die "git diff --name-only"
	names path < "$tmp/files" >> "$in"
	git diff --cached -U0 --no-color --no-ext-diff --no-textconv > "$tmp/diff" || die "git diff"
	added "" < "$tmp/diff" >> "$in"
	scan < "$in" ;;
--msg)
	[ -f "${2:-}" ] || { echo "usage: $0 --msg FILE" >&2; exit 2; }
	# Every line, comments too (git keeps them with --cleanup=verbatim or another comment
	# character). Only the diff `git commit -v` adds is left out: it starts at the scissors line
	# when the next line is git's own "Do not modify or remove the line above."
	awk '
		/^[#;] ------------------------ >8 ------------------------$/ { s = $0; if ((getline n) > 0) { if (n ~ /^[#;] Do not modify or remove the line above\.$/) exit; print s; print n } else print s; next }
		{ print }' "$2" > "$tmp/msg" || die "reading $2"
	sed 's/^/message\t/' "$tmp/msg" | scan ;;
--tag)
	[ "$(git cat-file -t "${2:-}" 2>/dev/null)" = tag ] || { echo "usage: $0 --tag TAG-OBJECT" >&2; exit 2; }
	git cat-file tag "$2" > "$tmp/tag" || die "git cat-file tag"
	sed "s/^/tag ${2:0:7}\t/" "$tmp/tag" | scan ;;
--text)
	[ $# = 3 ] || { echo "usage: $0 --text LABEL STRING" >&2; exit 2; }
	printf '%s\t%s\n' "$2" "$3" | scan ;;
--range)
	shift
	# --have FILE: "^<sha>" lines, commits the remote already has (read on stdin by git, so a
	# remote with very many refs does not overflow the command line).
	have=/dev/null
	[ "${1:-}" = --have ] && { have=$2; shift 2; }
	[ $# -gt 0 ] || { echo "usage: $0 --range [--have FILE] REV…" >&2; exit 2; }
	# \001 starts a commit's header (names, emails, message), \002 ends it; the diff follows.
	# A merge is shown against its first parent, so lines added while resolving it are seen.
	git log --root --no-color --no-ext-diff --no-textconv --diff-merges=first-parent -U0 -p \
		--format='%x01%h%n%an <%ae>%n%cn <%ce>%n%B%x02' "$@" --stdin -- < "$have" > "$tmp/log" || die "git log"
	awk '
		/^\001/            { c = substr($0, 2); m = 1; next }
		m && /\002$/       { sub(/\002$/, ""); if ($0 != "") print c " message\t" $0; m = 0; next }
		m                  { print c " message\t" $0; next }
		/^diff --git /     { h = 1; next }
		/^@@ /             { h = 0; next }
		h && /^\+\+\+ /    { f = substr($0, 7); next }
		h && /^Binary files / { print c "\tBINARY " $0; next }
		!h && /^\+/        { print c " " f "\t" substr($0, 2) }' "$tmp/log" >> "$in"
	# Each commit's raw object, header and message: what the log above may not show (a merged
	# tag's "mergetag", a message cut short by a \002 byte); a signature block is left out.
	git rev-list "$@" --stdin -- < "$have" > "$tmp/revs" || die "git rev-list"
	while read -r c; do
		git cat-file commit "$c" > "$tmp/obj" || die "git cat-file $c"
		awk -v c="${c:0:7}" '
			/^$/ { b = 1 }
			!b && /^gpgsig(-sha256)? / { g = 1; next }
			!b && g && /^ / { next }
			{ g = 0; print c " header\t" $0 }' "$tmp/obj" >> "$in"
	done < "$tmp/revs"
	# Every file name, also of a pure rename or an empty file (no "+++" line for those).
	git log --root --format='%x01%h' --name-only -z --no-renames --diff-merges=first-parent "$@" --stdin -- \
		< "$have" > "$tmp/names" || die "git log --name-only"
	tr '\0' '\n' < "$tmp/names" | awk '/^\001/ { c = substr($0, 2); next } $0 != "" { print c " path\t" $0 }' >> "$in"
	scan < "$in" ;;
*)
	sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
