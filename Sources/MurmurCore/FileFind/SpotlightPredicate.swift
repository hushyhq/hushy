import Foundation

/// The Spotlight predicate for one `FileSearchSpec`, built from validated words only (letters,
/// digits, hyphens), passed as arguments, never spliced into a query string. This is the query
/// language `mdfind` uses; the app runs it through `NSMetadataQuery`, never through a shell.
public enum SpotlightPredicate {
    public static let displayName = "kMDItemDisplayName"
    public static let fileName = "kMDItemFSName"
    public static let textContent = "kMDItemTextContent"
    public static let contentTypeTree = "kMDItemContentTypeTree"

    public static func make(_ spec: FileSearchSpec) -> NSPredicate {
        var parts: [NSPredicate] = []
        let groups = spec.termGroups.map { group -> NSPredicate in
            let matches = group.map { variant in
                switch spec.pass {
                case .content:
                    NSPredicate(format: "%K LIKE[cd] %@", textContent, "\(variant)*")
                case .nameAll, .nameAny:
                    NSPredicate(format: "%K LIKE[cd] %@", displayName, "*\(variant)*")
                }
            }
            return NSCompoundPredicate(orPredicateWithSubpredicates: matches)
        }
        if !groups.isEmpty {
            parts.append(spec.pass == .nameAny
                ? NSCompoundPredicate(orPredicateWithSubpredicates: groups)
                : NSCompoundPredicate(andPredicateWithSubpredicates: groups))
        }
        if !spec.kind.contentTypes.isEmpty {
            let kinds = spec.kind.contentTypes.map { NSPredicate(format: "%K == %@", contentTypeTree, $0) }
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: kinds))
        }
        if parts.isEmpty { parts.append(NSPredicate(format: "%K LIKE %@", fileName, "*")) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }
}
