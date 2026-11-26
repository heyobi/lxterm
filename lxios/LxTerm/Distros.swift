import CryptoKit
import Foundation

/// The distributions a tab can run. Debian comes with the app; the others are each
/// project's official arm64 image, downloaded when chosen in Settings › Distributions:
/// from Docker Hub's registry, where the image manifest and every layer are
/// content-addressed and each is checked against its SHA-256 digest before it is used.
struct Distro: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String          // version and package manager, shown in Settings
    let repo: String            // registry repository ("library/ubuntu"); "" for the bundled one
    let tag: String
    let megabytes: Int          // about how much is downloaded

    static let debian = Distro(id: "debian", name: "Debian", detail: "13 · apt", repo: "", tag: "", megabytes: 0)
    static let all: [Distro] = [
        debian,
        Distro(id: "ubuntu", name: "Ubuntu", detail: "26.04 LTS · apt", repo: "library/ubuntu", tag: "26.04", megabytes: 40),
        Distro(id: "alpine", name: "Alpine Linux", detail: "apk", repo: "library/alpine", tag: "latest", megabytes: 4),
        Distro(id: "fedora", name: "Fedora", detail: "dnf", repo: "library/fedora", tag: "latest", megabytes: 65),
        Distro(id: "almalinux", name: "AlmaLinux", detail: "10 · dnf", repo: "library/almalinux", tag: "10", megabytes: 64),
        Distro(id: "rocky", name: "Rocky Linux", detail: "10 · dnf", repo: "rockylinux/rockylinux", tag: "10", megabytes: 66),
        Distro(id: "opensuse", name: "openSUSE Tumbleweed", detail: "zypper", repo: "opensuse/tumbleweed", tag: "latest", megabytes: 38),
        Distro(id: "arch", name: "Arch Linux ARM", detail: "pacman", repo: "archlinuxarm", tag: "", megabytes: 110),
    ]

    static let repairExplanation = String(localized: "A fresh copy of the system is installed and checked. Your files in /root and /home are kept; packages you installed and changes elsewhere are not. Its tabs are closed.")

    static func named(_ id: String?) -> Distro { all.first { $0.id == id } ?? debian }

    var builtIn: Bool { repo.isEmpty }
    static let dir = Store.support.appendingPathComponent("distros", isDirectory: true)
    var root: URL { builtIn ? Store.rootDir : Distro.dir.appendingPathComponent(id, isDirectory: true) }
    private var okFile: URL { root.appendingPathComponent(".lxterm-ok") }
    var installed: Bool { FileManager.default.fileExists(atPath: okFile.path) }

    static var installed: [Distro] { all.filter(\.installed) }

    /// Debian deleted by the user: not unpacked again at launch.
    static var debianRemoved: Bool {
        get { UserDefaults.standard.bool(forKey: "debianRemoved") }
        set { UserDefaults.standard.set(newValue, forKey: "debianRemoved") }
    }

    func remove() {
        if builtIn { Distro.debianRemoved = true }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Where a new copy is put together before it replaces `root` (a half-done download never
    /// becomes the distribution).
    private var tmpRoot: URL {
        (builtIn ? Store.rootDir.deletingLastPathComponent() : Distro.dir).appendingPathComponent(".\(id)-new", isDirectory: true)
    }

    /// The distribution a new tab runs (Settings › Default distribution), if it is installed.
    static var preferred: Distro? {
        let d = named(UserDefaults.standard.string(forKey: "defaultDistro"))
        return d.installed ? d : installed.first
    }

    /// Bytes used on this iPhone (slow for big trees: call off the main thread). Hard links
    /// (Ubuntu's coreutils are one program under a hundred names) count once.
    func diskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return 0 }
        var n: Int64 = 0
        var seen = Set<UInt64>()
        while let rel = e.nextObject() as? String {
            var st = stat()
            guard lstat(root.path + "/" + rel, &st) == 0 else { continue }
            if st.st_nlink > 1, !seen.insert(UInt64(st.st_ino)).inserted { continue }
            n += Int64(st.st_blocks) * 512
        }
        return n
    }

    enum Failure: LocalizedError {
        case http(Int, String), noArm64, digest(String), format(String), unpack(String), noStart
        var errorDescription: String? {
            switch self {
            case .http(let c, let what): return String(localized: "The download failed (HTTP \(c), \(what)).")
            case .noArm64: return String(localized: "The image has no arm64 version.")
            case .digest(let what): return String(localized: "The checksum of \(what) does not match: the download was not used.")
            case .format(let t): return String(localized: "Unsupported image format: \(t)")
            case .unpack(let e): return String(localized: "Could not unpack: \(e)")
            case .noStart: return String(localized: "The new copy's shell did not start, so it was not used.")
            }
        }
    }

    /// Downloads, verifies and unpacks the image, checks that its shell starts, then puts it
    /// in place of `root`. keepUserFiles (Repair): /root and /home of the copy it replaces are
    /// moved into the new one. progress: 0...1.
    func install(keepUserFiles: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let tmpRoot = tmpRoot
        try? fm.removeItem(at: tmpRoot)
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }
        let image: String
        if builtIn {                                               // Debian again, from the app
            guard let tarball = Bundle.main.path(forResource: "rootfs-debian", ofType: "tar.gz") else { throw Failure.unpack("rootfs-debian.tar.gz") }
            var files: UInt = 0
            if let err = lx_unpack(tarball, tmpRoot.path, &files, nil, nil) { throw Failure.unpack(String(cString: err)) }
            image = "debian (included in the app)\n"
        } else if repo == "archlinuxarm" {                          // its own repositories (Pacstrap.swift)
            try await Pacstrap.install(into: tmpRoot, progress: progress)
            image = "archlinuxarm (packages from its repositories)\n"
        } else {
            let reg = Registry(repo: repo)
            try await reg.login()
            let manifest = try await reg.arm64Manifest(tag: tag)
            let total = max(1, manifest.layers.reduce(0) { $0 + $1.size })
            var done: Int64 = 0
            for layer in manifest.layers {
                guard layer.mediaType.hasSuffix("gzip") else { throw Failure.format(layer.mediaType) }
                let base = done
                let file = try await reg.blob(layer.digest) { got in progress(0.9 * Double(base + got) / Double(total)) }
                defer { try? fm.removeItem(at: file) }
                guard try Distro.sha256(file) == layer.digest else { throw Failure.digest(String(layer.digest.prefix(19))) }
                done += layer.size
                try Distro.unpack(file, into: tmpRoot)
                Distro.applyWhiteouts(tmpRoot)
            }
            image = "\(repo):\(tag) \(manifest.digest)\n"
        }
        try Task.checkCancellation()
        progress(0.95)
        lx_engine_prepare_root(tmpRoot.path)
        Distro.installServiceTools(tmpRoot)
        guard await Distro.shellStarts(in: tmpRoot) else { throw Failure.noStart }
        try Task.checkCancellation()
        if keepUserFiles { Distro.moveUserFiles(from: root, to: tmpRoot) }
        try? fm.removeItem(at: root)
        try fm.moveItem(at: tmpRoot, to: root)
        lx_engine_prepare_root(root.path)
        try Data(image.utf8).write(to: root.appendingPathComponent(".lxterm-image"))
        fm.createFile(atPath: okFile.path, contents: nil)
        if builtIn { Distro.debianRemoved = false }
        progress(1)
    }

    /// Whether a login shell in `root` starts and runs a command (a copy is only used if so,
    /// and a tab that cannot start offers Repair).
    static func shellStarts(in root: URL) async -> Bool {
        guard let out = try? await Headless.run("echo lxterm-shell-ok", root: root.path, seconds: 90) else { return false }
        return out.contains("lxterm-shell-ok")
    }

    /// LxTerm's systemctl and journalctl (systemctl.sh: the services packages install, run
    /// without systemd) in /usr/local/bin, first in a tab's PATH, and the hook that starts
    /// enabled services when a tab opens. Written when missing or changed; the
    /// distribution's own files are left as they are.
    static func installServiceTools(_ root: URL) {
        guard let src = Bundle.main.url(forResource: "systemctl", withExtension: "sh"), let data = try? Data(contentsOf: src) else { return }
        let fm = FileManager.default
        let bin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("systemctl")
        if (try? Data(contentsOf: tool)) != data {
            try? fm.removeItem(at: tool)
            fm.createFile(atPath: tool.path, contents: data, attributes: [.posixPermissions: 0o755])
        }
        let journal = bin.appendingPathComponent("journalctl")
        if (try? fm.destinationOfSymbolicLink(atPath: journal.path)) != "systemctl" {
            try? fm.removeItem(at: journal)
            try? fm.createSymbolicLink(atPath: journal.path, withDestinationPath: "systemctl")
        }
        let profile = root.appendingPathComponent("etc/profile.d", isDirectory: true)
        try? fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let hook = profile.appendingPathComponent("lxterm-services.sh")
        let text = "# LxTerm: services enabled with systemctl start again when a tab opens (/usr/local/bin/systemctl)\n"
            + "[ -d /etc/lxterm/autostart ] && [ -x /usr/local/bin/systemctl ] && (/usr/local/bin/systemctl --lxterm-autostart >/dev/null 2>&1 &)\n"
        if (try? String(contentsOf: hook, encoding: .utf8)) != text { try? Data(text.utf8).write(to: hook) }
    }

    /// LxTerm just started: no service of the last run is alive (they ended with the app),
    /// so what systemctl noted about them goes - else a new process that got an old PID
    /// would pass for the service. Enabled services start again with the first tab.
    static func forgetServices(_ root: URL) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("run/lxterm/units", isDirectory: true))
    }

    /// Repair: the user's own files (/root, with its dotfiles and history, and /home) go
    /// into the fresh copy.
    static func moveUserFiles(from old: URL, to new: URL) {
        let fm = FileManager.default
        for d in ["root", "home"] {
            let o = old.appendingPathComponent(d), n = new.appendingPathComponent(d)
            guard fm.fileExists(atPath: o.path) else { continue }
            try? fm.removeItem(at: n)
            try? fm.moveItem(at: o, to: n)
        }
    }

    static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { sha.update(data: d) }
        return "sha256:" + sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unpack(_ file: URL, into dir: URL) throws {
        var files: UInt = 0
        if let err = lx_unpack(file.path, dir.path, &files, nil, nil) { throw Failure.unpack(String(cString: err)) }
    }

    /// Layered images (OCI): a ".wh.NAME" file deletes NAME of the layers below, and
    /// ".wh..wh..opq" empties its folder of them.
    static func applyWhiteouts(_ root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        var marks: [URL] = []
        for case let u as URL in e where u.lastPathComponent.hasPrefix(".wh.") { marks.append(u) }
        for m in marks {
            let name = m.lastPathComponent
            let dir = m.deletingLastPathComponent()
            if name == ".wh..wh..opq" {
                for c in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where !c.lastPathComponent.hasPrefix(".wh.") {
                    try? fm.removeItem(at: c)
                }
            } else {
                try? fm.removeItem(at: dir.appendingPathComponent(String(name.dropFirst(4))))
            }
            try? fm.removeItem(at: m)
        }
    }
}

