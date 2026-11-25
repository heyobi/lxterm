import Compression
import Foundation

/// Arch Linux ARM has no small official image (its root tarball is 830 MB, kernel and
/// firmware included), so it is installed the way Arch's own pacstrap does: the packages
/// pacman needs and their dependencies, from Arch Linux ARM's repositories, each checked
/// against the SHA-256 the repository database lists. The first tab then runs the rest of
/// the setup in view (/tmp/lxterm-setup.sh): system users, the CA bundle, pacman's keyring,
/// and pacman recording the packages after checking their signatures.
enum Pacstrap {
    /// Official mirrors whose HTTPS certificates are valid (the redirector's is not).
    static let mirrors = ["https://de3.mirror.archlinuxarm.org/aarch64", "https://fl.us.mirror.archlinuxarm.org/aarch64",
                          "https://ca.us.mirror.archlinuxarm.org/aarch64"]
    static let repos = ["core", "extra", "alarm"]
    static let want = ["filesystem", "bash", "coreutils", "pacman", "pacman-mirrorlist", "archlinuxarm-keyring",
                       "ca-certificates", "sed", "grep", "gawk", "findutils", "tar", "gzip", "xz", "which", "less", "nano"]

    struct Package { let name, repo, file, sha256: String; let size: Int64; let depends, provides: [String] }

    private static func fetch(_ path: String, to dest: URL) async throws {
        var last: Error = Distro.Failure.http(0, path)
        for m in mirrors {
            do {
                let (tmp, r) = try await URLSession.shared.download(from: URL(string: "\(m)/\(path)")!)
                let code = (r as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { last = Distro.Failure.http(code, path); continue }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return
            } catch { last = error }
        }
        throw last
    }

    /// A repository database (a .tar.gz of NAME-VERSION/desc and /depends files), unpacked
    /// with the app's own unpacker and read.
    private static func database(_ repo: String, work: URL) async throws -> [Package] {
        let fm = FileManager.default
        let file = work.appendingPathComponent("\(repo).db.tar.gz"), dir = work.appendingPathComponent("db-\(repo)")
        try await fetch("\(repo)/\(repo).db", to: file)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Distro.unpack(file, into: dir)
        var out: [Package] = []
        for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            var f: [String: [String]] = [:]
            for name in ["desc", "depends"] {
                guard let text = try? String(contentsOf: dir.appendingPathComponent(entry).appendingPathComponent(name), encoding: .utf8) else { continue }
                var key = ""
                for line in text.components(separatedBy: "\n") {
                    if line.hasPrefix("%") && line.hasSuffix("%") && line.count > 2 { key = String(line.dropFirst().dropLast()); f[key, default: []] = [] }
                    else if !line.isEmpty && !key.isEmpty { f[key, default: []].append(line) }
                }
            }
            guard let n = f["NAME"]?.first, let file = f["FILENAME"]?.first, let sum = f["SHA256SUM"]?.first else { continue }
            out.append(Package(name: n, repo: repo, file: file, sha256: sum, size: Int64(f["CSIZE"]?.first ?? "") ?? 0,
                               depends: f["DEPENDS"] ?? [], provides: f["PROVIDES"] ?? []))
        }
        return out
    }

    private static func bare(_ dep: String) -> String {
        String(dep.prefix { !"<>=".contains($0) })
    }

