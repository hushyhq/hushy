import MurmurCore
import Testing
@testable import Murmur

/// Modes are presented as Formats (founder, 2026-10-28): one-off shapes from the pill, never "picks itself per app".
@Suite("Formats presentation")
struct FormatsPresentationTests {
    @Test("the section is called Formats and its line points to the pill, not to apps choosing")
    func naming() {
        #expect(VoiceAndStyleView.Tab.formats.title == "Formats")
        let line = VoiceStyleCopy.formatsLine.lowercased()
        #expect(line.contains("pill"))
        #expect(!line.contains("automatic"))
        #expect(!line.contains("mode"))
    }

    @Test("each built-in format draws its own shape; the person's own shows its instruction")
    func shapes() {
        let builtIns = Mode.builtIns(userName: "Sam")
        let shapes = builtIns.map(FormatShape.init)
        #expect(shapes == [.plain, .email, .message, .note, .bullets])
        let own = Mode(name: "Standup", icon: "person.2", cleanupLevel: .clean, prompt: "  Three lines.  ")
        #expect(FormatShape(own) == .custom("Three lines."))
        let plain = Mode(name: "Plain", icon: "waveform", cleanupLevel: .clean, prompt: "   ")
        #expect(FormatShape(plain) == .plain)
    }

    @Test("every built-in has a one-line shape description")
    func lines() {
        for mode in Mode.builtIns(userName: "") {
            #expect(VoiceStyleCopy.formatLine(FormatShape(mode)) != nil, "\(mode.name)")
        }
    }
}
