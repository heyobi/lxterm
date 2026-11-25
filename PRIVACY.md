# LxTerm privacy policy

LxTerm does not collect, store or share any personal data.

- No accounts, no analytics, no advertising, no tracking.
- Linux (Debian, and any other distribution you download) runs entirely on your device, inside the app's own storage. Your files, installed packages and command history stay there; deleting the app deletes them.
- **Network.** The app contacts a server only when you ask it to download a distribution (Settings › Distributions): the official images come from Docker Hub (auth.docker.io, registry-1.docker.io and its download servers), Arch Linux ARM's packages from its mirrors (*.mirror.archlinuxarm.org). Like any download, those servers see your IP address; nothing else is sent. Programs you run in the terminal connect where you tell them to: for example `apt`, `dnf` or `pacman` download packages from their distribution's mirrors, `ssh` and `curl` reach the hosts you type. Those connections are yours, as on any computer.
- **Servers you start** (for example `python3 -m http.server`) listen on your iPhone; the Ports list and the built-in browser only read which ports are open, on the device.
- **Shortcuts and Siri.** Commands run from the Shortcuts app run on the device, like commands typed in a tab; their output goes only to the shortcut that ran them.
- DNS servers are read from your iPhone's settings so programs in the terminal can look up names.

Questions: open an issue at https://github.com/heyobi/lxterm/issues

Last updated: 25 November 2026
