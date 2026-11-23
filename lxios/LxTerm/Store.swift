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

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let rootDir = support.appendingPathComponent("debian", isDirectory: true)
    static let sessionsDir = support.appendingPathComponent("sessions", isDirectory: true)
    private static let okFile = rootDir.appendingPathComponent(".lxterm-ok")
    private static let idsKey = "sessionIDs"

    var current: Session? { sessions.indices.contains(selected) ? sessions[selected] : nil }

    func boot() {
        try? FileManager.default.createDirectory(at: Store.sessionsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: Store.okFile.path) { ready(); return }
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

    private func ready() {
        if ProcessInfo.processInfo.arguments.contains("-trace") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            lx_engine_trace(docs.appendingPathComponent("lxterm.trace").path)
        }
        lx_engine_init(Store.rootDir.path)
        phase = .ready
        let ids = UserDefaults.standard.stringArray(forKey: Store.idsKey) ?? []
        sessions = ids.map { Session(id: $0) }
        if sessions.isEmpty { sessions = [Session()] }
        selected = min(UserDefaults.standard.integer(forKey: "selected"), sessions.count - 1)
        persist()
    }

    func newSession() {
        sessions.append(Session())
        selected = sessions.count - 1
        persist()
    }

    func close(_ s: Session) {
        guard let i = sessions.firstIndex(where: { $0 === s }) else { return }
        s.close()
        sessions.remove(at: i)
        if sessions.isEmpty { sessions = [Session()] }
        selected = min(selected, sessions.count - 1)
        persist()
    }

    func select(_ i: Int) {
        selected = i
        UserDefaults.standard.set(i, forKey: "selected")
    }

    private func persist() {
        UserDefaults.standard.set(sessions.map(\.id), forKey: Store.idsKey)
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

    /// Erases Debian and unpacks it again (Settings › Reset).
    func reset() {
        for s in sessions { s.close() }
        sessions = []
        try? FileManager.default.removeItem(at: Store.rootDir)
        try? FileManager.default.removeItem(at: Store.sessionsDir)
        try? FileManager.default.createDirectory(at: Store.sessionsDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: Store.idsKey)
        unpack()
    }
}

final class ProgressBox {
    let report: (Double) -> Void
    init(_ r: @escaping (Double) -> Void) { report = r }
}
