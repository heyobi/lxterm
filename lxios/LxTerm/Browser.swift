import SwiftUI
import WebKit

/// A browser inside LxTerm for servers running in Debian (python3 -m http.server, Flask,
/// Jupyter): opening Safari would send LxTerm to the background, where iOS soon suspends it
/// and the server with it. Opened from the globe button or a localhost link in a shell.
struct BrowserPage: Identifiable { let id = UUID(); let url: URL }

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var target: URL
    @State private var reload = 0

    init(url: URL) {
        _address = State(initialValue: url.absoluteString)
        _target = State(initialValue: url)
    }

    var body: some View {
        NavigationStack {
            WebPage(url: target, reload: reload)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TextField("http://localhost:8000", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { go() }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(Text("Reload"))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func go() {
        var s = address.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "http://" + s }
        if let u = BrowserView.local(URL(string: s)) { target = u; reload += 1 }
    }

    /// 0.0.0.0 (what servers print) is this phone.
    static func local(_ u: URL?) -> URL? {
        guard let u, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        if c.host == "0.0.0.0" || c.host == "[::]" { c.host = "127.0.0.1" }
        return c.url
    }

    static func isLocal(_ u: URL) -> Bool {
        ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"].contains(u.host ?? "")
    }
}

private struct WebPage: UIViewRepresentable {
    let url: URL
    let reload: Int

    final class Coordinator { var shown: (URL, Int)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.allowsBackForwardNavigationGestures = true
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.shown?.0 != url || context.coordinator.shown?.1 != reload {
            context.coordinator.shown = (url, reload)
            w.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
}

extension Notification.Name {
    static let lxOpenBrowser = Notification.Name("lxOpenBrowser")
}
