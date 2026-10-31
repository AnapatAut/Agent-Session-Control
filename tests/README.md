# Tests

Six scripts. None touches your own tmux, `~/.tmux.conf` or systemd user units.

| Script | Time | Needs | Checks |
|---|---|---|---|
| `tests/lint.sh` | seconds | bash; `shellcheck` if installed | bash syntax and shellcheck for every script; the privacy check of every tracked file |
| `tests/asc.sh` | about 30 s (`ASC_MUTANTS=1`: minutes) | bash, tmux, jq, python3 | `asctl`: live, fav, on, off, rename, mode, forget, with a fake claude on a tmux server of its own |
| `tests/privacy.sh` | seconds (`PRIVACY_MUTANTS=1`: about a minute) | bash, git | the privacy check and its hooks catch each kind of leak and let the allowed cases through |
| `tests/container.sh` | about 3 min | Docker, network (apt, GitHub) | everything below; each case in a throwaway systemd container of its own |
| `tests/killsweep.sh` | about 3 min | Docker, network (apt, GitHub) | a kill before every step of install, upgrade and uninstall, and inside the writes |
| `tests/mutants.sh` | about 15 min (`MUTANTS_FULL=1`: about 2 h) | Docker, network | each safeguard broken on purpose must make a test fail |

Run the first three before changing `install.sh`, the hook scripts, or a plugin pin, and
`tests/mutants.sh` after changing a safeguard:

```bash
tests/lint.sh
tests/container.sh          # prints ok/FAIL per check and a summary; exit 0 = all passed
tests/killsweep.sh          # prints only the FAIL lines and the totals; exit 0 = all passed
TCR_ONLY=xdg,ro tests/container.sh      # only these cases (names: the case_* functions)
TCR_ONLY=ro tests/container.sh --keep   # one case, its container left running to look around
TCR_SWEEP=install,write tests/killsweep.sh   # only these kinds of kill-sweep case
```

`container.sh` runs each case (one user's block, or `core`: stages 1–8, which build on each
other) in a fresh container of its own, `TCR_JOBS` (default 4) at a time, and prints them in
order. With `TCR_LOGS=<folder>` set, a whole run of either script copies its logs there
(`mutants.sh` does this for its baseline); otherwise none are kept.

Do not edit a test script while it runs: bash reads a script as it goes, and the run breaks.

## The sandbox

`tests/lib.sh` holds what both container scripts share. It builds `tests/sandbox/Dockerfile`:
Ubuntu 24.04 (tmux 3.4, mawk as `awk`, gawk installed for one test) booting real systemd, with
lingering users, so `tmux.service`, the
autosave timer, reboots and crashes behave as on a real machine. `tests/sandbox/claude` is a
fake `claude`: it shows the home-folder trust prompt the way Claude Code 2.1.310 does (layout
captured from the real one), writes `~/.claude/sessions/<pid>.json` once past it, exits on
SIGTERM, and logs its arguments to `~/claude-args.log`.

The code under test is your working tree (`install.sh` and the 3 hook scripts). The first
commit in git history serves as the "first version" for the upgrade tests (it had no manifest).
A copy of the working tree with one unit and one script changed serves as an "old version"
that had one.

The plugins are cloned once from GitHub into a mirror, mounted read-only. Test users get a
`url.<mirror>.insteadOf` line in their git config, so `install.sh` clones the same URLs from the
mirror. User `fresh` has no such line: the new-machine stage clones from GitHub itself.

`snap` lists every path in a test user's home with its type, mode and content hash, minus
saves and logs (`~/.local/share`, `~/.claude`, `~/claude-args.log`). "Byte-identical" below
means two such lists are equal.

## What `container.sh` covers

1. **New machine** (tmux off): plugins at their pins, the user's own option value kept,
   tmux started as `tmux.service`, timer active, drop-ins loaded, `systemd-analyze verify`,
   `--check` exit 0, manifest written without `pending` (folder 0700, file 0600), no backup
   file, re-run changes nothing and takes no step.
2. **Save rules:** direct claudes recorded with folder (one with a space) and rc state; nested
   claude skipped; a session file with an empty field skipped; the pending lock blocks saves.
3. **Autosave with no client attached** (interval set to 1 min to keep it short), and no
   journal lines from the per-minute runs.
