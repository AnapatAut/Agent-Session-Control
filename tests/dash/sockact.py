"""Socket activation as systemd does it, for tests/dash.sh (systemd-socket-activate starts its
program once): listen on PATH (mode 0600; its folder must be 0700), and each time a connection
waits while no program runs, start CMD with the socket as fd 3 (LISTEN_FDS=1, LISTEN_PID its
pid), the environment as given; "start N" appended to LOG as each starts. At most 10 starts,
then it ends; else until killed.
  python3 -I tests/dash/sockact.py PATH LOG CMD...
"""
import os
import select
import socket
import sys

path, log, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
s = socket.socket(socket.AF_UNIX)
old = os.umask(0o177)
s.bind(path)
os.umask(old)
s.listen(16)
for n in range(1, 11):
    select.select([s], [], [])
    with open(log, "a") as f:
        f.write(f"start {n}\n")
    pid = os.fork()
    if pid == 0:
        if s.fileno() != 3:
            os.dup2(s.fileno(), 3)
        os.set_inheritable(3, True)
        os.environ.update(LISTEN_FDS="1", LISTEN_PID=str(os.getpid()))
        try:
            os.execvp(cmd[0], cmd)
        finally:
            os._exit(127)
    os.waitpid(pid, 0)
