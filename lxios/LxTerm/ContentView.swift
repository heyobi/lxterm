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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hsize
    @AppStorage("split") private var split = false
    @State private var showSearch = false
    @State private var showSnippets = false

    var body: some View {
        let theme = Theme.current
        VStack(spacing: 0) {
            TabStrip(showSettings: $showSettings, showPorts: $showPorts, showSearch: $showSearch, showSnippets: $showSnippets)
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
                } else if hsize == .regular, split, proxy.size.width > 640 {   // iPad: two shells side by side
                    HStack(spacing: 0) {
                        terminal(store.current).frame(width: (proxy.size.width - 1) / 2)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
                        secondHalf
                    }
                } else {
                    terminal(store.current)
                }
            }
        }
        .background { KeyCommands(showSettings: $showSettings, showPorts: $showPorts, split: $split, showSearch: $showSearch, showSnippets: $showSnippets) }
        .background(Color(theme.background).ignoresSafeArea())
        .preferredColorScheme(Theme.automatic ? nil : theme.isDark ? .dark : .light)
        .onChange(of: scheme) { _, _ in                            // Automatic: the iPhone turned light or dark
            if Theme.automatic { NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
        }
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
        .sheet(isPresented: $showSearch) { if let s = store.current { SearchView(session: s) } }
        .sheet(isPresented: $showSnippets) { SnippetsView().environmentObject(store).presentationDetents([.medium, .large]) }
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
        let n = store.sessions.count
        let others = (1..<max(n, 1)).map { (store.selected + $0) % n }.filter { $0 != store.selected }   // the next tab first
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

/// A hardware keyboard's shortcuts (iPad, or a keyboard on the iPhone): hold ⌘ to see them.
struct KeyCommands: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool
    @Binding var showPorts: Bool
    @Binding var split: Bool
    @Binding var showSearch: Bool
    @Binding var showSnippets: Bool

    var body: some View {
        ZStack {
            Button("Search the Output") { showSearch = true }.keyboardShortcut("f", modifiers: .command)
            Button("Saved Commands") { showSnippets = true }.keyboardShortcut("k", modifiers: .command)
            Button("New Tab") { store.newSession() }.keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { if let s = store.current { store.close(s) } }.keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { store.selectNext(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectNext(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { i in
                Button("Tab \(i)") { if store.sessions.count >= i { store.select(i - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: .command)
            }
            Button("Bigger Text") { KeyCommands.font(+1) }.keyboardShortcut("+", modifiers: .command)
            Button("Bigger Text") { KeyCommands.font(+1) }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { KeyCommands.font(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("Ports") { showPorts = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Settings") { showSettings = true }.keyboardShortcut(",", modifiers: .command)
            Button("Split View") { split.toggle() }.keyboardShortcut("d", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    static func font(_ d: Double) {
        Settings.fontSize = min(28, max(8, Settings.fontSize + d))
        NotificationCenter.default.post(name: .lxFontChanged, object: nil)
    }
}

struct TabStrip: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool
    @Binding var showPorts: Bool
    @Binding var showSearch: Bool
    @Binding var showSnippets: Bool
    @ObservedObject private var ports = Ports.shared
    @Environment(\.horizontalSizeClass) private var hsize
    @AppStorage("split") private var split = false

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
            if hsize == .regular {
                Button { split.toggle() } label: { Image(systemName: split ? "rectangle" : "rectangle.split.2x1") }
                    .accessibilityLabel(Text("Split View"))
            }
            NewTabButton()
            Menu {
                Button("Saved Commands", systemImage: "text.badge.star") { showSnippets = true }
                Button("Search the Output", systemImage: "magnifyingglass") { showSearch = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(Text("More"))
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
