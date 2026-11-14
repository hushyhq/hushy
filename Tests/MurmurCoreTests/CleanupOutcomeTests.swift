import Foundation
import Testing
@testable import MurmurCore

/// The model's outcome for a dictation reaches History as a short code and a plain sentence. Neither may
/// carry anything the speaker said: guard reasons quote words, so only closed names get through.
@Suite("Cleanup outcome record", .timeLimit(.minutes(1)))
struct CleanupOutcomeTests {
    private func trace(
        _ outcome: ModelOutcome, guardCode: GuardCode? = nil, repaired: Int = 0
    ) -> GroupTrace {
        GroupTrace(words: 12, outcome: outcome, guardCode: guardCode, edited: false, modelMs: 900, repairedSpans: repaired)
    }

    // MARK: Guard codes carry no text

    @Test("a guard reason that quotes the speaker maps to a closed name without the quote")
    func guardCodeDropsQuotedWords() {
        let reasons = [
            "kept retracted item: off the dry cleaning", "added words: [\"invoice\", \"Priya\"]",
            "changed protected term: Kubernetes", "dropped number: 4150", "language mismatch: expected es, model answered in en",
            "changed connective: but -> so", "dropped stance word: probably",
        ]
        for reason in reasons {
            let code = GuardCode(reason: reason)
            #expect(code != .other, Comment(rawValue: "closed table misses: \(reason.prefix(24))"))
            let label = ModelOutcome.logLabel(usedModel: false, rejection: reason)
            let quoted = reason.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            #expect(!label.contains("Priya") && !label.contains("Kubernetes") && !label.contains("dry"))
            #expect(quoted.isEmpty || !label.contains(quoted.trimmingCharacters(in: .whitespaces)))
            #expect(label == "rejected-by-guard(\(code.rawValue))")
        }
    }

    @Test("a reason the table does not know is other, whatever it carries")
    func unknownReasonIsOther() {
        #expect(GuardCode(reason: "brand new guard: with some spoken words") == .other)
        #expect(ModelOutcome.logLabel(usedModel: false, rejection: "something else entirely") == "rejected-by-guard(other)")
        #expect(GuardCode.allCases.allSatisfy { !$0.rawValue.contains(" ") })
    }

