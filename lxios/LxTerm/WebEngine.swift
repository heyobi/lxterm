import Foundation
import UIKit
import WebKit

/// The accelerated engine (Settings › Accelerated engine): the same core built for WebAssembly
/// runs in a hidden WKWebView, where the JavaScript engine's JIT compiles the guest code the
/// core translates (the only JIT iOS gives an app). Every ⚡ tab is a session of one core:
/// its own terminal and bash, one file system. The page reaches the app over lx://host/:
/// `tty` (every tab's output in, keys out, held while nothing is due), `net/…` (TCP
/// connections, listening sockets and names for the guest), `fs/…` (the guest's /root/Files
/// is Documents/Files, seen in the Files app); everything else comes from the app bundle.
final class WebEngine: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = WebEngine()

    private var web: WKWebView?
    private var pageReady = false, booted = false
    private var first: (id: Int, cols: Int, rows: Int)?     // the session the core starts with
    private var sessions: [Int: Session] = [:]
    private var nextID = 1

    // terminal state, main thread only
    private var keys: [Int: [UInt8]] = [:]
    private var ctl = ""                                   // N id c r; S id c r; C id;
    private var saveWanted = false
    private var waiting: (task: WKURLSchemeTask, url: URL, id: Int)?
    private var waitID = 0
    private var stopped = Set<ObjectIdentifier>()

    /// Settings › Reset: the engine's next start uses the root in the app, not its saved copy.
    static func resetRoot() {
        UserDefaults.standard.set(true, forKey: "webFresh")
        if shared.booted { shared.shutDown("") }
    }

    /// Starts a shell for `s`; returns its session id.
    @discardableResult
    func start(_ s: Session, cols: Int, rows: Int) -> Int {
        let id = nextID
        nextID += 1
        sessions[id] = s
        if booted { ctl += "N \(id) \(cols) \(rows);"; answerWaiting() }
        else if first == nil {
            first = (id, cols, rows)
            if web == nil { makeWeb() }
            if pageReady { boot() }
        } else { ctl += "N \(id) \(cols) \(rows);" }          // (sent once the core runs)
        return id
    }

    private func boot() {
        guard let f = first else { return }
        let fresh = UserDefaults.standard.bool(forKey: "webFresh")
        UserDefaults.standard.removeObject(forKey: "webFresh")
        booted = true
        ctl = "S \(f.id) \(f.cols) \(f.rows);" + ctl
        web?.evaluateJavaScript("lxStart(\(fresh), \(f.id))")
    }

    func input(_ s: Session, _ bytes: [UInt8]) {
        guard let id = s.webID else { return }
        keys[id, default: []].append(contentsOf: bytes)
        answerWaiting()
    }

    func resize(_ s: Session, cols: Int, rows: Int) {
        guard let id = s.webID else { return }
        if first?.id == id && !booted { first = (id, cols, rows); return }
        ctl += "S \(id) \(cols) \(rows);"
        answerWaiting()
    }

    /// The root goes to OPFS at the core's next turn (the app goes to the background).
    func save() {
        guard booted else { return }
        saveWanted = true
        answerWaiting()
    }

    /// A tab is closed: its session ends (the others keep running).
    func close(_ s: Session) {
        guard let id = s.webID else { return }
        sessions[id] = nil
        keys[id] = nil
        ctl += "C \(id);"
        answerWaiting()
    }

    /// The page is gone (WebKit ended it, or Reset): every ⚡ tab's shell ends.
    private func shutDown(_ why: String) {
        let all = sessions.values
        sessions = [:]
        keys = [:]
        ctl = ""
        first = nil
        booted = false
        pageReady = false
        waiting = nil
        web?.removeFromSuperview()
        web = nil
        for s in all {
            if !why.isEmpty { s.webOutput(Data(("\r\n[engine] " + why + "\r\n").utf8)) }
            s.shellEnded()
        }
    }

    private func makeWeb() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(self, forURLScheme: "lx")
        cfg.userContentController.add(self, name: "engine")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        w.isHidden = true
        w.navigationDelegate = self
        if #available(iOS 16.4, *) { w.isInspectable = true }
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            win.addSubview(w)                                      // (a web view outside a window may be throttled)
        }
        web = w
        w.load(URLRequest(url: URL(string: "lx://host/engine.html")!))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        shutDown(String(localized: "The accelerated engine was stopped by iOS (memory). Tap to start again."))
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String, let d = s.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if msg["ready"] != nil {
            pageReady = true
            if first != nil && !booted { boot() }
        } else if let e = msg["error"] as? String {
            for s in sessions.values { s.webOutput(Data(("\r\n[engine] " + e.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)) }
        } else if msg["done"] != nil {
            shutDown("")
        }
    }

    // MARK: lx://host/

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        stopped.remove(ObjectIdentifier(task))                     // (an identifier may be reused)
        let path = url.path
        if path == "/tty" { tty(task, url); return }
        if path.hasPrefix("/net/") {
            WebNet.shared.handle(url, body: WebEngine.body(of: task.request)) { [weak self] status, data in
                self?.reply(task, url, data, ["X-Lx": status])
            }
            return
        }
        if path.hasPrefix("/fs/") {
            let (status, data) = SharedFiles.shared.handle(url, body: WebEngine.body(of: task.request))
            reply(task, url, data, ["X-Lx": status])
            return
        }
        if path == "/native-root.tar" {                            // the native engine's root, to start from
            DispatchQueue.global(qos: .userInitiated).async {
                let data = NativeRoot.tar()
                DispatchQueue.main.async { self.reply(task, url, data) }
            }
            return
        }
        // app files: the page, the worker, the core (web/), the Debian root (bundle root)
        let name = String(path.dropFirst())
        let file = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "web")
            ?? Bundle.main.url(forResource: name, withExtension: nil)
        let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
        let type = name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".js") ? "text/javascript"
            : name.hasSuffix(".wasm") ? "application/wasm" : "application/octet-stream"
        reply(task, url, data, ["Content-Type": type, "Cross-Origin-Opener-Policy": "same-origin",
                                "Cross-Origin-Embedder-Policy": "require-corp", "Cross-Origin-Resource-Policy": "same-origin"])
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
        if let w = waiting, w.task === task { waiting = nil }
    }

    private func reply(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, _ extra: [String: String] = [:]) {
        if stopped.remove(ObjectIdentifier(task)) != nil { return }
        var h = ["Content-Type": "application/octet-stream", "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        extra.forEach { h[$0] = $1 }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: h)!)
        task.didReceive(data)
        task.didFinish()
    }

    /// The terminals: the body is the tabs' output as frames ([u32 id][u32 length][bytes]),
    /// X-Meta carries titles and ended sessions; the answer is the keys typed since (frames),
    /// X-Ctl (new, resized, closed sessions) and X-Save. With nothing to send it waits up to
    /// ?wait= ms (a guest waiting for input costs no polling).
    private func tty(_ task: WKURLSchemeTask, _ url: URL) {
        if let out = WebEngine.body(of: task.request), !out.isEmpty { demux(out) }
        if let m = task.request.value(forHTTPHeaderField: "X-Meta")?.removingPercentEncoding, !m.isEmpty { meta(m) }
        if let w = waiting { waiting = nil; replyTTY(w.task, w.url) }   // (one at a time)
        let wait = Double(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "wait" }?.value ?? "0") ?? 0
        if !keys.isEmpty || !ctl.isEmpty || saveWanted || wait <= 0 { replyTTY(task, url); return }
        waitID += 1
        let id = waitID
        waiting = (task, url, id)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(wait, 200) / 1000) { [weak self] in
            guard let self, let w = self.waiting, w.id == id else { return }
            self.waiting = nil
            self.replyTTY(w.task, w.url)
        }
    }

    private func demux(_ d: Data) {
        let b = [UInt8](d)
        var i = 0
        while i + 8 <= b.count {
            let id = Int(UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24)
            let n = Int(UInt32(b[i + 4]) | UInt32(b[i + 5]) << 8 | UInt32(b[i + 6]) << 16 | UInt32(b[i + 7]) << 24)
            i += 8
            let e = min(i + n, b.count)
            if let s = sessions[id], e > i { s.webOutput(Data(b[i..<e])) }
            i = e
        }
    }

    private func meta(_ m: String) {
        for part in m.split(separator: ";") {
            let f = part.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count >= 2, let id = Int(f[1]) else { continue }
            if f[0] == "T", f.count == 3 { sessions[id]?.title = f[2] }
            else if f[0] == "E", let s = sessions.removeValue(forKey: id) { keys[id] = nil; s.shellEnded() }
        }
    }

    private func answerWaiting() {
        guard let w = waiting else { return }
        waiting = nil
        replyTTY(w.task, w.url)
    }

    private func replyTTY(_ task: WKURLSchemeTask, _ url: URL) {
        var extra: [String: String] = [:]
        if !ctl.isEmpty { extra["X-Ctl"] = ctl; ctl = "" }
        if saveWanted { extra["X-Save"] = "1"; saveWanted = false }
        var data = Data()
        for (id, k) in keys where !k.isEmpty {
            var h = [UInt8](repeating: 0, count: 8)
            for j in 0..<4 { h[j] = UInt8(truncatingIfNeeded: id >> (8 * j)); h[4 + j] = UInt8(truncatingIfNeeded: k.count >> (8 * j)) }
            data.append(contentsOf: h)
            data.append(contentsOf: k)
        }
        keys.removeAll()
        reply(task, url, data, extra)
    }

    /// A request's body: WebKit hands it over as data or as a stream.
    static func body(of r: URLRequest) -> Data? {
        if let b = r.httpBody { return b }
        guard let st = r.httpBodyStream else { return nil }
        var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
        st.open(); defer { st.close() }
        while true { let k = st.read(&buf, maxLength: buf.count); if k <= 0 { break }; out.append(buf, count: k) }
        return out
    }
}

