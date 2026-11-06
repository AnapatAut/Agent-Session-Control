# Tests

Six scripts. None touches your own tmux, tmux config or systemd user units.

| Script | Time | Needs | Checks |
|---|---|---|---|
| `tests/lint.sh` | about 45 s | bash; `shellcheck` and `node` if installed | bash syntax and shellcheck for every script, Python compiles, app.js parses, the suites' checks and waits (`tests/checklint.py`, with `tests/bashtree.py`), the mutant lists, the case runner, how a mutant run is read (`tests/mutjudge.py`), the mutant runner on toy repos (`tests/mutate-test.sh`), the sandbox's container check with a fake docker (`tests/sandbox-lib-test.sh`); the privacy check of every tracked file |
| `tests/asc.sh` | about 4 min | bash, tmux, jq, python3 | `asctl`: live, fav, on, off, rename, restart, mode, rc, the event log, the watcher, boot, the tmux server unit and `asctl setup`, with a fake claude on a tmux server of its own and a fake systemctl (`tests/asc/bin`) |
| `tests/dash.sh` | about 1 min | bash, tmux, jq, curl, python3; node for the page's logic (skipped without) | the dashboard server: socket and folder modes, the login, Host, Origin and token checks, one request per connection, the API and its actions, past conversations, idle and SIGTERM exit, systemd socket activation; the notices (boot, setup, the watcher), the auto-restart setting, conversation lengths; the page's own logic (`tests/dash/page.js`: row reasons, history wording and folding) |
| `tests/sandbox.sh` | about 7 min | Docker, network for the build only | asctl under real systemd, in a container: the two suites above on a clean Ubuntu, the dashboard as user units, a real out-of-memory kill, the watcher, the units from a checkout, the machine install (`install.sh`) and `asctl setup` by a second user, a reboot, then `setup --remove` and `--uninstall` |
| `tests/privacy.sh` | seconds (`PRIVACY_MUTANTS=1`: about 4 min) | bash, git | the privacy check and its hooks catch each kind of leak and let the allowed cases through |
| `tests/mutate.sh` | about 30 min (`MUTANT_JOBS=3`; its baseline about 2 min) | as `asc.sh` and `dash.sh` | each mutant of `tests/mutants-asc.txt` and `tests/mutants-dash.txt`: one safeguard of asctl broken in a copy must make its named check fail |

```bash
tests/lint.sh
tests/asc.sh                 # prints ok/FAIL per check and a summary; exit 0 = all passed
ASC_ONLY=main tests/asc.sh   # only that case (tests/cases.sh)
ASC_TRACE=1 tests/asc.sh     # after a FAIL, the end of the fake claudes' trace: to find a race
tests/dash.sh
tests/mutate.sh              # every mutant; exit 0 only if each is caught by its own check
tests/sandbox.sh             # KEEP=1: leave the container up; --down removes what a run left
```

In `asc.sh` and `dash.sh` each check prints `  ok    NAME` or `  FAIL  NAME`, the same fixed
name both ways, and after a FAIL what was seen, each line indented further; `  skip  NAME` when
it cannot run here. The lint
refuses a name with a value in it (a pid, an id, a time), used twice in a suite, or on a check in
a loop or a function (it would print more than once), so a name means the same check, once, in
every run. It reads the suites with a small bash parser (`tests/bashtree.py`), and a script it
cannot read fails the lint. A mutant's name holds its file, old text and new text.

A suite is split into cases, functions `case_NAME` that `tests/cases.sh`'s `run_cases` runs
once each, in order; each must pass on its own, after only the suite's setup. `ASC_ONLY=a,b`
runs only those cases (an unknown name exits 2; a mutant run refuses it). After each case the
runner prints `case done NAME` and `== counts NAME <pass> <fail>`: a case that never got there
(a `stop`, an exit at `TEST_STOP_AT`) is unfinished. The lint allows a check in a case function only, and
refuses a call of one other than through `run_cases`.

