import Foundation

/// What is at a path, looking at the path itself and never through a link.
public enum UninstallItemKind: Sendable, Equatable {
    case missing, file, folder, link
}

/// The file operations an uninstall needs, behind a seam so tests run on temporary folders and fakes.
public protocol UninstallFileSystem: Sendable {
    func kind(of url: URL) -> UninstallItemKind
    /// The path with every link in it followed.
    func resolvingLinks(_ url: URL) -> URL
    /// The path as the disk names it: links followed, and each existing part spelled in the
    /// letter case the volume stores. A part that does not exist is kept as written.
    func canonical(_ url: URL) -> URL
    func removeItem(at url: URL) throws
    /// Removes the folder when it holds nothing. False when it still holds something.
    func removeFolderIfEmpty(at url: URL) throws -> Bool
    /// Bytes on disk of the file, or of everything in the folder. Zero when nothing is there.
    func byteSize(of url: URL) -> Int64
}

/// The real disk.
public struct LocalUninstallFileSystem: UninstallFileSystem {
    public init() {}

    public func kind(of url: URL) -> UninstallItemKind {
        // `attributesOfItem` describes a link itself, not what it points to.
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else {
            return .missing
        }
        switch type {
        case .typeSymbolicLink: return .link
        case .typeDirectory: return .folder
        default: return .file
        }
    }

    public func resolvingLinks(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    /// Walks up to the deepest part that exists, asks the disk for its real name, and puts the
    /// parts that do not exist back on the end.
    public func canonical(_ url: URL) -> URL {
        var missing: [String] = []
        var existing = UninstallPathPolicy.components(url)
        while !existing.isEmpty {
            // A fresh URL each time: resource values are cached on the URL they were read from.
            let candidate = URL(fileURLWithPath: "/" + existing.joined(separator: "/"), isDirectory: false)
                .resolvingSymlinksInPath()
            if let real = try? candidate.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                return UninstallPathPolicy.plain(
                    URL(fileURLWithPath: ([real] + missing).joined(separator: "/"), isDirectory: false))
            }
            missing.insert(existing.removeLast(), at: 0)
        }
        return UninstallPathPolicy.plain(url)
    }

    public func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }

    public func removeFolderIfEmpty(at url: URL) throws -> Bool {
        if rmdir(url.path) == 0 { return true }
        let code = errno
        if code == ENOTEMPTY || code == EEXIST { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    public func byteSize(of url: URL) -> Int64 {
        switch kind(of: url) {
        case .missing, .link: return 0
        case .file: return Self.allocatedBytes(url)
        case .folder:
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in files { total += Self.allocatedBytes(file) }
            return total
        }
    }

    private static func allocatedBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}

/// The rules every removal passes before anything is touched.
public enum UninstallPathPolicy {
    /// The path's parts, without the leading `/`, after `.` and `..` are worked out from the
    /// text alone. No file is looked at.
    static func components(_ url: URL) -> [String] {
        var parts: [String] = []
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts
    }

    /// The same location written one way: absolute, no `.` or `..`, no trailing slash.
    static func plain(_ url: URL) -> URL {
        URL(fileURLWithPath: "/" + components(url).joined(separator: "/"), isDirectory: false)
    }

    /// A location inside `url`, built from text so that no file is looked at.
    static func child(of url: URL, _ relativePath: String) -> URL {
        plain(URL(fileURLWithPath: url.path + "/" + relativePath, isDirectory: false))
    }

    static func isSame(_ first: URL, _ second: URL) -> Bool {
        components(first) == components(second)
    }

    /// How many folders `url` is below `root`; nil when it is not inside it.
    static func depth(of url: URL, below root: URL) -> Int? {
        let inner = components(url)
        let outer = components(root)
        guard inner.count > outer.count, Array(inner.prefix(outer.count)) == outer else { return nil }
        return inner.count - outer.count
    }

    /// True when `url` is somewhere inside `root` (not `root` itself).
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        depth(of: url, below: root) != nil
    }

    /// How a location stands to the export folder.
    public enum ExportRelation: Sendable, Equatable {
        case apart, same, insideExport, holdsExport
    }

    /// The path's parts for comparing two locations the way a Mac volume does: letter case and
    /// the two ways of writing an accented letter do not tell names apart. On a volume that does
    /// tell them apart this treats two folders as one, which only ever keeps more.
    static func folded(_ url: URL) -> [String] {
        components(url).map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    }

    private static func relation(folded target: [String], export: [String]) -> ExportRelation {
        if target == export { return .same }
        if target.count > export.count, Array(target.prefix(export.count)) == export { return .insideExport }
        if export.count > target.count, Array(export.prefix(target.count)) == target { return .holdsExport }
        return .apart
    }

    /// Whether `url` is, is inside, or holds the export folder. Asked twice, of the paths as
    /// written and of the paths as `resolving` says the disk names them (links followed), and
    /// any answer but "apart" wins: a link from the export folder into the data folder, or a
    /// path written in another letter case, still counts.
    public static func relation(of url: URL, toExport export: URL, resolving: (URL) -> URL) -> ExportRelation {
        let written = relation(folded: folded(url), export: folded(export))
        guard written == .apart else { return written }
        return relation(folded: folded(resolving(url)), export: folded(resolving(export)))
    }

    /// Empty, `/`, relative, or written with `.` / `..` parts.
    static func isPlain(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        return !url.pathComponents.contains { $0 == "." || $0 == ".." }
    }

    /// Nil when `target` may be removed; otherwise the reason it is left alone.
    ///
    /// The target must be a plain path, deep enough inside one allowed folder, not a link itself,
    /// and reached without passing through a link that leads out of that folder.
    public static func refusal(
        for target: URL, allowedRoots: [UninstallAllowedRoot], fileSystem: any UninstallFileSystem
    ) -> UninstallRefusal? {
        guard isPlain(target) else { return .notAPlainPath(target.path) }
        let usable = allowedRoots.filter { components($0.url).count >= 2 }
        guard let root = usable.first(where: { root in
            depth(of: target, below: root.url).map { $0 >= root.minimumDepth } ?? false
        }) else { return .outsideAllowedFolders(target.path) }
        switch fileSystem.kind(of: target) {
        case .missing: return nil   // nothing there, so nothing to remove or to refuse
        case .link: return .isALink(target.path)
        case .file, .folder: break
        }
        let realRoot = fileSystem.resolvingLinks(root.url)
        let realParent = fileSystem.resolvingLinks(child(of: target, ".."))
        guard isSame(realParent, realRoot) || isInside(realParent, realRoot) else {
            return .leadsOutside(target.path)
        }
        return nil
    }
}
