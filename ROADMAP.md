# Roadmap

Agent-Session-Control grows from tmux-claude-restore into a control panel for coding-agent
sessions. Claude Code first; the design keeps other agents possible. Nothing below is built yet.

- **A session registry.** List every running agent session and every past conversation. Mark
  the ones you care about as favorites. A favorite keeps its folder, session id, names,
  remote-control setting and permission mode, refreshed as it runs.
- **On and off.** Turn a favorite off (the agent exits, its tmux session closes) and on again
  (a new tmux session in its folder, the same conversation resumed). A busy session is not
  turned off unless forced.
- **Restore per session.** After a reboot, only favorites with restore turned on come back.
  tmux-resurrect and tmux-continuum are no longer needed.
- **Memory-aware starts.** A session starts only when enough memory is free and steady. A
  session ended by an out-of-memory killer can come back on its own only with clear evidence
  of that, and not more than once per 30 minutes.
- **A dashboard.** A web page per Linux user, reached over a unix socket so other local users
  cannot reach it.
- **A machine-wide install.** One install for the whole machine; each user opts in.
- **A command line tool:** `asctl`.
