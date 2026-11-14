import Testing
@testable import Murmur

@Suite("Rival dictation apps on the dictation key")
struct RivalDictationAppsTests {
    private let wispr = "com.electron.wispr-flow"
    private let granola = "com.granola.app"
    private let superwhisper = "com.superduper.superwhisper"

    @Test("the table lists all eight apps, each with a sourced bundle id and key")
    func tableIsComplete() {
        let ids = RivalDictationApps.table.map(\.id)
        #expect(Set(ids) == ["wispr-flow", "granola", "superwhisper", "macwhisper", "aqua-voice", "hush", "speakoflow", "eloquent"])
        #expect(Set(ids).count == ids.count)
        let bundleIDs = RivalDictationApps.table.flatMap(\.bundleIDs)
        #expect(Set(bundleIDs).count == bundleIDs.count)
        for app in RivalDictationApps.table {
            #expect(!app.bundleIDs.isEmpty)
            #expect(app.keySource.hasPrefix("https://"))
            #expect(!app.bundleIDSource.isEmpty)
        }
    }

    @Test("a running Wispr Flow or Granola collides with fn")
    func fnCollides() {
        #expect(RivalDictationApps.collisions(running: [wispr], trigger: .fn).map(\.id) == ["wispr-flow"])
        #expect(RivalDictationApps.collisions(running: [wispr, granola], trigger: .fn).map(\.id) == ["wispr-flow", "granola"])
    }

    @Test("nothing collides when the rival is not running or the key is not its key")
    func quietCases() {
        #expect(RivalDictationApps.collisions(running: [], trigger: .fn).isEmpty)
        #expect(RivalDictationApps.collisions(running: ["com.apple.finder"], trigger: .fn).isEmpty)
        #expect(RivalDictationApps.collisions(running: [wispr, granola], trigger: .rightOption).isEmpty)
        #expect(RivalDictationApps.collisions(running: [superwhisper], trigger: .fn).isEmpty)
    }

    @Test("Superwhisper collides with Right Command only")
    func superwhisperKey() {
        #expect(RivalDictationApps.collisions(running: [superwhisper], trigger: .rightCommand).map(\.id) == ["superwhisper"])
        #expect(RivalDictationApps.collisions(running: [superwhisper], trigger: .controlOption).isEmpty)
    }

    @Test("apps with no published default key never collide")
    func unpublishedDefaults() {
        let running: Set<String> = ["com.goodsnooze.MacWhisper", "com.google.AIEdgeEloquent"]
        for key in TriggerKey.allCases {
            #expect(RivalDictationApps.collisions(running: running, trigger: key).isEmpty)
        }
    }

    @Test("the suggested key is no rival's default and not the current key")
    func suggestion() {
        for current in TriggerKey.allCases {
            let next = RivalDictationApps.suggestedKey(replacing: current, running: [wispr, granola, superwhisper])
            #expect(next != nil)
            #expect(next != current)
            #expect(!RivalDictationApps.claimedKeys.contains(next!))
        }
        #expect(RivalDictationApps.suggestedKey(replacing: .fn, running: [wispr]) == .rightOption)
    }

    @Test("an offer names the running rivals and the key to move to")
    func offerShape() {
        let offer = RivalDictationApps.offer(running: [wispr, "com.apple.finder"], trigger: .fn, dismissed: [])
        #expect(offer?.rivals.map(\.id) == ["wispr-flow"])
        #expect(offer?.current == .fn)
        #expect(offer?.suggested == .rightOption)
    }

    @Test("a rival the person chose to live with is not offered again, a new one is")
    func dismissals() {
        #expect(RivalDictationApps.offer(running: [wispr], trigger: .fn, dismissed: ["wispr-flow"]) == nil)
        let offer = RivalDictationApps.offer(running: [wispr, granola], trigger: .fn, dismissed: ["wispr-flow"])
        #expect(offer?.rivals.map(\.id) == ["granola"])
    }

    @Test("no offer once Hushy is already on another key")
    func movedAway() {
        #expect(RivalDictationApps.offer(running: [wispr, granola], trigger: .rightOption, dismissed: []) == nil)
    }
}
