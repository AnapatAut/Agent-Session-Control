# Agent-Session-Control

A control panel for Claude Code sessions in tmux. You mark the conversations you care about as
favorites, and turn each one on (a tmux session in its folder, the conversation resumed) and off
from a command line (`asctl`) or a dashboard behind `tailscale serve`. After a reboot only the
favorites with resurrect on come back, one at a time, once there is memory for them. What is
built and what comes next: [`ROADMAP.md`](ROADMAP.md).

Linux with systemd only (it reads `/proc`, and each user's units run in their systemd user
manager). Needs tmux (3.x; built with systemd, as distribution packages are, for the pane
scopes below), Python 3.9 or newer (standard library only), and Claude Code.

**Contributing:** install the privacy hooks once per clone, `tools/install-hooks.sh` (again after
changing them). They refuse a commit or push that names a machine, a user, a claude.ai session
or a credential ([`tools/privacy-rules`](tools/privacy-rules)). They run from copies inside
`.git`, so checking out an older commit does not turn them off. Your own real names (host, users, logins,
addresses) go in `.git/privacy-local`, one per line: it is inside `.git`, so it is never
committed. `tests/lint.sh` runs the same check on every tracked file.

## Install

**For the whole machine**, from a checkout, as root:

```bash
sudo ./install.sh              # install, or upgrade to this checkout
sudo ./install.sh --uninstall  # remove it (refused while a user still has it set up)
```

The code goes in `/opt/agent-session-control/releases/<id>`. It belongs to root and users can
only read it. `current` points at the release in use, and `/usr/local/bin/asctl` at
`current/bin/asctl`. The units go in `/etc/systemd/user/`, enabled for no one. An upgrade
switches `current` with one rename. A running asctl keeps the release it started from; this
release and the one before it stay, older ones go once no process runs them. The installer
copies the checkout once, refusing a link at any level, and reads nothing from it after that.
It refuses, changing nothing, when a path it would write is not its own (a folder or
`/usr/local/bin/asctl` it did not make, a unit file it did not write, a unit file changed
since: keep a change in a drop-in, `<unit>.d/`). Users' managers read changed units at their
next `systemctl --user daemon-reload`.

**Each user** who wants it then runs, as themselves, in a login session of their own (not as
root, not through `sudo -u` or `su`: it needs that user's systemd manager):

```bash
asctl setup                    # shows what it will do and asks; --yes does not ask
asctl setup --remove           # off again: favorites, the event log and the settings stay
```

Setup refuses, changing nothing, while an older tmux-claude-restore install is there (remove it
first with its own `install.sh --uninstall`; this repo has that installer up to commit
`dd28b57`), or while tmux-continuum's restore or boot is on (`set -g @continuum-restore 'off'`
and `set -g @continuum-boot 'off'` in your tmux config: a continuum restore brings every saved
session back at once, past boot's memory gates, and its boot turns its `tmux.service` on again).
It reads `~/.tmux.conf`, the XDG one, the files they `source-file` by a literal path, and the
running server's options. When only the running server still has one on (it read your config
before that said off), setup names the `tmux set -g @continuum-… off` commands that turn it off
there: they touch no session. Then it:

- writes `~/.config/systemd/user/tmux-spawn-.scope.d/asctl.conf` (in the folder your user
  manager reads), so that the kernel's OOM kill of one claude does not end its tmux session
  (`OOMPolicy=continue`);
- disables every other enabled user unit that runs tmux (directly, through `env` or a shell's
  `-c`, or as a template's instance), such as continuum's `tmux.service`; one that runs it
  through a script of its own is not seen. It never stops one: a stop ends every session, so the
  running server stays that unit's until the next boot. `setup --remove` enables it again;
- enables `asctl-tmux.service`, `asctl-boot.service`, `asctl-watch.timer` and
  `asctl-dash.socket`, and starts the timer and the socket.

It says when linger is off: without it the units start only once you log in, so after a reboot
nothing comes back until then (`sudo loginctl enable-linger NAME`). The server gets the user
manager's environment, not a login shell's: something your old tmux unit set in `Environment=`
(such as `DISPLAY`) goes in a drop-in, `~/.config/systemd/user/asctl-tmux.service.d/`.

**The dashboard** needs `~/.config/agent-session-control/dash.json` (it and its folder yours
and writable only by you):

```json
{"login": "<your Tailscale login>", "host": "<MagicDNS name>:<port>"}
```

and an admin's `tailscale serve`, one port per user (each user's dashboard needs an origin of
its own; see `asc/dash.py`):

```bash
sudo tailscale serve --bg --https=<port> unix:/run/user/<uid>/asctl/dash.sock
```

**A checkout of your own**, without the machine install: `tools/install-units.sh` writes the
units into `~/.config/systemd/user/` with that checkout's `bin/asctl` in them. A unit there that
is not the same is shown and left, unless `--force`. Your own units come before the machine's.
Then run `bin/asctl setup` from the checkout.

