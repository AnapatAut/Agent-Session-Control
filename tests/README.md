# Tests

Five scripts. None touches your own tmux, tmux config or systemd user units.

| Script | Time | Needs | Checks |
|---|---|---|---|
| `tests/lint.sh` | seconds | bash; `shellcheck` and `node` if installed | bash syntax and shellcheck for every script, Python compiles, app.js parses, the suites' check names (`tests/checknames.py`); the privacy check of every tracked file |
| `tests/asc.sh` | about 4 min (`ASC_MUTANTS=1`: about 85 min at 6 at a time) | bash, tmux, jq, python3 | `asctl`: live, fav, on, off, rename, restart, mode, rc, the event log, the watcher, boot, the tmux server unit and `asctl setup`, with a fake claude on a tmux server of its own and a fake systemctl (`tests/asc/bin`) |
| `tests/dash.sh` | about 1 min (`DASH_MUTANTS=1`: about 10 min) | bash, tmux, jq, curl, python3; node for the page's logic (skipped without) | the dashboard server: socket and folder modes, the login, Host, Origin and token checks, one request per connection, the API and its actions, past conversations, idle and SIGTERM exit, systemd socket activation; the notices (boot, setup, the watcher), the auto-restart setting, conversation lengths; the page's own logic (`tests/dash/page.js`: row reasons, history wording and folding) |
| `tests/sandbox.sh` | about 8 min | Docker, network for the build only | asctl under real systemd, in a container: the two suites above on a clean Ubuntu, the dashboard as user units, a real out-of-memory kill, the watcher, the units from a checkout, the machine install (`install.sh`) and `asctl setup` by a second user, a reboot, then `setup --remove` and `--uninstall` |
| `tests/privacy.sh` | seconds (`PRIVACY_MUTANTS=1`: about two minutes) | bash, git | the privacy check and its hooks catch each kind of leak and let the allowed cases through |

```bash
tests/lint.sh
tests/asc.sh                 # prints ok/FAIL per check and a summary; exit 0 = all passed
ASC_MUTANTS=1 tests/asc.sh   # also each mutant: one safeguard broken in a copy must make it fail
tests/dash.sh
tests/sandbox.sh             # KEEP=1: leave the container up; --down removes what a run left
```

In `asc.sh` and `dash.sh` each check prints `  ok    NAME` or `  FAIL  NAME`, the same fixed
name both ways, and after a FAIL what was seen, each line indented further; `  skip  NAME` when
it cannot run here. The lint
refuses a name with a value in it (a pid, an id, a time) or used twice in a suite, so a name
means the same check in every run.

Mutant runs (`tests/mutate.sh`) run 8 copies at a time, each stopping at its first FAIL, and
print the check that caught each mutant. Do not edit a test script while it runs: bash reads a
script as it goes, and the run breaks.

## The sandbox

`tests/sandbox.sh` builds `tests/sandbox-asc/Dockerfile` (Ubuntu 24.04 booting real systemd,
two lingering users, the repo's tracked files in `/opt/asc`) with a throwaway buildx builder,
and runs one container with no network but loopback, no mounts, no published ports, not
privileged, no new privileges, fewer capabilities, 1 GiB of memory and no swap, a process
limit and the highest OOM score. A check before any test aborts the run when that does not
hold. Root inside is still root on the host with fewer capabilities (systemd needs
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
`gpgsig-x` header is checked. `PRIVACY_MUTANTS=1 tests/privacy.sh` (about two
minutes) also breaks the checker and hooks 37 ways,
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
