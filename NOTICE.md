# Pocket Distro: license and third-party notices

Pocket Distro, formerly Pocket Distro (this repository: `core/`, `lxios/`, `tools/`, `tests/`, `scripts/`) is
Copyright (C) 2026 İbrahim Polat and contributors, free software under the GNU
General Public License, version 3 or later (`LICENSE`, SPDX `GPL-3.0-or-later`).
`core/` is shared with LiquidAPK (github.com/heyobi/apk-on-iphone); it contains no
code copied from other projects.

## Shipped inside the app

| Component | Where it comes from | License |
|---|---|---|
| SwiftTerm 1.18.0 (terminal view) | github.com/migueldeicaza/SwiftTerm | MIT (text in the app's `licenses/`) |
| Debian 13 arm64 root (`debian:trixie-slim`) plus python3, procps, nano, less, curl, ca-certificates and tmux (installed with `apt`) | official image on Docker Hub, digests checked (`scripts/make-roots.sh`); packages from deb.debian.org | per package, in Debian at `/usr/share/doc/<package>/copyright`: glibc LGPL-2.1, bash/coreutils GPL-3.0, dpkg/apt GPL-2.0, Python PSF, … |

## Downloaded when you choose them (Settings › Distributions)

| Distribution | Where it comes from | Sources |
|---|---|---|
| Ubuntu 26.04 LTS | official image `ubuntu:26.04` on Docker Hub, digests checked | launchpad.net/ubuntu |
| Alpine Linux | official image `alpine:latest`, digests checked | gitlab.alpinelinux.org/alpine/aports |
| Fedora | official image `fedora:latest`, digests checked | src.fedoraproject.org |
| AlmaLinux 10 | official image `almalinux:10`, digests checked | git.almalinux.org |
| Rocky Linux 10 | official image `rockylinux/rockylinux:10`, digests checked | git.rockylinux.org |
| openSUSE Tumbleweed | official image `opensuse/tumbleweed`, digests checked | build.opensuse.org |
| Arch Linux ARM | its own repositories, package by package, each checked against the repository database's SHA-256; pacman then checks their signatures | github.com/archlinuxarm/PKGBUILDs |

None of them is modified. Each package's license is in that distribution, usually under
`/usr/share/licenses` or `/usr/share/doc`. The names are trademarks of their owners
(Canonical Ltd., the Alpine Linux project, Red Hat, Inc., the AlmaLinux OS Foundation,
the Rocky Enterprise Software Foundation, SUSE LLC, Judd Vinet and Aaron Griffin);
Pocket Distro is not affiliated with or endorsed by any of these projects.

## Debian

The Debian programs are Debian's own binaries, unmodified. Their source code, for
the exact versions shipped, is available from Debian: sources.debian.org, or
`apt source <package>` after adding a `deb-src` line. Pocket Distro's own source is at
github.com/pocketdistro/pocketdistro.

Debian is a registered trademark of Software in the Public Interest, Inc. Pocket Distro
is not affiliated with or endorsed by the Debian Project.
