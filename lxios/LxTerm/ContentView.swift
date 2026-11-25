import SwiftTerm
import SwiftUI

@main
struct LxTermApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear { store.boot() }
                .onChange(of: phase) { _, p in if p == .background { store.saveAll() } }
                .onOpenURL { url in store.receive(url) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        switch store.phase {
        case .unpacking(let f): SetupView(progress: f)
        case .failed(let e): FailedView(error: e)
        case .ready: MainView()
        }
    }
}

/// First launch: Debian is unpacked into the app's own storage.
struct SetupView: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "terminal")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.green)
            Text("Preparing Debian").font(.title2.bold())
            ProgressView(value: progress).frame(maxWidth: 260)
            Text("Debian 13 is unpacked onto this iPhone once. It takes a few seconds.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Theme.all[0].background))
        .preferredColorScheme(.dark)
    }
}

struct FailedView: View {
    let error: String
    var body: some View {
        ContentUnavailableView("Debian could not be prepared", systemImage: "exclamationmark.triangle", description: Text(error))
    }
}

/// Tabs on top, the terminal below. On an iPhone Duo the fold is never crossed: half open
/// like a laptop the terminal stays above the fold; open like a book two shells sit side
/// by side, one on each half.
struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false
    @State private var themeTick = 0
    @State private var browser: BrowserPage?
    @State private var showPorts = false
    @ObservedObject private var ports = Ports.shared

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            TabStrip(showSettings: $showSettings, showPorts: $showPorts)
            GeometryReader { proxy in
                let fold = foldFrame(proxy)
                if let fold, fold.width > fold.height {                // laptop: above the fold
                    terminal(store.current)
                        .frame(height: max(120, fold.minY))
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if let fold, fold.height > fold.width, store.sessions.count > 0 {   // book: one shell per half
                    HStack(spacing: 0) {
                        terminal(store.current).frame(width: max(100, fold.minX))
                        Color.clear.frame(width: fold.width)
                        secondHalf.frame(width: max(100, proxy.size.width - fold.maxX))
                    }
                } else {
                    terminal(store.current)
                }
            }
        }
        .background(Color(theme.background).ignoresSafeArea())
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay(alignment: .top) {
            if let p = ports.announced {
                PortToast(port: p, open: { ports.announced = nil; browser = BrowserPage(url: Ports.url(p.port)) },
                          close: { ports.announced = nil })
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: p.port) { try? await Task.sleep(for: .seconds(8)); if ports.announced == p { ports.announced = nil } }
            }
        }
        .animation(.spring(duration: 0.3), value: ports.announced)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $showPorts) {
            PortsView { u in DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { browser = BrowserPage(url: u) } }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $browser) { BrowserView(url: $0.url) }
        .onReceive(NotificationCenter.default.publisher(for: .lxOpenBrowser)) { n in
            if let u = n.object as? URL { browser = BrowserPage(url: BrowserView.local(u) ?? u) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lxFontChanged)) { _ in
            for s in store.sessions { s.applySettings() }
            themeTick += 1
        }
        .id(themeTick)
    }

    @ViewBuilder private func terminal(_ s: Session?) -> some View {
        if let s { TerminalHost(session: s).id(s.id) } else { Color.clear }
    }

    @ViewBuilder private var secondHalf: some View {
        let others = store.sessions.indices.filter { $0 != store.selected }
        if let i = others.first {
            terminal(store.sessions[i])
        } else {
            Button { store.newSession(); store.select(0) } label: {
                Label("Second shell", systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TabStrip: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool
    @Binding var showPorts: Bool
    @ObservedObject private var ports = Ports.shared

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                        TabChip(session: s, selected: i == store.selected,
                                select: { store.select(i) }, close: { store.close(s) })
                    }
                }
                .padding(.horizontal, 10)
            }
            Button {
                if let v = store.current?.view { _ = v.isFirstResponder ? v.resignFirstResponder() : v.becomeFirstResponder() }
            } label: { Image(systemName: "keyboard") }
                .accessibilityLabel(Text("Show or hide the keyboard"))
            Button { showPorts = true } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .overlay(alignment: .topTrailing) {
                        if !ports.list.isEmpty {
                            Text("\(ports.list.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).background(Capsule().fill(.green)).offset(x: 9, y: -7)
                        }
                    }
            }
            .accessibilityLabel(Text("Ports: servers running in the shells"))
            NewTabButton()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(Text("Settings"))
                .padding(.trailing, 12)
        }
        .font(.system(size: 17, weight: .medium))
        .frame(height: 44)
        .background(.bar)
    }
}

/// "+": a new Debian shell; with other distributions downloaded, a menu of them.
struct NewTabButton: View {
    @EnvironmentObject var store: Store
    @State private var showDistros = false
    @ObservedObject private var distros = DistroManager.shared

    var body: some View {
        let others = distros.installed.filter { !$0.builtIn }
        Group {
            if others.isEmpty {
                Button { store.newSession() } label: { Image(systemName: "plus") }
            } else {
                Menu {
                    ForEach([Distro.debian] + others) { d in
                        Button(d.name) { store.newSession(d) }
                    }
                    Divider()
                    Button("Get more…") { showDistros = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .accessibilityLabel(Text("New shell"))
        .sheet(isPresented: $showDistros) {
            NavigationStack {
                DistrosView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDistros = false } } }
            }
            .environmentObject(store)
        }
    }
}

struct TabChip: View {
    @ObservedObject var session: Session
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.exited ? "stop.circle" : session.accelerated ? "bolt.fill" : session.distro.builtIn ? "terminal" : "shippingbox").font(.caption)
            Text(session.title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
            if selected {
                Button(action: close) { Image(systemName: "xmark").font(.caption2.bold()) }
                    .accessibilityLabel(Text("Close shell"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
        .onTapGesture(perform: select)
    }
}

/// The terminal view of a session (SwiftTerm), started the first time it is shown.
struct TerminalHost: UIViewRepresentable {
    let session: Session

    func makeUIView(context: Context) -> TerminalView {
        let v = session.view
        DispatchQueue.main.async {
            session.start()
            _ = v.becomeFirstResponder()
        }
        return v
    }

    func updateUIView(_ v: TerminalView, context: Context) {}
}

/// The division (fold) of an iPhone Duo in this geometry's coordinates, if any; from the
/// system, never assumed to be the middle.
func foldFrame(_ proxy: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
        if let d = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first {
            return d.frame
        }
    }
    return nil
}
