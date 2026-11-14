import Foundation
import Testing
@testable import MurmurCore

/// The ruling: one clear name match acts (show it, or open it when the person said open); nothing
/// else does. A list, a text-only match, nothing found and failures never touch Finder.
@Suite("FileEffect")
struct FileEffectTests {
    typealias F = FileFixtures
    private let file = F.file("Documents/Resume.pdf", F.now, kinds: F.pdf)

    @Test("one clear name match shows it in Finder")
    func revealsOne() {
        #expect(FileEffect.forOutcome(.foundOne(file, matchedBy: .name), action: .reveal) == .reveal(path: file.path, instead: false))
    }

    @Test("one clear name match opens only when the person said open")
    func opensWhenAsked() {
        #expect(FileEffect.forOutcome(.foundOne(file, matchedBy: .name), action: .open) == .open(path: file.path))
    }

    @Test("a file that runs when opened is shown, never opened")
    func programsAreShown() {
        let script = F.file("Documents/resume-builder.command", F.now)
        #expect(FileEffect.forOutcome(.foundOne(script, matchedBy: .name), action: .open) == .reveal(path: script.path, instead: true))
        #expect(FileEffect.forChoice(path: script.path, open: true) == .reveal(path: script.path, instead: true))
    }

    @Test("several matches never act, whatever was asked", arguments: [FileAction.reveal, .open])
    func severalNeverAct(action: FileAction) {
        let other = F.file("Downloads/Resume.pdf", F.now, kinds: F.pdf)
        #expect(FileEffect.forOutcome(.foundSeveral([file, other], matchedBy: .name), action: action) == .none)
    }

    @Test("a text-only match never acts, one or several", arguments: [FileAction.reveal, .open])
    func contentOnlyNeverActs(action: FileAction) {
        #expect(FileEffect.forOutcome(.foundOne(file, matchedBy: .content), action: action) == .none)
        #expect(FileEffect.forOutcome(.foundSeveral([file], matchedBy: .content), action: action) == .none)
    }

    @Test("nothing found, unavailable and cancelled never act", arguments: [FileAction.reveal, .open])
    func failuresNeverAct(action: FileAction) {
        for outcome in [FileFindOutcome.none, .unavailable(.slow), .unavailable(.indexOff), .cancelled] {
            #expect(FileEffect.forOutcome(outcome, action: action) == .none)
        }
    }

    @Test("through the engine: a content-only single match and a list produce no effect")
    func throughTheEngine() async {
        let notes = F.file("Documents/Notes on onboarding.docx", F.date(2026, 6, 2), kinds: F.docx)
        let contentOnly = InMemoryFileFinder(files: [notes], contents: [notes.path: "Kafka consumer groups"])
        let single = await F.engine(contentOnly).find(F.request(["kafka"], action: .open))
        #expect(FileEffect.forOutcome(single, action: .open) == .none)
        let invoices = InMemoryFileFinder(files: [
            F.file("Documents/Invoice acme.pdf", F.date(2026, 3, 2), kinds: F.pdf),
            F.file("Documents/Invoice dana.pdf", F.date(2026, 4, 2), kinds: F.pdf),
        ])
        let several = await F.engine(invoices).find(F.request(["invoice"], action: .open))
        #expect(FileEffect.forOutcome(several, action: .open) == .none)
    }
}
