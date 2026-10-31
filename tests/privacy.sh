#!/usr/bin/env bash
# Self-test of tools/privacy-check.sh and the hooks in .githooks, in throwaway git repos.
# Each leak below is put together at run time, so this file does not hold one itself.
#   tests/privacy.sh          prints ok/FAIL per check; exit 0 = all passed. Seconds, no network.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=1+t@users.noreply.github.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=1+t@users.noreply.github.com

# A repo with the checker, its rules, the hooks and a test that makes the user "fresh".
newrepo() {
	rm -rf "$T/r"; mkdir -p "$T/r/tools" "$T/r/tests/sandbox"
	cp "$REPO/tools/privacy-check.sh" "$REPO/tools/privacy-rules" "$REPO/tools/install-hooks.sh" "$T/r/tools/"
	cp -r "$REPO/.githooks" "$T/r/"
	echo 'mkuser fresh 2001' > "$T/r/tests/a.sh"; : > "$T/r/tests/sandbox/Dockerfile"
	git -C "$T/r" init -q -b main && git -C "$T/r" add -A && git -C "$T/r" commit -qm init
	printf 'zorblax\n' > "$T/r/.git/privacy-local"
}
chk() { "$T/r/tools/privacy-check.sh" "$@" 2>/dev/null; }

H=/ho; U=/Us; A=claude.; E=@; N=.ts; M=-; O=
leaks=(
	"home folder|cd ${H}me/alice/src"
	"macOS home|${U}ers/alice/x"
	"session link|https://${A}ai/code/session_0${RANDOM}abcdefgh"
	"session id|id session_0${RANDOM}abcdefghij"
	"real UUID|3f2b9c1a${M}4d5e-4f60-8a7b-1c2d3e4f5a6b"
	"email|mail alice${E}example.com"
	"MagicDNS name|ssh box.tail1234${N}.net"
	"tailnet address|ping 100.${O}101.2.3"
	"GitHub token|gh""p_abcdefghijklmnopqrstuvwxyz0123456789"
	"private key|-----BEGIN OPENSSH ""PRIVATE KEY-----"
	"local name, other case|host Zorblax is up"
)
allowed=(
	"test user home|${H}me/fresh/proj"
	"home in a variable|${H}me/\$u/x"
	"GitHub noreply|63034620+AnapatAut${E}users.noreply.github.com"
	"Anthropic noreply|noreply${E}anthropic.com"
	"git remote|git${E}github.com:AnapatAut/x.git"
	"one-digit test UUID|77777777-7777-4777-8777-777777777777"
	"address outside the tailnet range|100.63.1.1"
	"local name inside a longer word|zorblaxy"
	"local name after a letter|xzorblax"
)

echo "== --tree"
for c in "${leaks[@]}"; do
	newrepo; printf '%s\n' "${c#*|}" > "$T/r/f.txt"; git -C "$T/r" add f.txt
	chk --tree && bad "tree: ${c%%|*} not caught" || ok "tree: ${c%%|*} caught"
done
for c in "${allowed[@]}"; do
	newrepo; printf '%s\n' "${c#*|}" > "$T/r/f.txt"; git -C "$T/r" add f.txt
	chk --tree && ok "tree: ${c%%|*} allowed" || bad "tree: ${c%%|*} refused"
done
newrepo; : > "$T/r/alice${E}example.com"; git -C "$T/r" add -A
chk --tree && bad "tree: an empty file's name not checked" || ok "tree: an empty file's name is checked"
newrepo; chk --tree && ok "tree: the rules file and checker pass their own check" || bad "tree: the rules file or checker matches itself"

