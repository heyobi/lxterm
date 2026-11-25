import SwiftTerm
import SwiftUI
import UIKit

enum Settings {
    static var fontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "fontSize"); return v > 0 ? v : 13 }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize") }
    }

    /// The fonts iOS has that keep columns: SF Mono (the system's), Menlo, Courier New.
    static let fonts: [(id: String, name: String)] = [("system", "SF Mono"), ("Menlo-Regular", "Menlo"), ("CourierNewPSMT", "Courier New")]

    static var font: UIFont {
        let size = CGFloat(fontSize)
        let id = UserDefaults.standard.string(forKey: "font") ?? "system"
        if id != "system", let f = UIFont(name: id, size: size) { return f }
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var cursor: CursorStyle {
        let blink = UserDefaults.standard.object(forKey: "cursorBlink") as? Bool ?? true
        switch UserDefaults.standard.string(forKey: "cursor") ?? "block" {
        case "underline": return blink ? .blinkUnderline : .steadyUnderline
        case "bar": return blink ? .blinkBar : .steadyBar
        default: return blink ? .blinkBlock : .steadyBlock
        }
    }
}

/// Terminal colours.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: LocalizedStringKey
    let background: UIColor
    let foreground: UIColor
    let cursor: UIColor

    static let all: [Theme] = [
        Theme(id: "night", name: "Night", background: UIColor(red: 0.06, green: 0.065, blue: 0.08, alpha: 1),
              foreground: UIColor(white: 0.9, alpha: 1), cursor: UIColor(red: 0.31, green: 0.92, blue: 0.55, alpha: 1)),
        Theme(id: "paper", name: "Paper", background: UIColor(white: 0.98, alpha: 1),
              foreground: UIColor(white: 0.12, alpha: 1), cursor: UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)),
        Theme(id: "solarized", name: "Solarized", background: UIColor(red: 0.0, green: 0.169, blue: 0.212, alpha: 1),
              foreground: UIColor(red: 0.514, green: 0.58, blue: 0.588, alpha: 1), cursor: UIColor(red: 0.71, green: 0.54, blue: 0.0, alpha: 1)),
        Theme(id: "amber", name: "Amber", background: UIColor(red: 0.07, green: 0.05, blue: 0.0, alpha: 1),
              foreground: UIColor(red: 1.0, green: 0.71, blue: 0.0, alpha: 1), cursor: UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)),
    ]

    /// "auto": Night or Paper, as the iPhone is dark or light.
    static var automatic: Bool { UserDefaults.standard.string(forKey: "theme") == "auto" }

    static var current: Theme {
        var id = UserDefaults.standard.string(forKey: "theme") ?? "night"
        if id == "auto" { id = UITraitCollection.current.userInterfaceStyle == .light ? "paper" : "night" }
        return all.first { $0.id == id } ?? all[0]
    }

    var isDark: Bool { id != "paper" }

    /// Each distribution's own colours in its tabs (Settings › Distribution colours): the
    /// terminal's, set by the app; nothing in the distribution is changed.
    static var distroColours: Bool { UserDefaults.standard.object(forKey: "distroColours") as? Bool ?? true }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let distros: [String: Theme] = [
        "ubuntu": Theme(id: "ubuntu", name: "Ubuntu", background: rgb(0x300A24), foreground: rgb(0xFFFFFF), cursor: rgb(0xE95420)),
        "fedora": Theme(id: "fedora", name: "Fedora", background: rgb(0x0B1C2E), foreground: rgb(0xE8EEF4), cursor: rgb(0x51A2DA)),
        "arch": Theme(id: "arch", name: "Arch", background: rgb(0x0E1419), foreground: rgb(0xD8DEE9), cursor: rgb(0x1793D1)),
        "alpine": Theme(id: "alpine", name: "Alpine", background: rgb(0x0C1A2B), foreground: rgb(0xE2E8F0), cursor: rgb(0x3A8FC1)),
        "opensuse": Theme(id: "opensuse", name: "openSUSE", background: rgb(0x10201A), foreground: rgb(0xE6F0E6), cursor: rgb(0x73BA25)),
        "almalinux": Theme(id: "almalinux", name: "AlmaLinux", background: rgb(0x14171F), foreground: rgb(0xEDEFF3), cursor: rgb(0xFFCB12)),
        "rocky": Theme(id: "rocky", name: "Rocky", background: rgb(0x0E1D17), foreground: rgb(0xE5F2EC), cursor: rgb(0x10B981)),
    ]

    /// The theme of a tab: its distribution's when that is on, else the chosen one.
    static func of(_ d: Distro) -> Theme {
        if distroColours, !d.builtIn, let t = distros[d.id] { return t }
        return current
    }

    func apply(to tv: TerminalView) {
        tv.nativeBackgroundColor = background
        tv.nativeForegroundColor = foreground
        tv.caretColor = cursor
        tv.backgroundColor = background
        tv.keyboardAppearance = isDark ? .dark : .light
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = "night"
    @AppStorage("webEngine") private var webEngine = false
    @AppStorage("font") private var font = "system"
    @AppStorage("cursor") private var cursor = "block"
    @AppStorage("cursorBlink") private var cursorBlink = true
    @AppStorage("distroColours") private var distroColours = true
    @State private var size = Settings.fontSize
    @State private var resetting: Distro?
    @ObservedObject private var distros = DistroManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    HStack {
                        Text("Size")
                        Slider(value: $size, in: 8...28, step: 1)
                        Text("\(Int(size))").monospacedDigit().frame(width: 28)
                    }
                    Picker("Font", selection: $font) {
                        ForEach(Settings.fonts, id: \.id) { f in Text(f.name).tag(f.id) }
                    }
                    Picker("Cursor", selection: $cursor) {
                        Text("Block").tag("block"); Text("Underline").tag("underline"); Text("Bar").tag("bar")
                    }
                    Toggle("Blinking cursor", isOn: $cursorBlink)
                    Text("Pinch the terminal to change the size too.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Colours") {
                    Picker("Theme", selection: $theme) {
                        Text("Automatic (light or dark, as the iPhone)").tag("auto")
                        ForEach(Theme.all) { t in Text(t.name).tag(t.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Toggle("Distribution colours", isOn: $distroColours)
                }
                Section {
                    NavigationLink { DistrosView() } label: {
                        LabeledContent("Distributions", value: DistroManager.shared.installed.map(\.name).joined(separator: ", "))
                    }
                } footer: {
                    Text("Ubuntu, Alpine Linux, Fedora, AlmaLinux, Rocky Linux, openSUSE and Arch Linux ARM can be downloaded for new tabs, beside Debian.")
                }
                Section {
                    Toggle("Accelerated engine (beta)", isOn: $webEngine)
                } footer: {
                    Text("New tabs (marked ⚡) run Debian in WebKit's WebAssembly engine, which compiles programs as they run: long jobs are several times faster. It starts from a copy of your system and keeps its own from then on.")
                }
                Section {
                    Menu {
                        ForEach(distros.installed) { d in Button(d.name) { resetting = d } }
                    } label: {
                        Text("Reset a distribution…").foregroundStyle(.red)
                    }
                } footer: {
                    Text("Erases everything installed or changed in the chosen distribution and puts a fresh copy in its place: Debian from the app, the others downloaded again. Use it if a system no longer starts.")
                }
                Section("About") {
                    Text("Linux distributions' own arm64 programs (Debian, Ubuntu, Alpine Linux, Fedora, AlmaLinux, Rocky Linux, openSUSE, Arch Linux ARM), unmodified, run on this iPhone in a no-JIT AArch64 interpreter with a Linux system-call layer. Not affiliated with or endorsed by these projects.")
                        .font(.footnote)
                    Link(destination: URL(string: "https://apps.apple.com/developer/id6820301575")!) {
                        Label("Enjoying LxTerm? See my other apps", systemImage: "app.badge.checkmark")
                    }
                    Link("Source code (GPL-3.0)", destination: URL(string: "https://github.com/heyobi/lxterm")!)
                    NavigationLink("Package sources") { PackageSourcesView() }
                    Link("Privacy", destination: URL(string: "https://github.com/heyobi/lxterm/blob/main/PRIVACY.md")!)
                    NavigationLink("Licenses") { LicensesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: size) { _, v in
                Settings.fontSize = v
                NotificationCenter.default.post(name: .lxFontChanged, object: nil)
            }
            .onChange(of: theme) { _, _ in NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
            .onChange(of: font) { _, _ in NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
            .onChange(of: cursor) { _, _ in NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
            .onChange(of: cursorBlink) { _, _ in NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
            .onChange(of: distroColours) { _, _ in NotificationCenter.default.post(name: .lxFontChanged, object: nil) }
            .confirmationDialog(Text("Reset \(resetting?.name ?? "")?"), isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), titleVisibility: .visible) {
                Button("Erase and start fresh", role: .destructive) {
                    guard let d = resetting else { return }
                    if d.builtIn { dismiss(); store.reset() }
                    else {
                        for s in store.sessions where s.distro == d { store.close(s) }
                        distros.remove(d)
                        distros.download(d)
                    }
                }
            } message: {
                Text("Installed packages, your files in it (not those in /root/Files) and its open tabs are deleted.")
            }
        }
    }
}

/// Where each distribution publishes the source code of its packages.
struct PackageSourcesView: View {
    static let sources: [(String, String)] = [
        ("Debian", "https://sources.debian.org"),
        ("Ubuntu", "https://launchpad.net/ubuntu"),
        ("Alpine Linux", "https://gitlab.alpinelinux.org/alpine/aports"),
        ("Fedora", "https://src.fedoraproject.org"),
        ("AlmaLinux", "https://git.almalinux.org"),
        ("Rocky Linux", "https://git.rockylinux.org"),
        ("openSUSE", "https://build.opensuse.org"),
        ("Arch Linux ARM", "https://github.com/archlinuxarm/PKGBUILDs"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(PackageSourcesView.sources, id: \.0) { name, url in
                    Link(destination: URL(string: url)!) {
                        LabeledContent(name, value: URL(string: url)?.host ?? url)
                    }
                }
            } footer: {
                Text("The programs in each distribution are that project's own binaries, unmodified; each project publishes their source code here. The package managers can fetch it too, for example apt source, dnf download --source or asp.")
            }
        }
        .navigationTitle("Package sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small Markdown reader for the notices: headings, paragraphs (hard-wrapped lines
/// joined), tables as one block per row, inline `code`, **bold** and links.
struct MarkdownText: View {
    let blocks: [(kind: Int, text: String)]                    // 1-3 heading, 0 paragraph, 9 table row

    init(_ md: String) {
        var out: [(Int, String)] = [], para: [String] = []
        func flush() { if !para.isEmpty { out.append((0, para.joined(separator: " "))); para = [] } }
        var header: [String] = []
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); header = []; continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append((min(level, 3), line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                flush()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if header.isEmpty { header = cells; continue }
                let row = zip(header, cells).map { "**\($0)**: \($1)" }.joined(separator: "\n")
                out.append((9, row))
            } else { para.append(line) }
        }
        flush()
        blocks = out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                let a = (try? AttributedString(markdown: b.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(b.text)
                switch b.kind {
                case 1: Text(a).font(.title2.bold())
                case 2: Text(a).font(.title3.bold()).padding(.top, 6)
                case 3: Text(a).font(.headline)
                case 9: Text(a).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                default: Text(a).font(.subheadline)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            ForEach(["LICENSE", "NOTICE.md", "SwiftTerm-LICENSE.txt"], id: \.self) { name in
                if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                             withExtension: (name as NSString).pathExtension.isEmpty ? nil : (name as NSString).pathExtension,
                                             subdirectory: "licenses"),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    NavigationLink(name) {
                        ScrollView {
                            if name.hasSuffix(".md") { MarkdownText(text).padding() }
                            else { Text(text).font(.system(.footnote, design: .monospaced)).padding() }
                        }
                        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("Licenses")
    }
}
