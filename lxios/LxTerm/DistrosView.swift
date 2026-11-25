import SwiftUI

/// Settings › Distributions: download another distribution for new tabs, or remove it.
struct DistrosView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var m = DistroManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove: Distro?
    @State private var confirmReset: Distro?

    var body: some View {
        List {
            Section {
                ForEach(Distro.all) { d in row(d) }
            } footer: {
                Text("Each is the project's own official arm64 image, unmodified, downloaded from Docker Hub and checked against its SHA-256 digest; Arch Linux ARM is installed from its own repositories, package by package, as pacstrap does. Once downloaded, choose it from + when opening a tab. Unofficial: not affiliated with or endorsed by these projects.")
            }
        }
        .navigationTitle("Distributions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { m.refresh() }
        .alert("Download failed", isPresented: Binding(get: { m.failure != nil }, set: { if !$0 { m.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(m.failure ?? "") }
        .confirmationDialog(Text("Remove \(confirmRemove?.name ?? "")?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let d = confirmRemove {
                    m.remove(d)
                    store.distributionsChanged()
                }
            }
        } message: { Text("Everything installed or changed in it is deleted, and its tabs are closed.") }
        .confirmationDialog(Text("Reset \(confirmReset?.name ?? "")?"), isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }), titleVisibility: .visible) {
            Button("Erase and download again", role: .destructive) {
                if let d = confirmReset {
                    if d.builtIn { dismiss(); store.reset() }
                    else {
                        m.remove(d)
                        store.distributionsChanged()
                        m.download(d)
                    }
                }
            }
        } message: { Text("Everything installed or changed in it is deleted and a fresh copy is downloaded. Its tabs are closed.") }
    }

    @ViewBuilder private func row(_ d: Distro) -> some View {
        let installed = m.installed.contains(d)
        HStack(spacing: 12) {
            Image(systemName: d.builtIn ? "terminal" : "shippingbox").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name)
                Group {
                    if d.builtIn { Text("\(d.detail) · included") }
                    else if m.progress[d.id] != nil { Text("\(d.detail) · downloading…") }
                    else if installed, let s = m.sizes[d.id] { Text("\(d.detail) · \(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))") }
                    else { Text("\(d.detail) · about \(d.megabytes) MB download") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let p = m.progress[d.id] { ProgressView(value: p).padding(.top, 2) }
            }
            Spacer()
            if m.progress[d.id] != nil {
                Button { m.cancel(d) } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .foregroundStyle(.secondary).buttonStyle(.plain)
                    .accessibilityLabel(Text("Cancel download"))
            } else if installed {
                Button("Open") { store.newSession(d); dismiss() }.buttonStyle(.bordered)
            } else {
                Button(d.builtIn ? "Add" : "Download") { m.download(d) }.buttonStyle(.borderedProminent)
            }
        }
        .swipeActions {
            if installed {
                Button("Remove", role: .destructive) { confirmRemove = d }
                Button("Reset") { confirmReset = d }.tint(.orange)
            }
        }
        .contextMenu {
            if installed {
                if store.defaultDistro != d.id { Button("Make Default", systemImage: "star") { store.defaultDistro = d.id } }
                Button("Reset…", systemImage: "arrow.counterclockwise") { confirmReset = d }
                Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = d }
            }
        }
    }
}