echo "== --staged, --msg"
newrepo; printf '%s\n' "${H}me/alice" > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && bad "staged: a leak not caught" || ok "staged: a leak caught"
newrepo; printf '\0\1\2' > "$T/r/b.bin"; git -C "$T/r" add b.bin
chk --staged && bad "staged: a binary file not refused" || ok "staged: a binary file refused"
newrepo; printf 'x\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
GIT_AUTHOR_EMAIL="alice${E}example.com" chk --staged && bad "staged: an author email not caught" || ok "staged: an author email caught"
chk --staged && ok "staged: a clean change passes" || bad "staged: a clean change refused"
printf 'fix\n\nClaude-Ses''sion: https://x\n' > "$T/msg"
chk --msg "$T/msg" && bad "msg: a session trailer not caught" || ok "msg: a session trailer caught"
printf 'fix\n# from %s\n' "${H}me/alice" > "$T/msg"
chk --msg "$T/msg" && bad "msg: a comment line not checked (git keeps it with --cleanup=verbatim)" || ok "msg: a comment line checked"
sc='# ------------------------ >8 ------------------------'
printf 'fix\n%s\n# Do not modify or remove the line above.\n# Everything below it will be ignored.\n-%s\n' "$sc" "${H}me/alice" > "$T/msg"
chk --msg "$T/msg" && ok "msg: the diff below the scissors line (commit -v) ignored" || bad "msg: the commit -v diff checked"
printf 'fix\n%s\nhost zorblax\n' "$sc" > "$T/msg"
chk --msg "$T/msg" && bad "msg: text after a bare scissors line (kept by -m) missed" || ok "msg: text after a bare scissors line (kept by -m) caught"

