import Foundation

/// Synthetic dictation → user-edit data for `murmur-eval learn`. Built from the *shapes* of the
/// dev set (`Evals/dictation-golden.json` plain dictations: short requests, status updates,
/// scheduling) plus names and jargon of the kind users report (`Evals/context-golden.json`,
/// `docs/research/accent-robustness.md`). No held-out data, no Voice Lab audio: everything here
/// is text, generated deterministically.
enum LearnFixtures {
    /// A term and how the recognizer renders it (the ASR text a user would then correct).
    struct Term {
        let term: String
        let heardAs: [String]
        /// Expected to be learnable; false marks a known limit (the term is itself an ordinary
        /// English word, so the classifier deliberately refuses it — reported, not hidden).
        let learnable: Bool
    }

    static let terms: [Term] = [
        Term(term: "Priya", heardAs: ["Pria", "Preeya"], learnable: true),
        Term(term: "Kubernetes", heardAs: ["Kubernetis", "Kubernetties"], learnable: true),
        Term(term: "Hushy", heardAs: ["Hushie", "Hushey"], learnable: true),
        Term(term: "Siobhan", heardAs: ["Sioban", "Shivon"], learnable: true),
        Term(term: "Karthik", heardAs: ["Karthick", "Kartik"], learnable: true),
        Term(term: "Zoraida", heardAs: ["Zoraeda", "Soraida"], learnable: true),
        Term(term: "Nguyen", heardAs: ["Nguyan", "Nuyen"], learnable: true),
        Term(term: "kubectl", heardAs: ["cube cuddle", "kube control"], learnable: true),
        Term(term: "Grafana", heardAs: ["Grafanna", "Grafauna"], learnable: true),
        Term(term: "Terraform", heardAs: ["Teraform", "Terra form"], learnable: true),
        Term(term: "Chidinma", heardAs: ["Chidima", "Chidinmah"], learnable: true),
        Term(term: "Anthropic", heardAs: ["Entropic", "Anthropik"], learnable: false),
    ]

    /// Dev-set-shaped sentences; `{T}` is the term slot.
    static let learningTemplates = [
        "Can you send the deck to {T} before the meeting tomorrow.",
        "I just talked to {T} and we agreed to push the launch to next week.",
        "Please loop in {T} on the thread about the budget.",
        "We should ask {T} whether the migration is finished.",
        "{T} said the dashboard numbers look good this morning.",
    ]

    /// Different sentences for the follow-up set, so improvement isn't memorised text.
    static let followUpTemplates = [
        "Let's set up a quick call with {T} on Thursday afternoon.",
        "Remind me to follow up on the {T} review after lunch.",
        "The notes from {T} are in the shared folder now.",
    ]

    /// Follow-up dictations with no learned term: output must not change at all.
    static let controlSentences = [
        "Let's meet at 9 tomorrow in the main conference room.",
        "I think their team is ready to ship the report by Friday.",
        "Can you check the nodes in the staging cluster before lunch.",
        "We need the deck, the budget and the demo for the review.",
        "Send the invoice to Sarah and copy John on the thread.",
        "The privacy review is scheduled for next Tuesday at 3.",
        "Please grab a coffee for Grace when you come in.",
        "Our big customer asked for a large discount this quarter.",
    ]

    /// One adversarial scenario: a sequence of (inserted, what the user left) edits, all of
    /// which should teach nothing active. `context` overrides for privacy scenarios.
    struct Scenario {
        let name: String
        let category: String
        let edits: [(inserted: String, edited: String, dayOffset: Double)]
        var isCode = false
        var isSecure = false
        var excluded = false
    }

    static func twice(_ inserted: String, _ edited: String, gap: Double = 2) -> [(String, String, Double)] {
        [(inserted, edited, 0), (inserted.replacingOccurrences(of: "tomorrow", with: "today"),
                                 edited.replacingOccurrences(of: "tomorrow", with: "today"), gap)]
    }

