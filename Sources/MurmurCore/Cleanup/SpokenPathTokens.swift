import Foundation

/// Spoken paths, branch names and long flags ("config slash staging dot yaml", "feature slash
/// retry dash logic", "dash dash no verify"). Part of `SpokenTechnicalTokens`.
///
/// A chain of words joined by "slash", "dot", "underscore" or "dash" is only a path when the words
/// themselves say so: it ends in a known file extension, it has two or more slashes, or it starts
/// with a branch prefix right after a git word. Every part of the chain must be a name, never a
/// function word or a number. Otherwise "slash the budget", "a dash for the door" and "yes slash no"
/// are plain speech and stay as spoken.
enum SpokenPathTokens {
    private static let separators: [String: String] = ["slash": "/", "dot": ".", "underscore": "_", "dash": "-"]

    static let extensions: Set<String> = [
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "csv", "plist", "proto", "gradle",
        "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "go", "rs", "swift", "kt", "java", "sh", "sql",
        "md", "txt", "html", "css", "scss", "lock", "log", "env", "dockerfile",
    ]

    static let branchPrefixes: Set<String> = [
        "feature", "feat", "fix", "bugfix", "hotfix", "release", "chore", "refactor", "docs", "test",
        "perf", "ci", "revert", "dependabot", "renovate",
    ]

    private static let gitWords: Set<String> = [
        "push", "pushed", "pushing", "rebase", "rebased", "rebasing", "merge", "merged", "merging",
        "checkout", "switch", "switched", "branch", "branches", "cherry", "pick", "picked", "onto", "pull",
        "pulled", "fetch", "fetched", "delete", "deleted", "branched", "base", "based", "tracking",
    ]

    /// Files whose whole name starts with a dot: "dot env" is `.env`, "dot gitignore" is `.gitignore`.
    /// A closed list, because "dot" before any other word is ordinary speech ("the dot product").
    static let dotfiles: Set<String> = [
        "env", "gitignore", "gitattributes", "gitmodules", "npmrc", "nvmrc", "bashrc", "zshrc", "eslintrc",
        "prettierrc", "babelrc", "editorconfig", "dockerignore", "htaccess", "vimrc",
    ]

    /// What can follow `.env` as a second dotted part: ".env.local", ".env.production".
    static let envSuffixes: Set<String> = [
        "local", "example", "sample", "template", "production", "development", "staging", "test", "dev", "prod",
    ]

    /// Nouns that introduce a path or address; the path after them keeps its leading slash and the
    /// space before it ("the route slash api slash orders" -> "the route /api/orders").
    /// The request verbs ("hit slash api slash users", "curl slash health slash check") introduce one too.
    static let pathIntroducers: Set<String> = [
        "route", "routes", "endpoint", "endpoints", "url", "uri", "path", "redirect",
        "hit", "hits", "call", "calls", "curl", "get", "post", "put", "patch", "fetch", "visit", "open", "ping",
    ]

    /// Words that may stand before a dotfile name when "dot" is the punctuation mark: "draw a dot env
    /// label". A file name after one of these is still a file when no noun follows it ("the dot env
    /// is missing") or when the noun is "file".
    private static let dotDeterminers: Set<String> = [
        "a", "an", "the", "this", "that", "my", "our", "your", "their", "his", "her", "its", "one", "another",
    ]
    /// A noun that names a thing a path points at: "dev slash staging slash prod config" is a path
    /// to a config, not spoken alternatives, so it does not count as the noun that declines a chain.
    private static let pathObjects: Set<String> = [
        "file", "files", "folder", "folders", "directory", "dir", "config", "configs", "script", "scripts",
        "repo", "bucket", "module", "handler", "manifest",
    ]
    private static let fileNouns: Set<String> = ["file", "files"]

    /// Imperative verbs that take a file: "open dot env" is "open .env", never the chain `open.env`.
    private static let fileVerbs: Set<String> = [
        "open", "edit", "source", "load", "cat", "read", "create", "add", "copy", "delete", "remove", "update",
        "check", "rename", "move", "commit", "ignore", "touch", "diff", "print", "show", "export",
    ]

    private static let dotfilePattern = #"(?<![\w.-])dot\s+([A-Za-z]+)(?:\s+dot\s+([A-Za-z]+))?\b"#
    private static let versionSegmentPattern = #"\b(slash\s+)v\s+(one|two|three|four|five|six|seven|eight|nine)\b"#
    private static let versionDigits = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static let chainPattern = #"\b[A-Za-z0-9]+(?:\s+(?:slash|dot|underscore|dash)\s+[A-Za-z0-9]+)+\b"#
    private static let flagPattern = #"\bdash\s+dash\s+((?:no\s+)?[A-Za-z][A-Za-z0-9]*(?:\s+dash\s+[A-Za-z][A-Za-z0-9]*)*)\b"#