echo "== --range and the hooks"
newrepo; cd "$T/r" || exit 2
tools/install-hooks.sh >/dev/null
printf '%s\n' "${H}me/alice" > f.txt; git add f.txt
git commit -qm leak 2>/dev/null && bad "pre-commit: a leak committed" || ok "pre-commit: a leak refused"
git reset -q; rm f.txt
printf 'fine\n' > f.txt; git add f.txt
git commit -qm "$(printf 'fine\n\nClaude-Ses''sion: x')" 2>/dev/null && bad "commit-msg: a trailer committed" || ok "commit-msg: a trailer refused"
git commit -qm fine 2>/dev/null && ok "hooks: a clean commit passes" || bad "hooks: a clean commit refused"
git init -q --bare "$T/remote.git"; git remote add origin "$T/remote.git"
git push -q origin main 2>/dev/null && ok "pre-push: a clean new branch pushed" || bad "pre-push: a clean branch refused"
# A leak committed past the hooks, then removed: the push must still refuse.
printf '%s\n' "${H}me/alice" > g.txt; git add g.txt; git commit -q --no-verify -m leak
git rm -q g.txt; git commit -qm "remove it"
git push -q origin main 2>/dev/null && bad "pre-push: a removed leak in history pushed" || ok "pre-push: a removed leak in history refused"
[ "$(git rev-parse HEAD~2)" = "$(git -C "$T/remote.git" rev-parse main)" ] && ok "pre-push: the remote did not move" || bad "pre-push: the remote moved"
# The leak reaches the remote anyway (hook skipped); a clean new branch on top of it must pass:
# it is checked only for the commits the remote does not have yet.
git push -q --no-verify origin main
git checkout -q -b side; printf 'x\n' > h.txt; git add h.txt; git commit -qm side
git push -q origin side 2>/dev/null && ok "pre-push: a new branch checks only commits the remote lacks" || bad "pre-push: a new branch blamed for commits the remote has"
# A session trailer in a message, committed past the hooks: the push must refuse.
git commit -q --no-verify --allow-empty -m "$(printf 'side\n\nClaude-Ses''sion: x')"
git push -q origin side 2>/dev/null && bad "pre-push: a leak in a message pushed" || ok "pre-push: a leak in a message refused"
git reset -q --hard HEAD~1
GIT_AUTHOR_EMAIL="alice${E}example.com" git commit -q --no-verify --allow-empty -m side2
git push -q origin side 2>/dev/null && bad "pre-push: an author email pushed" || ok "pre-push: an author email refused"
# A force push over a remote commit this clone never had: no error, a clean push passes.
git push -q --no-verify --force origin side
git -C "$T/remote.git" update-ref refs/heads/side "$(git -C "$T/remote.git" commit-tree -m x "$(git -C "$T/remote.git" mktree </dev/null)")"
git reset -q --hard HEAD~1; git commit -q --allow-empty -m clean
git push -q --force origin side 2>/dev/null && ok "pre-push: a force push over an unknown remote commit works" || bad "pre-push: a force push over an unknown remote commit fails"
git tag -a v1 -m "$(printf 'built in %s' "${H}me/alice")"
git push -q origin v1 2>/dev/null && bad "pre-push: an annotated tag's message pushed" || ok "pre-push: an annotated tag's message refused"
git tag -a inner -m "inner from zorblax"; git tag -a outer -m clean inner; git tag -d inner >/dev/null
git push -q origin refs/tags/outer 2>/dev/null && bad "pre-push: a tag inside a tag pushed" || ok "pre-push: a tag inside a tag refused"
printf 'zorblax secret\n' > s.txt; b=$(git hash-object -w s.txt); rm s.txt
git tag lwblob "$b"; git tag -a blobtag -m clean "$b"; git tag lwtree "$(git write-tree)"
git push -q origin refs/tags/lwblob 2>/dev/null && bad "pre-push: a tag on a blob pushed" || ok "pre-push: a tag on a blob refused"
git push -q origin refs/tags/blobtag 2>/dev/null && bad "pre-push: an annotated tag on a blob pushed" || ok "pre-push: an annotated tag on a blob refused"
git push -q origin refs/tags/lwtree 2>/dev/null && bad "pre-push: a tag on a tree pushed" || ok "pre-push: a tag on a tree refused"
# A replace ref shows a clean commit in place of the one push sends.
printf 'host zorblax\n' > p.txt; git add p.txt; git commit -q --no-verify -m bad; badc=$(git rev-parse HEAD)
git reset -q --hard HEAD~1; git commit -q --allow-empty -m clean2; git replace "$badc" HEAD; git reset -q --hard "$badc"
git push -q origin side 2>/dev/null && bad "pre-push: a commit hidden by git replace pushed" || ok "pre-push: a commit hidden by git replace refused"
chk --range "$(git rev-parse HEAD~1)..$badc" && bad "range: a commit hidden by git replace missed" || ok "range: a commit hidden by git replace caught"
git replace -d "$badc" >/dev/null
git reset -q --hard HEAD~1    # a clean commit: only the names below can be refused
git push -q origin HEAD:refs/heads/zorblax-fix 2>/dev/null && bad "pre-push: a local name in a branch name pushed" || ok "pre-push: a local name in a branch name refused"
git tag zorblax-v1; git push -q origin zorblax-v1 2>/dev/null && bad "pre-push: a local name in a tag name pushed" || ok "pre-push: a local name in a tag name refused"
git tag -d zorblax-v1 >/dev/null
# A branch without the hook files (like an old commit): the installed copies still run.
git checkout -q --orphan bare; git rm -rqf .; printf '%s\n' "${H}me/alice" > x.txt; git add x.txt
git commit -qm bare 2>/dev/null && bad "pre-commit: gone in a checkout without .githooks" || ok "pre-commit: still runs in a checkout without .githooks"
git commit -q --no-verify -m bare
git push -q origin bare 2>/dev/null && bad "pre-push: gone in a checkout without .githooks" || ok "pre-push: still runs in a checkout without .githooks"
git -c log.showRoot=false push -q origin bare 2>/dev/null && bad "pre-push: log.showRoot=false hides a root commit's content" || ok "pre-push: log.showRoot=false does not hide a root commit"
git checkout -q -f side
printf 'ok\002\nhost zorblax\n' > "$T/m2"; git commit -q --no-verify --allow-empty -F "$T/m2"
git push -q origin side 2>/dev/null && bad "pre-push: a message after a \\002 byte pushed" || ok "pre-push: a message after a \\002 byte refused"
git reset -q --hard HEAD~1
# A message whose body has a line starting with "gpgsig", after a \002: still checked.
printf 'ok\n\nend\002\ngpgsig x\n see zorblax here\n' > "$T/m3"; git commit -q --no-verify --allow-empty -F "$T/m3"
git push -q origin side 2>/dev/null && bad "pre-push: a 'gpgsig' line in a message body skipped" || ok "pre-push: a 'gpgsig' line in a message body checked"
git reset -q --hard HEAD~1
# A stale tracking ref pointing at an unpushed leak: what the remote really has decides.
git commit -q --no-verify --allow-empty -m "zorblax stale"; git update-ref refs/remotes/origin/gone HEAD
git commit -q --allow-empty -m clean3
git push -q origin HEAD:refs/heads/t5 2>/dev/null && bad "pre-push: a leak behind a stale tracking ref pushed" || ok "pre-push: a leak behind a stale tracking ref refused"
git update-ref -d refs/remotes/origin/gone; git reset -q --hard HEAD~2
cd "$REPO" || exit 2
# A moved clone keeps its hooks (they live in its own .git/hooks).
mv "$T/r" "$T/r-moved"; printf '%s\n' "${H}me/alice" > "$T/r-moved/mv.txt"; git -C "$T/r-moved" add mv.txt
git -C "$T/r-moved" commit -qm moved 2>/dev/null && bad "hooks: gone after moving the clone" || ok "hooks: still run after moving the clone"
newrepo; printf '#!/bin/sh\necho mine\n' > "$T/r/.git/hooks/pre-commit"; chmod +x "$T/r/.git/hooks/pre-commit"
(cd "$T/r" && tools/install-hooks.sh >/dev/null 2>&1) && bad "install: someone else's pre-commit overwritten" || ok "install: refuses to overwrite someone else's pre-commit"
grep -q mine "$T/r/.git/hooks/pre-commit" && ok "install: someone else's pre-commit kept" || bad "install: someone else's pre-commit changed"
newrepo; git -C "$T/r" config core.hooksPath /elsewhere
(cd "$T/r" && tools/install-hooks.sh >/dev/null 2>&1) && bad "install: passes while core.hooksPath points elsewhere" || ok "install: refuses while core.hooksPath points elsewhere"
newrepo; (cd "$T/r" && tools/install-hooks.sh >/dev/null && tools/install-hooks.sh >/dev/null) && ok "install: a second run works" || bad "install: a second run fails"
# A remote with 60000 refs: the push still works (the list goes through a file, not argv).
newrepo; git init -q --bare "$T/big.git"; git -C "$T/r" push -q --no-verify "$T/big.git" main
h=$(git -C "$T/big.git" rev-parse main)
for i in $(seq 1 60000); do echo "create refs/x/$i $h"; done | git -C "$T/big.git" update-ref --stdin
(cd "$T/r" && tools/install-hooks.sh >/dev/null && git commit -q --allow-empty -m more && timeout 120 git push -q "$T/big.git" main 2>/dev/null) &&
	ok "pre-push: a remote with 60000 refs works" || bad "pre-push: a remote with 60000 refs fails"