4. **Crash** (`kill -9` of the tmux server): the last save survives, `tmux.service` is not
   left failed, a restart restores every claude and answers the trust prompt.
5. **Upgrade from the first version** (no manifest) with tmux running and a config of the
   user's own: only the block's header line changes, no new backup, own values and plugin lines
   kept, old hand-added hook line replaced, the manifest records the config without our parts.
6. **Clean reboot** (`docker restart`): tmux.service starts without a login, every claude comes
   back with its conversation, folder and rc state, including one started after the last save.
7. **Drift:** `--check` exits 4 on a changed or stopped timer; `install.sh` repairs both.
8. **Uninstall:** config restored byte for byte, our units and scripts removed, plugins and
   `tmux.service` kept and listed as no longer needed, `--check` then says not installed,
   second uninstall harmless, reinstall clean.
9. **Refusals change nothing:** no user manager reachable (user `nosd`), root, a config in a
   read-only folder; `--dry-run` lists the steps and changes nothing; an unknown option exits 2.
10. **Symlinked config, closed pipe, inherited `GIT_DIR`:** the link stays a link;
    `install.sh | head -n1` and `--uninstall --autoremove | head -n1` exit 0 and finish, and the
    home is byte-identical afterwards; with `GIT_DIR` pointing at another repo, the plugins
    are at their pins and that repo is untouched.
11. **Interrupts**, sent to the process group as a terminal does, during a slowed-down clone:
    the first SIGINT, SIGTERM or SIGHUP lets the clone finish and stops before the next step
    (exit 3), `--check` reports it (exit 4), a rerun finishes it; a second SIGINT stops at
    once, the clone is not killed, a rerun finishes and an uninstall leaves the home
    byte-identical; under `nohup` a SIGHUP is ignored and the run completes; a SIGINT while a
    plain command runs (a slowed-down `mv`) lets it finish, and the run stops before the next
    step.
12. **Pending runs and the lock:** `--check` names the command that finishes a killed install
    or uninstall; install refuses (exit 1, nothing changed) while an uninstall is unfinished;
    with the lock held, install and uninstall refuse and change nothing; a plain tmux server
    started by install does not keep the lock.
13. **`--autoremove`** keeps a plugin that is off its pin, has a file of the user's, is a
    symlink, or is still named by an `@plugin` line, and keeps `tmux.service` while
    tmux-continuum stays; it removes the rest. (Stage 14 adds a file hidden by
    `status.showUntrackedFiles=no` and a commit on a local branch.)
14. **Edge cases:** the user's config edits made between two installs survive uninstall (with and
    without a config of their own before); a block missing its end line makes install and
    uninstall refuse (exit 1, nothing changed); a killed `--autoremove` after a plain
    uninstall is reported by `--check` and finished by a plain `--uninstall`; no `claude` on
    PATH is a warning, not a failure; two first installs at the same time end healthy, each
    exiting 0 or 1; a `tmux.service` of the user's own gets no drop-in and is never changed or
    removed; a commented-out `@plugin` line does not count as one; with tmux running and the
    plugins already there, `tmux.service` is never written and not recorded as brought in; a
    config with a Latin-1 byte, CRLF lines and no final newline comes back byte for byte under a
    UTF-8 locale, with mawk and with gawk; a gitconfig fsmonitor hook that leaves a process
    running is never run by our git calls, so nothing keeps the lock; an edit the user saves to
    `~/.tmux.conf` while install or uninstall runs (held open by a slowed-down `mv` or
    `systemctl`) stops the run with exit 3 and is kept, and a rerun finishes with it.
15. **Config in `~/.config/tmux`:** with only the XDG config, install puts the block and TPM's
    `run` line there, the plugins in `~/.config/tmux/plugins` (none in `~/.tmux`, no
    `~/.tmux.conf`), tmux-resurrect is loaded from there, the units name that folder, the save
    hook records a claude pane, and `--autoremove` leaves the home byte-identical. Hooks set
    but tmux-resurrect not loaded: `--check` exits 4, install repairs it. The config moved to
    the XDG file after install: `--check` exits 4, install refuses (nothing changed),
    uninstall works from the manifest's paths, then install into the XDG config works with
    tmux still running from the old one. Moved back from the XDG file to `~/.tmux.conf`:
    uninstall takes our lines out of `~/.tmux.conf` byte for byte and removes the XDG plugins.
    Refusals that change nothing: our block in `~/.tmux.conf` with no manifest once the XDG
    file exists, `TMUX_PLUGIN_MANAGER_PATH` set in the config, a plugin folder with a space.
    `--autoremove` keeps a plugin the other config file names. `@resurrect-dir` is honored
    by `--check` and uninstall's message.
