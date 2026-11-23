import Foundation
import SwiftTerm
import UIKit

/// One Debian shell: a terminal view (SwiftTerm) on one end, the core's session (a bash on
/// a pty, in its own thread) on the other. The output of the last minutes is kept, so a
/// session resumed from its snapshot shows what it showed before.
final class Session: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    let id: String
    @Published var title = "bash"
    @Published var exited = false
    private(set) var handle: OpaquePointer?
    private(set) var resumed = false
    lazy var view: TerminalView = makeView()

    private let lock = NSLock()
    private var pending = [UInt8]()
    private var flushQueued = false
    private var history = [UInt8]()              // the last output, replayed on resume
    private static let historyMax = 256 * 1024

    init(id: String = UUID().uuidString) {
        self.id = id
        super.init()
    }

    var snapPath: String { Store.sessionsDir.appendingPathComponent("\(id).snap").path }
    var logPath: URL { Store.sessionsDir.appendingPathComponent("\(id).log") }

    private func makeView() -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        tv.terminalDelegate = self
        Theme.current.apply(to: tv)
        tv.font = UIFont.monospacedSystemFont(ofSize: CGFloat(Settings.fontSize), weight: .regular)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        tv.addGestureRecognizer(pinch)
        return tv
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed || g.state == .ended else { return }
        let size = min(28, max(8, Settings.fontSize * Double(g.scale)))
        if abs(size - Settings.fontSize) >= 0.5 {
            Settings.fontSize = size.rounded()
            g.scale = 1
            NotificationCenter.default.post(name: .lxFontChanged, object: nil)
        }
    }

    /// Starts the shell (resumed from its snapshot when there is one).
    func start() {
        guard handle == nil else { return }
        exited = false
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var res: Int32 = 0
        let term = view.getTerminal()
        let cols = Int32(max(term.cols, 20)), rows = Int32(max(term.rows, 5))
        if FileManager.default.fileExists(atPath: snapPath), let log = try? Data(contentsOf: logPath) {
            history = [UInt8](log.suffix(Session.historyMax))
        }
        handle = lx_session_start(snapPath, cols, rows, { ctx, s, n in
            guard let ctx, let s else { return }
            Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue().output(UnsafeRawPointer(s), n)
        }, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.shellEnded() }
        }, ctx, &res)
        resumed = res != 0
        if resumed, !history.isEmpty {
            view.feed(byteArray: history[...])                // what it showed before
        } else {
            history.removeAll()
        }
    }

    private func output(_ p: UnsafeRawPointer, _ n: Int) {
        let bytes = UnsafeRawBufferPointer(start: p, count: n)
        lock.lock()
        pending.append(contentsOf: bytes)
        history.append(contentsOf: bytes)
        if history.count > Session.historyMax + 64 * 1024 { history.removeFirst(history.count - Session.historyMax) }
        let schedule = !flushQueued
        flushQueued = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let data = pending
        pending.removeAll(keepingCapacity: true)
        flushQueued = false
        lock.unlock()
        if !data.isEmpty { view.feed(byteArray: data[...]) }
        updateTitle()
    }

    private func updateTitle() {
        guard let handle else { return }
        var buf = [CChar](repeating: 0, count: 64)
        lx_session_title(handle, &buf, 64)
        let t = String(cString: buf)
        if t != title { title = t }
    }

    private func shellEnded() {
        handle = nil
        exited = true
        try? FileManager.default.removeItem(atPath: snapPath)
        view.feed(text: "\r\n\u{1b}[2m" + String(localized: "[the shell has ended — tap to start a new one]") + "\u{1b}[0m\r\n")
    }

    func restart() {
        guard exited else { return }
        start()
    }

    /// Saves the shell to its snapshot (and what it showed). 0 saved, 1 busy, -1 failed.
    @discardableResult
    func save() -> Int32 {
        guard let handle else { return -1 }
        let r = lx_session_save(handle)
        if r == 0 {
            lock.lock()
            let h = Data(history)
            lock.unlock()
            try? h.write(to: logPath, options: .atomic)
        }
        return r
    }

    func close() {
        if let handle { lx_session_close(handle) }
        handle = nil
        try? FileManager.default.removeItem(atPath: snapPath)
        try? FileManager.default.removeItem(at: logPath)
    }

    func applySettings() {
        Theme.current.apply(to: view)
        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(Settings.fontSize), weight: .regular)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if exited { restart(); return }
        guard let handle else { return }
        data.withUnsafeBufferPointer { b in
            b.baseAddress?.withMemoryRebound(to: CChar.self, capacity: b.count) { lx_session_input(handle, $0, b.count) }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let handle { lx_session_resize(handle, Int32(newCols), Int32(newRows)) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link), ["http", "https"].contains(u.scheme ?? "") { UIApplication.shared.open(u) }
    }
}

extension Notification.Name {
    static let lxFontChanged = Notification.Name("lxFontChanged")
}
