#!/bin/sh
# Builds the two root file systems the app bundles, on an arm64 Linux host:
# the official Alpine minirootfs and Debian image (checksums verified by
# tests/linux/fetch-*.sh), each with python3 installed by its own package manager
# running in our interpreter (build/lxrun). Writes rootfs-alpine.tar.gz and
# rootfs-debian.tar.gz in the current directory.
set -eu
T=${RUNNER_TEMP:-/tmp}
make build/lxrun

R=$T/alpine
sh tests/linux/fetch-alpine.sh "$R"
cp /etc/resolv.conf "$R/etc/resolv.conf"
LXRUN_STATS=1 LXRUN_QUIET=1 timeout 900 build/lxrun "$R" /sbin/apk add --no-progress python3
LXRUN_QUIET=1 build/lxrun "$R" /usr/bin/python3 -c 'import sys; print("alpine python", sys.version.split()[0])'
rm -f "$R/etc/resolv.conf" "$R"/var/cache/apk/*
tar -czf rootfs-alpine.tar.gz -C "$R" .

R=$T/debian
sh tests/linux/fetch-debian.sh "$R"
rm -f "$R/etc/resolv.conf"; cp /etc/resolv.conf "$R/etc/resolv.conf"
LXRUN_STATS=1 LXRUN_QUIET=1 timeout 1800 build/lxrun "$R" /bin/sh -c \
    'apt-get update && apt-get install -y --no-install-recommends python3 && apt-get clean'
LXRUN_QUIET=1 build/lxrun "$R" /usr/bin/python3 -c 'import sys; print("debian python", sys.version.split()[0])'
rm -rf "$R"/var/lib/apt/lists/* "$R/etc/resolv.conf"
tar -czf rootfs-debian.tar.gz -C "$R" .
ls -la rootfs-*.tar.gz
