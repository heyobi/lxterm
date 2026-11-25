import AppIntents
import Foundation

/// The distributions as Shortcuts shows them.
enum DistroOption: String, AppEnum {
    case debian, ubuntu, alpine, fedora, almalinux, rocky, opensuse

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Distribution" }
    static var caseDisplayRepresentations: [DistroOption: DisplayRepresentation] = [
        .debian: "Debian", .ubuntu: "Ubuntu", .alpine: "Alpine Linux", .fedora: "Fedora",
        .almalinux: "AlmaLinux", .rocky: "Rocky Linux", .opensuse: "openSUSE Tumbleweed",
    ]

    var distro: Distro { Distro.named(rawValue) }
}

enum IntentFailure: LocalizedError {
    case notReady, notDownloaded(String), failed
    var errorDescription: String? {
        switch self {
        case .notReady: return String(localized: "Open LxTerm once first: Debian is unpacked on the first start.")
        case .notDownloaded(let n): return String(localized: "\(n) is not downloaded. Download it in LxTerm › Settings › Distributions.")
        case .failed: return String(localized: "The command could not be started.")
        }
    }
}

/// Opens LxTerm with a new tab in the distribution, the command typed into its shell.
struct RunInTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Command in LxTerm"
    static var description = IntentDescription("Opens a new tab in the chosen distribution and runs the command in it, as if typed.")
    static var openAppWhenRun = true

    @Parameter(title: "Command") var command: String
    @Parameter(title: "Distribution", description: "Empty: the default distribution in LxTerm’s Settings.") var distribution: DistroOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in \(\.$distribution)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let d = distribution?.distro ?? Distro.preferred ?? .debian
        guard d.installed else { throw IntentFailure.notDownloaded(d.name) }
        for _ in 0..<50 where Store.shared?.phase != .ready { try await Task.sleep(for: .milliseconds(200)) }   // (just launched)
        guard let store = Store.shared, store.phase == .ready else { throw IntentFailure.notReady }
        store.run(command, in: d)
        return .result()
    }
}

/// Runs the command without a tab and gives Shortcuts what it printed.
struct RunCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Command and Get Output"
    static var description = IntentDescription("Runs the command in the chosen distribution and returns what it printed, for the next actions of a shortcut. It stops after the time limit.")

    @Parameter(title: "Command") var command: String
    @Parameter(title: "Distribution", description: "Empty: the default distribution in LxTerm’s Settings.") var distribution: DistroOption?
    @Parameter(title: "Time limit (seconds)", default: 25, inclusiveRange: (1, 25)) var seconds: Int
    @Parameter(title: "Input", description: "Text given to the command on its standard input.") var input: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in \(\.$distribution)") { \.$input; \.$seconds }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let d = distribution?.distro ?? Distro.preferred ?? .debian
        guard await MainActor.run(body: { Store.prepareEngine() }) else { throw IntentFailure.notReady }
        guard d.installed else { throw IntentFailure.notDownloaded(d.name) }
        let out = try await Headless.run(command, root: d.builtIn ? nil : d.root.path, seconds: seconds, input: input)
        return .result(value: out)
    }
}

/// One command on a terminal of its own; its output collected until it ends or time runs out.
final class Headless {
    fileprivate let lock = NSLock()
    fileprivate var data = Data()
    private var cont: CheckedContinuation<String, Error>?
    private var handle: OpaquePointer?

    static func run(_ command: String, root: String?, seconds: Int, input: String? = nil) async throws -> String {
        var command = command
        if let input {                                             // (standard input from a file in the guest's /tmp)
            let name = "lxterm-input-\(UUID().uuidString)"
            let host = (root ?? Store.rootDir.path) + "/tmp/" + name
            try? FileManager.default.createDirectory(atPath: (root ?? Store.rootDir.path) + "/tmp", withIntermediateDirectories: true)
            try Data(input.utf8).write(to: URL(fileURLWithPath: host))
            command = "( \(command)\n) < /tmp/\(name); s=$?; rm -f /tmp/\(name); exit $s"
        }
        let h = Headless()
        return try await withCheckedThrowingContinuation { c in
            h.cont = c
            let ctx = Unmanaged.passRetained(h).toOpaque()
            h.handle = lx_session_run(root, command, { ctx, s, n in
                guard let ctx, let s else { return }
                let me = Unmanaged<Headless>.fromOpaque(ctx).takeUnretainedValue()
                me.lock.lock(); me.data.append(UnsafeRawPointer(s).assumingMemoryBound(to: UInt8.self), count: n); me.lock.unlock()
            }, { ctx in
                guard let ctx else { return }
                Unmanaged<Headless>.fromOpaque(ctx).takeRetainedValue().finish()
            }, ctx)
            if h.handle == nil { Unmanaged<Headless>.fromOpaque(ctx).release(); c.resume(throwing: IntentFailure.failed); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { [weak h] in
                guard let h, let handle = h.handle else { return }
                lx_session_close(handle)                           // (a closed session does not call exited)
                h.lock.lock(); h.data.append(contentsOf: Array("\n[time limit reached]".utf8)); h.lock.unlock()
                h.finish()
            }
        }
    }

    fileprivate func finish() {
        lock.lock()
        let text = String(decoding: data, as: UTF8.self)
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: Headless.plain(text))
    }