    /// Installs into `root`; progress 0...0.9.
    static func install(into root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pacstrap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var db: [String: Package] = [:]
        for r in repos {
            for p in try await database(r, work: work) where db[p.name] == nil { db[p.name] = p }
        }
        progress(0.05)
        var provides: [String: String] = [:]
        for p in db.values { for v in p.provides { let b = bare(v); if provides[b] == nil { provides[b] = p.name } } }
        var todo = want, seen = Set<String>(), order: [Package] = []
        while !todo.isEmpty {
            let d = bare(todo.removeFirst())
            guard let name = db[d] != nil ? d : provides[d], let p = db[name], !seen.contains(name) else { continue }
            seen.insert(name); order.append(p); todo += p.depends
        }
        let total = max(1, order.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        let cache = root.appendingPathComponent("var/cache/pacman/pkg", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        // downloads six at a time (the mirrors are slow per file), each checked; then unpacked in order
        let downloaded = Counter()
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = 0
            func add() {
                guard next < order.count else { return }
                let p = order[next]; next += 1
                g.addTask {
                    let pkg = cache.appendingPathComponent(p.file)
                    try await fetch("\(p.repo)/\(p.file)", to: pkg)
                    guard try Distro.sha256(pkg) == "sha256:" + p.sha256 else { throw Distro.Failure.digest(p.file) }
                    progress(0.05 + 0.65 * Double(downloaded.add(p.size)) / Double(total))
                }
            }
            for _ in 0..<6 { add() }
            while try await g.next() != nil { add() }
        }
        for p in order {
            let pkg = cache.appendingPathComponent(p.file)
            let tar = work.appendingPathComponent(p.name + ".tar")
            if p.file.hasSuffix(".xz") { try unxz(pkg, to: tar) }
            else if p.file.hasSuffix(".gz") { try? fm.removeItem(at: tar); try fm.copyItem(at: pkg, to: tar) }
            else { throw Distro.Failure.format(p.file) }
            try Distro.unpack(tar, into: root)                     // (plain tar: the unpacker reads it as is)
            try? fm.removeItem(at: tar)
            for meta in [".PKGINFO", ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG"] { try? fm.removeItem(at: root.appendingPathComponent(meta)) }
            done += p.size
            progress(0.7 + 0.2 * Double(done) / Double(total))
        }
        let names = order.map(\.name).joined(separator: " ")
        let script = """
        #!/bin/sh
        # LxTerm: the rest of Arch Linux ARM's setup, once (what pacstrap's hooks do).
        echo "Setting up Arch Linux ARM, once: system users, certificates, pacman's keyring. This takes a few minutes."
        systemd-sysusers > /dev/null 2>&1
        update-ca-trust
        # no Landlock or seccomp in this kernel layer (as in WSL1 and many containers): pacman's setting for that
        grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\\[options\\]/a DisableSandbox' /etc/pacman.conf
        # mirrors with valid HTTPS first, Arch Linux ARM's redirector last
        printf 'Server = https://de3.mirror.archlinuxarm.org/$arch/$repo\\nServer = https://fl.us.mirror.archlinuxarm.org/$arch/$repo\\nServer = https://ca.us.mirror.archlinuxarm.org/$arch/$repo\\nServer = http://mirror.archlinuxarm.org/$arch/$repo\\n' > /etc/pacman.d/mirrorlist
        pacman-key --init && pacman-key --populate archlinuxarm
        pacman -Sy --noconfirm
        # pacman records the packages installed from its cache, checking their signatures
        pacman -S --noconfirm --needed --dbonly \(names) || pacman -Sy --noconfirm --needed --dbonly \(names)
        # filesystem again, the usual way: its install script (/etc/os-release and the rest)
        pacman -S --noconfirm filesystem
        rm -f /.lxterm-firstrun /tmp/lxterm-setup.sh
        echo "Arch Linux ARM is ready. Install more with: pacman -S <package>"

        """
        try fm.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: root.appendingPathComponent("tmp/lxterm-setup.sh"))
        fm.createFile(atPath: root.appendingPathComponent(".lxterm-firstrun").path, contents: nil)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n: Int64 = 0
        func add(_ d: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; n += d; return n }
    }

    /// .xz (LZMA2 in the xz container) to a plain file, with Apple's Compression.
    static func unxz(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        fm.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src), out = try FileHandle(forWritingTo: dst)
        defer { try? input.close(); try? out.close() }
        let filter = try OutputFilter(.decompress, using: .lzma) { d in if let d { out.write(d) } }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try filter.write(chunk) }
        try filter.finalize()
    }
}
