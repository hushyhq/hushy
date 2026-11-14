import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: held dictations and the edit verdict", .timeLimit(.minutes(1)))
struct PendingDictationMetricsTests {
    typealias F = UsageMetricsFixtures

    private func input() -> DictationMetricInput {
        DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 12,
            audioSeconds: 4, speechMilliseconds: 300, cleanupMilliseconds: 600, releaseToDeliveryMilliseconds: 900)
    }

    private var pending: PendingDictationMetrics { PendingDictationMetrics(calendar: F.utc) }

    @Test("a kept verdict is recorded as kept, once")
    func kept() throws {
        var held = pending
        let id = held.hold(input(), at: F.noonOct3)
        let maybeReleased = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3.addingTimeInterval(8))
        let released = try #require(maybeReleased)
        #expect(released.event.feedback.editObservation == .kept)
        #expect(released.event.feedback.editCoverage == .observed)
        let repeated = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3.addingTimeInterval(9))
        #expect(repeated == nil)
        #expect(held.count == 0)
    }

    @Test("an edited verdict is recorded as edited")
    func edited() throws {
        var held = pending
        let id = held.hold(input(), at: F.noonOct3)
        let maybeReleased = held.resolve(id, observation: .edited, coverage: .observed, at: F.noonOct3.addingTimeInterval(8))
        let released = try #require(maybeReleased)
        #expect(released.event.feedback.editObservation == .edited)
    }

    @Test("a watcher that could not look reports unknown with its reason")
    func unobservable() throws {
        var held = pending
        let id = held.hold(input(), at: F.noonOct3)
        let maybeReleased = held.resolve(id, observation: .unknown, coverage: .secure, at: F.noonOct3.addingTimeInterval(8))
        let released = try #require(maybeReleased)
        #expect(released.event.feedback.editObservation == .unknown)
        #expect(released.event.feedback.editCoverage == .secure)
    }

    @Test("a watcher that never reports is released as not checked once its window has closed, and not before")
    func neverReports() throws {
        var held = pending
        _ = held.hold(input(), at: F.noonOct3)
        let early = held.expire(at: F.noonOct3.addingTimeInterval(PendingDictationMetrics.window - 1))
        #expect(early.isEmpty)
        let released = held.expire(at: F.noonOct3.addingTimeInterval(PendingDictationMetrics.window))
        #expect(released.count == 1)
        #expect(released.first?.event.feedback.editObservation == .unknown)
        #expect(released.first?.event.feedback.editCoverage == .notAttempted)
        let again = held.expire(at: F.noonOct3.addingTimeInterval(1_000))
        #expect(again.isEmpty)       // never twice
    }

    @Test("a report that arrives after the window closed changes nothing")
    func lateReport() throws {
        var held = pending
        let id = held.hold(input(), at: F.noonOct3)
        _ = held.expire(at: F.noonOct3.addingTimeInterval(60))
        let late = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3.addingTimeInterval(61))
        #expect(late == nil)
    }

    @Test("quitting releases everything held as not checked, once")
    func quit() {
        var held = pending
        _ = held.hold(input(), at: F.noonOct3)
        _ = held.hold(input(), at: F.noonOct3)
        let released = held.drain()
        #expect(released.count == 2)
        #expect(released.allSatisfy { $0.event.feedback.editCoverage == .notAttempted })
        let second = held.drain()
        #expect(second.isEmpty)
    }

    @Test("a verdict that arrives on a later calendar day is recorded as not checked, on the day of the dictation")
    func dayBoundary() throws {
        var held = pending
        let late = try #require(F.utc.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 59, second: 55)))
        let id = held.hold(input(), at: late)
        let maybeReleased = held.resolve(id, observation: .kept, coverage: .observed, at: late.addingTimeInterval(10))
        let released = try #require(maybeReleased)
        #expect(released.event.feedback.editObservation == .unknown)
        #expect(released.event.feedback.editCoverage == .notAttempted)
        #expect(released.heldAt == late)
    }

    @Test("discarding forgets everything without recording it")
    func discard() {
        var held = pending
        _ = held.hold(input(), at: F.noonOct3)
        held.discardAll()
        let none = held.drain()
        #expect(none.isEmpty)
    }

    @Test("kept and edited reach the batch as the numbers that matter")
    func reachesTheBatch() throws {
        var held = pending
        var records: [MetricEventRecord] = []
        for verdict in [DictationFeedback.EditObservation.kept, .kept, .kept, .edited] {
            let id = held.hold(input(), at: F.noonOct3)
            let maybeReleased = held.resolve(id, observation: verdict, coverage: .observed, at: F.noonOct3.addingTimeInterval(8))
        let released = try #require(maybeReleased)
            records.append(F.record(.dictation(released.event)))
        }
        let batch = try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct5).closedBatches.first)
        let lines = MetricsDisclosure.lines(for: batch)
        #expect(lines.contains("Kept without edits: 3 of 4 checked"))
        #expect(lines.contains("Edited after pasting: 1 of 4 checked"))
    }
}

