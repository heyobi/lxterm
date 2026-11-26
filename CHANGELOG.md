# Changelog

Pocket Distro was called LxTerm until November 2026. Versions are App Store versions;
builds in between go to TestFlight first.

## 1.0.2 — in TestFlight

**Faster AlmaLinux** (measured on an iPhone, AlmaLinux 10; details in [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md))
- `dnf --version` 4.2 s → 0.39 s; `dnf makecache` 2 min 22 s → 1 min 27 s.
- Fast start: dnf and yum continue from a process saved after dnf's imports instead of starting Python for every command. The snapshot renews itself when dnf, Python or a library it uses changes (an unrelated install keeps it).
- Libraries translated ahead of time: AlmaLinux's dnf stack (Python, libsolv, rpm, sqlite, OpenSSL and more) runs as code compiled into the app, built in CI for the image the app downloads and shipped only when every check command gives the interpreter's output byte for byte.
- Hardware AES and SHA instructions (they were up to a third of dnf's time), glibc's string functions on the host.
- Settings › Speed-ups turns the translated libraries and the fast start off, to compare.

**Services**
- `systemctl start/stop/restart/enable/status` and `journalctl`, the app's own (no init system): httpd and nginx start, serve and stop; enabled services start again when a tab opens.

**Reliability**
- Settings › Distributions › Repair: a fresh copy of a distribution that keeps `/root` and `/home`.
- DNS: the phone's servers are written again on every start and every new tab; lookups ask for IPv4 and IPv6 in turn (on some networks one of two parallel answers was lost, and every download waited out a timeout).
- Unpacking keeps files' modification times (Python recompiled every module on the first run after an install).
- The screen stays on while a command runs (Settings), so iOS does not pause a long install.
- Tabs show the distribution's name at the prompt in Debian too.

**Name**
- The app is now called Pocket Distro on the home screen, in Shortcuts and Siri, and in the Files app. The App Store listing changes with this release.

## 1.0.1

- Eight distributions: Debian (bundled), Ubuntu, Alpine Linux, Fedora, AlmaLinux, Rocky Linux, openSUSE Tumbleweed and Arch Linux ARM, from their official images and repositories, digests checked.
- Ports: listening servers with the program that opened them, a built-in browser.
- Shortcuts and Siri: run a command or a saved command; seven ready-made tools.
- The Files app: `/root/Files` under Locations, shared by every distribution.
- The accelerated engine (beta) for Debian tabs: the core as WebAssembly in WebKit.

## 1.0

- Debian 13 for arm64 on iPhone and iPad: apt, Python, git, ssh, tmux, job control, a key row for the terminal.
