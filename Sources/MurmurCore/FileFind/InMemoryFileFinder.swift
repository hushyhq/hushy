import Foundation

/// A file index held in memory: the fake behind tests, `murmur-eval files` and the pill
/// snapshots. It answers a `FileSearchSpec` the way the Spotlight query would (name contains,
/// kind and folder scope, newest first), so the engine is exercised on the real code path. It
/// never touches the disk.
public struct InMemoryFileFinder: FileFinding {
    public var files: [FileCandidate]
    /// Text per path, for the content pass.
    public var contents: [String: String]
    /// How long a search takes (to exercise the time box).
    public var delay: Duration
    public var unavailable: FileSearchUnavailable?
    public var indexAvailable: Bool

    public init(
        files: [FileCandidate] = [], contents: [String: String] = [:], delay: Duration = .zero,
        unavailable: FileSearchUnavailable? = nil, indexAvailable: Bool = true
    ) {
        self.files = files
        self.contents = contents
        self.delay = delay
        self.unavailable = unavailable
        self.indexAvailable = indexAvailable
    }

    public func search(_ spec: FileSearchSpec) async -> FileSearchResponse {
        if let unavailable { return .unavailable(unavailable) }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return .results([]) }
        }
        let rootPrefixes = spec.roots.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let matches = files.filter { file in
            guard rootPrefixes.contains(where: { file.path.hasPrefix($0) }) else { return false }
            if !spec.homePath.isEmpty, FileScope.isExcluded(path: file.path, home: spec.homePath) { return false }
            guard kindMatches(file, spec.kind) else { return false }
            return textMatches(file, spec)
        }
        let newestFirst = matches.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return .results(Array(newestFirst.prefix(spec.limit)))
    }

    public func isIndexAvailable() async -> Bool { indexAvailable }

    private func kindMatches(_ file: FileCandidate, _ kind: FileKind) -> Bool {
        switch kind {
        case .any: true
        case .folder: file.isFolder
        default: file.kinds.contains(kind)
        }
    }

    private func textMatches(_ file: FileCandidate, _ spec: FileSearchSpec) -> Bool {
        guard !spec.termGroups.isEmpty else { return true }
        switch spec.pass {
        case .nameAll:
            let name = file.displayName.lowercased()
            return spec.termGroups.allSatisfy { group in group.contains { name.contains($0.lowercased()) } }
        case .nameAny:
            let name = file.displayName.lowercased()
            return spec.termGroups.contains { group in group.contains { name.contains($0.lowercased()) } }
        case .content:
            guard let text = contents[file.path]?.lowercased() else { return false }
            let words = Set(text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
            return spec.termGroups.allSatisfy { group in
                group.contains { variant in words.contains { $0.hasPrefix(variant.lowercased()) } }
            }
        }
    }
}
