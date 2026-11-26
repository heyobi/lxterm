import Foundation
import SwiftTerm
import UIKit

/// One Debian shell: a terminal view (SwiftTerm) on one end, the core's session (a bash on
/// a pty, in its own thread) on the other. The output of the last minutes is kept, so a
/// session resumed from its snapshot shows what it showed before.
final class Session: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    let id: String
    /// Runs in the accelerated engine (WebEngine: WebAssembly in WebKit, JIT-compiled) instead
    /// of the interpreter. Its root is the engine's own copy, kept by the engine.
    let accelerated: Bool
    /// The distribution it runs (Distros.swift); Debian unless chosen otherwise.
    let distro: Distro
    private(set) var webID: Int?                 // its session in the accelerated engine
    private var webRunning: Bool { webID != nil }
    static var accelTabs = 0                      // (CI: -accel)
    @Published var title = "bash"
    @Published var exited = false
    private(set) var handle: OpaquePointer?
    private(set) var resumed = false
    private var size: (cols: Int, rows: Int)?    // the view's last size: sent again once the shell runs
    var ctrlArmed = false                         // the key bar's Ctrl: applies to the next key
    private weak var keyBar: KeyBar?
    lazy var view: TerminalView = makeView()

    private let lock = NSLock()
    private var pending = [UInt8]()
    private var flushQueued = false
    private var history = [UInt8]()              // the last output, replayed on resume
    private static let historyMax = 256 * 1024

    init(id: String = UUID().uuidString, accelerated: Bool = false, distro: Distro = .debian) {
        self.id = id
        self.distro = distro
        self.accelerated = accelerated && distro.builtIn           // (the accelerated engine runs Debian)
        super.init()
        if !distro.builtIn { title = distro.name.components(separatedBy: " ").first ?? distro.name }
    }

    var snapPath: String { Store.sessionsDir.appendingPathComponent("\(id).snap").path }
    var logPath: URL { Store.sessionsDir.appendingPathComponent("\(id).log") }

    private func makeView() -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        tv.terminalDelegate = self
        Theme.of(distro).apply(to: tv)
        tv.font = Settings.font
        tv.getTerminal().setCursorStyle(Settings.cursor)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        tv.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        let bar = KeyBar(session: self)
        tv.inputAccessoryView = bar
        keyBar = bar
        return tv
    }

    /// A tap on the terminal brings the keyboard back after it was hidden.
    @objc private func tapped() {
        if !view.isFirstResponder { _ = view.becomeFirstResponder() }
    }

    /// The last `n` bytes of output as text (screenshot tour).
    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: history.suffix(n), as: UTF8.self)
    }

    /// Keys from the key bar (Ctrl applies to them too).
    func sendKeys(_ bytes: [UInt8]) {
        if exited { restart(); return }
        var b = bytes
        if ctrlArmed, b.count == 1 { b = [Session.ctrl(b[0])]; ctrlArmed = false; keyBar?.updateCtrl() }
        if webRunning { WebEngine.shared.input(self, b); return }
        guard let handle else { return }
        b.withUnsafeBufferPointer { p in
            p.baseAddress?.withMemoryRebound(to: CChar.self, capacity: p.count) { lx_session_input(handle, $0, p.count) }
        }
    }

    static func ctrl(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return c - 96
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return c - 64
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1b
        case UInt8(ascii: " "), UInt8(ascii: "2"), UInt8(ascii: "@"): return 0
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1c
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1d
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7f
        default: return c
        }
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

    private var typeAfterStart: String?
    /// Keys typed once the shell is up (Shortcuts).
    func typeWhenStarted(_ s: String) {
        if handle != nil || webRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.sendKeys(Array(s.utf8)) }
        } else { typeAfterStart = s }
    }

    /// Starts the shell (resumed from its snapshot when there is one).
    func start() {
        if !distro.builtIn, typeAfterStart == nil,                 // (Arch Linux ARM: the rest of its setup, in view)
           FileManager.default.fileExists(atPath: distro.root.appendingPathComponent(".lxterm-firstrun").path) {
            typeAfterStart = "sh /tmp/lxterm-setup.sh\r"
        }
        defer {
            if let t = typeAfterStart, handle != nil || webRunning {
                typeAfterStart = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.sendKeys(Array(t.utf8)) }
            }
        }
        guard handle == nil, !webRunning else { return }
        exited = false
        if accelerated {
            let term = view.getTerminal()
            history.removeAll()
            webID = WebEngine.shared.start(self, cols: size?.cols ?? max(term.cols, 20), rows: size?.rows ?? max(term.rows, 5))
            if ProcessInfo.processInfo.arguments.contains("-accel") || ProcessInfo.processInfo.arguments.contains("-accel2") { accelTest() }
            return
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var res: Int32 = 0
        let term = view.getTerminal()
        let cols = Int32(max(term.cols, 20)), rows = Int32(max(term.rows, 5))
        if FileManager.default.fileExists(atPath: snapPath), let log = try? Data(contentsOf: logPath) {
            history = [UInt8](log.suffix(Session.historyMax))
        }
        lx_engine_prepare_root(distro.root.path)                  // (the DNS servers of the network the phone is on now)
        handle = lx_session_start(distro.builtIn ? nil : distro.root.path, snapPath, cols, rows, { ctx, s, n in
            guard let ctx, let s else { return }
            Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue().output(UnsafeRawPointer(s), n)
        }, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.shellEnded() }
        }, ctx, &res)
        resumed = res != 0
        if handle == nil {                                         // (no blank tab: say why)
            let root = distro.root.path
            let sh = FileManager.default.fileExists(atPath: root + "/bin/bash") ? "/bin/bash" : "/bin/sh"
            notice(String(localized: "The shell could not be started (\(sh) in \(distro.name)). Repair keeps your files in /root and /home: Settings › Distributions."))
            let d = distro
            DispatchQueue.main.async { NotificationCenter.default.post(name: .lxCannotStart, object: d.id) }
        }
        if let size, let handle { lx_session_resize(handle, Int32(size.cols), Int32(size.rows)) }
        if ProcessInfo.processInfo.arguments.contains("-demo"), !resumed { demo() }
        if resumed, !history.isEmpty {
            view.feed(byteArray: history[...])                // what it showed before
        } else {
            history.removeAll()
        }
    }

    /// For screenshots (launch argument -demo): a few commands typed as a user would.
    private func demo() {
        let cmds = ["head -n 2 /etc/os-release\r", "python3 -c 'import sys; print(sys.version)'\r", "tmux\r", "echo inside tmux: $TMUX\r", "ls /\r"]
        DispatchQueue.global().async { [weak self] in
            Thread.sleep(forTimeInterval: 2)
            for c in cmds {
                guard let self, let h = self.handle else { return }
                for ch in c.utf8 { var b = CChar(bitPattern: ch); lx_session_input(h, &b, 1); Thread.sleep(forTimeInterval: 0.03) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    /// A line from the app (dimmed), shown in the terminal without reaching the shell.
    func notice(_ text: String) {
        view.feed(text: "\r\n\u{1b}[2m[" + text + "]\u{1b}[0m\r\n")
    }

    /// Output of the accelerated engine.
    func webOutput(_ d: Data) {
        d.withUnsafeBytes { p in if let b = p.baseAddress, p.count > 0 { output(b, p.count) } }
    }

    /// CI (launch argument -accel): commands typed into the accelerated shell; what it shows
    /// goes to Documents/accel.log.
    private func accelTest() {
        Session.accelTabs += 1
        let tab = Session.accelTabs
        let again = ProcessInfo.processInfo.arguments.contains("-accel2")   // (the second launch: is the root still there?)
        let cmds = again ? ["echo second launch; cat /root/accel-mark; ls /root/Files\r"] : tab > 1 ? ["echo second tab; cat /root/Files/hello.txt; sleep 8; ls /root/Files\r"] : ["uname -a; head -n 2 /etc/os-release; date > /root/accel-mark\r",
                    "python3 -c 'import time; t=time.time(); s=sum(i*i for i in range(2000000)); print(\"py loop\", round(time.time()-t, 2), \"s\")'\r",
                    "curl -sI https://deb.debian.org/ | head -n 1\r",
                    "echo hello from Linux > /root/Files/hello.txt; ls -la /root/Files; cat /root/Files/hello.txt\r",
                    "(cd /root/Files && python3 -m http.server 8000 > /tmp/srv.log 2>&1 &) ; for i in $(seq 40); do curl -s http://localhost:8000/ > /tmp/o && break; sleep 2; done; head -n 6 /tmp/o; cat /tmp/srv.log; time python3 -c pass\r",
                    "apt-get update 2>&1 | tail -n 3\r"]
        let log = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(tab > 1 ? "accel-\(tab).log" : "accel.log")
        var i = 0, titles = ""
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            if !titles.hasSuffix(" " + self.title) { titles += " " + self.title }
            try? Data((self.tail(64 * 1024) + "\n[titles]" + titles + "\n").utf8).write(to: log)
            if i >= 20, i % 25 == 20, (i - 20) / 25 < cmds.count { WebEngine.shared.input(self, Array(cmds[(i - 20) / 25].utf8)) }
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

    /// A program other than the shell is in the foreground (Awake: the screen stays on).
    var runningProgram: Bool {
        guard let handle, !exited else { return false }
        var buf = [CChar](repeating: 0, count: 64)
        lx_session_title(handle, &buf, 64)
        return !["", "bash", "sh", "dash", "ash", "zsh", "fish", "busybox", "login"].contains(String(cString: buf))
    }

    private func updateTitle() {
        guard let handle else { return }
        var buf = [CChar](repeating: 0, count: 64)
        lx_session_title(handle, &buf, 64)
        var t = String(cString: buf)
        if !distro.builtIn, t == "bash" || t == "sh" || t == "busybox" { t = distro.name.components(separatedBy: " ").first ?? distro.name }
        if t != title { title = t }
    }

    func shellEnded() {
        handle = nil
        webID = nil
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
        if webRunning { DispatchQueue.main.async { WebEngine.shared.save() }; return 0 }
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
        if webRunning { WebEngine.shared.close(self); webID = nil }
        if let handle { lx_session_close(handle) }
        handle = nil
        try? FileManager.default.removeItem(atPath: snapPath)
        try? FileManager.default.removeItem(at: logPath)
    }

    func applySettings() {
        Theme.of(distro).apply(to: view)
        view.font = Settings.font
        view.getTerminal().setCursorStyle(Settings.cursor)
    }

    // MARK: TerminalViewDelegate

    /// “ ” ‘ ’ — – from the iPhone keyboard's smart punctuation: what a shell expects.
    static func plainPunctuation(_ data: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard data.contains(where: { $0 >= 0xE2 }), let s = String(bytes: data, encoding: .utf8) else { return data }
        let t = s.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
                 .replacingOccurrences(of: "\u{201E}", with: "\"")
                 .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
                 .replacingOccurrences(of: "\u{2014}", with: "--").replacingOccurrences(of: "\u{2013}", with: "-")
        return ArraySlice(Array(t.utf8))
    }

    func send(source: TerminalView, data inData: ArraySlice<UInt8>) {
        let data = UserDefaults.standard.object(forKey: "plainQuotes") as? Bool ?? true ? Session.plainPunctuation(inData) : inData
        if exited { restart(); return }
        if ctrlArmed, data.count == 1 { sendKeys([data[data.startIndex]]); return }
        if webRunning { WebEngine.shared.input(self, Array(data)); return }
        guard let handle else { return }
        data.withUnsafeBufferPointer { b in
            b.baseAddress?.withMemoryRebound(to: CChar.self, capacity: b.count) { lx_session_input(handle, $0, b.count) }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = (newCols, newRows)
        if webRunning { WebEngine.shared.resize(self, cols: newCols, rows: newRows) }
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
        guard let u = URL(string: link), ["http", "https"].contains(u.scheme ?? "") else { return }
        if BrowserView.isLocal(u) { NotificationCenter.default.post(name: .lxOpenBrowser, object: u) }   // a server in Debian
        else { UIApplication.shared.open(u) }
    }
}

extension Notification.Name {
    static let lxFontChanged = Notification.Name("lxFontChanged")
    /// A tab's shell could not be started (object: the distribution's id): Repair is offered.
    static let lxCannotStart = Notification.Name("lxCannotStart")
}
