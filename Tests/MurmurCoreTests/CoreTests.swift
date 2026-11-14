import Foundation
import Testing
@testable import MurmurCore

@Suite("Personalizer")
struct PersonalizerTests {
    @Test("dictionary fixes spoken variants and casing")
    func dictionary() {
        let personalizer = Personalizer(dictionary: [
            DictionaryEntry(term: "Kubernetes", soundsLike: ["cooper netties"]),
            DictionaryEntry(term: "iOS"),
        ])
        let output = personalizer.apply("Deploy cooper netties on ios today.")
        #expect(output.text == "Deploy Kubernetes on iOS today.")
        #expect(output.dictionaryFixes == 2)
    }

    @Test("dictionary does not touch partial words")
    func partialWords() {
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Kiro")])
        #expect(personalizer.apply("The kirov ballet and kiro.").text == "The kirov ballet and Kiro.")
        // An ordinary-word term keeps the sentence's case where it does not name the product (`OrdinaryTermCase`).
        #expect(Personalizer(dictionary: [DictionaryEntry(term: "Go")]).apply("It is good to go.").text == "It is good to go.")
    }

    @Test("whole-utterance snippet replaces everything")
    func wholeSnippet() {
        let personalizer = Personalizer(snippets: [Snippet(trigger: "my calendar link", expansion: "https://cal.com/me")])
        #expect(personalizer.apply("My calendar link.").text == "https://cal.com/me")
    }

    @Test("inline snippet is expanded in place")
    func inlineSnippet() {
        let personalizer = Personalizer(snippets: [Snippet(trigger: "my email", expansion: "me@example.com")])
        let output = personalizer.apply("Send it to my email, thanks.")
        #expect(output.text == "Send it to me@example.com, thanks.")
        #expect(output.snippetsUsed == 1)
    }

    @Test("snippet validation")
    func validation() {
        #expect(throws: Snippet.ValidationError.emptyTrigger) { try Snippet(trigger: " ", expansion: "x").validate() }
        #expect(throws: Snippet.ValidationError.triggerTooLong) {
            try Snippet(trigger: String(repeating: "a", count: 61), expansion: "x").validate()
        }
        #expect(throws: Snippet.ValidationError.emptyExpansion) { try Snippet(trigger: "hi", expansion: "").validate() }
    }
}

@Suite("Store")
struct StoreTests {
    @Test("saves, searches and deletes dictations")
    func dictations() throws {
        let store = try Store()
        let saved = try store.save(Dictation(rawText: "um ship the release", text: "Ship the release.", durationSeconds: 3))
        try store.save(Dictation(rawText: "lunch", text: "Lunch at noon.", durationSeconds: 2))
        #expect(saved.id != nil)
        #expect(try store.recentDictations().count == 2)
        #expect(try store.searchDictations("releas").map(\.text) == ["Ship the release."])
        #expect(try store.lastDictation()?.text == "Lunch at noon.")
        try store.deleteDictation(id: saved.id!)
        #expect(try store.searchDictations("release").isEmpty)
    }