@Suite("Usage metrics: delivery outcomes and model state", .timeLimit(.minutes(1)))
struct DeliveryOutcomeMetricsTests {
    private func event(_ result: DictationMetricInput.Result, release: Int? = 900) throws -> DictationMetricEvent {
        try DictationMetricInput(
            result: result, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 5,
            audioSeconds: 2, speechMilliseconds: 100, cleanupMilliseconds: 200, releaseToDeliveryMilliseconds: release).event()
    }

    @Test("every outcome the app has maps to its own delivery value")
    func outcomes() throws {
        #expect(try event(.pasted).feedback.delivery == .succeeded)
        #expect(try event(.copied).feedback.delivery == .copied)
        #expect(try event(.heldSecure).feedback.delivery == .heldSecure)
        #expect(try event(.noField).feedback.delivery == .noField)
        #expect(try event(.failed).feedback.delivery == .failed)
        #expect(try event(.cancelled).feedback.delivery == .cancelled)
        for result in [DictationMetricInput.Result.copied, .heldSecure, .noField, .failed, .cancelled] {
            #expect(try event(result).releaseToDeliveryMilliseconds == nil)
        }
    }

    @Test("each delivery result the app has maps to an honest outcome")
    func deliveryMapping() {
        typealias R = DictationMetricInput.Result
        #expect(R(.pasted) == .pasted && R(.pastedReturnSkipped(nil)) == .pasted && R(.returnSent) == .pasted)
        #expect(R(.copied(.app)) == .copied)
        #expect(R(.noField(copied: true)) == .copied && R(.noField(copied: false)) == .noField)
        #expect(R(.dispatchFailed(copied: true)) == .copied && R(.dispatchFailed(copied: false)) == .failed)
        #expect(R(.heldForSecureField(nil)) == .heldSecure)
        #expect(R(.cancelled) == .cancelled)
        #expect(R(.returnWithheld(nil)) == .failed)
    }

