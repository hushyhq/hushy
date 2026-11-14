import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The review round for Task 114: completed-but-unrecorded actions, saved failure reasons, the
/// spoken words in failed rows, overlapping actions, a cancelled follow-up, where an action
/// landed, and an Undo whose record cannot be updated. Fake backends and an in-memory store only.
private struct SaveFailure: Error {}

extension VoiceActionOutcomeTests {
    private func assistant(for rig: Rig, chat: Bool = true) throws -> AssistantModel {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "hushy-test-\(UUID().uuidString)")!)
        let model = AssistantModel(
            settings: settings, store: rig.store,
            workspaceBase: FileManager.default.temporaryDirectory.appendingPathComponent("t114-\(UUID().uuidString)"))
        let controller = rig.controller
        model.actionHandlers = AssistantActionHandlers(
            isEntitled: { controller.isEntitled() },
            execute: { await controller.executeConfirmed($0) },
            undo: { await controller.performUndo(recordID: $0) })
        if chat { model.currentChatID = try rig.store.createAssistantChat(AssistantChat(title: "t")).id }
        return model
    }

    private func reply(with actions: [ProposedAction], in model: AssistantModel) -> AssistantModel.Message {
        let message = AssistantModel.Message(
            role: .assistant, text: "Here you go", actions: actions.map { ChatActionEntry(action: $0) })
        model.replaceMessages([message])
        return message
    }

    private func settled(_ model: AssistantModel, _ id: UUID) async -> ChatActionEntry? {
        for _ in 0..<400 {
            if let entry = model.messages.first?.actions.first(where: { $0.id == id }),
               entry.status != .pending, !model.executingActions.contains(id) { return entry }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model.messages.first?.actions.first(where: { $0.id == id })
    }

    // MARK: A run whose History note could not be saved

    @Test("a Shortcut that ran but whose History record failed to save is completed, never retryable, and ran once")
    func historySaveFailureThenRetry() async throws {
        let rig = try Rig()
        rig.controller.saveRecord = { _ in throw SaveFailure() }
        let model = try assistant(for: rig)
        let action = shortcut()
        let message = reply(with: [action], in: model)

        model.confirmAction(action.id, in: message.id)
        let entry = try #require(await settled(model, action.id))
        #expect(entry.status == .added)
        #expect(entry.recordID == nil)
        #expect(!model.canUndo(entry), "nothing to undo with no record")
        #expect(model.actionNotes[action.id] == ActionWording.notRecorded)
        #expect(await rig.shortcuts.attempts == 1)

        // A second Add, the old Retry path, goes nowhere.
        model.confirmAction(action.id, in: message.id)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await rig.shortcuts.attempts == 1)
        #expect(await rig.shortcuts.runs.count == 1)
    }

    @Test("the controller reports an unrecorded run as one that ran, not as a plain failure")
    func unrecordedRunIsMarked() async throws {
        let rig = try Rig()
        rig.controller.saveRecord = { _ in throw SaveFailure() }
        let result = await rig.controller.executeConfirmed(reminder())
        guard case .failure(let failure) = result else { Issue.record("expected the unrecorded outcome"); return }
        #expect(failure.didRun)
        #expect(failure.kind != .failed)
        #expect(await rig.calendar.createdReminders.count == 1)
    }

    // MARK: Nothing the person said is saved with a chat

    @Test("a failure that names a Shortcut is shown this session but never saved with the chat")
    func failureReasonNotPersisted() async throws {
        let rig = try Rig(installed: ["Start Focus"])
        let model = try assistant(for: rig)
        let secret = shortcut("Alice Payroll Run")
        let message = reply(with: [secret], in: model)
        model.persistForTest(message)

        model.confirmAction(secret.id, in: message.id)
        let entry = try #require(await settled(model, secret.id))
        #expect(entry.failure == nil)
        let shown = model.actionNotes[secret.id] ?? ""
        #expect(shown.contains("Alice Payroll Run"), "the person sees which Shortcut was missing")

        let chatID = try #require(model.currentChatID)
        let saved = try rig.store.assistantMessages(chatId: chatID)
        let json = saved.compactMap(\.actionsJSON).joined()
        // The action's own title is saved with the card, as before; the reason is not.
        #expect(!json.contains("Couldn't find") && !json.contains("\"failure\""), "the saved chat holds only the fixed status")
        #expect(saved.flatMap(\.actions).allSatisfy { $0.failure == nil })

        // Restored from the saved chat: the fixed line, never the name.
        model.actionNotes = [:]
        let restored = try #require(saved.first?.actions.first)
        let row = model.confirmationRow(for: restored)
        #expect(!(row.status.problemLine ?? "").contains("Alice"))
        #expect(row.status.problemLine == "Couldn't do that")
    }

    @Test("a restored uncertain chat row shows the fixed line, offers no Retry, and never runs")
    func restoredUncertainRow() async throws {
        let rig = try Rig()
        let model = try assistant(for: rig)
        let action = shortcut()
        let stored = AssistantMessage(
            chatId: try #require(model.currentChatID), role: .assistant, text: "ok",
            actions: [ChatActionEntry(action: action, status: .uncertain)])
        let saved = try rig.store.appendAssistantMessage(stored)
        let restored = try #require(try rig.store.assistantMessages(chatId: saved.chatId).first?.actions.first)
        #expect(restored.status == .uncertain)
        let message = AssistantModel.Message(role: .assistant, text: "ok", actions: [restored])
        model.replaceMessages([message])

        let row = model.confirmationRow(for: restored)
        guard case .uncertain(let line) = row.status else { Issue.record("expected uncertain"); return }
        #expect(line == ActionWording.mayAlreadyHaveRun)
        #expect(!row.status.canRunAgain)
        model.confirmAction(action.id, in: message.id)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await rig.shortcuts.attempts == 0)
        #expect(!model.canUndo(restored))
    }

    // MARK: What History keeps for an attempt that did not complete

    @Test("a failed or uncertain attempt keeps the title and kind but not the words that were spoken")
    func failedKeepsNoSpokenWords() async throws {
        let rig = try Rig()
        let spoken = "remind me to call Dana Whitfield about the Hartley merger before the board meeting"
        var failing = reminder("Call Dana")
        failing.sourceText = spoken
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await rig.controller.dispatch([failing], utterance: spoken)

        var risky = shortcut()
        risky.sourceText = "run send standup and tell Hartley's lawyers"
        await rig.shortcuts.setNextError(.mayHaveRun(.timedOut))
        _ = await rig.controller.executeConfirmed(risky)

        let attempts = rig.records.filter { $0.status != .completed }
        #expect(attempts.count == 2)
        for record in attempts {
            #expect(record.sourceText.isEmpty)
            let stored = [record.title, record.detail ?? "", record.sourceText].joined(separator: " ")
            #expect(!stored.contains("Hartley") && !stored.contains("Whitfield"))
        }

        // A done action keeps what it always kept.
        await rig.controller.dispatch([failing], utterance: spoken)
        await rig.settle { rig.chip != nil }
        #expect(rig.records.contains { $0.status == .completed && $0.sourceText == spoken })
    }

    // MARK: Where a confirmed action landed

    @Test("a confirmed reminder with no list says where it went, on the card and in History")
    func confirmedShowsPlacement() async throws {
        let rig = try Rig(setting: .always)
        await rig.controller.dispatch([reminder("Call Dana"), reminder("Buy milk")], utterance: "two things")
        let card = try #require(rig.card)
        rig.controller.confirm(card.rows[0], in: card)
        await rig.settle { rig.card?.rows.first?.status != .confirming }
        let row = try #require(rig.card?.rows.first)
        #expect(row.placedIn == "Reminders")
        #expect(ActionConfirmationRowView.detail(for: row)?.contains("Reminders") == true)
        #expect(rig.records.first?.detail?.contains("Reminders") == true)
    }

    @Test("one confirmed action ends as the done chip, which names the default and carries Undo")
    func confirmedSingleEndsAsChip() async throws {
        let rig = try Rig(setting: .always)
        await rig.controller.dispatch([event(start: start)], utterance: "add dentist")
        await confirmFirstRow(rig)
        await rig.settle { rig.chip != nil }
        let chip = try #require(rig.chip)
        #expect(chip.detail?.contains("Home") == true)
        #expect(chip.canUndo)
        #expect(rig.records.first?.detail?.contains("Home") == true)
    }

    // MARK: Overlapping work

    @Test("an older action finishing late is recorded but does not replace a newer card")
    func overlappingCompletions() async throws {
        let rig = try Rig()
        await rig.calendar.setCreateDelay(.milliseconds(150))
        let older = Task { await rig.controller.dispatch([reminder("Older")], utterance: "older") }
        try? await Task.sleep(for: .milliseconds(30))

        // The person starts a newer utterance, which lands a card.
        rig.controller.supersedePresentation()
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        let newer = try #require(rig.card)

        await older.value
        #expect(rig.card == newer, "the older action must not cover the newer card")
        #expect(rig.records.contains { $0.title == "Older" && $0.status == .completed }, "it still happened and is recorded")
        #expect(await rig.calendar.createdReminders.count == 1)
    }

    @Test("a cancelled follow-up never dispatches the action it was extracting")
    func cancelDuringFollowUpExtraction() async throws {
        let rig = try Rig()
        rig.controller.extract = { _, _ in
            try? await Task.sleep(for: .milliseconds(120))
            return ActionExtractor.Output(result: .actions([self.reminder("Coffee")]), usedModel: false)
        }
        let card = AnswerCardState(question: "what groceries do i need", phase: .thinking)
        rig.pill.state = .answer(card)
        let task = Task { @MainActor in await rig.controller.followUpDo("add coffee", after: card) }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await task.value
        #expect(await rig.calendar.createdReminders.isEmpty)
        #expect(rig.records.isEmpty)
        #expect(rig.chip == nil && rig.card == nil)
    }

    @Test("a follow-up replaced by a newer utterance while extracting does not dispatch either")
    func supersededFollowUp() async throws {
        let rig = try Rig()
        rig.controller.extract = { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return ActionExtractor.Output(result: .actions([self.reminder("Coffee")]), usedModel: false)
        }
        let card = AnswerCardState(question: "what groceries do i need", phase: .thinking)
        let task = Task { @MainActor in await rig.controller.followUpDo("add coffee", after: card) }
        try? await Task.sleep(for: .milliseconds(30))
        rig.controller.supersedePresentation()
        await task.value
        #expect(await rig.calendar.createdReminders.isEmpty)
    }

    // MARK: An Undo whose record cannot be updated

    @Test("a delete that worked but whose record could not be updated is its own outcome, with the stored token cleared")
    func undoRecordWriteFailure() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        rig.controller.writeUndone = { _ in throw SaveFailure() }
        rig.controller.undoDone()
        await rig.settle { rig.chip?.isUndoing == false }
        let chip = try #require(rig.chip)
        #expect(!chip.undone, "never a plain Undone while the record still says otherwise")
        #expect(chip.undoFailure == ActionWording.undoNotRecorded)
        #expect(!chip.canUndo)
        #expect(await rig.calendar.createdReminders.isEmpty, "the item really is gone")
        let record = try #require(rig.records.first)
        #expect(record.undoBackendID == nil, "History stops offering an Undo with nothing left to remove")
        #expect(record.status == .completed)
    }

    @Test("when even clearing the token fails, the next attempt settles the record without deleting again")
    func undoReconciles() async throws {
        let rig = try Rig()
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let id = try #require(rig.records.first?.id)
        rig.controller.writeUndone = { _ in throw SaveFailure() }
        rig.controller.writeUndoExpired = { _ in throw SaveFailure() }
        #expect(await rig.controller.performUndo(recordID: id) == .removedNotRecorded)
        #expect(try rig.store.actionRecord(id: id)?.undoBackendID != nil)

        rig.controller.writeUndone = nil
        rig.controller.writeUndoExpired = nil
        #expect(await rig.controller.performUndo(recordID: id) == .undone)
        #expect(await rig.calendar.undone.count == 1, "deleted once")
        #expect(try rig.store.actionRecord(id: id)?.status == .undone)
    }
}

