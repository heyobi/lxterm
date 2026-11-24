import Foundation
import UIKit
import WebKit

/// The accelerated engine (Settings › Accelerated engine): the same core built for WebAssembly
/// runs in a hidden WKWebView, where the JavaScript engine's JIT compiles the guest code the
/// core translates (the only JIT iOS gives an app). One shell at a time. The page reaches the
/// app over lx://host/: `tty` (the terminal: output in, keys out, held while no key is due),
/// `net/…` (TCP connections and names for the guest), `fs/…` (the guest's /root/Files is
/// Documents/Files, seen in the Files app); everything else comes from the app bundle.
final class WebEngine: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    static let shared = WebEngine()

    private var web: WKWebView?
    private weak var session: Session?
    private var pageReady = false, startPending = false, fresh = false

    // terminal state, main thread only
    private var keys = [UInt8]()
    private var size: (Int, Int)?
    private var saveWanted = false
    private var waiting: (task: WKURLSchemeTask, url: URL, id: Int)?
    private var waitID = 0
    private var stopped = Set<ObjectIdentifier>()

    var running: Bool { session != nil }

    /// Settings › Reset: the engine's next shell starts from the root in the app, not its saved copy.
    static func resetRoot() { UserDefaults.standard.set(true, forKey: "webFresh") }

    /// Starts a shell for `s` (a fresh root when `freshRoot`: Settings › Reset).
    func start(_ s: Session, cols: Int, rows: Int, freshRoot: Bool = false) {
        session = s
        size = (cols, rows)
        fresh = freshRoot || UserDefaults.standard.bool(forKey: "webFresh")
        UserDefaults.standard.removeObject(forKey: "webFresh")
        keys.removeAll()
        if web == nil { makeWeb() }
        if pageReady { web?.evaluateJavaScript("lxStart(\(fresh))") } else { startPending = true }
    }

    func input(_ bytes: [UInt8]) {
        keys.append(contentsOf: bytes)
        answerWaiting()
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        answerWaiting()
    }

    /// The root goes to OPFS at the shell's next turn (the app goes to the background).
    func save() {
        saveWanted = true
        answerWaiting()
    }

    /// The page is dropped: the shell ends without a save (Close tab).
    func stop() {
        session = nil
        web?.removeFromSuperview()
        web = nil
        pageReady = false
        waiting = nil
    }

    private func makeWeb() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(self, forURLScheme: "lx")
        cfg.userContentController.add(self, name: "engine")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        w.isHidden = true
        if #available(iOS 16.4, *) { w.isInspectable = true }
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            win.addSubview(w)                                      // (a web view outside a window may be throttled)
        }
        web = w
        w.load(URLRequest(url: URL(string: "lx://host/engine.html")!))
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let s = m.body as? String, let d = s.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if msg["ready"] != nil {
            pageReady = true
            if startPending { startPending = false; web?.evaluateJavaScript("lxStart(\(fresh))") }
        } else if let e = msg["error"] as? String {
            session?.webOutput(Data(("\r\n[engine] " + e.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8))
        } else if msg["done"] != nil {
            let s = session
            session = nil
            s?.shellEnded()
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

    /// The terminal: the body is the guest's output; the answer carries the keys typed since,
    /// and in headers a new size and a save request. With nothing to send, it waits up to
    /// ?wait= ms for a key (a guest waiting for input costs no polling).
    private func tty(_ task: WKURLSchemeTask, _ url: URL) {
        if let out = WebEngine.body(of: task.request), !out.isEmpty { session?.webOutput(out) }
        if let w = waiting { waiting = nil; replyTTY(w.task, w.url) }   // (one at a time)
        let wait = Double(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "wait" }?.value ?? "0") ?? 0
        if !keys.isEmpty || size != nil || saveWanted || wait <= 0 { replyTTY(task, url); return }
        waitID += 1
        let id = waitID
        waiting = (task, url, id)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(wait, 200) / 1000) { [weak self] in
            guard let self, let w = self.waiting, w.id == id else { return }
            self.waiting = nil
            self.replyTTY(w.task, w.url)
        }
    }

    private func answerWaiting() {
        guard let w = waiting else { return }
        waiting = nil
        replyTTY(w.task, w.url)
    }

    private func replyTTY(_ task: WKURLSchemeTask, _ url: URL) {
        var extra: [String: String] = [:]
        if let (c, r) = size { extra["X-Size"] = "\(c),\(r)"; size = nil }
        if saveWanted { extra["X-Save"] = "1"; saveWanted = false }
        let data = Data(keys)
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
