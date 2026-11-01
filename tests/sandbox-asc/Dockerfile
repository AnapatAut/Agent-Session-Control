# Throwaway machine for tests/sandbox.sh: Ubuntu 24.04 booting real systemd, with one user
# (sbuser, linger on, so it has a systemd user manager) and the repo's tracked files in /opt/asc.
# Never used in production. Packages are baked in: the test network has no route out.
# Pinned by digest (a re-pointed tag cannot swap it). Bump: docker buildx imagetools inspect ubuntu:24.04
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session tmux jq python3 curl procps iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask systemd-sysctl.service systemd-udevd.service systemd-udevd-control.socket \
       systemd-udevd-kernel.socket systemd-modules-load.service systemd-remount-fs.service \
       systemd-firstboot.service getty.target console-getty.service \
       sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount \
       sys-fs-fuse-connections.mount dev-hugepages.mount systemd-binfmt.service \
       proc-sys-fs-binfmt_misc.automount systemd-hwdb-update.service systemd-random-seed.service \
       systemd-timesyncd.service systemd-resolved.service systemd-networkd.service \
    && useradd -m -s /bin/bash -u 2001 sbuser \
    && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/sbuser
COPY asc /opt/asc
