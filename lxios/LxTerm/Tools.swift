import AppIntents
import SwiftUI
import UIKit

/// Search in what a tab has shown (the last 256 KB of its output): matching lines, newest
/// first; tap one to copy it.
struct SearchView: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var copied: String?

    private var lines: [String] {
        Headless.plain(session.tail(256 * 1024)).components(separatedBy: "\n")
    }

    private var matches: [(Int, String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return lines.enumerated().filter { $0.element.localizedCaseInsensitiveContains(q) }.reversed().prefix(300).map { ($0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty && matches.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
                ForEach(matches, id: \.0) { _, line in
                    Button {
                        UIPasteboard.general.string = line
                        copied = line
                    } label: {
                        Text(highlight(line)).font(.system(.footnote, design: .monospaced)).lineLimit(3)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search the output"))
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if copied != nil {
                    Text("Copied").font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, 20)
                        .task { try? await Task.sleep(for: .seconds(1.5)); copied = nil }
                }
            }
        }
    }

    private func highlight(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        let q = query.trimmingCharacters(in: .whitespaces)
        var from = a.startIndex
        while !q.isEmpty, let r = a[from...].range(of: q, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.45)
            from = r.upperBound
        }
        return a
    }
}

/// Saved commands: one tap types (and runs) a command in the shown tab.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var command: String
    var run: Bool = true
}

enum Snippets {
    private static let key = "snippets"
    static var all: [Snippet] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([Snippet].self, from: d) else {
                return [Snippet(title: "Weather", command: "curl -s 'wttr.in/Istanbul?format=3'"),
                        Snippet(title: "Update packages", command: "apt update && apt upgrade -y"),
                        Snippet(title: "System info", command: "fastfetch"),
                        Snippet(title: "Web server in /root/Files", command: "cd /root/Files && python3 -m http.server 8000")]
            }
            return s
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            LxTermShortcuts.updateAppShortcutParameters()          // (Siri learns the names)
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var list = Snippets.all
    @State private var editing: Snippet?
    @State private var showGuide = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SiriTipView(intent: RunSnippetIntent())
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    HStack {
                        ShortcutsLink()
                        Spacer()
                        Button { showGuide = true } label: { Label("Run every day…", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Every saved command is also in the Shortcuts app and works with Siri by its name: no need to type it again.")
                }
                Section {
                    ForEach(list) { s in
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                store.current?.sendKeys(Array((s.command + (s.run ? "\r" : "")).utf8))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { list.removeAll { $0 == s }; Snippets.all = list }
                            Button("Edit") { editing = s }.tint(.orange)
                        }
                    }
                    .onMove { list.move(fromOffsets: $0, toOffset: $1); Snippets.all = list }
                } footer: {
                    Text("Tap a command to type it into the shown tab. Swipe to edit or delete.")
                }
            }
            .navigationTitle("Saved Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Snippet(title: "", command: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("New command"))
                }
            }
            .sheet(isPresented: $showGuide) { AutomationGuide() }
            .sheet(item: $editing) { s in
                SnippetEditor(snippet: s) { saved in
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                    Snippets.all = list
                }
            }
        }
    }
}

/// How to run a saved command on a schedule: three steps in the Shortcuts app.
struct AutomationGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Open Shortcuts, tap Automation, then + (New Automation).", "square.stack.3d.up")
                    step(2, "Choose Time of Day, set the time and Daily, and pick Run Immediately.", "clock")
                    step(3, "Add the action LxTerm › Run Saved Command and choose your command from the list. Add Show Notification after it to see what it printed.", "terminal")
                } footer: {
                    Text("iOS gives such actions about 30 seconds: fetching a web page, a small script or writing a file fits. Longer jobs: use Run Command in LxTerm, which opens a tab.")
                }
                Section {
                    ShortcutsLink().frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section("Example") {
                    Text("curl -s 'wttr.in/Istanbul?format=3'").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text("Save it as a command named Weather, then say “LxTerm Weather” to Siri, or run it every morning with the steps above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Run Every Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28).background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let save: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $snippet.title)
                TextField("Command", text: $snippet.command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Run it (press Return)", isOn: $snippet.run)
            }
            .navigationTitle(snippet.title.isEmpty ? Text("New command") : Text(snippet.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if snippet.title.isEmpty { snippet.title = snippet.command }
                        save(snippet); dismiss()
                    }
                    .disabled(snippet.command.isEmpty)
                }
            }
        }
    }
}