    static func apply(_ text: String) -> String {
        let flagged = TokenRewrite.replace(text, pattern: flagPattern, flag)
        // "slash v two" is an API version segment; joining it lets the chain read it as one name.
        let versioned = TokenRewrite.replace(flagged, pattern: versionSegmentPattern) { match in
            guard let slash = match.group(1), let digit = match.group(2), let value = versionDigits[digit.lowercased()] else { return nil }
            return slash + "v" + value
        }
        let chained = TokenRewrite.replace(versioned, pattern: chainPattern, path)
        return TokenRewrite.replace(chained, pattern: dotfilePattern, dotfile)
    }

    /// "dot env" -> ".env", "dot env dot local" -> ".env.local". Runs after the chain rule, so
    /// "config dot env" has already become `config.env`.
    private static func dotfile(_ match: TokenMatch) -> String? {
        guard let name = match.group(1)?.lowercased(), dotfiles.contains(name) else { return nil }
        if isMarkOnDiagram(match) { return nil }
        guard let spokenSuffix = match.group(2) else { return "." + name }
        // A second "dot" that does not extend the file stays as spoken ("dot env dot yaml").
        guard name == "env", envSuffixes.contains(spokenSuffix.lowercased()) else { return "." + name + " dot " + spokenSuffix }
        return ".env." + spokenSuffix.lowercased()
    }

    /// "draw a dot env label": a determiner before "dot" and a noun-like word other than "file"
    /// after the name read "dot" as a mark and the name as a word. A closed shape test on the two
    /// neighbouring words; "the dot env needs a fix" and "the dot env" still convert.
    private static func isMarkOnDiagram(_ match: TokenMatch) -> Bool {
        guard let before = match.wordsBefore(1).first, dotDeterminers.contains(before),
              let after = match.wordsAfter(1).first else { return false }
        return TokenLexicon.isNounLike(after) && !fileNouns.contains(after)
    }

    private static func isName(_ word: String) -> Bool {
        let lower = word.lowercased()
        return !TokenLexicon.functionWords.contains(lower) && !TokenLexicon.numberWords.contains(lower)
            && separators[lower] == nil
    }

    /// "dash dash dry dash run" -> "--dry-run"; "dash dash no verify" -> "--no-verify".
    private static func flag(_ match: TokenMatch) -> String? {
        guard let spoken = match.group(1) else { return nil }
        var parts = spoken.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }.filter { $0 != "dash" }
        if parts.first == "no", parts.count > 1 {
            parts = ["no-" + parts[1]] + parts.dropFirst(2)
            guard isName(String(parts[0].dropFirst(3))) else { return nil }
        }
        guard !parts.isEmpty, parts.allSatisfy({ isName($0.replacingOccurrences(of: "no-", with: "")) }) else { return nil }
        return "--" + parts.joined(separator: "-")
    }

    private static func path(_ match: TokenMatch) -> String? {
        let words = match.text.split(whereSeparator: \.isWhitespace).map(String.init)
        // words alternate name, separator, name, separator, name ...
        let names = words.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let joiners = words.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.lowercased() }
        // "route slash api slash orders": the introducer is a word, not the first path part.
        let introduced = joiners.first == "slash" && pathIntroducers.contains(names[0].lowercased())
        guard names.count == joiners.count + 1, names.dropFirst(introduced ? 1 : 0).allSatisfy(isName) else { return nil }
        if isVerbBeforeDotfile(names: names, joiners: joiners) { return nil }
        guard let evidence = evidence(names: names, joiners: joiners, match: match) else { return nil }
        // Slashes alone join spoken alternatives as often as they write a path: "the route slash
        // detour slash bypass option". A noun-like word right after the last name makes it that.
        if evidence == .slashesOnly, let next = match.wordsAfter(1).first, TokenLexicon.isNounLike(next),
           !pathObjects.contains(next) { return nil }
        var out = introduced ? names[0] + " " : names[0]
        for (joiner, name) in zip(joiners, names.dropFirst()) { out += (separators[joiner] ?? "") + name }
        return out
    }

    /// "open dot env": a file verb, then "dot", then a dotfile name. The dotfile rule writes it.
    private static func isVerbBeforeDotfile(names: [String], joiners: [String]) -> Bool {
        guard names.count == 2, joiners == ["dot"], dotfiles.contains(names[1].lowercased()) else { return false }
        let verb = names[0].lowercased()
        return fileVerbs.contains(verb) || pathIntroducers.contains(verb)
    }

    private enum Evidence { case strong, slashesOnly }

    private static func evidence(names: [String], joiners: [String], match: TokenMatch) -> Evidence? {
        if joiners.last == "dot", let last = names.last?.lowercased(), extensions.contains(last) { return .strong }
        if let prefix = names.first?.lowercased(), joiners.first == "slash", branchPrefixes.contains(prefix),
           match.wordsBefore(4).contains(where: gitWords.contains) || match.wordsAfter(1).first == "onto" { return .strong }
        return joiners.filter({ $0 == "slash" }).count >= 2 ? .slashesOnly : nil
    }
}
