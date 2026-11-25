import SwiftUI

/// The servers running in any shell (either engine): the TCP ports this app listens on,
/// found every two seconds, with the program that opened each (Ports in the tab bar, like
/// an editor's forwarded ports). A newly opened port is announced once.
@MainActor
final class Ports: ObservableObject {
    struct Port: Identifiable, Equatable { let port: Int; let program: String; var id: Int { port } }

    static let shared = Ports()
    @Published private(set) var list: [Port] = []
    @Published var announced: Port?
    private var known = Set<Int>()
    private var timer: Timer?
    private var first = true

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func scan() {
        var ports = [Int32](repeating: 0, count: 64)
        var names = [CChar](repeating: 0, count: 64 * 40)
        let n = Int(lx_engine_listening(&ports, &names, 64))
        var now: [Port] = []
        for i in 0..<n {
            let name = String(decoding: names[(i * 40)..<(i * 40 + 40)].prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            now.append(Port(port: Int(ports[i]), program: name))
        }
        now.sort { $0.port < $1.port }
        if now != list { list = now }
        let fresh = now.filter { !known.contains($0.port) }
        known = Set(now.map(\.port))
        if !first, let p = fresh.first { announced = p }
        first = false
    }

    static func url(_ port: Int) -> URL { URL(string: "http://localhost:\(port)/")! }
}

/// The list behind the tab bar's Ports button: tap a server to open it.
struct PortsView: View {
    @ObservedObject var ports = Ports.shared
    @Environment(\.dismiss) private var dismiss
    let open: (URL) -> Void
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            List {
                if ports.list.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No servers are running.").font(.headline)
                            Text("Start one in a shell and it appears here, for example:").foregroundStyle(.secondary)
                            Text("python3 -m http.server").font(.system(.body, design: .monospaced))
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        ForEach(ports.list) { p in
                            Button { dismiss(); open(Ports.url(p.port)) } label: {
                                HStack {
                                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                                    VStack(alignment: .leading) {
                                        Text(verbatim: "localhost:\(p.port)").font(.body.monospacedDigit())
                                        if !p.program.isEmpty { Text(p.program).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } footer: {
                        Text("Servers listening in your shells. They keep running while LxTerm is open.")
                    }
                }
                Section("Other port") {
                    HStack {
                        TextField("Port", text: $custom).keyboardType(.numberPad)
                        Button("Open") {
                            if let n = Int(custom), (1...65535).contains(n) { dismiss(); open(Ports.url(n)) }
                        }
                        .disabled(Int(custom) == nil)
                    }
                }
            }
            .navigationTitle("Ports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// "Port 8000 is open (python3) · Open": shown for a few seconds when a server starts.
struct PortToast: View {
    let port: Ports.Port
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Port \(String(port.port)) is open").font(.subheadline.weight(.semibold))
                if !port.program.isEmpty { Text(port.program).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button("Open", action: open).buttonStyle(.borderedProminent).controlSize(.small)
            Button(action: close) { Image(systemName: "xmark").font(.caption.bold()) }
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8, y: 2)
        .padding(.horizontal, 12)
    }
}
