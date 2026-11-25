# LxTerm: license and third-party notices

LxTerm (this repository: `core/`, `lxios/`, `tools/`, `tests/`, `scripts/`) is
Copyright (C) 2026 İbrahim Polat and contributors, free software under the GNU
General Public License, version 3 or later (`LICENSE`, SPDX `GPL-3.0-or-later`).
`core/` is shared with LiquidAPK (github.com/heyobi/apk-on-iphone); it contains no
code copied from other projects.

## Additional permission: app stores (GPL-3.0 section 7)

As an additional permission under section 7 of the GNU General Public License,
version 3, the copyright holders of LxTerm give you permission to convey this
program, or a work based on it, through an application store (such as Apple's App
Store) whose terms of service or usage rules impose restrictions beyond those of the
GPL (for example, limits on the devices a downloaded copy may run on, or on copying
it), provided that the complete Corresponding Source of the conveyed version is
available to its recipients free of charge under the GPL, together with this
permission.

If you modify this program, you may extend this permission to your version, but you
are not obliged to do so. If you do not wish to do so, delete this permission
statement from your version. Every contribution to this repository is accepted under
this permission (`CONTRIBUTING.md`).

## Shipped inside the app

| Component | Where it comes from | License |
|---|---|---|
| SwiftTerm 1.18.0 (terminal view) | github.com/migueldeicaza/SwiftTerm | MIT (text in the app's `licenses/`) |
| Debian 13 arm64 root (`debian:trixie-slim`) plus python3, procps, nano, less, curl, ca-certificates and tmux (installed with `apt`) | official image on Docker Hub, digests checked (`scripts/make-roots.sh`); packages from deb.debian.org | per package, in Debian at `/usr/share/doc/<package>/copyright`: glibc LGPL-2.1, bash/coreutils GPL-3.0, dpkg/apt GPL-2.0, Python PSF, … |

The Debian programs are Debian's own binaries, unmodified. Their source code, for
the exact versions shipped, is available from Debian: sources.debian.org, or
`apt source <package>` after adding a `deb-src` line. LxTerm's own source is at
github.com/heyobi/lxterm.

Debian is a registered trademark of Software in the Public Interest, Inc. LxTerm
is not affiliated with or endorsed by the Debian Project.
