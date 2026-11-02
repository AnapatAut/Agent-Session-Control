# Agent-Session-Control

Agent-Session-Control starts from **tmux-claude-restore**, described below: it brings back the
Claude Code conversation of each tmux pane after a reboot. What comes next (a session
registry, an on/off dashboard, per-session restore) is in [`ROADMAP.md`](ROADMAP.md).

**Contributing:** install the privacy hooks once per clone, `tools/install-hooks.sh` (again after
changing them). They refuse a commit or push that names a machine, a user, a claude.ai session
or a credential ([`tools/privacy-rules`](tools/privacy-rules)). They run from copies inside
`.git`, so checking out an older commit does not turn them off. Your own real names (host, users, logins,
addresses) go in `.git/privacy-local`, one per line: it is inside `.git`, so it is never
committed. `tests/lint.sh` runs the same check on every tracked file.

## asctl (phase 1: registry, on and off)

`bin/asctl` keeps a registry of favorite Claude Code sessions and turns each one on (a tmux
session `NAME-ID` in its folder, the conversation resumed) and off (claude gets SIGTERM, then
its tmux session closes). Python 3 standard library only.

```bash
asctl live                  # running claudes: pid, session id, tmux session, folder
asctl fav 12345 --name das  # favorite one (by pid, session id or pane %N); its tmux session becomes das-0421
asctl list                  # favorites and their state
asctl off 0421              # refuses while claude works or another pane runs something; --force
asctl on 0421               # tmux session das-0421, claude --resume <id> --name das-0421
                            # (refused under 20% memory available, or if it would leave under 15%;
                            # --force-memory starts it anyway)
asctl mode 0421 manual      # its own permission mode: auto (default), manual, skip. A start follows
                            # the mode the conversation last ran in (its transcript; a shift+tab
                            # change carries over), skip only when set here; else this one
asctl rc 0421 on --title "DB work"   # remote control: a running claude at once when idle,
                            # else from its next start (--next-start: only the setting)
asctl resurrect 0421 on     # bring it back after a reboot (turns rc on; a resurrect start always has rc)
asctl note 0421 "talks to the API"
asctl rename 0421 db        # db-0421; a running claude, when idle, gets /rename db-0421,
                            # which claude also sends to its claude.ai session (the rc title)
asctl restart 0421          # off and on again (--resume), only when idle and running nothing
asctl forget 0421
```