16. **No systemd at all** (a second container without init): install exits 0 with a warning,
    starts a plain tmux server, writes no units; `--check` exits 0; uninstall leaves the home
    byte-identical.

## What `killsweep.sh` covers

It reads the number of steps n of each command from `--dry-run`, then, each on a new user
with a config of its own (an option, a comment, no final newline), 4 at a time:

- for install (also with the config in `~/.config/tmux`), upgrade from the "old version",
  upgrade from the first commit, `--uninstall --autoremove` and a plain `--uninstall`, and
  every k from 1 to n+1: run with `TCR_FAILPOINT=step:k`, which
  makes the run `kill -9` itself just before step k; expect exit 137; the user's own config
  lines are intact; rerun the same command until exit 0 (at most 4 tries); no temp file left;
  `--check` exits 0 and the manifest has no `pending`; the upgrade reached the new version; a
  final `--uninstall --autoremove` leaves the home byte-identical to before the first install.
  From the first commit, which kept no records, the check is that everything of ours is gone.
  After a plain `--uninstall`: the plugins are kept, everything else of ours is gone, only the
  record of the kept plugins is left (not pending), `--check` says not installed (exit 4), and
  `--autoremove` then leaves the home byte-identical.
- `TCR_FAILPOINT=write:<file>` for the manifest, `~/.tmux.conf`, a hook script and a unit:
  killed inside the atomic write, after the temp file is synced and before the rename. The
  file holds its old bytes (or is still absent), never a cut one; `--check` reports the
  unfinished run; the rerun removes the temp file and finishes; uninstall leaves the home
  byte-identical.

## What `mutants.sh` covers

Each mutant is an exact piece of code, its replacement, the test that guards it
(`killsweep.sh`, `container.sh` with `TCR_ONLY=later` for the stages from "Refusals" on, or the
full `container.sh`) and the check expected to fail. The script copies the working tree (with
its git history) once per mutant, applies the change, and runs that test. It reports CAUGHT
(the expected check failed), UNCLEAR (the test failed elsewhere: read the log) or SURVIVED (no
check caught it: write one). The unmodified copy must pass first. 57 mutants, one per
safeguard: the manifest written first, marked pending (install and uninstall) and cleared
last, temp-file cleanup, atomic writes, the state folder's removal, the kill window's
records, the config restore and its record of the first install, the config's `was` hash and
the edit-during-a-run checks (install and uninstall), the interrupt flag, the second
interrupt and the supervisor, the lock and its descriptor, writing through a symlink, the root and user-manager
refusals, a block with a missing marker, the closed pipe, `GIT_DIR`, the `--autoremove`
conditions, finishing an uninstall from the leftover record, the exit code of an unexpected
error, a missing `claude`, systemd detection, the two systemd drop-ins and a `tmux.service`
of the user's own, a commented-out `@plugin` line, an `@plugin` URL and a sourced config, the
lock held by children but not by tmux, git config that could start a lasting process, the
user's own hooks, and the config-file choice: the XDG config, tmux-resurrect loaded from the
plugin folder, a config moved either way after install, our lines in the other file, a
plugin the other file names, `TMUX_PLUGIN_MANAGER_PATH` reset and refused, an unsafe plugin
folder, `@resurrect-dir`, and the hook scripts finding tmux-resurrect. `run_child`'s own session has
no mutant: since the supervisor, no terminal signal reaches the worker's group, so no test can
tell it apart; it stays as a second layer.

Fast mode, the default: each mutant names its selection, the case (`case:xdg`), the
kill-sweep kinds (`sweep:install`) or `core` that holds its expected check, and runs only
that, in a fresh container. A mutant not CAUGHT there runs again on its whole suite, and that
run gives the verdict, marked "(full)". So the fast mode saves time; the verdicts are those
of the slow mode (`MUTANTS_FULL=1`, every mutant on its whole suite), except that a mutant
whose selection lacks its check is BROKEN, to be fixed.

The baseline: both whole suites, run unmodified at the start of the same `mutants.sh` run (in
both modes), on the same copy of the files, image and mirror; none is kept from one run to
the next. Every case must pass there with its machine sound, or the run stops.