    static let adversarial: [Scenario] = [
        // Unrelated rewrites: the user replaced most of the sentence.
        Scenario(name: "rewrite-plan", category: "unrelated rewrite", edits: [
            ("Can you send the deck to Priya before the meeting tomorrow.", "Actually never mind, I will present it myself on Friday.", 0),
            ("Can you send the deck to Priya before the meeting today.", "Skip the deck, we can talk it through live.", 1),
        ]),
        Scenario(name: "rewrite-tone", category: "unrelated rewrite", edits: [
            ("I think the numbers look good this morning.", "Numbers look fine, shipping it.", 0),
            ("I think the numbers look good this afternoon.", "Numbers look fine, shipping it now.", 1),
        ]),
        Scenario(name: "rewrite-append", category: "unrelated rewrite", edits: [
            ("Please loop in the team on the thread.", "Please loop in the team on the thread about the Q3 budget and hiring plan for Grafana.", 0),
            ("Please loop in the team on the thread.", "Please loop in the team on the thread about the Q3 budget and hiring plan for Grafana.", 1),
        ]),
        // Deliberate one-off changes, repeated so the threshold alone can't save us.
        Scenario(name: "name-swap", category: "deliberate change", edits: twice(
            "Can you send the deck to John before the meeting tomorrow.", "Can you send the deck to Sarah before the meeting tomorrow.")),
        Scenario(name: "name-swap-2", category: "deliberate change", edits: twice(
            "Ask Priya about the release tomorrow.", "Ask Pooja about the release tomorrow.")),
        Scenario(name: "day-swap", category: "deliberate change", edits: twice(
            "Let's meet on Tuesday at the office tomorrow.", "Let's meet on Friday at the office tomorrow.")),
        Scenario(name: "number-swap", category: "deliberate change", edits: twice(
            "Let's meet at 10 in the main room tomorrow.", "Let's meet at 11 in the main room tomorrow.")),
        Scenario(name: "year-swap", category: "deliberate change", edits: twice(
            "The report covers 2023 for the board tomorrow.", "The report covers 2024 for the board tomorrow.")),
        // Ordinary-word swaps (grammar, synonyms, ASR slips between real words).
        Scenario(name: "their-there", category: "common-word swap", edits: twice(
            "I think their ready to ship tomorrow.", "I think they're ready to ship tomorrow.")),
        Scenario(name: "nodes-notes", category: "common-word swap", edits: twice(
            "Check the nodes after the meeting tomorrow.", "Check the notes after the meeting tomorrow.")),
        Scenario(name: "big-large", category: "common-word swap", edits: twice(
            "We have a big customer call tomorrow.", "We have a large customer call tomorrow.")),
        Scenario(name: "privacy-priya", category: "common-word swap", edits: twice(
            "The privacy review is ready for tomorrow.", "The security review is ready for tomorrow.")),
        // A sound-alike correction made only once (should stay a suggestion).
        Scenario(name: "once-only", category: "one-off sound-alike", edits: [
            ("Send the deck to Sara before the meeting tomorrow.", "Send the deck to Sarah before the meeting tomorrow.", 0),
        ]),
        // The same correction twice, but three weeks apart.
        Scenario(name: "outside-window", category: "one-off sound-alike", edits: [
            ("Please loop in Zoraeda on the thread.", "Please loop in Zoraida on the thread.", 0),
            ("Ask Zoraeda about the release.", "Ask Zoraida about the release.", 21),
        ]),
        // Privacy exclusions: real corrections that must be refused by the gate.
        Scenario(name: "code-editor", category: "privacy exclusion", edits: twice(
            "Rename the get user by id helper tomorrow.", "Rename the getUserById helper tomorrow."), isCode: true),
        Scenario(name: "secure-field", category: "privacy exclusion", edits: twice(
            "Send the deck to Pria before the meeting tomorrow.", "Send the deck to Priya before the meeting tomorrow."), isSecure: true),
        Scenario(name: "excluded-app", category: "privacy exclusion", edits: twice(
            "Send the deck to Pria before the meeting tomorrow.", "Send the deck to Priya before the meeting tomorrow."), excluded: true),
    ]
}
