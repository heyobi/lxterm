import SwiftTerm
import SwiftUI
import UIKit

enum Settings {
    static var fontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "fontSize"); return v > 0 ? v : 13 }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize") }
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
    @State private var size = Settings.fontSize
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    HStack {
                        Text("Size")
                        Slider(value: $size, in: 8...28, step: 1)
                        Text("\(Int(size))").monospacedDigit().frame(width: 28)
                    }
                    Text("Pinch the terminal to change the size too.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Colours") {
                    Picker("Theme", selection: $theme) {
                        Text("Automatic (light or dark, as the iPhone)").tag("auto")
                        ForEach(Theme.all) { t in Text(t.name).tag(t.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    NavigationLink { DistrosView() } label: {
                        LabeledContent("Distributions", value: DistroManager.shared.installed.map(\.name).joined(separator: ", "))
                    }
                } footer: {
                    Text("Ubuntu, Alpine Linux, Fedora, AlmaLinux, Rocky Linux and openSUSE can be downloaded for new tabs, beside Debian.")
                }
                Section {
                    Toggle("Accelerated engine (beta)", isOn: $webEngine)
                } footer: {
                    Text("New tabs (marked ⚡) run Debian in WebKit's WebAssembly engine, which compiles programs as they run: long jobs are several times faster. It starts from a copy of your system and keeps its own from then on.")
                }
                Section {
                    Button("Reset Debian…", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Erases everything installed or changed in Debian and unpacks a fresh system. Use it if the system no longer starts.")
                }
                Section("About") {
                    Text("Debian's own arm64 programs, unmodified, run on this iPhone in a no-JIT AArch64 interpreter with a Linux system-call layer. Not affiliated with the Debian Project.")
                        .font(.footnote)
                    Link("Source code (GPL-3.0)", destination: URL(string: "https://github.com/heyobi/lxterm")!)
                    Link("Debian package sources", destination: URL(string: "https://sources.debian.org")!)
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
            .confirmationDialog("Reset Debian?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Erase and unpack again", role: .destructive) { dismiss(); store.reset() }
            } message: {
                Text("Installed packages, your files in Debian and open shells are deleted.")
            }
        }
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
                    NavigationLink(name) { ScrollView { Text(text).font(.system(.footnote, design: .monospaced)).padding() } }
                }
            }
        }
        .navigationTitle("Licenses")
    }
}
