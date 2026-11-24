import FileProvider
import Foundation

/// "LxTerm" in the Files app's Locations: the File Provider domain of lxios/LxTermFiles,
/// added once at launch; while the app runs, the working set is signalled every few seconds
/// so that what Linux programs write into /root/Files shows up in Files.
enum FilesDomain {
    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("lxterm"), displayName: "LxTerm")
    private static var timer: Timer?

    static func register() {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedFiles.group) != nil else { return }
        NSFileProviderManager.add(domain) { _ in }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in SharedFiles.changed() }
    }
}