    @Test("paste-last skips empty failed captures")
    func lastDictationSkipsEmptyFailure() throws {
        let store = try Store()
        try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 10), rawText: "hello", text: "Hello.", durationSeconds: 2))
        try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 20), rawText: "", text: "", durationSeconds: 2, status: .failed))
        try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 30), rawText: "old", text: "Cancelled.", durationSeconds: 2, status: .cancelled))
        #expect(try store.lastDictation()?.text == "Hello.")

        let onlyEmpty = try Store()
        try onlyEmpty.save(Dictation(rawText: "", text: "", durationSeconds: 2, status: .failed))
        #expect(try onlyEmpty.lastDictation() == nil)
    }

    @Test("a failed dictation round trips with its audio path and empty transcript")
    func failedDictationRoundTrip() throws {
        let store = try Store()
        let failed = try store.save(Dictation(
            rawText: "", text: "", appBundleID: "com.apple.mail", appName: "Mail",
            durationSeconds: 4, status: .failed, audioPath: "/tmp/failed-audio.wav"))

        let reloaded = try store.recentDictations().first { $0.id == failed.id }
        #expect(reloaded?.status == .failed)
        #expect(reloaded?.text == "")
        #expect(reloaded?.rawText == "")
        #expect(reloaded?.audioPath == "/tmp/failed-audio.wav")
        #expect(reloaded?.appBundleID == "com.apple.mail")

        // Failed rows never surface as "paste last" candidates, but they still show in History.
        #expect(try store.lastDictation()?.id != failed.id)
        #expect(try store.allDictations().contains { $0.id == failed.id })
    }

    @Test("a retried transcription replaces the cleanup outcome with the new one, or clears it")
    func retryReplacesCleanupOutcome() throws {
        let store = try Store()
        let saved = try store.save(Dictation(
            rawText: "", text: "", durationSeconds: 3, status: .failed, audioPath: "/tmp/retry.wav", cleanupOutcome: "timeout"))
        try store.updateTranscription(
            id: saved.id!, rawText: "ship it", text: "Ship it.", status: .notInserted, cleanupOutcome: "ran")
        #expect(try store.recentDictations().first { $0.id == saved.id }?.cleanupOutcome == "ran")
        try store.updateTranscription(id: saved.id!, rawText: "ship it", text: "Ship it.", status: .notInserted)
        #expect(try store.recentDictations().first { $0.id == saved.id }?.cleanupOutcome == nil)
    }

    @Test("updateTranscription overwrites text and status after a retry")
    func updateTranscription() throws {
        let store = try Store()
        let failed = try store.save(Dictation(
            rawText: "", text: "", durationSeconds: 3, status: .failed, audioPath: "/tmp/retry.wav"))

        try store.updateTranscription(
            id: failed.id!, rawText: "ship the release", text: "Ship the release.", status: .notInserted)

        let reloaded = try store.recentDictations().first { $0.id == failed.id }
        #expect(reloaded?.rawText == "ship the release")
        #expect(reloaded?.text == "Ship the release.")
        #expect(reloaded?.status == .notInserted)
        #expect(reloaded?.wordCount == 3)
        // Retry never re-pastes: audio and app metadata are untouched, status is never .inserted.
        #expect(reloaded?.audioPath == "/tmp/retry.wav")
    }

    @Test("deleteDictations removes several rows in one transaction and reports their audio paths")
    func deleteDictationsBatch() throws {
        let store = try Store()
        let first = try store.save(Dictation(rawText: "a", text: "A.", durationSeconds: 1, audioPath: "/tmp/a.wav"))
        let second = try store.save(Dictation(rawText: "b", text: "B.", durationSeconds: 1))
        let third = try store.save(Dictation(rawText: "c", text: "C.", durationSeconds: 1, audioPath: "/tmp/c.wav"))
        let kept = try store.save(Dictation(rawText: "d", text: "D.", durationSeconds: 1))

        let removedAudio = try store.deleteDictations(ids: [first.id!, second.id!, third.id!])

        #expect(Set(removedAudio) == ["/tmp/a.wav", "/tmp/c.wav"])
        let remaining = try store.recentDictations()
        #expect(remaining.map(\.id) == [kept.id])
    }

    @Test("deleteDictations with an unknown id still deletes the ones that exist")
    func deleteDictationsBatchToleratesMissingID() throws {
        let store = try Store()
        let saved = try store.save(Dictation(rawText: "a", text: "A.", durationSeconds: 1))

        let removedAudio = try store.deleteDictations(ids: [saved.id!, 999_999])

        #expect(removedAudio.isEmpty)
        #expect(try store.recentDictations().isEmpty)
    }

    @Test("needsAttention flags failed, not-pasted and cancelled dictations")
    func needsAttention() {
        #expect(Dictation(rawText: "", text: "", durationSeconds: 1, status: .failed).needsAttention)
        #expect(Dictation(rawText: "a", text: "A.", durationSeconds: 1, status: .notInserted).needsAttention)
        #expect(Dictation(rawText: "a", text: "A.", durationSeconds: 1, status: .cancelled).needsAttention)
        #expect(!Dictation(rawText: "a", text: "A.", durationSeconds: 1, status: .inserted).needsAttention)
    }

    @Test("notes are searchable across title, transcript and summary")
    func notes() throws {
        let store = try Store()
        var note = try store.save(Note(title: "Pricing sync", transcript: "We agreed on eight dollars a month."))
        note.summary = "Pro plan price decided."
        note.status = .ready
        try store.save(note)
        #expect(try store.searchNotes("dollars").count == 1)
        #expect(try store.searchNotes("decided").first?.title == "Pricing sync")
        #expect(try store.notes().count == 1)
        try store.deleteNote(id: note.id!)
        #expect(try store.notes().isEmpty)
    }

    @Test("action item completion persists per note and survives deleting the note")
    func actionItemCompletion() throws {
        let store = try Store()
        let note = try store.save(Note(
            title: "Standup", transcript: "…", summary: "…",
            actionItems: ["Email Sam", "File the report", "Book travel"], status: .ready))
        let id = try #require(note.id)

        #expect(try store.doneActionItemIndexes(noteId: id).isEmpty)

        try store.setActionItemDone(noteId: id, itemIndex: 1, isDone: true)
        #expect(try store.doneActionItemIndexes(noteId: id) == [1])
        #expect(try store.doneActionItemIndexesByNote()[id] == [1])

        // Toggling a second item accumulates rather than replacing the first.
        try store.setActionItemDone(noteId: id, itemIndex: 0, isDone: true)
        #expect(try store.doneActionItemIndexes(noteId: id) == [0, 1])

        // Un-marking removes the row rather than leaving isDone = false lying around.
        try store.setActionItemDone(noteId: id, itemIndex: 1, isDone: false)
        #expect(try store.doneActionItemIndexes(noteId: id) == [0])

        // Deleting the note cascades and cleans up its action-item rows (foreign key ON DELETE
        // CASCADE), so a new note reusing the same id never inherits stale completion state.
        try store.deleteNote(id: id)
        #expect(try store.doneActionItemIndexes(noteId: id).isEmpty)
    }

    @Test("startup lists unfinished notes to resume and preserves content")
    func interruptedNotes() throws {
        let store = try Store()
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = try store.save(Note(
            title: "Still recording", createdAt: capturedAt, durationSeconds: 12,
            transcript: "Saved words", status: .recording, audioPath: "/tmp/note-audio"
        ))
        let processing = try store.save(Note(
            title: "Summarizing", createdAt: capturedAt, durationSeconds: 25,
            transcript: "Another saved transcript", status: .processing, audioPath: "/tmp/other-audio"
        ))
        let ready = try store.save(Note(title: "Finished", status: .ready))
        let failed = try store.save(Note(
            title: "Already incomplete", transcript: "Earlier words", summary: "Earlier summary",
            actionItems: ["Call Sam"], status: .failed, audioPath: "/tmp/failed-audio"
        ))
        try store.writer.write { db in
            for index in 0..<505 {
                var note = Note(title: "Interrupted \(index)", status: .recording)
                try note.insert(db)
            }
        }

        // A launch resumes every interrupted note from its journal; a legacy one starts at sealing (notes audit B3).
        let resumed = try store.notesToResume()
        #expect(resumed.count == 507)
        #expect(Set(resumed).isSuperset(of: [recording.id!, processing.id!]))
        #expect(!resumed.contains(ready.id!) && !resumed.contains(failed.id!))
        #expect(try store.finalizeState(noteId: recording.id!)?.step == .sealing)
        let kept = try store.note(id: recording.id!)
        #expect(kept?.status == .recording, "nothing is marked failed: the runner finishes it")
        #expect(kept?.createdAt == capturedAt)
        #expect(kept?.durationSeconds == 12)
        #expect(kept?.transcript == "Saved words")
        #expect(kept?.audioPath == "/tmp/note-audio")
        let preexistingFailure = try store.note(id: failed.id!)
        #expect(preexistingFailure?.status == .failed)
        #expect(preexistingFailure?.transcript == "Earlier words")
        #expect(try store.notesToResume().count == 507, "asking again adds no rows and lists the same notes")
        for id in resumed { try store.advanceFinalize(noteId: id, from: .sealing, to: .done, pipelineVersion: 1) }
        #expect(try store.notesToResume().isEmpty)
    }

    @Test("notes are ready only with saved text and all chunks persisted")
    func noteFinalizationPolicy() {
        #expect(Note.finalizedStatus(transcript: "A transcript", chunkFailed: false, persistenceFailed: false) == .ready)
        #expect(Note.finalizedStatus(transcript: " ", chunkFailed: false, persistenceFailed: false) == .failed)
        #expect(Note.finalizedStatus(transcript: "Partial transcript", chunkFailed: true, persistenceFailed: false) == .failed)
        #expect(Note.finalizedStatus(transcript: "Transcript", chunkFailed: false, persistenceFailed: true) == .failed)
    }

    @Test("retention removes old cancelled items and detaches old audio")
    func retention() throws {
        let store = try Store()
        let old = Date().addingTimeInterval(-10 * 86_400)
        try store.save(Dictation(createdAt: old, rawText: "a", text: "A.", durationSeconds: 1, status: .cancelled, audioPath: "/tmp/a.wav"))
        try store.save(Dictation(createdAt: old, rawText: "b", text: "B.", durationSeconds: 1, audioPath: "/tmp/b.wav"))
        try store.save(Dictation(rawText: "c", text: "C.", durationSeconds: 1, audioPath: "/tmp/c.wav"))
        let removed = try store.applyRetention(audioDays: 7)
        #expect(Set(removed) == ["/tmp/a.wav", "/tmp/b.wav"])
        let remaining = try store.recentDictations()
        #expect(remaining.count == 2)
        #expect(remaining.first { $0.text == "C." }?.audioPath == "/tmp/c.wav")
        #expect(try store.applyRetention(audioDays: nil).isEmpty)
    }

    @Test("dictionary and snippets round-trip")
    func personalization() throws {
        let store = try Store()
        try store.save(DictionaryEntry(term: "Murmur", soundsLike: ["mur mur"]))
        try store.save(Snippet(trigger: "sig", expansion: "Best, N"))
        #expect(try store.dictionary().first?.soundsLike == ["mur mur"])
        #expect(try store.personalizer().apply("sig").text == "Best, N")
        #expect(throws: Snippet.ValidationError.self) { try store.save(Snippet(trigger: "", expansion: "x")) }
    }
}