/// The native engine's Debian (Application Support/debian) as one uncompressed tar file:
/// the accelerated engine's first start begins from it, so what was installed before is
/// there too. Written to Caches and handed over memory-mapped.
enum NativeRoot {
    static func tar() -> Data {
        let root = Store.rootDir
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("native-root.tar")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".lxterm-ok").path) else { return Data() }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: out) else { return Data() }
        var buf = Data()
        func flush(_ force: Bool) { if buf.count >= 1 << 20 || force { try? h.write(contentsOf: buf); buf.removeAll(keepingCapacity: true) } }
        func header(_ name: String, _ mode: UInt32, _ size: Int, _ type: UInt8, _ link: String = "") {
            var b = [UInt8](repeating: 0, count: 512)
            func put(_ o: Int, _ n: Int, _ s: String) { let u = Array(s.utf8.prefix(n)); for (i, c) in u.enumerated() { b[o + i] = c } }
            func oct(_ o: Int, _ n: Int, _ v: Int) { put(o, n - 1, String(String(v, radix: 8).suffix(n - 1)).leftPad(n - 1)) }
            put(0, 100, name); oct(100, 8, Int(mode & 0o7777)); oct(108, 8, 0); oct(116, 8, 0)
            oct(124, 12, size); oct(136, 12, Int(Date().timeIntervalSince1970)); for i in 148..<156 { b[i] = 32 }
            b[156] = type; put(157, 100, link); put(257, 6, "ustar"); put(263, 2, "00")
            let sum = b.reduce(0) { $0 + Int($1) }
            put(148, 7, String(String(sum, radix: 8)).leftPad(6) + "\0")
            buf.append(contentsOf: b)
        }
        func entry(_ name: String, _ mode: UInt32, _ data: Data?, _ type: UInt8, _ link: String = "") {
            let nb = Array(name.utf8)
            if nb.count > 99 {
                header("././@LongLink", 0o644, nb.count + 1, UInt8(ascii: "L"))
                var pad = nb + [0]; pad += [UInt8](repeating: 0, count: (512 - pad.count % 512) % 512)
                buf.append(contentsOf: pad)
            }
            header(name, mode, data?.count ?? 0, type, link)
            if let d = data, !d.isEmpty {
                buf.append(d)
                buf.append(contentsOf: [UInt8](repeating: 0, count: (512 - d.count % 512) % 512))
            }
            flush(false)
        }
        func walk(_ rel: String) {
            let dir = root.path + rel
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for n in names.sorted() {
                let r = rel + "/" + n, full = root.path + r, name = String(r.dropFirst())
                if r == "/root/Files" || r == "/.lxterm-ok" || r == "/proc" || r == "/dev" { if r != "/.lxterm-ok" { entry(name + "/", 0o755, nil, UInt8(ascii: "5")) }; continue }
                var st = stat()
                if lstat(full, &st) != 0 { continue }
                let mode = UInt32(st.st_mode)
                switch mode & UInt32(S_IFMT) {
                case UInt32(S_IFLNK):
                    let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? ""
                    entry(name, mode, nil, UInt8(ascii: "2"), link)
                case UInt32(S_IFDIR):
                    entry(name + "/", mode, nil, UInt8(ascii: "5"))
                    walk(r)
                case UInt32(S_IFREG):
                    if let d = try? Data(contentsOf: URL(fileURLWithPath: full), options: .mappedIfSafe) { entry(name, mode, d, UInt8(ascii: "0")) }
                default: break
                }
            }
        }
        walk("")
        buf.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        flush(true)
        try? h.close()
        return (try? Data(contentsOf: out, options: .mappedIfSafe)) ?? Data()
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