/// Docker Hub's registry (the OCI distribution API), anonymous pulls.
private final class Registry: NSObject, URLSessionDownloadDelegate {
    struct Layer: Decodable { let mediaType: String; let digest: String; let size: Int64 }
    struct Manifest { let digest: String; let layers: [Layer] }

    let repo: String
    private var token = ""
    private var onProgress: ((Int64) -> Void)?
    private var finished: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(repo: String) { self.repo = repo }

    private var base: String { "https://registry-1.docker.io/v2/\(repo)" }

    func login() async throws {
        struct T: Decodable { let token: String }
        let url = URL(string: "https://auth.docker.io/token?service=registry.docker.io&scope=repository:\(repo):pull")!
        let (d, r) = try await URLSession.shared.data(from: url)
        try check(r, "token")
        token = try JSONDecoder().decode(T.self, from: d).token
    }

    private func get(_ path: String, accept: String) async throws -> (Data, String) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        try check(r, "manifest")
        return (d, (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    private func check(_ r: URLResponse, _ what: String) throws {
        let c = (r as? HTTPURLResponse)?.statusCode ?? 0
        if c != 200 { throw Distro.Failure.http(c, what) }
    }

    func arm64Manifest(tag: String) async throws -> Manifest {
        struct Entry: Decodable {
            struct P: Decodable { let architecture: String?; let os: String? }
            let digest: String; let mediaType: String?; let platform: P?
        }
        struct Index: Decodable { let manifests: [Entry]?; let layers: [Layer]? }
        let anyIndex = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
        let anyManifest = "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
        let (d, _) = try await get("/manifests/\(tag)", accept: anyIndex + ", " + anyManifest)
        let idx = try JSONDecoder().decode(Index.self, from: d)
        guard let e = idx.manifests?.first(where: { $0.platform?.architecture == "arm64" && $0.platform?.os == "linux" }) else {
            throw Distro.Failure.noArm64
        }
        let (md, _) = try await get("/manifests/\(e.digest)", accept: e.mediaType ?? anyManifest)
        let got = "sha256:" + SHA256.hash(data: md).map { String(format: "%02x", $0) }.joined()
        guard got == e.digest else { throw Distro.Failure.digest("manifest") }
        let m = try JSONDecoder().decode(Index.self, from: md)
        return Manifest(digest: e.digest, layers: m.layers ?? [])
    }

    /// A layer, downloaded to a temporary file (the registry redirects to its CDN).
    func blob(_ digest: String, progress: @escaping (Int64) -> Void) async throws -> URL {
        var req = URLRequest(url: URL(string: base + "/blobs/\(digest)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        onProgress = progress
        let task = session.downloadTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                finished = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite _: Int64) {
        onProgress?(w)
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { finished?.resume(throwing: Distro.Failure.http(code, "layer")); finished = nil; return }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        do { try FileManager.default.moveItem(at: location, to: keep); finished?.resume(returning: keep) }
        catch { finished?.resume(throwing: error) }
        finished = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finished?.resume(throwing: error); finished = nil }
    }

    // the redirect to the CDN must not carry the registry's token
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var n = newRequest
        if n.url?.host != "registry-1.docker.io" { n.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(n)
    }
}

/// Downloads in progress and what is installed, for Settings › Distributions and "+".
@MainActor
final class DistroManager: ObservableObject {
    static let shared = DistroManager()
    @Published private(set) var installed: [Distro] = Distro.installed
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var repairing: Set<String> = []
    @Published var failure: String?
    @Published private(set) var sizes: [String: Int64] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    /// Stops a download in progress (what was fetched so far is deleted).
    func cancel(_ d: Distro) {
        tasks[d.id]?.cancel()
        tasks[d.id] = nil
        progress[d.id] = nil
        repairing.remove(d.id)
        if !d.installed { d.remove(); if d.builtIn { Distro.debianRemoved = true } }
        refresh()
    }

    func download(_ d: Distro, keepUserFiles: Bool = false) {
        guard progress[d.id] == nil else { return }
        progress[d.id] = 0
        if keepUserFiles { repairing.insert(d.id) }
        tasks[d.id] = Task.detached(priority: .userInitiated) {
            do {
                try await d.install(keepUserFiles: keepUserFiles) { f in Task { @MainActor in if DistroManager.shared.progress[d.id] != nil { DistroManager.shared.progress[d.id] = f } } }
                await MainActor.run { DistroManager.shared.finished(d, nil) }
            } catch {
                await MainActor.run { DistroManager.shared.finished(d, error) }
            }
        }
    }

    private func finished(_ d: Distro, _ e: Error?) {
        let cancelled = tasks[d.id] == nil || e is CancellationError || (e as? URLError)?.code == .cancelled
        tasks[d.id] = nil
        progress[d.id] = nil
        repairing.remove(d.id)
        if let e, !cancelled { failure = "\(d.name): \(e.localizedDescription)" }
        refresh()
        Store.shared?.distributionsChanged()                      // (the first one installed becomes the default)
    }

    func remove(_ d: Distro) {
        if progress[d.id] != nil { cancel(d) }
        if d.builtIn { WebEngine.resetRoot(); UserDefaults.standard.set(false, forKey: "webEngine") }
        d.remove()
        refresh()
    }

    func refresh() {
        installed = Distro.installed
        let list = installed
        Task.detached(priority: .utility) {
            var s: [String: Int64] = [:]
            for d in list { s[d.id] = d.diskUsage() }
            await MainActor.run { DistroManager.shared.sizes = s }
        }
    }
}
