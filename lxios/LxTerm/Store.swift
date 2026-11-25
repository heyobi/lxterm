import Foundation
import SwiftUI
import UIKit

/// The app's state: is Debian unpacked, the open sessions (tabs), which one is shown.
@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case unpacking(Double), ready, failed(String) }

    @Published var phase: Phase = .unpacking(0)
    @Published var sessions: [Session] = []
    @Published var selected = 0
    /// Settings › Default distribution (a new tab, and the tab opened when the last one closes).
    @Published var defaultDistro: String = UserDefaults.standard.string(forKey: "defaultDistro") ?? "debian" {
        didSet { UserDefaults.standard.set(defaultDistro, forKey: "defaultDistro") }
    }

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let rootDir = support.appendingPathComponent("debian", isDirectory: true)
    static let sessionsDir = support.appendingPathComponent("sessions", isDirectory: true)
    static let okFile = rootDir.appendingPathComponent(".lxterm-ok")
    private static let idsKey = "sessionIDs"
    private static let fastKey = "acceleratedIDs"
    private static let distroKey = "sessionDistros"

    var current: Session? { sessions.indices.contains(selected) ? sessions[selected] : nil }

    /// Shortcuts' Run Command in LxTerm: a new tab in `d` with the command typed into it.
    func run(_ command: String, in d: Distro) {
        newSession(d)
        current?.typeWhenStarted(command + "\r")
    }

    func boot() {
        Store.shared = self
        try? FileManager.default.createDirectory(at: Store.sessionsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: Store.okFile.path) || Distro.debianRemoved { ready(); return }
        unpack()
    }

    private func unpack() {
        phase = .unpacking(0)
        let root = Store.rootDir
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let tarball = Bundle.main.path(forResource: "rootfs-debian", ofType: "tar.gz") else {
                DispatchQueue.main.async { self.phase = .failed("rootfs-debian.tar.gz is not in the app") }
                return
            }
            let box = Unmanaged.passRetained(ProgressBox { f in
                DispatchQueue.main.async { if case .unpacking = self.phase { self.phase = .unpacking(f) } }
            })
            var files: UInt = 0
            let err = lx_unpack(tarball, root.path, &files, { ctx, f in
                guard let ctx else { return }
                Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue().report(f)
            }, box.toOpaque())
            box.release()
            DispatchQueue.main.async {
                if let err { self.phase = .failed(String(cString: err)); return }
                FileManager.default.createFile(atPath: Store.okFile.path, contents: nil)
                self.ready()
            }
        }
    }

    /// The engine set up once per launch (also when Shortcuts start LxTerm without a window).
    nonisolated(unsafe) private static var engineReady = false
    static func prepareEngine(again: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: okFile.path) || Distro.debianRemoved else { return false }
        if !engineReady || again {                                 // (again: a fresh root after Reset)
            engineReady = true
            lx_engine_init(rootDir.path)
            lx_engine_bind_files(SharedFiles.shared.root.path)
        }
        return true
    }

    /// The app's one store, for Shortcuts.
    static weak var shared: Store?

    private func ready() {
        if ProcessInfo.processInfo.arguments.contains("-trace") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            lx_engine_trace(docs.appendingPathComponent("lxterm.trace").path)
        }
        _ = Store.prepareEngine(again: true)
        fixDefault()
        FilesDomain.register()
        Examples.install(in: SharedFiles.shared.root)
        Ports.shared.start()
        phase = .ready
        let ids = UserDefaults.standard.stringArray(forKey: Store.idsKey) ?? []
        let fast = Set(UserDefaults.standard.stringArray(forKey: Store.fastKey) ?? [])
        let distros = UserDefaults.standard.dictionary(forKey: Store.distroKey) as? [String: String] ?? [:]
        sessions = ids.compactMap { id in
            let d = Distro.named(distros[id])
            return d.installed ? Session(id: id, accelerated: fast.contains(id), distro: d) : nil   // (its distribution was removed)
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-accel") || args.contains("-accel2") {     // CI: the accelerated engine
            UserDefaults.standard.set(true, forKey: "webEngine")
            sessions = [Session(accelerated: true)]
            if args.contains("-accel") { DispatchQueue.main.asyncAfter(deadline: .now() + 175) { self.newSession() } }   // a second tab in the same engine
        }
        if sessions.isEmpty, let d = Distro.preferred { sessions = [makeSession(d)] }
        selected = max(0, min(UserDefaults.standard.integer(forKey: "selected"), sessions.count - 1))
        persist()
        if ProcessInfo.processInfo.arguments.contains("-shots") { Tour.run(self) }
        if args.contains("-distros") { DistroTest.run(self) }
    }

    /// A new tab runs in the accelerated engine when Settings › Accelerated engine is on.
    private func makeSession(_ d: Distro) -> Session {
        Session(accelerated: UserDefaults.standard.bool(forKey: "webEngine") && Distro.debian.installed, distro: d)
    }

    /// A new tab: in `d`, or the default distribution.
    func newSession(_ d: Distro? = nil) {
        guard let d = d ?? Distro.preferred else { return }
        sessions.append(makeSession(d))
        selected = sessions.count - 1
        persist()
    }

    func close(_ s: Session) {
        guard let i = sessions.firstIndex(where: { $0 === s }) else { return }
        s.close()
        sessions.remove(at: i)
        if sessions.isEmpty, let d = Distro.preferred { sessions = [makeSession(d)] }   // (the default distribution's)
        selected = max(0, min(selected, sessions.count - 1))
        persist()
    }

    /// The tab `d` places to the right (or left), wrapping around.
    func selectNext(_ d: Int) {
        guard !sessions.isEmpty else { return }
        select(((selected + d) % sessions.count + sessions.count) % sessions.count)
    }

    func select(_ i: Int) {
        selected = i
        UserDefaults.standard.set(i, forKey: "selected")
    }

    private func persist() {
        UserDefaults.standard.set(sessions.map(\.id), forKey: Store.idsKey)
        UserDefaults.standard.set(sessions.filter(\.accelerated).map(\.id), forKey: Store.fastKey)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: sessions.filter { !$0.distro.builtIn }.map { ($0.id, $0.distro.id) }), forKey: Store.distroKey)
        UserDefaults.standard.set(selected, forKey: "selected")
    }

    /// The app goes to the background: every idle shell is saved, so it comes back even if
    /// iOS ends the app.
    func saveAll() {
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask { app.endBackgroundTask(task) }
        let list = sessions
        DispatchQueue.global(qos: .userInitiated).async {
            for s in list { s.save() }
            DispatchQueue.main.async { app.endBackgroundTask(task) }
        }
    }

    /// A file shared with LxTerm (share sheet, Files' "Open in"): copied into the shared
    /// folder, /root/Files in every shell; the shown terminal says where it is.
    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = SharedFiles.shared.root
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) { dest = url }   // already there
        else {
            var n = 2
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do { try fm.copyItem(at: url, to: dest) } catch {
                current?.notice(String(localized: "Could not copy the file: \(error.localizedDescription)"))
                return
            }
        }
        current?.notice(String(localized: "File received: /root/Files/\(dest.lastPathComponent)"))
    }

    /// Erases Debian and unpacks it again (Settings › Reset).
    func reset() {
        for s in sessions { s.close() }
        sessions = []
        try? FileManager.default.removeItem(at: Store.rootDir)
        try? FileManager.default.removeItem(at: Store.sessionsDir)
        try? FileManager.default.createDirectory(at: Store.sessionsDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: Store.idsKey)
        UserDefaults.standard.removeObject(forKey: Store.fastKey)
        WebEngine.resetRoot()
        Distro.debianRemoved = false
        unpack()
    }

    /// The default distribution is always an installed one while any is: the first installed
    /// when the chosen one was removed (or none was chosen).
    func fixDefault() {
        if !Distro.named(defaultDistro).installed, let first = Distro.installed.first { defaultDistro = first.id }
    }

    /// After a distribution was removed: its tabs go; with none left, one in the default.
    func distributionsChanged() {
        fixDefault()
        for s in sessions where !s.distro.installed { s.close() }
        sessions.removeAll { !$0.distro.installed }
        if sessions.isEmpty, let d = Distro.preferred { sessions = [makeSession(d)] }
        selected = max(0, min(selected, sessions.count - 1))
        persist()
    }
}

final class ProgressBox {
    let report: (Double) -> Void
    init(_ r: @escaping (Double) -> Void) { report = r }
}
