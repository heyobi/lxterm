#!/bin/sh
# Builds the root file system the app bundles, on an arm64 Linux host: Debian's official
# image (digests verified by tests/linux/fetch-debian.sh) with a few everyday packages
# installed by apt itself, running in our interpreter (build/lxrun). Writes
# rootfs-debian.tar.gz in the current directory.
set -eu
T=${RUNNER_TEMP:-/tmp}
make build/lxrun
R=$T/debian
sh tests/linux/fetch-debian.sh "$R"
rm -f "$R/etc/resolv.conf"; cp /etc/resolv.conf "$R/etc/resolv.conf"
LXRUN_STATS=1 LXRUN_QUIET=1 timeout 2400 build/lxrun "$R" /bin/sh -c \
    'apt-get update && apt-get install -y --no-install-recommends python3 procps nano less curl ca-certificates && apt-get clean'
LXRUN_QUIET=1 build/lxrun "$R" /usr/bin/python3 -c 'import sys; print("debian python", sys.version.split()[0])'
# a friendlier first prompt: colours and a short welcome (only in this image's root's own files)
cat >> "$R/root/.bashrc" <<'EOF'

# LxTerm
export PS1='\[\e[1;32m\]\u@iphone\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
[ -z "$LXTERM_QUIET" ] && [ -r /etc/motd ] && cat /etc/motd && export LXTERM_QUIET=1
EOF
cat > "$R/etc/motd" <<'EOF'

Debian 13 on your iPhone, in LxTerm. apt works: try `apt update && apt install fastfetch`.
This is an unofficial project, not made or endorsed by the Debian Project.

EOF
rm -rf "$R"/var/lib/apt/lists/* "$R/etc/resolv.conf"
tar -czf rootfs-debian.tar.gz -C "$R" .
ls -la rootfs-debian.tar.gz