# A git that fails part way (a missing object): the check stops with exit 2, it never passes.
newrepo; printf 'a\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt; git -C "$T/r" commit -qm a
printf 'b\nhost zorblax\n' > "$T/r/f.txt"; git -C "$T/r" commit -q --no-verify -am b
o=$(git -C "$T/r" rev-parse HEAD~1:f.txt); rm -f "$T/r/.git/objects/${o:0:2}/${o:2}"
chk --range HEAD~1..HEAD; [ $? = 2 ] && ok "range: a missing object stops the check (exit 2)" || bad "range: a missing object lets the check pass"
# A local file with only comments, or a line that is only \E: no name, so no false alarm.
newrepo; printf '# names go here\n\n' > "$T/r/.git/privacy-local"; printf 'x\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && ok "a local file with only comments refuses nothing" || bad "a local file with only comments refuses everything"
newrepo; printf 'zorblax\n\\E\n' > "$T/r/.git/privacy-local"; printf 'x\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && ok "a local line that is only \\E refuses nothing" || bad "a local line that is only \\E refuses everything"
# A hand-made header that starts with "gpgsig" but is not a signature: still checked.
newrepo; t=$(git -C "$T/r" write-tree); p=$(git -C "$T/r" rev-parse HEAD)
c=$(printf 'tree %s\nparent %s\nauthor t <1+t@users.noreply.github.com> 1 +0000\ncommitter t <1+t@users.noreply.github.com> 1 +0000\ngpgsig-x see %s\n\nok\n' "$t" "$p" "${H}me/alice" | git -C "$T/r" hash-object -t commit -w --stdin)
chk --range "$p..$c" && bad "range: a 'gpgsig-x' header skipped" || ok "range: a 'gpgsig-x' header checked"
newrepo; git -C "$T/r" config core.hooksPath "$T/r/.githooks"; printf 'x\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
git -C "$T/r" commit -qm x 2>/dev/null && bad "hooks run straight from .githooks pass without a checker" || ok "hooks run straight from .githooks refuse (not installed)"

