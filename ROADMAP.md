# Roadmap

Agent-Session-Control is a control panel for coding-agent sessions: Claude Code first, built so
other agents can be added. It grew out of tmux-claude-restore, which it replaces.

Built:

- **A session registry.** It lists every running agent session and every past conversation.
  The ones you care about become favorites. A favorite keeps its folder, session id, names,
  remote-control setting and permission mode, refreshed as it runs (`asctl`).
- **On and off.** Off: the agent exits and its tmux session closes. On: a new tmux session in
  its folder, with the same conversation resumed. A busy session is not turned off unless
  forced. Rename works while it runs; a restart only while it is idle.
- **Restore per session.** After a reboot, only favorites that were on and have resurrect on come
  back, one at a time (`asctl-boot.service`). tmux-resurrect and tmux-continuum are not needed
  (setup refuses while continuum's restore or boot is on).
- **Memory-aware starts.** A session starts only under a memory limit of your own (60 to 85%
  used) with room for its size (a restart excepted); boot and the watcher also wait for memory
  to be steady. A session that a kernel out-of-memory kill ended can come back by itself (a first
  `asctl setup` turns this on). That needs clear evidence of the kill, and happens at most once
  per 10 minutes, 30 once it keeps being killed (the watcher).
- **A dashboard.** One web page per Linux user, reached through a unix socket that other local
  users cannot open, behind `tailscale serve`. It installs as an app.
- **An event log** of every action: each favorite's last 200.
- **A tmux server of its own** (`asctl-tmux.service`). Restarting the dashboard or the watcher
  never ends a session, and one session's out-of-memory kill does not end the others.
- **A machine-wide install** (`sudo ./install.sh`). Each user opts in with `asctl setup`. It
  says the version it installs; `asctl --version` and the dashboard's Settings say which runs.
  A running dashboard moves to a new release by itself, and its open page with it.

Next:

- A rework of the dashboard's design.
- Agents other than Claude Code.