It never starts a tmux server itself (the server would belong to asctl's process); a later
phase adds `asctl-tmux.service` to own it. Every tmux target is exact (`=name`, `=name:`), every
command an argument list (no shell), and a session counts as live only when its PID runs, is
named `claude` and started when Claude Code's session file says. Tests: `tests/asc.sh`.

`asctl rc` on a running favorite types `/remote-control <title>` (or `/remote-control` and
Disconnect in the dialog it opens) into that claude's own pane, only when claude is idle, the
pane not in copy mode and the prompt empty, and checks the screen and the session file before
and after. Otherwise it changes only the setting and says why. See `asc/rclive.py`.

A rename does not restart: `--resume` reconnects to the conversation's claude.ai session, which
keeps its title, so only `/rename` changes it. A conversation that once ran as a Claude Code
background job takes that job's recorded name back at every start (`nameSource: "peer"`).

A restart (`asctl restart`, `rename --restart`) goes ahead only when the
claude is idle and runs nothing: no command (each runs as a child bash that sources claude's
shell snapshot, a background one too) and no subagent (a recent subagent transcript not marked
finished and not ending in a final answer). The same counts as busy for Off.

`asctl dash` serves a dashboard of the same for one Tailscale login, on a unix socket only its
user can open, meant to sit behind `tailscale serve`; it installs as an app (home screen,
launcher). The main page is a list (needs attention, on, off, running claudes not favorited,
past conversations, memory used; a running claude with a made-up name goes by its chat title,
as the Claude apps list it; a session's memory is the PSS of its pane's processes, shared
pages split, so the figures add up); a tap opens a session's sheet with On/Off, remote control
(live), resurrect, permissions, rename and forget, and what claude itself last reported.
Every request needs that login and host; every action the page's token and Origin; the config
must be its user's and writable only by them. A refused page shows only its title and icon;
the manifest's `x_title` names it for readers that list serve ports. See `asc/dash.py`;
tests: `tests/dash.sh`.

## tmux-claude-restore

After the machine reboots or crashes, reopen the Claude Code conversation that was running in
each tmux pane: same conversation (`--resume <id>`), same folder, auto permission mode, and
remote control back on if it was on.

tmux-resurrect + tmux-continuum already bring back the tmux sessions, windows and folders,
but they only relaunch a short list of programs (vim, less, htop…). `claude` is not on it,
so panes came back as empty shells. This adds the missing piece.

Works for any user on the machine. Each user installs it for themselves.

Repo: `git@github.com:AnapatAut/Agent-Session-Control.git`.

## What is ours and what is not

**Ours** (this folder, first written 2026-10-15):
- `install.sh`
- `claude-lib.sh`, `claude-save.sh`, `claude-restore.sh`
- `README.md`, `ROADMAP.md`
- `tools/privacy-check.sh`, `tools/privacy-rules`, `tools/install-hooks.sh`, `.githooks/` (the privacy check)
- `tests/`: `lint.sh`; `container.sh`, an automated end-to-end test in a throwaway systemd
  container; `killsweep.sh`, which kills the installer before every step and checks that a
  rerun or an uninstall always ends clean (see [`tests/README.md`](tests/README.md))
- the managed block that `install.sh` writes into your tmux config, `~/.tmux.conf` or
  `~/.config/tmux/tmux.conf` (see [Which config file](#which-config-file))
- the manifest, `~/.local/state/tmux-claude-restore/manifest.json` (see
  [Manifest and interrupted runs](#manifest-and-interrupted-runs))
- `~/.config/systemd/user/tmux-claude-autosave.service` and `.timer`, written by `install.sh`
- two systemd drop-ins written by `install.sh` (see [Crash safety](#crash-safety)):
  `~/.config/systemd/user/tmux.service.d/tmux-claude-restore.conf` for tmux-continuum's
  `tmux.service`, and `~/.config/systemd/user/tmux-spawn-.scope.d/tmux-claude-restore.conf` for
  the scopes tmux runs each pane in

**From others:**
- **tmux-resurrect, tmux-continuum, tpm**: third-party, from `github.com/tmux-plugins`, by Bruno
  Sutic and contributors, MIT license. They do the tmux save and restore themselves: sessions,
  windows, panes, folders and pane contents. `install.sh` clones them at pinned commits (see
  [Plugin versions](#plugin-versions)); they are not copied here.
- **`~/.config/systemd/user/tmux.service`**: generated by tmux-continuum's boot feature
  (`@continuum-boot 'on'`, template in `tmux-continuum/scripts/handle_tmux_automatic_start/systemd_enable.sh`),
  including its `ExecStop=…/tmux-resurrect/scripts/save.sh` line. We did not write it, and
  `install.sh` does not edit it; our drop-in replaces its `ExecStop` lines.
- **Claude Code (Anthropic)**. The Claude restore relies on what Claude Code provides:
  - the `~/.claude/sessions/<pid>.json` files, which say which session runs in which pane;
  - `claude --resume <id>`;
  - `--permission-mode auto`;
  - `--settings '{"remoteControlAtStartup":true}'`.
- **System tools**: tmux itself, jq, git, systemd, loginctl.

**Where ours hooks in.** The Claude part sits on top of tmux-resurrect. It uses resurrect's
official hook options (`@resurrect-hook-post-save-all`, `@resurrect-hook-post-restore-all`). It
also sources resurrect's internal `variables.sh` and `helpers.sh` (for `resurrect_dir`), which are
not a public interface. That is why `install.sh` pins the plugin versions.

## Sudo

Mostly not needed:
- The plugins install into your home (`~/.tmux/plugins/`, or `~/.config/tmux/plugins/`).
- `tmux.service` and the autosave timer are user units in `~/.config/systemd/user/`, run by
  `systemctl --user`.

Sudo is needed for two things only:
- **Linger**, once per user: `sudo loginctl enable-linger <user>`. It lets that user's systemd
  start at boot without a login, so tmux (and the restore) comes back after a reboot.
- **Packages**, if missing: `tmux`, `jq`, `git` (apt).

## Install (each user, as themselves, no sudo)

New machine:

1. Install `tmux`, `jq`, `git` and `claude`.
2. Clone the repo: `git clone git@github.com:AnapatAut/Agent-Session-Control.git ~/src/agent-session-control`
   (any folder works; `install.sh` finds its own).
3. Run `bash ~/src/agent-session-control/install.sh`.
4. Turn on linger once: `sudo loginctl enable-linger $USER`.
5. Run `bash ~/src/agent-session-control/install.sh --check`: every line should be `[ok]`.

What `install.sh` does. It works out every change first, then runs them as numbered steps
(`--dry-run` prints them and changes nothing). Re-running it changes nothing when everything is
in place.

1. Checks that `tmux`, `jq` and `git` are there and warns if `claude` is not on PATH. Refuses,
   changing nothing, when run as root, or when the machine runs systemd but your user manager is
   not reachable from this shell (a `su` shell, or ssh without a login session).
2. Writes the manifest (see [Manifest and interrupted runs](#manifest-and-interrupted-runs)),
   marked as pending.
3. Clones `tpm`, `tmux-resurrect` and `tmux-continuum` into the plugin folder (see
   [Which config file](#which-config-file)) if missing, each at its pinned commit.
4. Copies the 3 scripts to `~/.tmux/scripts/`.
5. Writes the autosave timer, `tmux-claude-autosave.timer` (see
   [Autosave](#autosave-without-an-attached-client)), and the two drop-ins (see
   [Crash safety](#crash-safety)).
6. Adds a managed block to your tmux config, above TPM's `run` line, between
   `# >>> tmux-claude-restore >>>` and `# <<< tmux-claude-restore <<<`. It only adds options you
   don't already set; your own values win. No backup file: the manifest keeps the file's bytes
   from before the first install, for uninstall.
7. Reloads systemd and starts the timer.
8. If tmux is running: sets the hooks live (or reloads the config if the plugins were just
   installed, or tmux has not loaded them from the plugin folder), then runs a first save.
   If tmux is not running: starts it the way a boot does, as `tmux.service` (tmux-continuum's own
   script creates and enables that unit first, if it does not exist yet). Like a boot, this
   restores the last save, if there is one.
9. Runs the status check, then writes the manifest again, no longer pending.

On a machine that does not run systemd at all, the systemd steps are left out: tmux saves while
a client is attached, but there is no autosave without one and no start at boot.

`@continuum-boot 'on'` makes tmux-continuum keep `~/.config/systemd/user/tmux.service` enabled, so
tmux starts at boot. For it to start without anyone logging in, linger must be on. The status
report shows it, and the fix is `sudo loginctl enable-linger <user>`.

### Which config file

`install.sh` uses the files TPM uses at its pinned commit: `~/.config/tmux/tmux.conf` (or
`$XDG_CONFIG_HOME/tmux/tmux.conf`) when it exists, with the plugins in
`~/.config/tmux/plugins/`; otherwise `~/.tmux.conf` and `~/.tmux/plugins/`. tmux reads both
files, but TPM reads `@plugin` lines only from that one, so our block goes there. The scripts
stay in `~/.tmux/scripts/` either way.

The manifest records the config and the plugin folder. If you create, move or remove the XDG
config after install, `--check` says so and `install.sh` refuses: run `install.sh --uninstall`
(it works from the recorded paths, and also takes our lines out of the other file), then
`install.sh`. `--autoremove` keeps a plugin that either file names.

`--check` also checks that the running tmux loaded tmux-resurrect from the plugin folder. The
hooks are plain options, set even when TPM loaded nothing, and then nothing is saved.

## Check / upgrade / uninstall

```bash
bash ~/src/agent-session-control/install.sh --check       # status only, changes nothing
bash ~/src/agent-session-control/install.sh               # upgrade after a git pull; also repairs
bash ~/src/agent-session-control/install.sh --dry-run     # print the steps it would take
bash ~/src/agent-session-control/install.sh --uninstall   # remove block, hooks, scripts, our systemd units
bash ~/src/agent-session-control/install.sh --uninstall --autoremove   # also what install brought in
```

`--check` warns when your installed scripts differ from the clone, when a plugin is not at its
pinned commit, and when the last save is older than expected. Re-run `install.sh` to pick up a
new version.

**Uninstall** puts your tmux config back byte for byte when you have changed nothing outside our
block since the install: the bytes from before the first install (or no file, if install
created it). If you have changed it, uninstall removes only our block. It also removes hook
lines for these scripts that were added by hand before the installer existed. In a running
tmux it unsets only the hooks that run these scripts; a hook of your own stays.

**`--autoremove`**, the way `apt autoremove` handles dependencies: plain `--uninstall` keeps
the tmux plugins and the `tmux.service` that install brought in, and lists them as no longer
needed. `--uninstall --autoremove` also removes them, each only when install brought it in
(plugins and a `tmux.service` you had before always stay), it is unchanged (a plugin at its
pin with no file of yours in it, tracked, untracked or ignored, no stash and no commit only on
a local branch; a symlink is never followed; `tmux.service` with the hash it had when
tmux-continuum wrote it), and nothing still needs it (no
`@plugin` line for it left in your config, in any form tpm takes; a config that sources
another file keeps every plugin; `tmux.service` only when tmux-continuum goes too).
A running tmux keeps running. The resurrect saves, the pane list and the restore log always
stay.

### Exit status

| Code | Meaning | What changed |
|---|---|---|
| 0 | done (`--check`: healthy) | the whole change |
| 1 | refused | nothing |
| 2 | usage error | nothing |
| 3 | stopped part-way: a step failed, or the run was interrupted | the steps before it; rerun the same command to finish it, or `--uninstall` |
| 4 | `--check` found problems | nothing |

### Manifest and interrupted runs

The installer works the way dpkg does: it records what it is about to do, keeps every write
atomic, and lets the next run finish the job. Nothing is ever undone.

- **The manifest**, `~/.local/state/tmux-claude-restore/manifest.json` (folder 0700, file 0600:
  it holds a copy of your config), lists every file the installer writes with its hash, the
  folders it created, the plugins and `tmux.service` it brought in, and your config's bytes from
  before the first install. Step 1 of every run writes it marked `pending`; the last step
  rewrites it without.
- **Every write is atomic:** a temp file beside the target (through a symlink, so a dotfile
  manager's link stays a link), fsync, rename over the target, fsync of the folder. A kill or a
  power cut leaves the old file or the new one, never a cut one. Like `sed -i`, this gives the
  file a new inode: a hard link to `~/.tmux.conf` keeps the old content, and extended
  attributes and ACLs on it are not kept. The mode is kept; the owner is not: the new file
  is yours, even when a symlink points at a file of another user's in a folder you can write.
- **A failure, Ctrl-C or kill** stops the run with exit 3 (a kill shows as 137). Rerun the same
  command to finish it, or run `--uninstall`, which works from any state. `--check` reports an
  unfinished run (exit 4) with the command that finishes it; install refuses while an uninstall
  is unfinished.
- **Ctrl-C**: the first one lets the current step finish and stops before the next; a second one
  stops at once. No command a step runs is ever killed by it: install and uninstall run in a
  session of their own, and the process you started passes each Ctrl-C, SIGTERM or SIGHUP on
  to it. Under `nohup`, a hangup is ignored and the run completes.
- **Uninstall re-checks** the config and each plugin right before it changes them: an
  edit you save while it runs stops it (exit 3) instead of being overwritten.
- **One run at a time:** a second run is refused (exit 1) while one is working.
- **Installs from before the manifest** are upgraded in place; their config record is the
  config without our block.

### Known limits

Accepted on purpose, each rare or harmless:

- **Linux only:** systemd user units, `flock`, `setsid` and GNU coreutils (`stat -c`,
  `readlink -f`, `sync FILE`). Tested on Ubuntu 24.04 only (mawk and gawk for the config).
- **One state folder:** the manifest and the lock live under `$XDG_STATE_HOME` (default
  `~/.local/state`). Run every install and uninstall with the same `XDG_STATE_HOME`, or a run
  will not see the other's manifest.
- **One install per user:** two checkouts of this repo installing for the same user share it.
  The last run's scripts win, and an uninstall from either removes it.
- **Atomic writes replace the inode** (above): hard links, extended attributes, ACLs and the
  owner of the tmux config are not kept.
- **Full disk, or a filesystem that turns read-only during a run:** not tested. The atomic
  write leaves the old file, and the step fails with exit 3.
- **A config that sources another file:** `--autoremove` keeps every plugin, and an `@plugin`
  line in the sourced file is not seen, so our block may name that plugin a second time.
- **A hook option that runs our script and a command of yours:** uninstall unsets the whole
  option in the running tmux. Your config line comes back at the next tmux start.
- **Two tiny kill windows** leave an empty folder: between creating the state folder and the
  first manifest write, and between removing the manifest and its folder. The next install or
  uninstall removes the state folder by name; an empty `~/.local/state` it created stays.
- **`kill -9` of the process you started** leaves its worker to finish the run alone, as under
  `nohup`; Ctrl-C then no longer reaches it.
- **A home folder whose path is not valid UTF-8** is not supported (the manifest is JSON).
- **Plugins in a folder of your own** (`set-environment -g TMUX_PLUGIN_MANAGER_PATH` in the
  config): install refuses.
- **A plugin folder with a space or a quote in its path** (below the home): install refuses.
  The config's `run` line and the systemd units hold the path unquoted.
- **One `XDG_CONFIG_HOME` for install, tmux and systemd:** tmux and TPM choose the config by
  the tmux server's environment (under `tmux.service`, the systemd user manager's). If it
  differs from install's, `--check` reports tmux-resurrect not loaded. The units always go to
  `~/.config/systemd/user`; a user manager with `XDG_CONFIG_HOME` set elsewhere does not read
  them, and `--check` reports the timer not active.

## Plugin versions

`install.sh` clones each plugin from `github.com/tmux-plugins` and checks out a fixed commit
(`PIN` in `install.sh`):

| plugin | commit | date |
|---|---|---|
| tpm | `e261deb1b47614eed3400089ce7197dc68acc4eb` | 2026-05-17 |
| tmux-resurrect | `cff343cf9e81983d3da0c8562b01616f12e8d548` | 2023-03-06 |
| tmux-continuum | `0698e8f4b17d6454c71bf5212895ec055c578da0` | 2024-01-20 |

An upstream change therefore never reaches an install by itself. To move to a newer commit:
test it, change `PIN`, and commit. TPM's update key (`prefix + U`) does not work on the
pinned checkouts, and that is intended. Installs that already have a plugin are not changed;
`--check` warns and prints the `git checkout` that fixes it.

## Autosave without an attached client

tmux-continuum saves from the status line, and tmux only draws the status line while a
client is attached. When sessions are used only through Claude remote control, often no
client is attached, so continuum alone may not save for hours.

`tmux-claude-autosave.timer` runs every minute and calls continuum's own
`continuum_save.sh`. That script saves only when `@continuum-save-interval` (5 min) has passed
since the last save, and it holds continuum's lock, so it never doubles up with the
status-line autosave. Saves therefore come every 5 to 7 minutes with or without a client. When
no tmux server runs, the run does nothing. The service has `LogLevelMax=notice`, so the
per-minute runs do not fill the journal.

## Crash safety

tmux-continuum's `tmux.service` saves on stop with `ExecStop=…/tmux-resurrect/scripts/save.sh`.
systemd also runs `ExecStop` when the tmux server dies while the machine is up (crash,
`kill -9`, OOM kill). With no server, `save.sh` still writes a new save file, an empty one, and
points `last` at it. The next tmux start then restores nothing, and the Claude restore never
runs. (Found and reproduced 2026-10-25.)

The drop-in `~/.config/systemd/user/tmux.service.d/tmux-claude-restore.conf` replaces those
`ExecStop` lines. It saves with `tmux run-shell "…/save.sh quiet"`, which runs only through a live
server: with no server, `tmux run-shell` fails and nothing is written. A clean shutdown still
saves as before. After a crash, `last` still points at the last good save, so starting tmux again
(`tmux`, or `systemctl --user start tmux.service`) brings everything back.

A clean shutdown had a second problem. tmux runs each pane in its own systemd scope
(`tmux-spawn-<id>.scope`), outside `tmux.service`. At shutdown systemd stops those scopes at the
same time as `tmux.service`, so claude gets SIGTERM and exits while the stop save runs. The save
then records no claude, and after the reboot no conversation comes back. (Found 2026-10-25.) The
drop-in `~/.config/systemd/user/tmux-spawn-.scope.d/tmux-claude-restore.conf` applies to every
pane scope and sets `Before=tmux.service`. systemd then stops `tmux.service` (and so saves) first,
and the panes after.

## How it works

| When | Script | Does |
|---|---|---|
| Every tmux-resurrect save (every 5 min via continuum and the autosave timer; also `prefix + Ctrl-s`, and tmux.service stop) | `claude-save.sh` | Reads `~/.claude/sessions/<pid>.json` for every live interactive claude whose parent is a tmux pane. Writes `pane / session id / folder / rc 1-0` to `claude-panes.tsv` |
| After tmux-resurrect restore (tmux server start at boot) | `claude-restore.sh` | For each line: waits for network (max 2 min), waits for the pane's shell, types `cd <folder> && claude --permission-mode auto --resume <id>`, adds `--settings '{"remoteControlAtStartup":true}'` only if rc was on |

Files: scripts in `~/.tmux/scripts/` (`claude-lib.sh` holds the shared paths). Data lives in the
resurrect dir, usually `~/.local/share/tmux/resurrect/`:
- `claude-panes.tsv`: the current pane list.
- `claude-restore.log`: what each restore did or skipped.
- `claude-restore.pending`: exists only while a restore runs.

### Which sessions come back

The list is detected automatically; there is nothing to add by hand. A claude is tracked when it is
- interactive (not `claude -p`, not `claude --bg` background jobs), and
- the direct program in a tmux pane (not nested inside another program).

If you quit claude in a pane, the next save drops it, so it won't come back. The exception is a
crash within 5 minutes of quitting, before the next save; then it comes back once.
Restore runs only when the tmux server starts fresh, at boot or after a crash. Nothing
relaunches claude while the machine is up.

### Remote control

Restored as it was. A pane with rc connected at the last save (`bridgeSessionId` set) reconnects.
A pane without rc stays off. Turning rc off with `/rc` → Disconnect is picked up at the next save.

### Trust prompt for the home folder (security note)

Claude Code never remembers "Yes, I trust this folder" for your home directory. So a claude
started in `~` stops at that prompt on every boot. The restore script answers **Yes** only when
the prompt names the exact folder that pane was saved with, and checks that "Yes" is
highlighted before pressing Enter. It logs `trusted <folder>`. Any other trust prompt is left
for you. Folders you've already trusted for good, like project dirs, never show the prompt.

### Safety rails

- Panes that are busy (not at a bash/zsh/sh/fish prompt) are skipped and logged.
- Session ids are checked against the UUID format before being typed.
- Old session files left behind by a crash are ignored. Only a live claude counts.
- While a restore is running, saves don't overwrite the pane list, so a slow boot can't wipe it.
- The restore runs in the background, so it never holds up tmux startup.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Panes came back as empty shells | `claude-restore.log` (skipped? why?). `claude-panes.tsv` (was the pane listed?). `install.sh --check` |
| A pane is missing from the list | Is claude the pane's own program? (`tmux display -p -t <pane> '#{pane_current_command}'` should print `claude`). Wait up to 5 min for the next save, or press `prefix + Ctrl-s` |
| rc didn't reconnect | Was rc on at the last save (4th column = 1)? No network within 2 min of boot → run `/rc` by hand |
| Stuck on the trust prompt | Log says `left for user`: the folder didn't match, or the prompt looked different. Answer it by hand |
| `--check`: last save is old | `systemctl --user status tmux-claude-autosave.timer` (active?). Is tmux running? Re-run `install.sh` |
| Want a different permission mode | Edit `--permission-mode auto` in `claude-restore.sh` here, then re-run `install.sh` |

## Tested (2026-10-27, dpkg-style installer and XDG config, sandbox, tmux 3.4)

`tests/lint.sh`, `tests/container.sh`, `tests/killsweep.sh` and `tests/mutants.sh`; see
[`tests/README.md`](tests/README.md) for what each checks. Nothing on the live machine was
changed.

- **Container suite:** 217 checks passed. Besides the stages of 2026-10-25: the manifest and
  its permissions, a byte-exact config restore, refusals that change nothing (root, no user
  manager, read-only config folder, a pending uninstall, the lock), `--dry-run`, a symlinked
  config, `| head -n1`, `GIT_DIR`, interrupts sent to the process group (first and second
  SIGINT, SIGTERM, SIGHUP, `nohup`, and a SIGINT during a plain command), an unexpected error in
  a step, `--autoremove` keeping what it must (also hidden untracked files, local commits, URL
  `@plugin` lines, a sourced config), edits between installs kept, a broken block refused, two
  first installs at once, a `tmux.service` of the user's own, a Latin-1/CRLF config under mawk
  and gawk, a gitconfig fsmonitor hook, the config edited while a run is in progress, and a
  machine without systemd. For the config in `~/.config/tmux`: install, check and uninstall
  there; a config moved either way after install (refused, then uninstall from the recorded
  paths); our lines in the other file; `TMUX_PLUGIN_MANAGER_PATH` set in a config or left in
  a live server; a plugin folder with a space; `@resurrect-dir`; tmux-resurrect loaded into a
  server that never loaded it.
- **Kill sweep:** 129 kills (125 before a step of install, upgrade from a manifest version,
  upgrade from the first version, uninstall with `--autoremove` and plain uninstall, install
  with the XDG config, and kills then straight to uninstall; 4 inside the atomic writes), 1080
  checks passed: the user's own
  config lines were intact after every kill, every rerun or uninstall finished, and the home
  was byte-identical at the end.
- **Mutation test:** all 57 mutants caught.
- **Found and fixed while testing:** a manifest write that ran in a pipeline subshell (a kill
  left the write to finish on its own); the state folder created before step 1 (a kill there
  leaked `~/.local/state`); folders unrecorded after a kill inside the first manifest write;
  `tmux.service`'s hash recorded only at the end; a jq error in the tidy step.
- **Found and fixed in three fresh-context reviews:** a Ctrl-C killing a step's short
  commands (now a worker in its own session); an empty manifest from a killed `jq`; `--autoremove`
  missing files hidden by `status.showUntrackedFiles=no`, stashes and local commits; uninstall
  not re-checking the config and plugins before changing them; a run that lost the lock
  removing the state folder the winner used; a child left running after a second Ctrl-C not
  holding the lock; tidy skipped by an interrupt at the end; uninstall unsetting the user's own
  hooks; edits made between two installs lost on uninstall; a block missing a marker line.
- **Found by comparing with another project's installer review:** a git fsmonitor hook or
  detached gc from the user's gitconfig could leave a process holding the lock (now off for our
  git calls); `--check` printed `cat: write error` for units that differ.

## Tested (2026-10-25, sandbox, tmux 3.4, Claude Code 2.1.310)

To repeat these tests, run `tests/lint.sh` and `tests/container.sh` (see
[`tests/README.md`](tests/README.md)). The container run covers the systemd parts below.

Nothing on the live machine was changed. Two sandboxes:
- **systemd container** (Ubuntu 24.04, tmux 3.4, real systemd user managers, linger), several
  users, a fake `claude` that copies Claude Code 2.1.310's home-folder trust prompt (layout
  captured from the real one) and writes `~/.claude/sessions/<pid>.json` the same way.
- **live machine, isolated**: throwaway `HOME`, separate `tmux -L` server, fake `systemctl`.

Results:
- **New machine:** `install.sh` with tmux off cloned the 3 plugins at their pins, created
  `~/.tmux.conf` (no stray backup), wrote the units, let tmux-continuum create `tmux.service`,
  started it; `--check` all `[ok]`, exit 0. `systemd-analyze verify` passes on the units.
- **Upgrade from the 2026-10-15 version** with tmux running and a copy of the live
  `~/.tmux.conf`: only the block's header line changed (backup made), units added, hooks kept,
  first save ran. A re-run changes nothing.
- **Autosave, no client attached, 13 min:** saves every 6 min for 2 users (0 clients in all
  52 samples). The per-minute runs leave no journal lines.
- **Clean reboot** (2 rounds): tmux.service starts at boot through linger, every claude pane
  comes back with its conversation, folder (including one with a space) and rc state, and the
  home-folder trust prompt is answered. Panes started after the last autosave come back too
  (saved on stop). Without the pane-scope drop-in, the stop save recorded no claude (reproduced
  twice); see [Crash safety](#crash-safety).
- **Crash** (`kill -9` of the tmux server, 2 rounds): with the drop-in, `last` keeps the last good
  save and each restart restores everything. Without it, `last` pointed at an empty save.
- **Save rules:** nested, background (`kind` not interactive), stale and non-tmux sessions are
  skipped; the pending lock blocks saves; an empty field in a session file no longer shifts
  the columns.
- **Your options win** (`@continuum-save-interval '10'` kept), a plugin line you already have is
  not added twice, and old hand-added hook lines are replaced.
- **`--check`:** fails (exit 1) on a changed timer file or a stopped timer; `install.sh` repairs
  both.
- **No systemd user manager:** install warns, starts a plain tmux server, `--check` flags the
  timer.
- **Uninstall:** removes the block, hooks, scripts and all our units and drop-ins; keeps
  plugins and `tmux.service`; a second uninstall is harmless; reinstall gives the same result.

## Tested (2026-10-15, tmux 3.4, Claude Code 2.1.300)

These ran on a separate tmux server (`tmux -L`, own resurrect dir) with throwaway conversations,
so the real sessions were never touched:
- **Save → kill -9 → restore:** same conversation resumed, home trust prompt answered, auto mode on, rc reconnected.
- **rc:** on stays on, off stays off, and `/rc` Disconnect shows up as 0 at the next save.
- **Lock:** the pending lock blocks saves.
- **Crash leftovers:** an old session file isn't mistaken for a live claude.
- **Busy pane:** skipped.
- **Installer:**
  - fresh user (no plugins, tmux off) and fresh user with tmux running
  - existing config that already has the plugins and older hand-added hook lines
  - re-runs make no change, uninstall gives back the original config byte for byte, and a second uninstall is harmless