@Suite("Insights")
struct InsightsTests {
    let calendar = Calendar(identifier: .gregorian)

    func day(_ offset: Int, from now: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    @Test("computes totals, wpm, streaks and categories")
    func compute() {
        let now = Date()
        let items = [
            Dictation(createdAt: day(0, from: now), rawText: "", text: "one two three four", appBundleID: "com.apple.mail", durationSeconds: 2, fixes: 1),
            Dictation(createdAt: day(-1, from: now), rawText: "", text: "one two", appBundleID: "com.tinyspeck.slackmacgap", durationSeconds: 2),
            Dictation(createdAt: day(-3, from: now), rawText: "", text: "one two", durationSeconds: 2),
            Dictation(createdAt: day(-4, from: now), rawText: "", text: "one two", durationSeconds: 2),
            Dictation(createdAt: day(-5, from: now), rawText: "", text: "one two", durationSeconds: 2),
            Dictation(createdAt: now, rawText: "", text: "ignored words here", durationSeconds: 2, status: .cancelled),
        ]
        let insights = Insights.compute(from: items, now: now, calendar: calendar)
        #expect(insights.totalWords == 12)
        #expect(insights.totalDictations == 5)
        #expect(insights.averageWPM == 72)
        #expect(insights.currentStreak == 2)
        #expect(insights.longestStreak == 3)
        #expect(insights.fixes == 1)
        #expect(insights.categories.first?.category == .other)
        #expect(insights.appsUsed == 2)
    }

    @Test("streak continues from yesterday when nothing today")
    func streakFromYesterday() {
        let now = Date()
        let items = [Dictation(createdAt: day(-1, from: now), rawText: "", text: "hi", durationSeconds: 1)]
        #expect(Insights.compute(from: items, now: now, calendar: calendar).currentStreak == 1)
    }

    @Test("empty input")
    func empty() {
        #expect(Insights.compute(from: []) == .empty)
    }

    @Test("app classification", arguments: [
        ("com.openai.chat" as String?, AppCategory.aiPrompts), ("com.apple.mail", .email),
        ("com.microsoft.VSCode", .code), ("com.exafunction.windsurf", .code), (nil, .other),
    ])
    func classify(bundle: String?, expected: AppCategory) {
        #expect(AppCategory.classify(bundleID: bundle) == expected)
    }
}

@Suite("MCPServer")
struct MCPServerTests {
    func makeServer(scope: MCPServer.Scope = .notes) throws -> MCPServer {
        let store = try Store()
        var note = Note(title: "Launch plan", transcript: "We will launch on Friday. Sarah will write the post.")
        note.summary = "Launch Friday."
        note.actionItems = ["Sarah will write the post"]
        note.status = .ready
        try store.save(note)
        try store.save(Dictation(rawText: "", text: "Ping the design team about icons.", appName: "Slack", durationSeconds: 3))
        return MCPServer(reader: store.writer, scope: scope)
    }