    @Test("a copied dictation is not counted as a failure in the batch or the disclosure")
    func copiedIsNotFailed() throws {
        let records = [try event(.pasted), try event(.copied), try event(.heldSecure), try event(.noField), try event(.failed)]
            .map { UsageMetricsFixtures.record(.dictation($0)) }
        let batch = try #require(UsageMetricsFixtures.builder()
            .close(records: records, environment: UsageMetricsFixtures.environment, now: UsageMetricsFixtures.noonOct5).closedBatches.first)
        let totals = batch.combinedDictations.delivery
        #expect(totals[.succeeded] == 1 && totals[.copied] == 1 && totals[.heldSecure] == 1 && totals[.noField] == 1 && totals[.failed] == 1)
        let line = try #require(MetricsDisclosure.lines(for: batch).first { $0.hasPrefix("Outcome:") })
        #expect(line.contains("copied instead of pasted 1") && line.contains("held back (password field) 1") && line.contains("failed 1"))
    }

    @Test("warm means a model call already answered recently enough; cold means it did not; no model call means nil")
    func modelState() {
        let now = UsageMetricsFixtures.noonOct3
        let recent = now.addingTimeInterval(-30)
        let old = now.addingTimeInterval(-500)
        #expect(MetricsModelState.infer(outcome: .used, answeredAt: [], callStartedAt: now, idleUnloadSeconds: nil) == .cold)
        #expect(MetricsModelState.infer(outcome: .used, answeredAt: [recent], callStartedAt: now, idleUnloadSeconds: nil) == .warm)
        #expect(MetricsModelState.infer(outcome: .used, answeredAt: [old], callStartedAt: now, idleUnloadSeconds: 120) == .cold)
        #expect(MetricsModelState.infer(outcome: .used, answeredAt: [old], callStartedAt: now, idleUnloadSeconds: nil) == .warm)
        #expect(MetricsModelState.infer(outcome: .used, answeredAt: [now.addingTimeInterval(5)], callStartedAt: now, idleUnloadSeconds: nil) == .cold)
        for outcome in [ModelOutcome.notAsked, .unavailable, .skippedSlow, .breakerOpen, .thermalSerious, .notResponding] {
            #expect(MetricsModelState.infer(outcome: outcome, answeredAt: [recent], callStartedAt: now, idleUnloadSeconds: nil) == nil)
        }
        #expect(MetricsModelState.infer(outcome: nil, answeredAt: [recent], callStartedAt: now, idleUnloadSeconds: nil) == nil)
    }

    @Test("the model state reaches the event")
    func modelStateInEvent() throws {
        let input = DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 1,
            audioSeconds: 1, speechMilliseconds: 1, cleanupMilliseconds: 1, releaseToDeliveryMilliseconds: 1, modelState: .cold)
        #expect(try input.event().modelState == .cold)
    }
}

@Suite("Usage metrics: held dictations across midnight and what they hold", .timeLimit(.minutes(1)))
struct PendingMidnightTests {
    typealias F = UsageMetricsFixtures