extension AssistantModel {
    /// Saves a message into the open chat, as the chat flow does after a reply.
    @MainActor
    fileprivate func persistForTest(_ message: Message) {
        let stored = persist(message)
        updateMessage(message.id) { $0.storedID = stored }
    }
}

// MARK: - Round 3

extension VoiceActionOutcomeTests {
    /// A chat-message write that lands for the first `allowing` calls and fails after, as a
    /// database that goes bad mid-run would.
    @MainActor
    private final class FlakyWriter {
        var calls = 0
        var allowing: Int
        let store: Store
        init(store: Store, allowing: Int) { self.store = store; self.allowing = allowing }

        func write(_ row: AssistantMessage) throws -> Int64? {
            calls += 1
            guard calls <= allowing else { throw SaveFailure() }
            if row.id == nil { return try store.appendAssistantMessage(row).id }
            try store.updateAssistantMessage(row)
            return row.id
        }
    }

    private func assistantModel(_ rig: Rig) throws -> AssistantModel {
        let model = AssistantModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "hushy-test-\(UUID().uuidString)")!), store: rig.store,
            workspaceBase: FileManager.default.temporaryDirectory.appendingPathComponent("t114-\(UUID().uuidString)"))
        let controller = rig.controller
        model.actionHandlers = AssistantActionHandlers(
            isEntitled: { controller.isEntitled() },
            execute: { await controller.executeConfirmed($0) },
            undo: { await controller.performUndo(recordID: $0) })
        model.currentChatID = try rig.store.createAssistantChat(AssistantChat(title: "t")).id
        return model
    }

    private func waitForEntry(_ model: AssistantModel, _ id: UUID) async -> ChatActionEntry? {
        for _ in 0..<400 {
            if let entry = model.messages.first?.actions.first(where: { $0.id == id }),
               entry.status != .pending, !model.executingActions.contains(id) { return entry }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model.messages.first?.actions.first(where: { $0.id == id })
    }

    // MARK: Finding 1: the intent is written before the run

    @Test("when the chat update and the History save both fail, a restart does not offer Add again and the Shortcut ran once")
    func bothSavesFailThenReopen() async throws {
        let rig = try Rig()
        let model = try assistantModel(rig)
        let chatID = try #require(model.currentChatID)
        let writer = FlakyWriter(store: rig.store, allowing: 1) // the start is saved, nothing after it
        model.writeMessage = { try writer.write($0) }
        rig.controller.saveRecord = { _ in throw SaveFailure() }
        let action = shortcut()
        model.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: action)])])
        let messageID = try #require(model.messages.first?.id)

        model.confirmAction(action.id, in: messageID)
        _ = await waitForEntry(model, action.id)
        #expect(await rig.shortcuts.attempts == 1)

        // Reopen from the store, as after a restart.
        let reopened = try assistantModel(rig)
        reopened.openChat(chatID)
        let restored = try #require(reopened.messages.first?.actions.first)
        #expect(restored.status == .uncertain, "the saved start is what a restart sees")
        let row = reopened.confirmationRow(for: restored)
        guard case .uncertain(let line) = row.status else { Issue.record("expected uncertain"); return }
        #expect(line == ActionWording.mayAlreadyHaveRun)
        #expect(!row.status.canRunAgain)
        reopened.confirmAction(action.id, in: try #require(reopened.messages.first?.id))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await rig.shortcuts.attempts == 1, "never run a second time")
    }

    @Test("if the start cannot be saved the action does not run, says so, and works once the chat can be saved")
    func intentWriteFailsNothingRuns() async throws {
        let rig = try Rig()
        let model = try assistantModel(rig)
        let writer = FlakyWriter(store: rig.store, allowing: 0)
        model.writeMessage = { try writer.write($0) }
        let action = shortcut()
        model.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: action)])])
        let messageID = try #require(model.messages.first?.id)

        model.confirmAction(action.id, in: messageID)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await rig.shortcuts.attempts == 0)
        #expect(model.messages.first?.actions.first?.status == .pending)
        #expect(model.actionNotes[action.id] == ActionWording.notStartedChatNotSaved)
        let row = model.confirmationRow(for: try #require(model.messages.first?.actions.first))
        #expect(row.status == .failed(ActionWording.notStartedChatNotSaved))

        writer.allowing = 100
        model.confirmAction(action.id, in: messageID)
        let entry = try #require(await waitForEntry(model, action.id))
        #expect(entry.status == .added)
        #expect(await rig.shortcuts.attempts == 1)
    }

    @Test("an ordinary failure where nothing ran is saved as failed, not uncertain, and can be retried")
    func cleanFailureStaysRetryable() async throws {
        let rig = try Rig()
        let model = try assistantModel(rig)
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        let action = reminder()
        model.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: action)])])
        let messageID = try #require(model.messages.first?.id)
        model.persistForTest(try #require(model.messages.first))

        model.confirmAction(action.id, in: messageID)
        let failed = try #require(await waitForEntry(model, action.id))
        #expect(failed.status == .failed)
        let chatID = try #require(model.currentChatID)
        #expect(try rig.store.assistantMessages(chatId: chatID).first?.actions.first?.status == .failed)

        model.confirmAction(action.id, in: messageID)
        let done = try #require(await waitForEntry(model, action.id))
        #expect(done.status == .added)
        #expect(await rig.calendar.createdReminders.count == 1)
    }

    // MARK: Finding 4: reasons stay in the conversation they were shown in

    @Test("a failure reason is gone after leaving the conversation and reopening it")
    func notesClearedOnLeaving() async throws {
        let rig = try Rig(installed: ["Start Focus"])
        let model = try assistantModel(rig)
        let missing = shortcut("Alice Payroll Run")
        model.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: missing)])])
        let messageID = try #require(model.messages.first?.id)
        model.persistForTest(try #require(model.messages.first))
        let chatID = try #require(model.currentChatID)

        model.confirmAction(missing.id, in: messageID)
        _ = await waitForEntry(model, missing.id)
        #expect((model.actionNotes[missing.id] ?? "").contains("Alice Payroll Run"))

        model.newConversation()
        #expect(model.actionNotes.isEmpty)
        model.openChat(chatID)
        let restored = try #require(model.messages.first?.actions.first)
        let row = model.confirmationRow(for: restored)
        #expect(row.status.problemLine == "Couldn't do that")
    }

    // MARK: Finding 2 and 3: older results never cover a newer card

    @Test("a dictation fallback that finishes late still inserts the text but does not cover a newer card")
    func fallbackDoesNotCoverNewerCard() async throws {
        let rig = try Rig()
        var inserted: [String] = []
        rig.controller.insertFallbackText = { text in
            try? await Task.sleep(for: .milliseconds(100))
            inserted.append(text)
        }
        rig.controller.fallbackToDictation("hello there")
        try? await Task.sleep(for: .milliseconds(20))
        rig.controller.supersedePresentation()
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        let newer = try #require(rig.card)
        await rig.settle { !inserted.isEmpty }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(inserted == ["hello there"], "the text still goes in")
        #expect(rig.card == newer)
    }

    @Test("a dictation fallback that is still the latest shows the Pasted notice")
    func fallbackShowsNoticeWhenCurrent() async throws {
        let rig = try Rig()
        rig.controller.insertFallbackText = { _ in }
        rig.controller.fallbackToDictation("hello there")
        await rig.settle { if case .done = rig.pill.state { true } else { false } }
        guard case .done(let info) = rig.pill.state else { Issue.record("expected the done notice"); return }
        #expect(info.words == 2)
    }

    @Test("voice fallback does not claim a refused paste landed")
    func fallbackFailureFeedback() {
        #expect(VoiceActionsController.fallbackState(for: .pasted, words: 2) == .done(words: 2))
        #expect(VoiceActionsController.fallbackState(for: .focusChanged, words: 2)
                == .error("Couldn't paste here"))
        #expect(VoiceActionsController.fallbackState(for: .dispatchFailed, words: 2)
                == .error("Couldn't paste here"))
    }

    @Test("a transcription error from an older utterance does not cover a newer card, and shows when it is the latest")
    func transcriptionErrorGuarded() async throws {
        let rig = try Rig()
        rig.controller.transcribeSamples = { _ in
            try? await Task.sleep(for: .milliseconds(80))
            throw SaveFailure()
        }
        let older = Task { @MainActor in await rig.controller.process([0.1], followUp: nil) }
        try? await Task.sleep(for: .milliseconds(20))
        rig.controller.supersedePresentation()
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        let newer = try #require(rig.card)
        await older.value
        #expect(rig.card == newer)

        let latest = Task { @MainActor in await rig.controller.process([0.1], followUp: nil) }
        await latest.value
        guard case .error(let line) = rig.pill.state else { Issue.record("expected the error"); return }
        #expect(line == "Couldn't hear that")
    }

    // MARK: Finding 5: the refund is its own write

    @Test("a refund that fails after History was updated still reads Undone, and the use is given back next time")
    func refundFailureKeepsOutcome() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let id = try #require(rig.records.first?.id)
        #expect(try rig.store.voiceActionsThisMonth() == 1)

        rig.controller.refundUse = { _ in throw SaveFailure() }
        #expect(await rig.controller.performUndo(recordID: id) == .undone)
        #expect(try rig.store.actionRecord(id: id)?.status == .undone)
        #expect(try rig.store.voiceActionsThisMonth() == 1, "not given back yet")

        rig.controller.refundUse = nil
        _ = await rig.controller.performUndo(recordID: id) // settles the refund; nothing to delete again
        #expect(try rig.store.voiceActionsThisMonth() == 0)
        #expect(await rig.calendar.undone.count == 1)
    }

    // MARK: Usage numbers (merged from main)

    private final class Box: @unchecked Sendable { var list: [VoiceActionMetricEvent] = [] }

    @Test("every real attempt reports one event; a choice card reports none; a late result still reports")
    func metricMapping() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }

        await rig.controller.dispatch([reminder()], utterance: "x")
        #expect(box.list == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])

        box.list = []
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await rig.controller.dispatch([reminder("Two")], utterance: "x")
        #expect(box.list == [VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)])

        // A Shortcut that may have run is a failure for the numbers, with its own category.
        box.list = []
        await rig.shortcuts.setNextError(.mayHaveRun(.timedOut))
        await rig.controller.dispatch([shortcut()], utterance: "x")
        await confirmFirstRow(rig)
        #expect(box.list == [VoiceActionMetricEvent(outcome: .failed, failure: .timedOut)])

        // Refused for a missing detail at the executor: needs input.
        box.list = []
        _ = await rig.controller.executeConfirmed(event(start: nil))
        #expect(box.list == [VoiceActionMetricEvent(outcome: .failed, failure: .needsInput)])

        // Ran but History could not save it: it happened, so one success.
        box.list = []
        rig.controller.saveRecord = { _ in throw SaveFailure() }
        _ = await rig.controller.executeConfirmed(reminder("Three"))
        #expect(box.list == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])
        rig.controller.saveRecord = nil

        // "Did you mean…" is a question, not a failure.
        box.list = []
        await rig.links.setNextError(.closestApps(heard: "slak", apps: ["Slack", "Slate"]))
        let open = ProposedAction(kind: .openLink, title: "Open Slak", appName: "Slak", sourceText: "open slak")
        await rig.controller.dispatch([open], utterance: "open slak")
        #expect(box.list.isEmpty)
        #expect(rig.card != nil)
    }

    @Test("an older action that finishes after a newer card still reports its event")
    func staleResultStillReports() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }
        await rig.calendar.setCreateDelay(.milliseconds(120))
        let older = Task { await rig.controller.dispatch([reminder("Older")], utterance: "older") }
        try? await Task.sleep(for: .milliseconds(30))
        rig.controller.supersedePresentation()
        await rig.controller.dispatch([shortcut()], utterance: "run send standup")
        await older.value
        #expect(box.list == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])
    }

    // MARK: Round 4

    @Test("with no saved chat or no store there is nowhere to write the start, so the action does not run")
    func noSavedChatMeansNoRun() async throws {
        let rig = try Rig()
        let action = shortcut()

        let noChat = try assistantModel(rig)
        noChat.currentChatID = nil
        noChat.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: action)])])
        noChat.confirmAction(action.id, in: try #require(noChat.messages.first?.id))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await rig.shortcuts.attempts == 0)
        #expect(noChat.messages.first?.actions.first?.status == .pending)
        #expect(noChat.actionNotes[action.id] == ActionWording.notStartedChatNotSaved)

        let noStore = AssistantModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "hushy-test-\(UUID().uuidString)")!), store: nil,
            workspaceBase: FileManager.default.temporaryDirectory.appendingPathComponent("t114-\(UUID().uuidString)"))
        let controller = rig.controller
        noStore.actionHandlers = AssistantActionHandlers(
            isEntitled: { true }, execute: { await controller.executeConfirmed($0) },
            undo: { await controller.performUndo(recordID: $0) })
        noStore.currentChatID = 1
        noStore.replaceMessages([AssistantModel.Message(role: .assistant, text: "ok", actions: [ChatActionEntry(action: action)])])
        noStore.confirmAction(action.id, in: try #require(noStore.messages.first?.id))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await rig.shortcuts.attempts == 0)
    }

    private func choiceCard() throws -> ActionConfirmationCardState {
        let open = ProposedAction(kind: .openLink, title: "Open Slak", appName: "Slak", sourceText: "open slak")
        return try #require(VoiceActionsController.choiceCard(
            for: .closestApps(heard: "slak", apps: ["Slack", "Slate"]), action: open))
    }

    @Test("dismissing a Did-you-mean card, whole or one alternative, reports nothing; a real card still reports a cancel")
    func choiceDismissalReportsNothing() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }

        rig.pill.state = .actionConfirm(try choiceCard())
        rig.controller.cancelAll()
        #expect(box.list.isEmpty)

        let card = try choiceCard()
        rig.pill.state = .actionConfirm(card)
        rig.controller.cancel(card.rows[0])
        #expect(box.list.isEmpty)

        await rig.controller.dispatch([shortcut(), reminder()], utterance: "two things")
        rig.controller.cancelAll()
        #expect(box.list.count == 2 && box.list.allSatisfy { $0.outcome == .cancelled })
    }

    @Test("cancelling while an act-first action is already executing reports nothing; its own result reports once")
    func cancelDuringExecutionReportsOnce() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }
        await rig.calendar.setCreateDelay(.milliseconds(120))
        rig.controller.isProcessing = true
        let running = Task { await rig.controller.dispatch([reminder()], utterance: "x") }
        try? await Task.sleep(for: .milliseconds(30))
        rig.controller.cancelProcessing()
        await running.value
        #expect(box.list == [VoiceActionMetricEvent(outcome: .succeeded, failure: nil)])

        // Before anything executes, a cancel is the one event.
        box.list = []
        rig.controller.isProcessing = true
        rig.controller.cancelProcessing()
        #expect(box.list == [VoiceActionMetricEvent(outcome: .cancelled, failure: nil)])
    }

    @Test("a refund lost when the app quit is given back from the store on the next launch")
    func refundReconciledAfterRestart() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let id = try #require(rig.records.first?.id)
        rig.controller.refundUse = { _ in throw SaveFailure() }
        #expect(await rig.controller.performUndo(recordID: id) == .undone)
        #expect(try rig.store.voiceActionsThisMonth() == 1)

        // A new controller on the same store, as after a relaunch: nothing in memory.
        let integrity = SpeechModelIntegrity(
            fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: "hushy-test-\(UUID().uuidString)")
        let relaunched = VoiceActionsController(
            hotkeys: ActionHotkeyMonitor(), pill: PillModel(),
            speech: SpeechEngine(status: SpeechModelStatus(), integrity: integrity),
            modelStatus: SpeechModelStatus(), store: rig.store, calendarBackend: rig.calendar,
            shortcutsBackend: rig.shortcuts, linkBackend: rig.links)
        relaunched.settleRefunds()
        #expect(try rig.store.voiceActionsThisMonth() == 0)
    }

    // MARK: Round 5

    @Test("a row that failed and is then dismissed has reported exactly one event")
    func failedThenDismissedReportsOnce() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }
        await rig.calendar.setNextError(.backendFailed("Calendar is busy"))
        await rig.controller.dispatch([shortcut(), reminder()], utterance: "two things")
        let card = try #require(rig.card)
        rig.controller.confirm(card.rows[1], in: card)
        await rig.settle { rig.card?.rows[1].status != .confirming }
        #expect(box.list == [VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed)])

        let failed = try #require(rig.card?.rows[1])
        rig.controller.cancel(failed)
        #expect(box.list.count == 1, "dismissing a failed row adds nothing")
        // The Shortcut row was still waiting, so Esc on the card is its one cancellation.
        rig.controller.cancelAll()
        #expect(box.list.filter { $0.outcome == .failed }.count == 1)
        #expect(box.list.filter { $0.outcome == .cancelled }.count == 1)
    }

    @Test("a cancel of a newer utterance is its own event while an older action is still executing, and the older result reports once")
    func overlappingCancelAndResult() async throws {
        let rig = try Rig()
        let box = Box()
        rig.controller.onMetric = { box.list.append($0) }
        await rig.calendar.holdCreates()
        let older = Task { await rig.controller.dispatch([reminder("Older")], utterance: "older") }
        while await rig.calendar.heldCount == 0 { await Task.yield() }

        rig.controller.supersedePresentation() // a newer utterance now owns the pill
        rig.controller.isProcessing = true
        rig.controller.cancelProcessing()
        #expect(box.list == [VoiceActionMetricEvent(outcome: .cancelled, failure: nil)], "the newer utterance's own cancel")

        await rig.calendar.release()
        await older.value
        #expect(box.list.count == 2)
        #expect(box.list.last == VoiceActionMetricEvent(outcome: .succeeded, failure: nil))
    }

    @Test("refunds are reconciled from the store once, and again only after a failed attempt")
    func reconcileOnce() async throws {
        let rig = try Rig()
        rig.controller.isEntitled = { false }
        await rig.controller.dispatch([reminder()], utterance: "remind me to call dana")
        let id = try #require(rig.records.first?.id)
        rig.controller.settleRefunds() // the one reconcile for this controller
        try rig.store.markActionUndone(id: id) // an undone mark that lands behind its back
        rig.controller.settleRefunds()
        #expect(try rig.store.voiceActionsThisMonth() == 1, "no second scan")
    }
}