A wait (`poll`, `poll_gone`, `claude_in`, `start_dash`, and any helper that returns a wait's
failure) must have its status used: it fails a check, or `|| stop` ends the suite with one FAIL,
`setup: NAME`, where what did not come is something the test itself started (a claude in a
session it made, a process of its own). The suites run without `set -e`, so a wait whose status
is dropped goes on, and a "did not happen" check after it passes without testing anything; the
lint refuses one, and a poll loop written out by hand. On exit each suite ends what it started
(`tests/reap.sh`: its jobs and their children, then what the test tmux server's panes run)
before removing its folder.

The dashboard's token never goes on a command line, where any user on the machine can read it
with `ps`: `dash.sh` sends it as `-H @<(printf 'X-Asctl-Token: %s\n' "$TOK")` (printf is a
builtin), and the lint refuses `$TOK` (or an `X-Asctl-Token` header with a `$`) in any word of
any command, assignments and `$( )` text too, but in `printf` (not `-v`), `echo`, `[` and `test`.

A mutant is a line `file %%% old %%% new %%% check %%% case` of `tests/mutants-asc.txt` or
`tests/mutants-dash.txt`: a change to asctl, and the check, in its case, that must fail with it.
Its old text must be found exactly once in its file (a `⏎` in old or new stands for a newline, so
it can take in the line after or before it); the lint (`tests/mutantlint.py`) refuses one that is
not, a line given twice, a change that no longer parses (a mutant that breaks the syntax fails
every check, a catch that tests nothing), and a check or case that is not the suite's. A mutant
must never take a suite off its fakes onto the real machine: a change to a line marked
`# isolation:` (where asctl picks the test's tmux socket, `systemctl` or `claude`) is refused, as
is a new text naming `systemctl`, `claude`, `env -i`, or an `env=` not built from `os.environ`,
more often than the old one. A mutant whose module then fails at import (imported apart, in a
bare environment) is BROKEN.
`tests/mutate.sh` copies the tracked files to `/tmp/asc-mut.<run id>` and first runs every case
alone as the baseline: all `ok`, no `skip`, each case done, exactly the source's checks (else
exit 2, no verdicts). Then each mutant, `MUTANT_JOBS` (default 3) at a time, in a copy of its
own: its case alone, stopped at its check (`TEST_STOP_AT`); that check failing twice is CAUGHT.
Else the whole suite (`(full)`): failing twice, CAUGHT; the check `ok`, every case done and the
baseline's checks, SURVIVED; anything else (a FAIL elsewhere only, flaky, its case failing it
once, its case run cut short before its check) UNCLEAR. A run over its time limit, or with memory
pressure from a second before it to
a second after (available memory under 15%, tasks stalled on memory 0.1 s or more (PSI "full"),
a kernel OOM kill, a line in earlyoom's kill file if it can be read, the sampler stalled, the
clock set back, PSI or the OOM count no longer readable), never gives a verdict: UNCLEAR; and
once there is pressure no more mutants start (the rest UNCLEAR). The suites' own folders and
tmux sockets (`TMPDIR`, `TMUX_TMPDIR`) are in its folder. It holds a lock (one mutant run at a
time), is refused while a process of an earlier run still runs (one killed with no cleanup), and
on any exit ends every process it started and removes its folder. Do not edit a test script while it runs: bash reads a script
as it goes, and the run breaks.

## The sandbox

`tests/sandbox.sh` builds `tests/sandbox-asc/Dockerfile` (Ubuntu 24.04 booting real systemd,
two lingering users, the repo's tracked files in `/opt/asc`) with a throwaway buildx builder,
and runs one container with no network but loopback, no mounts, no published ports, not
privileged, no new privileges, fewer capabilities, 1 GiB of memory and no swap, a process
limit and the highest OOM score. The options, and the whole `HostConfig` docker must give a
container made with them, are written out in `tests/sandbox-lib.sh`: the container is
created, compared field by field before it starts (any difference, a field more or less,
aborts the run), then checked from inside after the start (`tests/sandbox-lib-test.sh`, run by
the lint, shows each dangerous change reported). The Dockerfile's `base` stage has no repo
files, for a run that copies its own into each container. Root inside is still root on the
host with fewer capabilities (systemd needs
`SYS_ADMIN`), so the box is for this repo's own code only; the tests run as the two users,
except `install.sh`, which runs as root by design. Its sections:

1. systemd and the users' managers;
2. `asc.sh` and `dash.sh` on a clean Ubuntu, as a user with its user manager's bus (so tmux
   makes pane scopes) and node: a suite that skips anything fails here;
