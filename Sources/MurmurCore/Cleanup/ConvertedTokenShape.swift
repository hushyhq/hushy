import Foundation

/// The shapes `SpokenTechnicalTokens` writes (a percentile "p99", a region "us-east-1", a flag
/// "--dry-run", a path or file name "config/staging.yaml", "package.json"). Their case is part of
/// the token: a model or a sentence capitaliser must never turn "p99" into "P99". Recognised by
/// shape alone, so it needs no list of products or names.
enum ConvertedTokenShape {
    private static let percentile = #"^p\d{2,4}$"#
    private static let region = #"^[a-z]{2}-[a-z]+-\d$"#
    private static let flag = #"^--[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#
    private static let file = #"^[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.([a-z0-9]+)$"#
    private static let path = #"^[a-z0-9._-]+(?:/[a-z0-9._-]+)+$"#
    private static let edgePunctuation = CharacterSet(charactersIn: ",.;:!?()[]{}\"'`")

    /// True when `token` (surrounding punctuation ignored) has one of the shapes above.
    static func isCaseSensitive(_ token: String) -> Bool {
        let bare = token.trimmingCharacters(in: edgePunctuation)
        guard bare.count >= 3 else { return false }
        if isMatch(bare, percentile, caseSensitive: true) { return true }
        let lower = bare.lowercased()
        if isMatch(lower, region) || isMatch(lower, flag) { return true }
        return isFile(lower) || isPath(lower)
    }

    /// Whether the word that starts at `index` in `chars` is such a token. A leading "--" sits
    /// just before the first letter, so it is read back from there.
    static func startsCaseSensitiveToken(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, chars[start - 1] == "-", index - start < 2 { start -= 1 }
        var end = index
        while end < chars.count, isTokenCharacter(chars, end) { end += 1 }
        return isCaseSensitive(String(chars[start..<end]))
    }

    /// True when a dotfile name starts at the "." at `index`: a "." at the start of a word followed
    /// by a name from `SpokenPathTokens.dotfiles` ("source the .bashrc file", ".vimrc is stale").
    /// Neither the space before it nor the lower case of the name may be touched by tidy-up.
    static func startsDotfile(_ chars: [Character], at index: Int) -> Bool {
        guard index < chars.count, chars[index] == ".", index == 0 || chars[index - 1].isWhitespace else { return false }
        var end = index + 1
        while end < chars.count, chars[end].isLetter { end += 1 }
        guard SpokenPathTokens.dotfiles.contains(String(chars[(index + 1)..<end])) else { return false }
        return end == chars.count || !(chars[end].isNumber || chars[end] == "-" || chars[end] == "_")
    }

    private static func isTokenCharacter(_ chars: [Character], _ index: Int) -> Bool {
        let char = chars[index]
        if char.isLetter || char.isNumber { return true }
        guard "-_/.".contains(char), index + 1 < chars.count else { return false }
        return chars[index + 1].isLetter || chars[index + 1].isNumber
    }

    private static func isFile(_ lower: String) -> Bool {
        guard isMatch(lower, file), let ext = lower.split(separator: ".").last else { return false }
        return SpokenPathTokens.extensions.contains(String(ext))
    }

    /// Two or more segments, and evidence it is a path: a file extension, a second slash, or a branch prefix.
    private static func isPath(_ lower: String) -> Bool {
        guard isMatch(lower, path) else { return false }
        let segments = lower.split(separator: "/")
        if segments.count > 2 { return true }
        if let last = segments.last, isFile(String(last)) { return true }
        return SpokenPathTokens.branchPrefixes.contains(String(segments[0]))
    }

    private static func isMatch(_ text: String, _ pattern: String, caseSensitive: Bool = false) -> Bool {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: !caseSensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
