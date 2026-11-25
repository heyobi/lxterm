import SwiftUI
import WebKit

/// A browser inside LxTerm for servers running in the shells (python3 -m http.server, Flask,
/// Jupyter): opening Safari would send LxTerm to the background, where iOS soon suspends it
/// and the server with it. Opened from Ports, a port's notice, or a localhost link.
struct BrowserPage: Identifiable { let id = UUID(); let url: URL }

@MainActor
final class BrowserModel: ObservableObject {
    @Published var title = ""
    @Published var url: URL?
    @Published var canBack = false
    @Published var canForward = false
    @Published var loading = false
    @Published var failed: String?
    let web: WKWebView
    private var watch: [NSKeyValueObservation] = []

    init() {
        web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.allowsBackForwardNavigationGestures = true
        watch = [
            web.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? "" } },
            web.observe(\.url) { [weak self] w, _ in Task { @MainActor in self?.url = w.url } },
            web.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in Task { @MainActor in self?.canForward = w.canGoForward } },
            web.observe(\.isLoading) { [weak self] w, _ in Task { @MainActor in self?.loading = w.isLoading } },
        ]
    }

    func load(_ u: URL) {
        failed = nil
        web.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()
    @ObservedObject private var ports = Ports.shared
    let start: URL

    init(url: URL) { start = url }

    private var heading: String {
        if let u = model.url, let h = u.host { return u.port.map { "\(h):\($0)" } ?? h }
        return start.host ?? ""
    }

    var body: some View {
        NavigationStack {
            WebPage(model: model)
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if let f = model.failed {
                        ContentUnavailableView {
                            Label("Nothing answers here", systemImage: "network.slash")
                        } description: {
                            Text(f)
                        } actions: {
                            Button("Try again") { model.load(model.url ?? start) }
                        }
                        .background(Color(.systemBackground))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .principal) {
                        Menu {
                            ForEach(ports.list) { p in
                                Button { model.load(Ports.url(p.port)) } label: {
                                    Text(verbatim: p.program.isEmpty ? "localhost:\(p.port)" : "localhost:\(p.port) · \(p.program)")
                                }
                            }
                        } label: {
                            VStack(spacing: 0) {
                                Text(model.title.isEmpty ? heading : model.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if !model.title.isEmpty { Text(heading).font(.caption2).foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(.primary)
                        }
                        .disabled(ports.list.count < 2)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.web.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!model.canBack).accessibilityLabel(Text("Back"))
                        Spacer()
                        Button { model.web.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!model.canForward).accessibilityLabel(Text("Forward"))
                        Spacer()
                        Button { if model.loading { model.web.stopLoading() } else { model.load(model.url ?? start) } } label: {
                            Image(systemName: model.loading ? "xmark" : "arrow.clockwise")
                        }
                        .accessibilityLabel(Text("Reload"))
                        Spacer()
                        ShareLink(item: model.url ?? start) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        }
        .onAppear { model.load(start) }
    }

    /// 0.0.0.0 (what servers print) is this phone.
    static func local(_ u: URL?) -> URL? {
        guard let u, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        if c.host == "0.0.0.0" || c.host == "[::]" || c.host == "::" { c.host = "localhost" }
        return c.url
    }

    static func isLocal(_ u: URL) -> Bool {
        ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1", "::"].contains(u.host ?? "")
    }
}

private struct WebPage: UIViewRepresentable {
    let model: BrowserModel

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(_ m: BrowserModel) { model = m }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            let code = (e as NSError).code
            if code == NSURLErrorCancelled { return }
            Task { @MainActor in
                model.failed = code == NSURLErrorCannotConnectToHost
                    ? String(localized: "No server is listening on this port. Start one in a shell, then try again.")
                    : e.localizedDescription
            }
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { Task { @MainActor in model.failed = nil } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> WKWebView {
        model.web.navigationDelegate = context.coordinator
        return model.web
    }

    func updateUIView(_ w: WKWebView, context: Context) {}
}

extension Notification.Name {
    static let lxOpenBrowser = Notification.Name("lxOpenBrowser")
}