echo "== cases found in review"
newrepo; printf 'ok\n++ %s\n' "${H}me/alice" > "$T/r/p.txt"; git -C "$T/r" add p.txt
chk --staged && bad "staged: an added line starting with '++ ' missed" || ok "staged: an added line starting with '++ ' caught"
git -C "$T/r" commit -q --no-verify -m p
chk --range HEAD~1..HEAD && bad "range: an added line starting with '++ ' missed" || ok "range: an added line starting with '++ ' caught"
newrepo; git -C "$T/r" checkout -q -b b; printf 'b\n' > "$T/r/b.txt"; git -C "$T/r" add b.txt; git -C "$T/r" commit -qm b
git -C "$T/r" checkout -q main; printf 'm\n' > "$T/r/m.txt"; git -C "$T/r" add m.txt; git -C "$T/r" commit -qm m
git -C "$T/r" merge -q --no-commit b >/dev/null 2>&1; printf '%s\n' "${H}me/alice" > "$T/r/evil.txt"; git -C "$T/r" add evil.txt
git -C "$T/r" commit -q --no-verify -m merge
chk --range HEAD~1..HEAD && bad "range: a leak added while resolving a merge missed" || ok "range: a leak added while resolving a merge caught"
newrepo; printf 'c\n' > "$T/r/c.txt"; git -C "$T/r" add c.txt; git -C "$T/r" commit -qm c
git -C "$T/r" mv c.txt zorblax-notes.txt; git -C "$T/r" commit -q --no-verify -m mv
chk --range HEAD~1..HEAD && bad "range: a local name in a pure rename missed" || ok "range: a local name in a pure rename caught"
newrepo; : > "$T/r/alice${E}example.com"; git -C "$T/r" add -A; git -C "$T/r" commit -q --no-verify -m e
chk --range HEAD~1..HEAD && bad "range: an empty file's name missed" || ok "range: an empty file's name caught"
newrepo; printf 'x\n' > "$T/r/a$(printf '\t')zorblax.txt"; git -C "$T/r" add -A
chk --staged && bad "staged: a local name after a tab in a file name missed" || ok "staged: a local name after a tab in a file name caught"
newrepo; printf 'user claude_Zorblax\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && bad "staged: a local name joined by '_' missed" || ok "staged: a local name joined by '_' caught"
newrepo; printf '%s\n' "~/.claude/projects/${M}home-alice-src-x" > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && bad "staged: an encoded project folder missed" || ok "staged: an encoded project folder caught"
newrepo; printf '%s\n' "~/.claude/projects/${M}home-fresh-proj" > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && ok "staged: a test user's encoded project folder allowed" || bad "staged: a test user's encoded project folder refused"
newrepo; printf 'useradd --home-dir /srv/x u\nclass="page-home-banner"\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged && ok "staged: '--home-dir' and 'page-home-x' allowed" || bad "staged: '--home-dir' or 'page-home-x' refused"
newrepo; printf '\n\n' > "$T/r/blank.txt"; git -C "$T/r" add blank.txt
chk --tree && ok "tree: a file of blank lines is text" || bad "tree: a file of blank lines called binary"
newrepo; t=$(git -C "$T/r" write-tree); p=$(git -C "$T/r" rev-parse HEAD)
c=$(printf 'tree %s\nparent %s\nauthor t <1+t@users.noreply.github.com> 1 +0000\ncommitter t <1+t@users.noreply.github.com> 1 +0000\nmergetag object %s\n type commit\n tag v0\n tagger x <%s> 1 +0000\n \n built on zorblax\n\nmerge\n' "$t" "$p" "$p" "alice${E}example.com" | git -C "$T/r" hash-object -t commit -w --stdin)
chk --range "$p..$c" && bad "range: a merged tag's tagger and message (mergetag) missed" || ok "range: a merged tag's tagger and message (mergetag) caught"
newrepo; ln -s "${H}me/alice/gone" "$T/r/l"; git -C "$T/r" add l
chk --tree && bad "tree: a dangling symlink's target missed" || ok "tree: a dangling symlink's target caught"
newrepo; git -C "$T/r" worktree add -q "$T/wt" -b wt 2>/dev/null; printf 'host zorblax\n' > "$T/wt/f.txt"; git -C "$T/wt" add f.txt
(cd "$T/wt" && tools/privacy-check.sh --staged 2>/dev/null) && bad "staged: the local file not found in a linked worktree" || ok "staged: the local file found in a linked worktree"
newrepo; printf '(unclosed\n' >> "$T/r/tools/privacy-rules"; printf 'x\n' > "$T/r/f.txt"; git -C "$T/r" add f.txt
chk --staged; [ $? = 2 ] && ok "a broken rule stops the check (exit 2), never passes" || bad "a broken rule lets the check pass"

