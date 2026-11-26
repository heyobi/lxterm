# Architecture

Pocket Distro runs a distribution's own arm64 programs inside an ordinary iOS app. There is no virtual machine and no kernel: the app interprets the programs' instructions and answers their Linux system calls itself. This page walks through the pieces, from a tap on "Download" to `dnf` starting in 0.4 s.

## The pieces

```mermaid
flowchart TB
    subgraph App["iOS app (SwiftUI, lxios/LxTerm)"]
        UI["Tabs, key row, themes<br/>Settings › Distributions"]
        Dl["Distribution downloads<br/>(Docker Hub registry, digests checked)"]
        Svc["systemctl / journalctl<br/>(the app's own, systemctl.sh)"]
        Int["Shortcuts and Siri<br/>(App Intents)"]
        Prt["Ports + built-in browser"]
        Fp["Files app<br/>(File Provider extension)"]
    end
    subgraph Core["Engine (C, core/, in the app's process)"]
        Interp["AArch64 interpreter<br/>cpu.c, simd.c (NEON, AES, SHA)"]
        Aot["Translated libraries<br/>aot.c + generated tables"]
        Fast["libc fast path<br/>lxfast.c"]
        Zyg["Fast start<br/>(snapshots, snap.c)"]
        Sys["Linux system calls<br/>proc.c, tty.c: processes, signals,<br/>terminals, sockets, files, futexes"]
    end
    Roots[("Distribution roots<br/>in the app's container")]
    Wasm["Accelerated engine (⚡)<br/>the same core as WebAssembly in WebKit"]
    UI --> Sys
    Int --> Sys
    Dl --> Roots
    Svc --> Sys
    Interp --- Aot
    Interp --- Fast
    Sys --- Interp
    Sys --- Zyg
    Sys --> Roots
    Prt -.->|listening sockets| Sys
    Fp -.->|/root/Files| Roots
    UI -.->|Debian tabs, optional| Wasm
```

| Piece | Files | What it does |
|---|---|---|
| Interpreter | `core/cpu.c`, `core/simd.c` | Executes AArch64 instructions one by one (computed-goto loop), NEON and the crypto extension included. |
| System calls | `core/proc.c`, `core/tty.c` | Linux's system calls on top of Darwin: `fork` copies the address space, `execve` replaces it in place; each process runs on its own iOS thread, the threads of one process take turns on it. Terminals follow Linux's line discipline. |
| libc fast path | `core/lxfast.c` | glibc's `memcpy`, `strlen`, `strcmp` and twelve more run as the app's own code when glibc is mapped. |
| Translated libraries | `core/aot.c`, `tools/aotgen.c`, `tools/aot-build.sh` | Hot functions of AlmaLinux's dnf stack compiled into the app; matched by build-id when a library is mapped. |
| Fast start | `core/snap.c`, `core/proc.c` (`aoi_proc_zygote`), `lxios/LxTerm/zygote-dnf.py` | `dnf` resumes a process saved after its imports. |
| App | `lxios/LxTerm/` | Sessions, distributions, Repair, systemctl, Ports, App Intents, settings. |
| Accelerated engine | `lxios/web/`, `lxios/webjs/` | The core compiled to WebAssembly, run in a hidden web view whose JIT compiles hot guest code. |

## A distribution arrives

```mermaid
sequenceDiagram
    participant U as You
    participant A as App
    participant R as Docker Hub registry
    participant D as Distribution root
    U->>A: Settings › Distributions › Download AlmaLinux
    A->>R: index for almalinux:10 → the linux/arm64 manifest
    R-->>A: manifest (checked against its SHA-256 digest)
    loop every layer
        A->>R: layer blob
        R-->>A: tar.gz (checked against its digest)
        A->>D: unpack: modes, links, modification times, whiteouts
    end
    A->>D: systemctl, resolv.conf (this network's DNS), /etc/hosts name, fast-start script
    A->>A: start a shell in the new copy before it replaces the old one (Repair keeps /root and /home)
```

## A command runs

```mermaid
flowchart LR
    Key["You type<br/>dnf install tmux"] --> Bash["bash (the distribution's)<br/>forks and execs /usr/bin/dnf"]
    Bash --> Exec{"execve in the engine"}
    Exec -->|"dnf-3 with a valid snapshot"| Resume["load the snapshot's memory and registers<br/>keep pid, fds, cwd<br/>(arguments, environment passed in)"]
    Exec -->|"anything else"| Load["load the ELF and its interpreter<br/>map libraries; translated tables<br/>attach by build-id"]
    Resume --> Run["interpret + translated code<br/>system calls answered by core/proc.c"]
    Load --> Run
    Run --> Out["output in the tab<br/>(Linux terminal semantics)"]
```

## Fast start in detail

```mermaid
flowchart TD
    E["exec /usr/bin/dnf-3"] --> S{"script present?"}
    S -->|no| P["plain exec"]
    S -->|yes| V{"snapshot of this build, and its stamp unchanged?<br/>(the script, dnf's Python folders,<br/>every file the snapshot maps)"}
    V -->|yes| R["resume after dnf's imports<br/>~0.4 s on an iPhone"]
    V -->|no| N["run the script: import dnf,<br/>save a snapshot (21 MB), go on with the command"]
    N --> W["write the stamp"]
```

- An unrelated install (tmux, with ldconfig) keeps the snapshot: pages of files under `/etc` are stored in it, not looked up again.
- An update of dnf, Python or a library the snapshot maps, or a new app build, makes the next `dnf` save a new one.
- Settings › Speed-ups turns it off (and the translated libraries), for comparison.

## Translated libraries: built for the image the app downloads

```mermaid
flowchart LR
    Img["almalinux:10<br/>(the image the app downloads)"] --> Train["train: dnf and Python commands<br/>under the profiler (LXRUN_PROF)"]
    Dbg["AlmaLinux debuginfo<br/>(function bounds)"] --> Sel
    Train --> Sel["pick the functions holding 99%<br/>of each library's samples"]
    Sel --> Gen["aotgen: one C function per page<br/>(memory through the guest's page table)"]
    Gen --> Check{"every check command<br/>gives the interpreter's<br/>output byte for byte?"}
    Check -->|yes| Ship["tables compiled into the app<br/>(TestFlight build)"]
    Check -->|no| Plain["app built without tables<br/>(interpreted, as before)"]
```

The tables are cached per image digest, so they are rebuilt only when the image or the translator changes. Apple allows code compiled into the app; nothing is downloaded and run as machine code.

## Why these choices

- **Interpreter, not a virtual machine:** iOS gives ordinary apps neither hypervisor access nor JIT. Every program stays the distribution's own, unmodified binary.
- **System calls in-process:** no kernel, no second process to talk to; `fork` and `execve` are real enough for package managers, their scripts and shells.
- **Speed where the time goes:** the profiler showed dnf's time in Python, libsolv, sqlite and SHA-256; each speed-up targets one of them and is checked against the interpreter's output.
