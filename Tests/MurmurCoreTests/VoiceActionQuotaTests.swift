import Foundation
import Testing
@testable import MurmurCore

/// The Free plan's 100-voice-actions-a-month rule (`VoiceActionQuota`) and the store count
/// behind it (`VoiceActionUse`, migration v15).
@Suite("VoiceActionQuota")
struct VoiceActionQuotaTests {
    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test("the 100th action may run, the 101st may not")
    func hundredth() {
        #expect(VoiceActionQuota.freeMonthlyLimit == 100)
        #expect(VoiceActionQuota.canUse(usedThisMonth: 99))
        #expect(!VoiceActionQuota.canUse(usedThisMonth: 100))
        let now = Date()
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: 99).remaining == 1)
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: 100).isExhausted)
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: 140).remaining == 0, "never negative")
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: -3).used == 0)
    }

    @Test("the heads-up starts at 10 left and ends when exhausted")
    func headsUp() {
        let now = Date()
        #expect(!VoiceActionQuota.status(now: now, usedThisMonth: 89).isNearLimit)
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: 90).isNearLimit)
        #expect(VoiceActionQuota.status(now: now, usedThisMonth: 90).remaining == 10)
        let full = VoiceActionQuota.status(now: now, usedThisMonth: 100)
        #expect(full.isExhausted && !full.isNearLimit)
    }

    @Test("the allowance resets on the first of the next local month")
    func resets() {
        let status = VoiceActionQuota.status(now: date("2026-09-28T20:00:00Z"), calendar: utc(), usedThisMonth: 100)
        #expect(status.resetsOn == date("2026-10-01T00:00:00Z"))
        #expect(status.month.start == date("2026-09-01T00:00:00Z"))
    }

    @Test("the store counts this month's uses, minus the ones Undo gave back")
    func storeCount() throws {
        let store = try Store()
        let now = date("2026-09-28T20:00:00Z")
        try store.recordVoiceActionUse(VoiceActionUse(usedAt: date("2026-09-01T00:00:00Z"), kind: .action, actionRecordID: 7))
        try store.recordVoiceActionUse(VoiceActionUse(usedAt: date("2026-09-15T00:00:00Z"), kind: .ask))
        try store.recordVoiceActionUse(VoiceActionUse(usedAt: date("2026-09-20T00:00:00Z"), kind: .summary))
        try store.recordVoiceActionUse(VoiceActionUse(usedAt: date("2026-08-31T23:59:59Z"), kind: .action))
        try store.recordVoiceActionUse(VoiceActionUse(usedAt: date("2026-10-01T00:00:00Z"), kind: .action))
        #expect(try store.voiceActionsThisMonth(now: now, calendar: utc()) == 3)

        try store.markVoiceActionUseUndone(actionRecordID: 7)
        #expect(try store.voiceActionsThisMonth(now: now, calendar: utc()) == 2, "an undone action gives its use back")
        try store.markVoiceActionUseUndone(actionRecordID: 999)
        #expect(try store.voiceActionsThisMonth(now: now, calendar: utc()) == 2, "unknown records change nothing")
        #expect(try store.voiceActionsThisMonth(now: date("2026-11-05T00:00:00Z"), calendar: utc()) == 0)
    }
}