# PRIVACY_MUTANTS=1: break the checker or a hook one way at a time, in a copy; each must make
# this test fail. About two minutes (37 mutants).
if [ "${PRIVACY_MUTANTS:-}" = 1 ]; then
	echo "== mutants"
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		f=${m%%' %%% '*}; rest=${m#*' %%% '}; old=${rest%%' %%% '*}; new=${rest#*' %%% '}
		d=$(mktemp -d -p "$T") || exit 2
		cp -r "$REPO/tools" "$REPO/tests" "$REPO/.githooks" "$d/"
		body=$(<"$d/$f")
		[[ $body == *"$old"* ]] || { bad "mutant does not apply: $f: $old"; continue; }
		printf '%s\n' "${body/"$old"/"$new"}" > "$d/$f"
		out=$(cd "$d" && git init -q -b main && PRIVACY_MUTANTS='' bash tests/privacy.sh 2>&1)
		grep -q '  FAIL  ' <<<"$out" && ok "mutant caught: $f: $old" || bad "mutant missed: $f: $old"
	done <<'MUTANTS'
tools/privacy-rules %%% (?<![A-Za-z0-9._%+-])(?![0-9] %%% (?!)(?<![A-Za-z0-9._%+-])(?![0-9]
tools/privacy-check.sh %%% grep -q . "$tmp/local" && find_hits %%% false && find_hits
tools/privacy-check.sh %%% s/\\E//g; /^$/d; %%% s/\\E//g;
tools/privacy-check.sh %%% /^gpgsig(-sha256)? / %%% /^gpgsig/
tools/privacy-check.sh %%% (?<![[:alnum:]])\\Q&\\E(?![[:alnum:]]) %%% \\Q&\\E
tools/privacy-check.sh %%% find_hits -P '^[^\t]*\tBINARY ' %%% :
tools/privacy-check.sh %%% /^[#;] ------------------------ >8 ------------------------$/ { %%% /^#/ { next } /^[#;] ------------------------ >8 ------------------------$/ {
tools/privacy-check.sh %%% printf 'author\t%s\ncommitter\t%s\n' "$a" "$c" >> "$in" %%% :
tools/privacy-check.sh %%% git diff --cached --name-only -z --no-renames > "$tmp/files" %%% : > "$tmp/files"
tools/privacy-check.sh %%% names path < "$tmp/files" >> "$in" %%% :
tools/privacy-check.sh %%% [ -n "$users" ] || users=fresh %%% users=nobodyx
tools/privacy-check.sh %%% --diff-merges=first-parent -U0 %%% -U0
tools/privacy-check.sh %%% /^@@ /                   { h = 0; next } %%% /^@@ /                   { next }
tools/privacy-check.sh %%% h && /^\+\+\+ /          { f %%% /^\+\+\+ /          { f
tools/privacy-check.sh %%% h && /^\+\+\+ /    { f %%% /^\+\+\+ /    { f
tools/privacy-check.sh %%% --git-common-dir %%% --git-dir
tools/privacy-check.sh %%% [ $? -le 1 ] || %%% true ||
tools/privacy-check.sh %%% [ -L "$f" ] && { printf %%% false && { printf
tools/privacy-check.sh %%% --name-only -z --no-renames --diff-merges=first-parent %%% --diff-merges=first-parent
.githooks/pre-push %%% "$check" --range --have "$have" "$lsha" || rc=1 %%% "$check" --range --have "$have" "$lsha" || true
tools/privacy-check.sh %%% > "$tmp/log" || die "git log" %%% > "$tmp/log" || true
.githooks/pre-push %%% awk '$2 == "commit" { print "^" $1 }' > "$have" %%% awk '0' > "$have"
.githooks/pre-push %%% 		"$check" --tag "$o" || rc=1 %%% 		:
.githooks/pre-push %%% git ls-remote -- "$2" 2>/dev/null | cut -f1 %%% git for-each-ref --format='%(objectname)' refs/remotes | cut -f1
tools/privacy-check.sh %%% /^$/ { b = 1 } %%% /^$/ { }
tools/install-hooks.sh %%% if p=$(git config --get core.hooksPath); then %%% if false; then
.githooks/pre-push %%% 		o=$(git cat-file tag "$o" | sed -n '1s/^object //p') %%% 		o=$(git rev-parse "$o^{}")
.githooks/pre-push %%% rc=1; continue; } %%% continue; }
tools/privacy-check.sh %%% export GIT_NO_REPLACE_OBJECTS=1 %%% :
tools/privacy-check.sh %%% n ~ /^[#;] Do not modify or remove the line above\.$/ %%% 1
tools/privacy-check.sh %%% { g = 0; print c " header\t" $0 } %%% { g = 0 }
tools/privacy-check.sh %%% grep -Iq '' "$f" %%% grep -Iq . "$f"
tools/privacy-rules %%% (?<![A-Za-z0-9-])-home- %%% -home-
.githooks/pre-push %%% 	"$check" --text ref "$lref $rref" || rc=1 %%% 	:
tools/privacy-check.sh %%% git log --root --no-color %%% git log --no-color
tools/privacy-check.sh %%% git cat-file commit "$c" > "$tmp/obj" %%% : > "$tmp/obj"
tools/privacy-check.sh %%% if [ "${HERE##*/}" = tools ]; then REPO= %%% if true; then REPO=
MUTANTS
fi

echo "== this repo"
"$REPO/tools/privacy-check.sh" --tree && ok "every tracked file passes" || bad "a tracked file has a leak (above)"

echo "privacy: $pass passed, $fail failed"
[ "$fail" = 0 ]