    private func input(mode: Mode? = nil) -> DictationMetricInput {
        DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: mode, wordCount: 12,
            audioSeconds: 4, speechMilliseconds: 300, cleanupMilliseconds: 600, releaseToDeliveryMilliseconds: 900)
    }

    @Test("a dictation held across midnight is written to its own day, as not checked, before that day closes")
    func midnightDrainKeepsTheDay() async throws {
        let directory = try F.tempDirectory()
        let gate = MetricsSwitch(isOn: true)
        let svc = UsageMetricsService(
            directory: directory, appBuild: 412, firstRunDay: nil, environment: F.environment,
            timeZone: { F.utc.timeZone }, gate: gate)
        var held = PendingDictationMetrics(calendar: F.utc)
        let justBeforeMidnight = F.noonOct3.addingTimeInterval(12 * 3_600 - 10)   // 23:59:50 on Oct 3
        _ = held.hold(input(), at: justBeforeMidnight)
        let afterMidnight = justBeforeMidnight.addingTimeInterval(40)               // 00:00:30 on Oct 4
        // The daily job drains earlier days first, then closes.
        for released in held.drainBefore(afterMidnight) { await svc.record(.dictation(released.event), at: released.heldAt) }
        #expect(held.count == 0)
        #expect(await svc.closeDays(now: afterMidnight) == 1)
        let batches = try await svc.queue.nextBatchesToSend(limit: 5, now: afterMidnight)
        let batch = try #require(batches.first)
        #expect(batch.day.isoString == "2026-10-03")
        #expect(batch.combinedDictations.editObservation[.unknown] == 1)            // not checked
        // Nothing leaked onto the next day.
        #expect(await svc.closeDays(now: F.noonOct5) == 0)
    }

    @Test("a dictation from today is not drained, and one resolved after midnight is not checked")
    func drainLeavesTodayAlone() throws {
        var held = PendingDictationMetrics(calendar: F.utc)
        let id = held.hold(input(), at: F.noonOct3)
        #expect(held.drainBefore(F.noonOct3.addingTimeInterval(60)).isEmpty)
        #expect(held.count == 1)
        let released = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct4)
        #expect(released?.event.feedback.editObservation == .unknown)
    }

    @Test("the day is taken when the dictation is held: a time-zone change while it waits cannot move it")
    func timeZoneChangeWhileHeld() async throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        let heldAt = try #require(newYork.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 30)))
        var held = PendingDictationMetrics(calendar: newYork)         // 23:30 on Oct 3 there; Oct 4 in UTC
        let id = held.hold(input(), at: heldAt, epoch: 0)
        let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt        // the Mac travels while the dictation waits
        let maybeReleased = held.resolve(id, observation: .kept, coverage: .observed, at: heldAt.addingTimeInterval(8))
        let released = try #require(maybeReleased)
        #expect(released.day.isoString == "2026-10-03")
        let gate = MetricsSwitch(isOn: true)
        let svc = UsageMetricsService(
            directory: try F.tempDirectory(), appBuild: 412, firstRunDay: nil, environment: F.environment,
            timeZone: { tokyo }, gate: gate)
        await svc.record(.dictation(released.event), onDay: released.day, epoch: released.epoch)
        #expect(await svc.closeDays(now: heldAt.addingTimeInterval(3 * 86_400)) == 1)
        let batch = try #require(try await svc.queue.nextBatchesToSend(limit: 5, now: heldAt).first)
        #expect(batch.day.isoString == "2026-10-03")                    // not Oct 4, which is Tokyo's day then
    }

    @Test("the clock set back while a dictation is held: it keeps its own day and is recorded as not checked")
    func clockSetBackWhileHeld() async throws {
        var held = PendingDictationMetrics(calendar: F.utc)
        let id = held.hold(input(), at: F.noonOct4, epoch: 0)
        let maybeReleased = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3)
        let released = try #require(maybeReleased)   // an earlier day now
        #expect(released.day.isoString == "2026-10-04")
        #expect(released.event.feedback.editObservation == .unknown)
        let svc = UsageMetricsService(
            directory: try F.tempDirectory(), appBuild: 412, firstRunDay: nil, environment: F.environment,
            timeZone: { F.utc.timeZone }, gate: MetricsSwitch(isOn: true))
        await svc.record(.dictation(released.event), onDay: released.day, epoch: 0)
        #expect(await svc.closeDays(now: F.noonOct5) == 1)
        let batch = try #require(try await svc.queue.nextBatchesToSend(limit: 5, now: F.noonOct5).first)
        #expect(batch.day.isoString == "2026-10-04")
    }

    @Test("what is held can only be closed-vocabulary values: no mode, no text, no bundle ID, no URL")
    func pendingHoldsNoMode() throws {
        let custom = Mode(
            name: "Secret client mode", icon: "star", cleanupLevel: .clean, prompt: "Use bundle com.example.Private",
            appBundleIDs: ["com.example.Private"])
        var held = PendingDictationMetrics(calendar: F.utc)
        _ = held.hold(input(mode: custom), at: F.noonOct3)
        #expect(held.count == 1)
        let forbidden: Set<String> = ["String", "Data", "URL", "Any", "Mode", "DictationMetricInput", "ModeAutoApply"]
        func scan(_ value: Any, path: String) -> [String] {
            let typeName = String(describing: type(of: value))
            var found = typeName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { forbidden.contains($0) }.map { _ in "\(path): \(typeName)" }
            for child in Mirror(reflecting: value).children { found += scan(child.value, path: "\(path).\(child.label ?? "_")") }
            return found
        }
        let entries = try #require(Mirror(reflecting: held).children.first { $0.label == "entries" }?.value)
        #expect(scan(entries, path: "entries").count == 0, "\(scan(entries, path: "entries"))")
        #expect(String(describing: type(of: entries)).contains("Entry"))
        // The scanner must be able to see a violation.
        struct Leaky { let mode: Mode? }
        #expect(!scan(Leaky(mode: custom), path: "leaky").isEmpty)
        // And the customised mode's words appear nowhere in what is held.
        #expect(!String(describing: entries).contains("Secret client mode") && !String(describing: entries).contains("com.example"))
    }
}
