# LxTerm

**A real aarch64 Linux userland on a non-jailbroken iPhone.** Unmodified Alpine Linux
(musl, busybox, `apk`) and Debian 13 (glibc, bash, `dpkg`, `apt`) run on the phone
itself, in a no-JIT AArch64 interpreter with an in-process Linux system-call layer:
real `fork`/`execve`, pipes, signals and job control, a terminal with Linux's line
discipline, and snapshots that bring a shell back in a fraction of a second.

Not an emulated PC (iSH emulates 32-bit x86) and not a set of ported commands
(a-Shell): the distributions' own arm64 binaries, from their own images and mirrors.

<p>
<img src="docs/screenshots/sim-lxterm-chooser.jpg" width="180" alt="Choose Alpine or Debian">
<img src="docs/screenshots/sim-lxterm-alpine.jpg" width="180" alt="Alpine in LxTerm">
<img src="docs/screenshots/sim-lxterm-debian.jpg" width="180" alt="Debian in LxTerm">
<img src="docs/screenshots/sim-lxterm-resumed.jpg" width="180" alt="A shell resumed from its snapshot">
</p>

Status: **early demo** (simulator screenshots above; TestFlight builds for testing).

## How it works

```
Alpine / Debian arm64 binaries (unmodified)
        │  svc #0
core/proc.c   Linux syscalls on Darwin, Linux userland mode: processes (fork copies
              the address space, execve in place), pids/groups/signals between them,
              fake root, statx, sockets, DNS ...
core/tty.c    the terminal: pty slave with Linux's line discipline, termios, job control
core/cpu.c, simd.c   no-JIT AArch64 interpreter (Unicorn-difftested)
core/vm.c     sparse guest address space; core/snap.c snapshots
lxios/        the iOS app: xterm.js in a WKWebView, key row, root unpacking
```

The core comes from [LiquidAPK](https://github.com/heyobi/apk-on-iphone) (Android apps
on iPhone, same author), branch `linux-userland`, where it is developed and tested in
both modes; `core/UPSTREAM` names the commit copied here.

## Build and test

- Host (Linux): `make build/lxrun`, `sh tests/linux/fetch-alpine.sh ~/alpine`,
  `build/lxrun -i ~/alpine /bin/sh -l`; checks: `tests/linux/run_alpine.sh`,
  `run_debian.sh` (both with `net` for the package managers).
- CI (`.github/workflows/ci.yml`): Alpine and Debian checks on an arm64 runner, then
  the app in the iOS simulator (screenshots, measurements).
- TestFlight (`.github/workflows/testflight.yml`): roots built on Linux (python3
  installed by `apk`/`apt` running in the interpreter), signed on macOS, uploaded.

## License

GPL-3.0-or-later (`LICENSE`), third-party notices in `NOTICE.md`. Alpine Linux and
Debian are trademarks of their projects; LxTerm is not affiliated with or endorsed by
either.
