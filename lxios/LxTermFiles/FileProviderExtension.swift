import FileProvider
import UniformTypeIdentifiers

/// LxTerm in the Files app's Locations (beside iCloud Drive): the folder every shell sees as
/// /root/Files, kept in the app group's container. Items are named by their path inside it.
/// Changes made from Linux are found by comparing the folder with the last listing the
/// system was given (the app signals the working set when something may have changed).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    static let group = "group.com.heyobi.lxterm"
    let root: URL
    private let fm = FileManager.default

    required init(domain: NSFileProviderDomain) {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FileProviderExtension.group)
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        super.init()
    }

    func invalidate() {}

    // MARK: identifiers <-> paths

    static func path(of id: NSFileProviderItemIdentifier) -> String? {
        if id == .rootContainer { return "" }
        if id == .trashContainer || id == .workingSet { return nil }
        return id.rawValue
    }

    func url(_ id: NSFileProviderItemIdentifier) -> URL? {
        guard let p = FileProviderExtension.path(of: id) else { return nil }
        if p.split(separator: "/").contains("..") { return nil }
        return p.isEmpty ? root : root.appendingPathComponent(p)
    }

    func item(at rel: String) -> FileItem? {
        let u = rel.isEmpty ? root : root.appendingPathComponent(rel)
        var st = stat()
        guard lstat(u.path, &st) == 0 else { return nil }
        return FileItem(rel: rel, st: st)
    }

    // MARK: NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let p = FileProviderExtension.path(of: identifier), let it = item(at: p) { completionHandler(it, nil) }
        else { completionHandler(nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)) }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let p = FileProviderExtension.path(of: itemIdentifier), let src = url(itemIdentifier), let it = item(at: p) else {
            completionHandler(nil, nil, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemIdentifier))
            return Progress()
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
        do { try fm.copyItem(at: src, to: tmp); completionHandler(tmp, it, nil) }
        catch { completionHandler(nil, nil, error) }
        return Progress()
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let parent = FileProviderExtension.path(of: itemTemplate.parentItemIdentifier) else {
            completionHandler(nil, [], false, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }
        let rel = parent.isEmpty ? itemTemplate.filename : parent + "/" + itemTemplate.filename
        let dest = root.appendingPathComponent(rel)
        do {
            if itemTemplate.contentType == .folder || itemTemplate.contentType == UTType.directory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else if itemTemplate.contentType == .symbolicLink, let target = itemTemplate.symlinkTargetPath ?? nil {
                try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
            } else {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if let url { try fm.copyItem(at: url, to: dest) } else { fm.createFile(atPath: dest.path, contents: nil) }
            }
            completionHandler(item(at: rel), [], false, nil)
        } catch { completionHandler(nil, [], false, error) }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard var rel = FileProviderExtension.path(of: item.itemIdentifier) else {
            completionHandler(nil, [], false, NSError.fileProviderErrorForNonExistentItem(withIdentifier: item.itemIdentifier))
            return Progress()
        }
        do {
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier),
               let parent = FileProviderExtension.path(of: item.parentItemIdentifier) {
                let to = parent.isEmpty ? item.filename : parent + "/" + item.filename
                if to != rel {
                    try fm.moveItem(at: root.appendingPathComponent(rel), to: root.appendingPathComponent(to))
                    rel = to
                }
            }
            if changedFields.contains(.contents), let newContents {
                let dest = root.appendingPathComponent(rel)
                _ = try fm.replaceItemAt(dest, withItemAt: newContents)
            }
            completionHandler(self.item(at: rel), [], false, nil)
        } catch { completionHandler(nil, [], false, error) }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let u = url(identifier), identifier != .rootContainer else { completionHandler(nil); return Progress() }
        do { try fm.removeItem(at: u); completionHandler(nil) } catch { completionHandler((error as NSError).code == NSFileNoSuchFileError ? nil : error) }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return Enumerator(ext: self, dir: nil) }
        guard let p = FileProviderExtension.path(of: containerItemIdentifier) else {
            throw NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)
        }
        return Enumerator(ext: self, dir: p)
    }
}

/// One file or folder of the shared folder.
final class FileItem: NSObject, NSFileProviderItem {
    let rel: String
    let st: stat

    init(rel: String, st: stat) { self.rel = rel; self.st = st }

    var isDir: Bool { st.st_mode & S_IFMT == S_IFDIR }
    var itemIdentifier: NSFileProviderItemIdentifier { rel.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(rel) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let i = rel.lastIndex(of: "/") else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(rel[..<i]))
    }
    var filename: String { rel.isEmpty ? "Pocket Distro" : String(rel.split(separator: "/").last ?? "") }
    var contentType: UTType {
        if isDir { return .folder }
        if st.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        return UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
    var documentSize: NSNumber? { isDir ? nil : NSNumber(value: st.st_size) }
    var contentModificationDate: Date? { Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) }
    var creationDate: Date? { Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)) }
    var capabilities: NSFileProviderItemCapabilities {
        isDir ? [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsAddingSubItems, .allowsContentEnumerating]
              : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }
    var itemVersion: NSFileProviderItemVersion {
        let d = Data("\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec).\(st.st_size)".utf8)
        return NSFileProviderItemVersion(contentVersion: d, metadataVersion: d)
    }
}

/// A folder's items, or (working set) every item, and what changed since the last listing.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    let ext: FileProviderExtension
    let dir: String?                 // nil: the working set (everything)

    init(ext: FileProviderExtension, dir: String?) { self.ext = ext; self.dir = dir }

    func invalidate() {}

    /// Every item below `dir` (one level), or all of them for the working set.
    func listing() -> [FileItem] {
        var out: [FileItem] = []
        func walk(_ rel: String, deep: Bool) {
            let u = rel.isEmpty ? ext.root : ext.root.appendingPathComponent(rel)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { return }
            for n in names {
                let r = rel.isEmpty ? n : rel + "/" + n
                if let it = ext.item(at: r) {
                    out.append(it)
                    if deep && it.isDir && out.count < 20000 { walk(r, deep: true) }
                }
            }
        }
        walk(dir ?? "", deep: dir == nil)
        return out
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let items = listing()
        observer.didEnumerate(items)
        try? JSONEncoder().encode(snapshot(items)).write(to: stateFile)
        observer.finishEnumerating(upTo: nil)
    }

    // the last listing given, per enumerator, in the extension's own storage
    private var stateFile: URL {
        let key = (dir ?? "#workingset").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("listings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(key + ".json")
    }

    private func snapshot(_ items: [FileItem]) -> [String: String] {
        var m: [String: String] = [:]
        for it in items { m[it.rel] = String(decoding: it.itemVersion.contentVersion, as: UTF8.self) }
        return m
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let items = listing()
        let now = snapshot(items)
        let before = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateFile))) ?? [:]
        let changed = items.filter { before[$0.rel] != now[$0.rel] }
        let gone = before.keys.filter { now[$0] == nil }.map { NSFileProviderItemIdentifier($0) }
        if !changed.isEmpty { observer.didUpdate(changed) }
        if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone) }
        try? JSONEncoder().encode(now).write(to: stateFile)
        observer.finishEnumeratingChanges(upTo: Enumerator.anchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Enumerator.anchor())
    }

    static func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }
}
