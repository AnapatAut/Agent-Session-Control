# Throwaway machine for tests/container.sh: Ubuntu 24.04 (tmux 3.4) booting real systemd,
# with a fake `claude` (see ./claude). Users:
#   fresh (2001, linger)  new machine
#   old   (2002, linger)  upgrade from the first version, existing ~/.tmux.conf
#   nosd  (2003)          no linger, so no systemd user manager
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	systemd systemd-sysv dbus dbus-user-session tmux jq git ca-certificates procps less gawk \
	&& rm -rf /var/lib/apt/lists/*
# gawk is there for one test (other distributions' default awk); awk stays Ubuntu's mawk.
RUN update-alternatives --set awk /usr/bin/mawk
# Linger stored the way `loginctl enable-linger` stores it.
RUN useradd -m -s /bin/bash -u 2001 fresh && useradd -m -s /bin/bash -u 2002 old \
	&& useradd -m -s /bin/bash -u 2003 nosd \
	&& mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/fresh /var/lib/systemd/linger/old
COPY claude /usr/local/bin/claude
RUN chmod 755 /usr/local/bin/claude
STOPSIGNAL SIGRTMIN+3
# Docker mounts the cgroup tree read-only; systemd needs it writable (own cgroup namespace only).
ENTRYPOINT ["/bin/sh", "-c", "mount -o remount,rw /sys/fs/cgroup && exec /sbin/init"]
