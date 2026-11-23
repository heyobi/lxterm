# LxTerm: license and third-party notices

LxTerm (this repository: `core/`, `lxios/`, `tools/`, `tests/`, `scripts/`) is
Copyright (C) 2026 İbrahim Polat and contributors, free software under the GNU
General Public License, version 3 or later (`LICENSE`, SPDX `GPL-3.0-or-later`).
`core/` is shared with LiquidAPK (github.com/heyobi/apk-on-iphone); it contains no
code copied from other projects.

## Shipped inside the app

| Component | Where it comes from | License |
|---|---|---|
| xterm.js 5.5.0 and its fit addon | npm `@xterm/xterm`, `@xterm/addon-fit` | MIT (text in the app's `licenses/`) |
| Alpine Linux aarch64 minirootfs + python3 (installed with `apk`) | dl-cdn.alpinelinux.org, SHA-256 checked (`tests/linux/fetch-alpine.sh`) | per package: busybox GPL-2.0, musl MIT, apk-tools GPL-2.0, Python PSF, … (`/lib/apk/db/installed`) |
| Debian 13 arm64 root (`debian:trixie-slim`) + python3 (installed with `apt`) | official image on Docker Hub, digests checked (`tests/linux/fetch-debian.sh`); deb.debian.org | per package (`/usr/share/doc/*/copyright`): glibc LGPL-2.1, bash/coreutils GPL-3.0, dpkg/apt GPL-2.0, … |

Source for the distribution packages is available from the distributions
(Alpine: git.alpinelinux.org/aports; Debian: sources.debian.org / `apt source`).

Debian is a registered trademark of Software in the Public Interest, Inc.; Alpine
Linux is a trademark of its project. LxTerm is not affiliated with or endorsed by
either; the root file systems are their unmodified images.
