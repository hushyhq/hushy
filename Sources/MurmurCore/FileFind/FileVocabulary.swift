import Foundation

/// The closed word tables behind file requests. No phrase-specific exceptions: every entry is a
/// word or a short phrase in a table, and the router and ranker read only these.
public enum FileVocabulary {
    // MARK: Kinds

    /// A kind word, and the name word it also implies (a "screenshot" is an image and its file
    /// name says "Screenshot").
    struct KindWord {
        let kind: FileKind
        let alsoName: String?
        init(_ kind: FileKind, alsoName: String? = nil) {
            self.kind = kind
            self.alsoName = alsoName
        }
    }

    static let kindWords: [String: KindWord] = [
        "pdf": .init(.pdf), "document": .init(.document), "doc": .init(.document), "docx": .init(.document),
        "presentation": .init(.presentation), "slides": .init(.presentation), "slide": .init(.presentation),
        "deck": .init(.presentation), "powerpoint": .init(.presentation), "keynote": .init(.presentation),
        "ppt": .init(.presentation), "pptx": .init(.presentation),
        "spreadsheet": .init(.spreadsheet), "sheet": .init(.spreadsheet), "excel": .init(.spreadsheet),
        "csv": .init(.spreadsheet), "xlsx": .init(.spreadsheet),
        "screenshot": .init(.image, alsoName: "screenshot"), "photo": .init(.image), "picture": .init(.image),
        "image": .init(.image), "png": .init(.image), "jpeg": .init(.image), "jpg": .init(.image),
        "folder": .init(.folder), "directory": .init(.folder),
    ]

    /// Words that say "a file" without saying which kind.
    static let fileWords: Set<String> = ["file", "files"]

    /// Names of things people keep as files. Seeing one of these after a fetch verb is enough to
    /// treat the request as a file request.
    static let fileNouns: Set<String> = [
        "resume", "cv", "invoice", "contract", "receipt", "proposal", "agreement", "lease", "itinerary",
        "report", "cover letter", "offer letter", "tax return", "boarding pass",
    ]

    // MARK: Synonyms (closed)

    /// Interchangeable name words. A term matches a file name if any word of its group does.
    static let synonymGroups: [[String]] = [
        ["resume", "cv", "curriculum vitae"],
        ["slides", "presentation", "deck"],
        ["spreadsheet", "sheet"],
        ["screenshot", "screen shot"],
    ]

    /// Every spelling a term may match a name with: itself, its singular form, its group.
    public static func variants(of term: String) -> [String] {
        let base = singular(term)
        var out = [term]
        if base != term { out.append(base) }
        for group in synonymGroups where group.contains(term) || group.contains(base) {
            for word in group where !out.contains(word) { out.append(word) }
        }
        return out
    }

    /// Crude plural strip ("invoices" → "invoice"); names are matched by substring so this is
    /// enough in one direction.
    static func singular(_ word: String) -> String {
        if word.hasSuffix("ss") || word.count <= 3 { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    // MARK: Speech clean-up (closed)

    /// Mis-hearings and spoken spellings, replaced as whole phrases before parsing.
    static let heard: [(String, String)] = [
        ("p d f", "pdf"), ("pee dee eff", "pdf"), ("dot pdf", "pdf"), ("c v", "cv"), ("see vee", "cv"),
        ("power point", "powerpoint"), ("key note", "keynote"), ("screen shot", "screenshot"),
        ("screen shots", "screenshot"), ("slide deck", "slides"), ("excel sheet", "excel"),
        ("word doc", "doc"), ("word document", "document"), ("dot doc", "doc"), ("dot docx", "docx"),
        ("curriculum vitae", "cv"), ("résumé", "resume"), ("resumé", "resume"),
    ]

    // MARK: Time words

    static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "sept": 9, "october": 10, "november": 11, "december": 12,
    ]

    static let recentWords: Set<String> = ["latest", "newest", "recent", "recently", "last", "yesterday", "today"]

    // MARK: Folders

    static let locations: [String: FileLocation] = [
        "desktop": .desktop, "documents": .documents, "downloads": .downloads,
    ]

    // MARK: Request frames

    /// Fetch verbs, longest first. "open" is the one that opens; the rest reveal.
    static let fetchVerbs = [
        "pull up", "bring up", "look for", "find", "fetch", "get", "grab", "locate", "show", "open", "bring", "give",
    ]
    static let whereFrames = [
        "where did i put", "where did i save", "where did i leave", "where do i have", "where can i find",
        "where is", "where's", "wheres", "where are",
    ]
    static let needFrames = ["i need", "i'm looking for", "im looking for", "looking for", "i am looking for"]

    /// What may open the object after the verb: a possessive or definite word.
    static let determiners: Set<String> = ["my", "our", "the", "a", "an", "that", "those", "any"]

    /// Words that put the request on the web or in the how-to world, not in the file system.
    static let notAboutFiles: Set<String> = [
        "template", "templates", "example", "examples", "sample", "samples", "tips", "advice", "ideas", "online",
        "free", "best", "website", "websites", "web", "google", "download", "tutorial", "guide", "how", "why",
        "builder", "maker", "generator", "writer",
    ]

    /// A topic of the person's own notes, reminders or calendar. With one of these and no kind
    /// word, the request is a question about their stuff, not a file.
    static let ownTopics: Set<String> = [
        "note", "notes", "list", "lists", "reminder", "reminders", "calendar", "schedule", "meeting", "meetings",
        "appointment", "appointments", "event", "events", "groceries", "grocery", "todo", "dictation", "dictations",
        "decision", "decisions", "standup", "recording", "recordings", "transcript", "transcripts",
    ]

    /// Words dropped from the name terms.
    static let termStopWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "me", "i", "we", "you", "that", "this", "those", "these", "any", "some",
        "of", "to", "for", "from", "in", "on", "at", "by", "with", "about", "named", "called", "titled", "and", "or",
        "it", "is", "was", "were", "be", "file", "files", "please", "one", "ones", "thing", "stuff", "up", "out",
        "latest", "newest", "recent", "recently", "last", "new", "newer", "yesterday", "today", "version", "copy",
        "sent", "send", "gave", "wrote", "made", "saved", "got", "downloaded", "created", "have", "had", "has",
        "there", "here", "folder", "again", "just", "now", "can", "could", "would", "will", "do", "did", "does",
        "month", "year", "week", "this", "earlier", "before", "after", "dot", "all",
    ]
}