/// TCP connections and names for the guest (lxios/webjs/netbridge.js): opened by the app with
/// BSD sockets, kept by id; reads never block (the guest's poll asks again).
final class WebNet {
    static let shared = WebNet()
    private var conns: [Int: Int32] = [:]
    private var nextID = 1

    private static func open(_ host: String, _ port: Int) -> (Int32, String) {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return (-1, "unreach") }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        var why = "unreach"
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    return (fd, "ok")
                }
                why = errno == ECONNREFUSED ? "refused" : errno == ETIMEDOUT ? "timeout" : "unreach"
                close(fd)
            }
            ai = a.pointee.ai_next
        }
        return (-1, why)
    }

    func handle(_ url: URL, body: Data?, reply: @escaping (String, Data) -> Void) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ n: String) -> String? { q.first { $0.name == n }?.value }
        let id = Int(arg("id") ?? "") ?? 0
        switch url.path {
        case "/net/connect":
            let host = arg("host") ?? "", port = Int(arg("port") ?? "") ?? 0
            DispatchQueue.global().async {
                let (fd, why) = WebNet.open(host, port)
                DispatchQueue.main.async {
                    if fd < 0 { reply(why, Data()); return }
                    let n = self.nextID; self.nextID += 1
                    self.conns[n] = fd
                    reply("ok", Data(String(n).utf8))
                }
            }
        case "/net/resolve":
            let host = arg("host") ?? "", v6 = arg("type") == "AAAA"
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: v6 ? AF_INET6 : AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                var lines: [String] = []
                if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
                    var ai: UnsafeMutablePointer<addrinfo>? = first
                    while let a = ai {
                        var buf = [CChar](repeating: 0, count: 64)
                        if v6 { var sin = a.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }; inet_ntop(AF_INET6, &sin, &buf, 64) }
                        else { var sin = a.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }; inet_ntop(AF_INET, &sin, &buf, 64) }
                        let ip = String(cString: buf)
                        if !lines.contains(ip) { lines.append(ip) }
                        ai = a.pointee.ai_next
                    }
                    freeaddrinfo(first)
                }
                DispatchQueue.main.async { reply("ok", Data(lines.joined(separator: "\n").utf8)) }
            }
        case "/net/send":
            guard let fd = conns[id] else { reply("err", Data()); return }
            let data = body ?? Data()
            var sent = 0, ok = true
            data.withUnsafeBytes { p in
                while sent < data.count {
                    let k = send(fd, p.baseAddress! + sent, data.count - sent, 0)
                    if k > 0 { sent += k; continue }
                    if k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { var pf = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); _ = poll(&pf, 1, 1000); continue }
                    ok = false; break
                }
            }
            reply(ok && sent == data.count ? "ok" : "err", Data(String(sent).utf8))
        case "/net/recv", "/net/poll":
            guard let fd = conns[id] else { reply("err", Data()); return }
            let peek = url.path == "/net/poll"
            let max = peek ? 1 : min(Int(arg("max") ?? "") ?? 65536, 262144)
            var buf = [UInt8](repeating: 0, count: max)
            let k = recv(fd, &buf, max, peek ? (MSG_PEEK | MSG_DONTWAIT) : MSG_DONTWAIT)
            if k > 0 { reply("data", peek ? Data() : Data(buf[0..<k])) }
            else if k == 0 { reply("eof", Data()) }
            else if errno == EAGAIN || errno == EWOULDBLOCK { reply("again", Data()) }
            else { reply("err", Data()) }
        case "/net/avail":
            guard let fd = conns[id] else { reply("err", Data()); return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(fd, &buf, buf.count, MSG_PEEK | MSG_DONTWAIT)
            reply("ok", Data(String(max(n, 0)).utf8))
        case "/net/close":
            if let fd = conns.removeValue(forKey: id) { close(fd) }
            reply("ok", Data())
        default:
            reply("err", Data())
        }
    }
}