    func call(_ server: MCPServer, _ json: String) throws -> [String: Any] {
        let line = try #require(server.handle(line: json))
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func toolText(_ response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @Test("initialize advertises tools capability")
    func initialize() throws {
        let response = try call(try makeServer(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test("notifications get no response")
    func notification() throws {
        #expect(try makeServer().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("tools/list returns read-only tools, and no dictation-history tool")
    func list() throws {
        let response = try call(try makeServer(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String } .contains("search_notes"))
        #expect(tools.count == 4 + MeetingMemoryTools.names.count, "three note lookups, the meeting-memory lookups and propose_action")
        let all = try call(try makeServer(scope: .all), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect((((all["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } == ["get_insights"])
        #expect(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
    }

    @Test("search and read notes")
    func searchAndGet() throws {
        let server = try makeServer()
        let search = try call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"launch"}}}"#)
        #expect(toolText(search).contains("Launch plan"))
        let get = try call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_note","arguments":{"id":1}}}"#)
        #expect(toolText(get).contains("- [ ] Sarah will write the post"))
        let history = try call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_history","arguments":{"query":"design"}}}"#)
        #expect(!toolText(history).contains("design team"))
        let insights = try call(try makeServer(scope: .all), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_insights","arguments":{}}}"#)
        #expect(toolText(insights).contains("Total words dictated: 6"))
    }

    @Test("errors are reported, not thrown")
    func errors() throws {
        let server = try makeServer()
        let missing = try call(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_note","arguments":{"id":99}}}"#)
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = try call(server, #"{"jsonrpc":"2.0","id":8,"method":"nope"}"#)
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let bad = try call(server, "not json")
        #expect((bad["error"] as? [String: Any])?["code"] as? Int == -32700)
    }
}

@Suite("Summaries and export")
struct SummaryTests {
    let transcript = """
        Today we reviewed the launch plan for the new pricing page. The pricing page needs a clear free tier. \
        Sarah will update the pricing page copy by Friday. We also talked about the onboarding flow and the \
        model download. The onboarding flow should start the model download on the first screen. \
        Lunch was great. I'll follow up with the design team about the pricing page icons.
        """

    @Test("extractive summary picks key sentences and action items")
    func summary() {
        let output = ExtractiveSummarizer.summarize(transcript, fallbackTitle: "Memo")
        #expect(output.summary.contains("pricing page"))
        #expect(!output.summary.contains("Lunch was great"))
        #expect(output.actionItems.contains("Sarah will update the pricing page copy by Friday"))
        #expect(output.actionItems.contains { $0.hasPrefix("I'll follow up") })
        #expect(output.title.contains("Pricing"))
    }

    @Test("empty transcript falls back")
    func empty() {
        let output = ExtractiveSummarizer.summarize("", fallbackTitle: "Memo")
        #expect(output == .init(title: "Memo", summary: "", actionItems: []))
    }

    @Test("markdown export has front matter and sections")
    func markdown() throws {
        let note = Note(id: 3, title: "Plan: \"Q4\"", transcript: "Hello.", summary: "Short.", actionItems: ["Do it"])
        let markdown = MarkdownExporter.markdown(for: note)
        #expect(markdown.hasPrefix("---\ntitle: \"Plan: \\\"Q4\\\"\""))
        #expect(markdown.contains("## Action items\n\n- [ ] Do it"))
        #expect(!MarkdownExporter.fileName(for: note).contains(":"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try MarkdownExporter.export(note, to: directory)
        #expect(try String(contentsOf: url, encoding: .utf8) == markdown)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("word stats")
    func stats() {
        #expect(TextStats.wordCount("Let's meet at 9, okay?") == 5)
        #expect(TextStats.changedWords(from: "meet at 10 no 9", to: "Meet at 9.") == 2)
    }
}

@Suite("Edit verdict")
struct EditVerdictTests {
    @Test("verbatim text is kept")
    func kept() {
        #expect(EditVerdict.judge(inserted: "Let's meet at 9.", fieldValue: "Hi team, Let's meet at 9. Thanks") == .kept)
    }

    @Test("changed text is edited")
    func edited() {
        #expect(EditVerdict.judge(inserted: "Let's meet at 9 tomorrow morning.", fieldValue: "Let's meet at 10 tomorrow morning.") == .edited)
    }

    @Test("cleared or unreadable fields are unknown")
    func unknown() {
        #expect(EditVerdict.judge(inserted: "Let's meet at 9 tomorrow.", fieldValue: "") == nil)
        #expect(EditVerdict.judge(inserted: "Let's meet at 9 tomorrow.", fieldValue: nil) == nil)
    }

    @Test("rate over judged dictations only")
    func rate() {
        var kept = Dictation(rawText: "", text: "a", durationSeconds: 1)
        kept.editState = .kept
        var edited = kept
        edited.editState = .edited
        let unjudged = Dictation(rawText: "", text: "b", durationSeconds: 1)
        #expect(EditVerdict.editFreeRate([kept, kept, edited, unjudged]) == 2.0 / 3.0)
        #expect(EditVerdict.editFreeRate([unjudged]) == nil)
    }
}

@Suite("Eval metrics")
struct EvalMetricsTests {
    @Test("WER counts substitutions, insertions and deletions")
    func wer() {
        #expect(EvalMetrics.wer(reference: "meet at nine", hypothesis: "Meet at 9.") == 0)
        #expect(EvalMetrics.wer(reference: "a b c d", hypothesis: "a x c") == 0.5)
    }

    @Test("list formatting comparison")
    func lists() {
        #expect(EvalMetrics.formatMatches("We need:\n- A\n- B", "We need:\n- a\n- b"))
        #expect(!EvalMetrics.formatMatches("We need:\n- A\n- B", "We need a and b"))
    }

    @Test("inline bullets are split onto lines")
    func inlineBullets() {
        #expect(ListFormatter.splitInlineBullets("We need: - Cups - Plates - Ice") == "We need:\n- Cups\n- Plates\n- Ice")
    }

    @Test("the timeout/rejection fallback keeps a multi-line rules draft intact", arguments: [
        "My shopping list:\n- Apples\n- Oranges\n- Milk",
        "My plan is:\n1. Fix the bug\n2. Write tests\n3. Ship it",
        "That covers the intro.\n\nNow the pricing.",
    ])
    func rulesFallbackKeepsLayout(draft: String) {
        #expect(SmartCleaner.rulesFallback(reason: "timeout or model error", draft: draft) == draft)
        #expect(SmartCleaner.rulesFallback(reason: "dropped content words: [\"list\"]", draft: draft) == draft)
    }

    @Test("the fallback still collapses an unambiguous phrase repeat on a single-line draft")
    func rulesFallbackSingleLine() {
        let draft = "It's a it's a three second dictation."
        #expect(!SmartCleaner.rulesFallback(reason: "timeout or model error", draft: draft).contains("it's a it's a"))
    }

    @Test("the founder's inline series is not an enumeration hint without the Oxford comma, and rules keep it a sentence")
    func founderSentenceHints() {
        let cleaner = TextCleaner()
        let plain = "I need four apples, one orange and one Bloody Mary"
        let oxford = "I need four apples, one orange, and one Bloody Mary"
        #expect(cleaner.clean(plain).text == plain + ".")
        #expect(cleaner.clean(oxford).text == oxford + ".")
        // Documents the shipping heuristic: two comma parts never fire, three do.
        #expect(!ModelHints.worthAsking(raw: plain, ruled: cleaner.clean(plain)))
        #expect(ModelHints.worthAsking(raw: oxford, ruled: cleaner.clean(oxford)))
        #expect(!ModelHints.worthAsking(raw: "We need salt and pepper.", ruled: cleaner.clean("We need salt and pepper.")))
    }

    @Test("model hints ignore a leading no")
    func hints() {
        let cleaner = TextCleaner()
        #expect(!ModelHints.worthAsking(raw: "No, I don't think so.", ruled: cleaner.clean("No, I don't think so.")))
        #expect(ModelHints.worthAsking(raw: "Bring tea, no, forget the tea.", ruled: cleaner.clean("Bring tea, no, forget the tea.")))
    }

    @Test("model hints fire on a 3-4 letter fragment the deterministic rule declined to touch")
    func hintsFragment() {
        let cleaner = TextCleaner()
        let raw = "Please cal calculate the total for me."
        #expect(ModelHints.worthAsking(raw: raw, ruled: cleaner.clean(raw)))
    }

    @Test("model hints do not fire on ordinary text with no fragment or repair shape", arguments: [
        "Can you send me the report by Friday?",
        "We work well together on this team.",
        "I went to the store and bought milk.",
    ])
    func hintsPlainTextUnaffected(raw: String) {
        let cleaner = TextCleaner()
        #expect(!ModelHints.worthAsking(raw: raw, ruled: cleaner.clean(raw)))
    }

    @Test("model hints do not fire on a plain short list the deterministic repair rule already declined", arguments: [
        "We need apples, oranges for the salad.",
        "Pick red, green for the design.",
    ])
    func hintsPlainListUnaffected(raw: String) {
        let cleaner = TextCleaner()
        #expect(!ModelHints.worthAsking(raw: raw, ruled: cleaner.clean(raw)))
    }

    @Test("model hints fire on a borderline near-duplicate repair the rule was too cautious to resolve")
    func hintsBorderlineRepair() {
        let cleaner = TextCleaner()
        // "cost, coast" shares only a 2-character prefix ("co") — below isCloseRepairPair's
        // confident 4-character bar, so SelfRepair.apply leaves it untouched, but it's still a
        // plausible enough near-miss that mightHaveUnresolvedRepair flags it for the model.
        let raw = "We need to check the cost, coast property before Friday."
        #expect(ModelHints.worthAsking(raw: raw, ruled: cleaner.clean(raw)))
    }
}

@Suite("Writing styles")
struct StyleTests {
    let message = "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."

    @Test("personal message styles")
    func personal() {
        #expect(StyleFormatter.apply(.formal, to: message, in: .personalMessages) == message)
        #expect(StyleFormatter.apply(.casual, to: message, in: .personalMessages)
            == "Hey are you free for lunch tomorrow? Let's do 12 if that works for you")
        #expect(StyleFormatter.apply(.veryCasual, to: message, in: .personalMessages)
            == "hey are you free for lunch tomorrow? let's do 12 if that works for you")
    }

    @Test("excited ends with an exclamation")
    func excited() {
        #expect(StyleFormatter.apply(.excited, to: "Let's chat about the great results", in: .workMessages)
            == "Let's chat about the great results!")
    }

    @Test("formal email lays out greeting and sign-off")
    func email() {
        let spoken = "Hi Alex, it was great talking with you today. Looking forward to our next chat. Best, Mary"
        #expect(StyleFormatter.apply(.formal, to: spoken, in: .email)
            == "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary")
        #expect(StyleFormatter.apply(.casual, to: spoken, in: .email)
            == "Hi Alex, it was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary")
    }

    @Test("words are never changed and lists are untouched")
    func wordsPreserved() {
        let list = "We need:\n- Milk\n- Eggs"
        #expect(StyleFormatter.apply(.veryCasual, to: list, in: .personalMessages) == list)
        for style in WritingStyle.allCases {
            let styled = StyleFormatter.apply(style, to: message, in: .personalMessages)
            #expect(EvalMetrics.normalizedWords(styled) == EvalMetrics.normalizedWords(message))
        }
    }

    @Test("code editors are never styled")
    func code() {
        #expect(StyleContext.from(.code) == nil)
    }
}

@Suite("App integration")
struct AppIntegrationTests {
    @Test("every app shown on the Style page gets that page's style", arguments: StyleContext.allCases)
    func representativeAppsMatch(context: StyleContext) {
        for bundleID in context.representativeApps {
            #expect(StyleContext.from(AppCategory.classify(bundleID: bundleID)) == context, "\(bundleID)")
        }
    }

    @Test("web apps in browsers are recognised by window title", arguments: [
        ("Inbox (3) - you@gmail.com - Gmail", StyleContext.email),
        ("general - Acme - Slack", .workMessages),
        ("WhatsApp", .personalMessages),
        ("Q4 plan - Google Docs", .other),
    ])
    func webApps(title: String, expected: StyleContext) {
        #expect(StyleContext.from(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: title)) == expected)
    }

    @Test("GitHub in a browser is a work message, never code (see BrowserProseTests)")
    func githubIsWorkMessage() {
        #expect(StyleContext.from(AppCategory.classify(bundleID: "com.apple.Safari", windowTitle: "Pull request #12 · GitHub")) == .workMessages)
    }

    @Test("window titles are ignored outside browsers")
    func nonBrowser() {
        #expect(AppCategory.classify(bundleID: "com.apple.Notes", windowTitle: "Gmail ideas") == .documents)
    }
}
