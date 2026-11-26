import Foundation

/// CI (launch argument -distros): downloads Ubuntu and Alpine Linux, opens a tab in each and
/// types a few commands; a server in Debian and one in Alpine must show up in Ports. What
/// happens goes to Documents/distros.log and Documents/distro-<id>.log.
@MainActor
enum DistroTest {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var lines: [String] = []

    static func log(_ s: String) {
        lines.append(s)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: docs.appendingPathComponent("distros.log"))
    }

    static func type(_ s: Session, _ text: String) { s.sendKeys(Array(text.utf8)) }

    static func keep(_ s: Session, _ name: String) {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                try? Data((s.tail(32 * 1024) + "\n[title] " + s.title + "\n").utf8).write(to: docs.appendingPathComponent("distro-\(name).log"))
            }
        }
    }

    static func run(_ store: Store) {
        Task { @MainActor in
            log("start")
            if let deb = store.current {
                keep(deb, "debian")
                try? await Task.sleep(for: .seconds(15))
                type(deb, "cd /tmp && python3 -m http.server 8123 > /tmp/srv.log 2>&1 & sleep 6; curl -sI http://127.0.0.1:8123/ | head -n 1; cat /tmp/srv.log\r")
            }
            for d in Distro.all where ["ubuntu", "alpine", "fedora", "almalinux", "arch"].contains(d.id) {
                let t0 = Date()
                do {
                    try await d.install { _ in }
                    log("\(d.id): installed in \(Int(Date().timeIntervalSince(t0))) s, \(d.diskUsage() / 1_000_000) MB")
                } catch { log("\(d.id): FAILED \(error.localizedDescription)"); continue }
                DistroManager.shared.refresh()
                store.newSession(d)
                guard let s = store.current else { continue }
                keep(s, d.id)
                try? await Task.sleep(for: .seconds(8))
                if d.id == "alpine" {
                    type(s, "head -n 2 /etc/os-release; echo shell=$0; apk add --no-progress python3 2>&1 | tail -n 2; python3 -c 'print(6*7)'\r")
                    try? await Task.sleep(for: .seconds(90))
                    type(s, "python3 -m http.server 8124 > /tmp/srv.log 2>&1 &\r")
                } else if d.id == "arch" {
                    try? await Task.sleep(for: .seconds(240))           // (its setup runs in the tab first)
                    type(s, "head -n 2 /etc/os-release; pacman -Q | wc -l; pacman -Qk pacman | tail -n 1; ls -la /usr/share/terminfo/x/xterm-256color; tput clear > /dev/null && echo tput-ok\r")
                    try? await Task.sleep(for: .seconds(20))
                } else if d.id == "almalinux" {
                    try? await Task.sleep(for: .seconds(15))
                    type(s, "head -n 2 /etc/os-release; echo alma-ok\r")
                    try? await Task.sleep(for: .seconds(10))
                    let r = d.root.path
                    for f in ["bin", "usr/bin/bash", "bin/bash", "lib/ld-linux-aarch64.so.1", "usr/lib/ld-linux-aarch64.so.1", "etc/profile"] {
                        let a = (try? FileManager.default.attributesOfItem(atPath: r + "/" + f)) ?? [:]
                        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: r + "/" + f)) ?? ""
                        log("alma \(f): \(a[.type] as? String ?? "missing") \(a[.size] as? Int ?? -1) \(link)")
                    }
                    // Repair: a copy whose loader is gone must not start; Repair must bring it back
                    // with the user's files in /root kept.
                    store.close(s)
                    try? Data("kept
".utf8).write(to: d.root.appendingPathComponent("root/keep.txt"))
                    try? FileManager.default.removeItem(atPath: r + "/usr/lib/ld-linux-aarch64.so.1")
                    let broken = await Distro.shellStarts(in: d.root)
                    let t1 = Date()
                    do { try await d.install(keepUserFiles: true) { _ in } } catch { log("alma repair: FAILED \(error.localizedDescription)") }
                    let fixed = await Distro.shellStarts(in: d.root)
                    let kept = (try? String(contentsOf: d.root.appendingPathComponent("root/keep.txt"), encoding: .utf8)) == "kept
"
                    log("alma repair: broken copy starts=\(broken), repaired starts=\(fixed), /root kept=\(kept), \(Int(Date().timeIntervalSince(t1))) s")
                } else if d.id == "fedora" {
                    type(s, "head -n 2 /etc/os-release; echo shell=$0; rpm -q bash; dnf --version | head -n 1\r")
                    try? await Task.sleep(for: .seconds(30))
                } else {
                    type(s, "head -n 2 /etc/os-release; echo shell=$0; apt-get update 2>&1 | tail -n 2; apt-get install -y hello 2>&1 | tail -n 1; hello\r")
                    try? await Task.sleep(for: .seconds(100))
                }
            }
            try? await Task.sleep(for: .seconds(10))
            Ports.shared.scan()
            var ports = [Int32](repeating: 0, count: 64)
            var names = [CChar](repeating: 0, count: 64 * 40)
            log("raw listening: \(lx_engine_listening(&ports, &names, 64)) \(ports.prefix(4))")
            log("ports: " + Ports.shared.list.map { "\($0.port)=\($0.program.isEmpty ? "?" : $0.program)" }.joined(separator: " "))
            log("announced: \(Ports.shared.announced.map { String($0.port) } ?? "none")")
            log("done")
        }
    }
}