    /// Without terminal colours and cursor moves.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\r", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LxTermShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .grayGreen
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LinuxToolIntent(.weather), phrases: ["Weather in \(.applicationName)", "\(.applicationName) weather"],
                    shortTitle: "Weather Here", systemImageName: "cloud.sun")
        AppShortcut(intent: LinuxToolIntent(.site), phrases: ["Is my site up in \(.applicationName)", "\(.applicationName) site check"],
                    shortTitle: "Is the Site Up?", systemImageName: "checkmark.shield")
        AppShortcut(intent: LinuxToolIntent(.network), phrases: ["My network in \(.applicationName)", "\(.applicationName) my IP"],
                    shortTitle: "My Network", systemImageName: "network")
        AppShortcut(intent: LinuxToolIntent(.rates), phrases: ["Exchange rates in \(.applicationName)", "\(.applicationName) rates"],
                    shortTitle: "Exchange Rates", systemImageName: "dollarsign.arrow.circlepath")
        AppShortcut(intent: LinuxToolIntent(.password), phrases: ["Strong password in \(.applicationName)", "\(.applicationName) password"],
                    shortTitle: "Strong Password", systemImageName: "key")
        AppShortcut(intent: LinuxToolIntent(.define), phrases: ["Define a word in \(.applicationName)", "\(.applicationName) dictionary"],
                    shortTitle: "Define a Word", systemImageName: "book")
        AppShortcut(intent: LinuxToolIntent(.news), phrases: ["Hacker News in \(.applicationName)", "\(.applicationName) news"],
                    shortTitle: "Hacker News", systemImageName: "newspaper")
        AppShortcut(intent: RunCommandIntent(), phrases: ["Run a command in \(.applicationName)", "\(.applicationName) command"],
                    shortTitle: "Run Command", systemImageName: "terminal")
        AppShortcut(intent: RunInTerminalIntent(), phrases: ["Open a command in \(.applicationName)"],
                    shortTitle: "Run in a Tab", systemImageName: "plus.rectangle")
        AppShortcut(intent: RunSnippetIntent(), phrases: ["Run \(\.$snippet) in \(.applicationName)", "\(.applicationName) \(\.$snippet)"],
                    shortTitle: "Run Saved Command", systemImageName: "text.badge.star")
    }
}

/// A saved command (Tools.swift) as Shortcuts and Siri name it.
struct SnippetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Saved Command" }
    static var defaultQuery = SnippetQuery()
    let id: String
    let title: String
    let command: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(command)") }

    init(_ s: Snippet) { id = s.id.uuidString; title = s.title; command = s.command }
}

struct SnippetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SnippetEntity] {
        Snippets.all.filter { identifiers.contains($0.id.uuidString) }.map(SnippetEntity.init)
    }
    func entities(matching string: String) async throws -> [SnippetEntity] {
        Snippets.all.filter { $0.title.localizedCaseInsensitiveContains(string) }.map(SnippetEntity.init)
    }
    func suggestedEntities() async throws -> [SnippetEntity] { Snippets.all.map(SnippetEntity.init) }
}

/// Runs a saved command and gives back what it printed (Siri reads it out).
struct RunSnippetIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Saved Command"
    static var description = IntentDescription("Runs one of LxTerm's saved commands and returns what it printed.")

    @Parameter(title: "Saved Command") var snippet: SnippetEntity
    @Parameter(title: "Distribution", description: "Empty: the default distribution in LxTerm’s Settings.") var distribution: DistroOption?
    @Parameter(title: "Input", description: "Text given to the command on its standard input.") var input: String?

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$snippet) in \(\.$distribution)") { \.$input } }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let d = distribution?.distro ?? Distro.preferred ?? .debian
        guard await MainActor.run(body: { Store.prepareEngine() }) else { throw IntentFailure.notReady }
        guard d.installed else { throw IntentFailure.notDownloaded(d.name) }
        let out = try await Headless.run(snippet.command, root: d.builtIn ? nil : d.root.path, seconds: 25, input: input)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out.isEmpty ? String(localized: "Done.") : String(out.suffix(600))))
    }
}