## asctl

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
                            # the mode the conversation last ran in, whichever it is (its transcript;
                            # a shift+tab change carries over); this one only when none is found
asctl rc 0421 on --title "DB work"   # remote control: a running claude at once when idle,
                            # else from its next start (--next-start: only the setting)
asctl resurrect 0421 on     # bring it back after a reboot (turns rc on; a resurrect start always has rc)
asctl note 0421 "talks to the API"
asctl rename 0421 db        # db-0421; a running claude, when idle, gets /rename db-0421,
                            # which claude also sends to its claude.ai session (the rc title)
asctl restart 0421          # off and on again (--resume), only when idle and running nothing
asctl forget 0421
asctl events 0421           # what happened to it (on, off, rename, refused, ended, ...): its last 200
```

Every action is logged in `~/.local/state/agent-session-control/events.jsonl` (0600; one JSON
line each: time, who (cli, page, watch, boot), what, text). A refused action is logged as
`refused`, one that went wrong after changing something as `failed`. Each favorite keeps its
last 200 events, however old; anything else (machine events, a forgotten favorite's) goes after
7 days, and the file stays under 2 MB. Logging never stops an action.

It never starts a tmux server from its own process (the server would belong to it, and
restarting the dashboard would end every session): with no server running, On starts
`asctl-tmux.service`, which owns it. Every tmux target is exact (`=name`, `=name:`), every
command an argument list (no shell), and a session counts as live only when its PID runs, is a
claude (named `claude`, or Claude Code's version binary run as claude, as background jobs are)
and started when Claude Code's session file says. Tests: `tests/asc.sh`.

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

`asctl watch` is one run of the watcher (`asctl-watch.timer`, every 30 s; `asc/watch.py`). It
keeps 8 minutes of memory samples (available memory, and counters that only grow: PSI `full`,
pages swapped, OOM kills), warns once (event log and tmux) under 15% available, and for each
favorite whose claude runs alone in its own tmux session keeps its memory size (what the start
gate expects), follows a new session id (a branch, a rewind) and a new folder (`/cd`), and sends
a rename that claude was too busy to take. A favorite wanted on whose claude ended with its tmux
session still up is logged once, with its exit code and the memory evidence. With
`asctl auto-restart on` (off by default: it only logs) it is started again in its own pane when
all hold: ended by a signal (143 SIGTERM, 137 SIGKILL) in this boot, memory pressure seen around
that end, memory steady at 20% for 5 minutes with room for its size, not started again in the
last 30 minutes, its session one pane running only its shell, one restart per run. The watcher
never turns a favorite off or on; an entry an action is changing is left to the next run.

`asctl boot` (`asctl-boot.service`, once per boot) starts again the favorites with resurrect
on that were on, the one turned on last first, one at a time: each needs memory at 20% steady
for 5 minutes (so the first start comes 5 minutes after the boot at the earliest) and room for
its size; before the first it waits up to 2 minutes for claude.ai, then starts anyway. A
favorite whose tmux session is up already is left to the watcher. What waits is logged; after an
hour the rest are left for Start. After a tmux server that ended without a reboot:
`systemctl --user start asctl-boot.service`.

`asctl-tmux.service` (`Type=forking`) runs `asctl tmux-server`: a server kept up with no
session (`exit-empty off`), or nothing when one runs already (the old tmux unit's, on the day
of the switch: no second server). A stop or restart of it would end every session, so it
refuses a manual one (`RefuseManualStop`), and a kernel OOM kill in it does not stop it
(`OOMPolicy=continue`). `asctl-wrap` starts claude only once tmux has moved the pane into its
scope, so claude is in that scope too (forked before the move, it stayed in the server's
cgroup). Tests: `tests/sandbox.sh` (real systemd in a container: the units, the machine
install and setup, a kernel OOM kill, a reboot).

`asctl dash` serves a dashboard of the same for one Tailscale login, on a unix socket only its
user can open, meant to sit behind `tailscale serve`; it installs as an app (home screen,
launcher). The main page is a list (needs attention, on, off, running claudes not favorited,
past conversations, memory used; a running claude with a made-up name goes by its chat title,
as the Claude apps list it; a session's memory is the PSS of its pane's processes, shared
pages split, so the figures add up); a tap opens a session's sheet with On/Off, remote control
(live), resurrect, permissions, rename and forget, what claude itself last reported, how long
its conversation is (past 100,000 lines Claude Code stops sending it to claude.ai) and its
history (its last 200 events, by day, repeats folded). Notices say when asctl boot is bringing
favorites back after a reboot, when asctl is not set up for the user, and when the watcher has
not run for 5 min; Settings has the out-of-memory auto-restart switch.
Every request needs that login and host; every action the page's token and Origin; the config
must be its user's and writable only by them. A refused page shows only its title and icon;
the manifest's `x_title` names it for readers that list serve ports. See `asc/dash.py`;
tests: `tests/dash.sh`.

## Tests

See [`tests/README.md`](tests/README.md). None touches your own tmux, tmux config or systemd
units.