A CAUGHT, in either mode, needs all of:
- a FAIL on exactly a check that was `ok` in the baseline (not just one that holds the text);
  in the fast mode, in the mutant's selection, which must have run more than 0 checks there;
- the machine of that case (or of the kill sweep, with every case finished) sound at its end:
  `systemctl is-system-running` running or degraded, no test user's manager died during the
  case, no sign in its journal of running out of inotify instances, open files or memory
  (a case that stopped part-way has no health line: for example one whose setup never got
  to a step its checks need, such as a fake's mark or a lock held);
- a trusted run: the host never short of memory or CPU during it (below 15% of memory
  available, a kernel OOM kill, or tasks waiting for a CPU 30% of the time or more, from
  `/proc/pressure/cpu`; the tally shows the lowest and the highest seen), and within its
  time limit (`MUTANTS_LIMIT`, 900 s; a whole suite three times that);
- the same check failing again in a second run of that case (or those kinds) alone, so a
  one-off failure of the host, of docker or of timing never counts.

A SURVIVED needs a trusted whole-suite run that passed with every machine sound; anything
else is UNCLEAR, with the reason. More rules:
- every mutant, the baseline and the image are made from one copy of the files, so an edit to
  the working tree during the run changes nothing;
- `case:core` is refused (BROKEN): its whole suite would skip core; the selection is `core`;
- an expected check whose name occurs twice in one case is refused (BROKEN): a FAIL of its
  twin would count as its own;
- every plugin pin must be in the mirror, and every run uses it, core too (a GitHub outage
  must not fail a check);
- whole-suite reruns run one case at a time (`TCR_JOBS=1`): `JOBS` of them already run side
  by side;
- it starts itself once more, without `BASH_ENV`, exported functions or `GIT_*` variables,
  and refuses a docker daemon that is not local.

An interrupt (Ctrl-C, TERM, a closed terminal) stops every process of the run (found by
`TCR_PARENT` in its environment, an orphan too) and waits until they are gone; it then
removes every container left with the run's own label, until none has appeared for 10 s (a
`docker run` in flight creates its container late), then the image and the work folder, which
holds the suites' own temp folders too.

One image and one plugin mirror serve every run. It ends with a tally and exits 0 only when
every mutant was caught.

```bash
tests/mutants.sh                     # all, 4 at a time (JOBS=n to change)
tests/mutants.sh no-lock pipe-kills  # only these
MUTANTS_FULL=1 tests/mutants.sh      # every mutant on its whole suite (the slow mode, 2 at a time)
```

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

Docker: one image per script run (`mutants.sh` builds one for all its runs), one container
per `container.sh` case (`tcr-test-<pid>-<case>`) and one for the kill sweep
(`tcr-sweep-<pid>`), all removed at the end unless `--keep`, plus a short-lived container in
the `nosystemd` case; the build cache keeps the Ubuntu layers for the next run. The plugin
mirror and the staged code live in a temp folder, removed at the end. No logs are kept, unless
`TCR_LOGS` names a folder for them.

The container needs more than the default rights, because systemd must manage cgroups:
`--cap-add SYS_ADMIN`, `--security-opt apparmor=unconfined`, its own cgroup namespace, and
the entrypoint remounts `/sys/fs/cgroup` read-write (the container's own cgroup tree only). It
is not `--privileged` and mounts no host paths except temporary copies of the scripts and the
mirror, read-only. With `SYS_ADMIN` and no user namespace, root in a container could remount
those read-write. What runs as root there is the tests' own code and, in the refusal tests,
`install.sh` under test (one mutant lets it run on as root): code from this repo, never from
outside, so this is a known limit, not a hole. The docker daemon must be local (a unix
socket): the mounts are this machine's paths. Not set yet, to be measured first: `--network none`, memory and process limits.

## Limits

- `claude` is a fake. The trust-prompt text and layout match Claude Code 2.1.310; if a later
  Claude Code changes that prompt, check it against the real one (`claude` in an untrusted
  folder, on a separate `tmux -L` server, without answering).
- Ubuntu 24.04 / tmux 3.4 / systemd 255 only.
- Not tested: a full disk, and a filesystem that becomes read-only during a run. Atomic writes
  mean the old file stays and the step fails with exit 3.