/// The folder shared with the Files app (lxios/webjs/filesbridge.js): Documents/Files is the
/// guest's /root/Files. Paths stay inside it.
final class SharedFiles {
    static let shared = SharedFiles()
    let root: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func url(_ p: String) -> URL? {
        let parts = p.split(separator: "/").map(String.init)
        if parts.contains("..") || parts.contains(".") { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    func handle(_ u: URL, body: Data?) -> (String, Data) {
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ n: String) -> String? { q.first { $0.name == n }?.value }
        guard let path = arg("p"), let f = url(path) else { return ("inval", Data()) }
        let fm = FileManager.default
        func code() -> String {
            switch errno { case ENOENT: return "noent"; case EEXIST: return "exist"; case ENOTDIR: return "notdir"
            case EISDIR: return "isdir"; case ENOTEMPTY: return "notempty"; case EACCES, EPERM: return "acces"; default: return "io" }
        }
        switch u.path {
        case "/fs/stat":
            var st = stat()
            if lstat(f.path, &st) != 0 { return (code(), Data()) }
            return ("ok", Data("{\"mode\":\(st.st_mode),\"size\":\(st.st_size),\"mtime\":\(st.st_mtimespec.tv_sec)}".utf8))
        case "/fs/readdir":
            guard let names = try? fm.contentsOfDirectory(atPath: f.path) else { return ("noent", Data()) }
            return ("ok", Data(names.joined(separator: "\n").utf8))
        case "/fs/read":
            let off = UInt64(arg("off") ?? "0") ?? 0, len = Int(arg("len") ?? "0") ?? 0
            guard let h = try? FileHandle(forReadingFrom: f) else { return (code(), Data()) }
            defer { try? h.close() }
            try? h.seek(toOffset: off)
            return ("ok", (try? h.read(upToCount: min(len, 1 << 20))) ?? Data())
        case "/fs/write":
            let off = UInt64(arg("off") ?? "0") ?? 0
            if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: f) else { return (code(), Data()) }
            defer { try? h.close() }
            try? h.seek(toOffset: off)
            try? h.write(contentsOf: body ?? Data())
            return ("ok", Data())
        case "/fs/create":
            if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: nil) }
            return ("ok", Data())
        case "/fs/truncate":
            return truncate(f.path, off_t(Int64(arg("size") ?? "0") ?? 0)) == 0 ? ("ok", Data()) : (code(), Data())
        case "/fs/mkdir":
            return mkdir(f.path, 0o755) == 0 ? ("ok", Data()) : (code(), Data())
        case "/fs/unlink":
            return unlink(f.path) == 0 ? ("ok", Data()) : (code(), Data())
        case "/fs/rmdir":
            return rmdir(f.path) == 0 ? ("ok", Data()) : (code(), Data())
        case "/fs/rename":
            guard let to = arg("to"), let t = url(to) else { return ("inval", Data()) }
            return rename(f.path, t.path) == 0 ? ("ok", Data()) : (code(), Data())
        default:
            return ("inval", Data())
        }
    }
}