    @Test("every reason the guards can build starts with a phrase the table knows")
    func everyGuardReasonIsInTheTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MurmurCore/Cleanup")
        let files = ["SmartCleaner", "RetractionGuard", "SpokenLayoutGuard", "DroppedClauseGuard", "ListStructureGuard",
                     "ProtectedTermGuard", "LiteralSyntaxProtection"]
        let pattern = try NSRegularExpression(
            pattern: #"(?:\.rejected\(|return\s+)"((?:added|changed|collapsed|dropped|kept|reason|reordered|replaced|language)[^"\\:]*)"#)
        var unknown: [String] = []
        for name in files {
            let source = try String(contentsOf: root.appendingPathComponent(name + ".swift"), encoding: .utf8)
            let ns = source as NSString
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let head = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if GuardCode(reason: head) == .other { unknown.append(head) }
            }
        }
        #expect(unknown.isEmpty, "add to GuardCode: \(Set(unknown).sorted())")
    }

    @Test("no log statement in cleanup, the pipeline or the dictation controller interpolates text or a reason")
    func logStatementsCarryNoText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let dirs = ["MurmurCore/Cleanup", "MurmurCore/Pipeline", "MurmurCore/Modes", "Murmur/Dictation"]
        // Whole words only, so a closed enum's `rawValue` is not mistaken for the speaker's raw text.
        let banned = [#"\.?rejection\b"#, #"\breason\)"#, #"\.text\b"#, #"\bdraft\b"#, #"\banswer\b"#, #"\bcandidate\b"#,
                      #"\.raw\b"#, #"\braw\b"#, #"\btranscript\b"#]
        var offenders: [String] = []
        for dir in dirs {
            let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                var index = 0
                while index < lines.count {
                    guard lines[index].range(of: #"\b(?:log|logger)\.(?:notice|info|debug|error|warning|fault)\("#,
                                             options: .regularExpression) != nil else { index += 1; continue }
                    var statement = lines[index]
                    var depth = statement.filter { $0 == "(" }.count - statement.filter { $0 == ")" }.count
                    var end = index
                    while depth > 0, end + 1 < lines.count {
                        end += 1
                        statement += "\n" + lines[end]
                        depth += lines[end].filter { $0 == "(" }.count - lines[end].filter { $0 == ")" }.count
                    }
                    for piece in statement.components(separatedBy: "\\(").dropFirst() {
                        // The interpolated expression only: up to the parenthesis that closes it.
                        var expression = "", open = 1
                        for character in piece {
                            if character == "(" { open += 1 } else if character == ")" { open -= 1 }
                            if open == 0 { break }
                            expression.append(character)
                        }
                        // A `logLabel` call is the only sanctioned way to name a rejection; a count of words is no text.
                        if expression.contains("logLabel(") || expression.contains(".label") { continue }
                        let measured = expression.replacingOccurrences(of: #"wordCount\([^)]*\)"#, with: "", options: .regularExpression)
                        if banned.contains(where: { measured.range(of: $0, options: .regularExpression) != nil }) {
                            offenders.append("\(file.lastPathComponent):\(index + 1)")
                        }
                    }
                    index = end + 1
                }
            }
        }
        #expect(offenders.isEmpty, "log lines that may carry text: \(offenders)")
    }

    // MARK: The saved code and the History sentence

    @Test("a dictation where every group ran says so")
    func ranCode() throws {
        let summary = try #require(CleanupOutcomeSummary(groups: [trace(.used), trace(.used)], level: .clean))
        #expect(summary.code == "ran")
        #expect(summary.ran)
        #expect(summary.plainLine == "The model pass ran.")
    }

    @Test("a repaired answer is recorded as ran and repaired")
    func repairedCode() throws {
        let summary = try #require(CleanupOutcomeSummary(groups: [trace(.used, repaired: 1)], level: .polished))
        #expect(summary.code == "ran-repaired")
        #expect(summary.plainLine.contains("put back"))
    }

    @Test("each way the model can fail to run has its own code and sentence")
    func skipCodes() throws {
        let cases: [(ModelOutcome, String, String)] = [
            (.timeout, "timeout", "took too long"), (.skippedSlow, "skipped-slow", "too slow"),
            (.thermalSerious, "thermal-serious", "running hot"), (.unavailable, "unavailable", "no cleanup model"),
            (.modelBusy, "model-busy", "too busy"), (.refused, "refused", "declined"),
            (.modelError, "model-error", "error"),
        ]
        for (outcome, code, phrase) in cases {
            let summary = try #require(CleanupOutcomeSummary(groups: [trace(outcome)], level: .clean))
            #expect(summary.code == code)
            #expect(summary.plainLine.contains(phrase), Comment(rawValue: summary.plainLine))
            #expect(!summary.ran)
        }
    }

    @Test("a guard rejection names the check in words and the code carries only the guard name")
    func guardCode() throws {
        let summary = try #require(CleanupOutcomeSummary(
            groups: [trace(.rejectedByGuard, guardCode: .changedDigits)], level: .clean))
        #expect(summary.code == "rejected-by-guard/changed-digits")
        #expect(summary.plainLine.contains("a number"))
    }

    @Test("a long dictation with some parts not run counts them")
    func partsCode() throws {
        let groups = [trace(.used), trace(.timeout), trace(.used), trace(.timeout)]
        let summary = try #require(CleanupOutcomeSummary(groups: groups, level: .polished))
        #expect(summary.code == "timeout:2/4")
        #expect(summary.plainLine.contains("2 of 4 parts"))
    }

    @Test("codes round-trip, and anything that is not a code is refused")
    func roundTrip() throws {
        for code in ["ran", "ran-repaired", "timeout:2/12", "rejected-by-guard/kept-retracted-item", "thermal-serious"] {
            #expect(CleanupOutcomeSummary(code: code)?.code == code)
        }
        for junk in ["", "ran and polished", "rejected-by-guard/not-a-guard", "timeout:x/y", "Priya was here"] {
            #expect(CleanupOutcomeSummary(code: junk) == nil)
        }
    }

    @Test("Verbatim has no model pass, so it records nothing")
    func verbatimRecordsNothing() {
        #expect(CleanupOutcomeSummary(groups: [trace(.notAsked)], level: .verbatim) == nil)
    }

    @Test("the code is saved with the History entry and read back")
    func codeIsStored() throws {
        let store = try Store()
        let saved = try store.save(Dictation(rawText: "a", text: "A", durationSeconds: 1, cleanupOutcome: "timeout"))
        #expect(saved.cleanupOutcome == "timeout")
        #expect(try store.lastDictation()?.cleanupOutcome == "timeout")
        let older = try store.save(Dictation(rawText: "b", text: "B", durationSeconds: 1))
        #expect(older.cleanupOutcome == nil)
    }

    @Test("the kind of app is saved with the History entry as a category name and read back")
    func categoryIsStored() throws {
        let store = try Store()
        let saved = try store.save(Dictation(rawText: "a", text: "A", durationSeconds: 1, appCategory: AppCategory.email.rawValue))
        #expect(saved.appCategory == "email")
        #expect(try store.lastDictation()?.appCategory == "email")
        let older = try store.save(Dictation(rawText: "b", text: "B", durationSeconds: 1))
        #expect(older.appCategory == nil)
    }
}
