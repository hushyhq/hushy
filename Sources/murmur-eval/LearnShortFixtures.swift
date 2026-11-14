import Foundation

/// Adversarial short dictations: each must teach nothing active, however often it repeats.
enum LearnShortFixtures {
    static let surname = "Lindqvist"

    struct Scenario {
        let name: String
        let category: String
        /// The dictation as pasted, the reads of the field afterwards, and the day.
        let edits: [(inserted: String, reads: [String], dayOffset: Double)]
        var isCode = false
        var isSecure = false
        var excluded = false
    }

    private static func repeated(_ inserted: String, _ reads: [String], gap: Double = 2) -> [(String, [String], Double)] {
        [(inserted, reads, 0), (inserted, reads, gap)]
    }

    private static func fixed(_ before: String, _ after: String, around: (String, String) = ("", "")) -> [String] {
        let wrap: (String) -> String = { around.0 + $0 + around.1 }
        return [wrap(before), wrap(after), wrap(after)]
    }

    static let adversarial: [Scenario] = [
        Scenario(name: "unrelated-word", category: "replaced", edits: repeated("Pria.", fixed("Pria.", "Gustavo."))),
        Scenario(name: "ordinary-swap", category: "common-word swap", edits: repeated("their", fixed("their", "there", around: ("call ", "")))),
        Scenario(name: "big-large", category: "common-word swap", edits: repeated("big", fixed("big", "large", around: ("a ", " deal")))),
        Scenario(name: "digits", category: "digits", edits: repeated("Room 10", fixed("Room 10", "Room 11", around: ("Meet in ", " now")))),
        Scenario(name: "word-added", category: "added/deleted word", edits: repeated("Pria", fixed("Pria", "Priya Raman"))),
        Scenario(name: "word-deleted", category: "added/deleted word", edits: repeated("Pria Raman", fixed("Pria Raman", "Priya"))),
        Scenario(name: "second-edit", category: "second edit", edits: repeated(
            "Pria", fixed("Pria and the deck", "Priya and the decks"))),
        Scenario(name: "context-changed", category: "surroundings changed", edits: repeated(
            "Pria", ["Hi team, welcome Pria today", "Hi all, welcome Priya today", "Hi all, welcome Priya today"])),
        Scenario(name: "word-elsewhere", category: "same word elsewhere", edits: repeated(
            "Pria", ["Priya wrote it. Pria", "Priya wrote it. Priya", "Priya wrote it. Priya"])),
        Scenario(name: "dictation-deleted", category: "deleted", edits: repeated("Pria", ["hello Pria today", "hello today", "hello today"])),
        Scenario(name: "field-emptied", category: "deleted", edits: repeated("Pria", ["Pria", "", ""])),
        Scenario(name: "half-typed", category: "unstable", edits: repeated("Pria", ["met Pria", "met Priy", "met Priya"])),
        Scenario(name: "no-anchor", category: "missing anchor", edits: repeated("Pria", ["met Priya", "met Priya", "met Priya"])),
        Scenario(name: "not-sound-alike", category: "replaced", edits: repeated("Pria", fixed("Pria", "Zachariah"))),
        Scenario(name: "code-editor", category: "privacy exclusion", edits: repeated("Kubernetis", fixed("Kubernetis", "Kubernetes")), isCode: true),
        Scenario(name: "secure-field", category: "privacy exclusion", edits: repeated("Pria", fixed("Pria", "Priya")), isSecure: true),
        Scenario(name: "excluded-app", category: "privacy exclusion", edits: repeated("Pria", fixed("Pria", "Priya")), excluded: true),
        // A real fix made once stays a suggestion; two weeks apart it is not enough either.
        Scenario(name: "once-only", category: "one-off sound-alike", edits: [("Pria", fixed("Pria", "Priya"), 0)]),
        Scenario(name: "outside-window", category: "one-off sound-alike", edits: [
            ("Pria", fixed("Pria", "Priya"), 0), ("Pria", fixed("Pria", "Priya"), 21),
        ]),
    ]
}