3. the dashboard as user units (socket activation, modes, idle exit, a stop that waits);
4. a real out-of-memory kill kept inside a capped unit;
5. the watcher: a favorite's claude killed by the kernel, told apart from other ends, and
   started again in place;
6. the units from a checkout (`tools/install-units.sh`): the tmux server unit, On with no
   server, the pane scopes;
7. the machine install: refusals (not root, a path not its own, a changed unit, a link in the
   checkout), the release and its modes, upgrades and pruning; then `asctl setup` by a second
   user whose old `tmux.service` (as tmux-continuum writes it) runs: refused while continuum's
   boot is on, then that unit disabled but its server left up;
8. a reboot (`docker restart`): each user's favorite with resurrect on comes back by
   `asctl-boot.service`, the second user's from the installed release, and the old unit stays
   off;
9. `asctl setup --remove` (the old unit enabled again), then `install.sh --uninstall`: refused
   while a user has it set up or a process runs its code, then removed.

## What `privacy.sh` covers

In throwaway git repos (no network, no global git config): each kind of leak the generic
rules know (a home folder outside the test users, a macOS home, a claude.ai session link or
id, a real UUID, an email, a MagicDNS name, a tailnet address, a GitHub token, a private key)
and a name from the local file in another case is caught by `--tree`; the allowed cases pass
(a test user's home, `/home/$u`, GitHub and Anthropic noreply emails, `git@github.com`, the
one-digit test UUID, an address outside the tailnet range, a local name inside a longer
word); a file name is checked; the rules file and checker pass their own check. `--staged`
catches a leak, a binary file and an author email; `--msg` catches a session trailer and
ignores git's comment lines. The hooks: a commit with a leak or a trailer is refused, a
clean one passes; a push of a leak committed past the hooks and then removed is refused and
the remote does not move; a new branch is checked only for the commits the remote lacks; a
pushed message trailer and author email are refused; a force push over a remote commit this
clone never had works; an annotated tag's message is refused. Cases found in review: an added
line starting with `++ `, a leak added while resolving a merge, a pure rename, an empty file's
name, a tab in a file name, a local name joined by `_`, an encoded `~/.claude/projects/` folder,
a dangling symlink, a linked worktree, a broken rule (it must stop the check with exit 2), a
tag inside a tag, a tag on a blob or a tree, a commit hidden by `git replace`, a merged tag's
`mergetag` header, text after a bare scissors line; and no false alarm on `--home-dir` or a
file of blank lines; a local name in a branch or tag name, a root commit with `log.showRoot=false`,
a message after a `\002` byte; the installed hooks still run on a branch without `.githooks`,
hooks used straight from `.githooks` refuse; a moved clone keeps its hooks; a `gpgsig` line in a
message body and a leak behind a stale tracking ref are refused; the installer keeps someone
else's hook and refuses while `core.hooksPath` points elsewhere; a remote with 60000 refs still
works; a git that fails part way (a missing object) stops the check with exit 2; a local file of only comments refuses nothing; a hand-made
`gpgsig-x` header is checked. `PRIVACY_MUTANTS=1 tests/privacy.sh` (about four
minutes) also breaks the checker and hooks 38 ways,
one at a time in a copy; each must make the test fail.

## What they change on the host

`asc.sh` and `dash.sh`: a temp folder (their HOME) and a tmux server of their own
(`tmux -L asc-test-<pid>`), both removed at the end. `sandbox.sh`: the image `asc-sandbox`, the
container `asc-sandbox`, the network `asc-sandbox-net` (kept only as the run's lock) and the
builder `asc-sandbox-builder`, all removed at the end unless `KEEP=1`; only those exact names
are ever removed.

## Limits

- `claude` is a fake (`tests/asc/bin/claude`). Its trust prompt and screens follow Claude Code
  as checked on the real one; if a later Claude Code changes them, check against the real one
  on a separate `tmux -L` server.
- The sandbox is Ubuntu 24.04, tmux 3.4 and systemd 255 only.
- `dash.sh` uses a fake `ip` (`tests/dash/bin/ip`: loopback and 192.0.2.77, the same on every
  machine), so the dashboard's reading of a real `ip -j addr` is not tested.
- `install.sh` is tested in the sandbox only (it needs root); the mutant runs cover `asctl`
  and the dashboard, not `install.sh`.
