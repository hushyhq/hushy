import Foundation
import MurmurCore
import Testing

@testable import Murmur

@Suite("Apple Notes access results")
struct AppleNotesAccessTests {
    @Test("no error means granted")
    func grantedWhenNoError() {
        #expect(AppleNotesAccessResult.from(errorNumber: nil) == .granted)
    }

    @Test("-1743 is the only refusal")
    func notPermitted() {
        #expect(AppleNotesAccessResult.from(errorNumber: -1743) == .notPermitted)
    }

    @Test("Notes not running or not found maps to notesUnavailable", arguments: [-600, -609, -1728, -10810, -10814])
    func notesUnavailable(code: Int) {
        #expect(AppleNotesAccessResult.from(errorNumber: code) == .notesUnavailable)
    }

    @Test("-1712 is a timeout")
    func timedOut() {
        #expect(AppleNotesAccessResult.from(errorNumber: -1712) == .timedOut)
    }

    @Test("anything else keeps its number", arguments: [-128, -50, 1, 0])
    func other(code: Int) {
        #expect(AppleNotesAccessResult.from(errorNumber: code) == .other(code))
    }

    @Test("only a refusal offers System Settings")
    func settingsOnlyForRefusal() {
        let all: [AppleNotesAccessResult] = [.granted, .notPermitted, .notesUnavailable, .timedOut, .other(-128)]
        #expect(all.filter(\.canOpenSettings) == [.notPermitted])
    }

    @Test("only a refusal says blocked")
    func blockedOnlyForRefusal() {
        let others: [AppleNotesAccessResult] = [.granted, .notesUnavailable, .timedOut, .other(-128)]
        for result in others { #expect(!result.message.lowercased().contains("blocked")) }
        #expect(AppleNotesAccessResult.notPermitted.message.lowercased().contains("blocked"))
    }

    @Test("the other message carries the error number")
    func otherShowsCode() {
        #expect(AppleNotesAccessResult.other(-128).message.contains("-128"))
    }

    @Test("the settings link opens the Automation pane")
    func automationURL() {
        #expect(AppleNotesAccessResult.automationSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }
}

/// A scripter that never runs AppleScript: returns what the test says, and records the sources.
@MainActor
final class FakeAppleNotesScripter: AppleNotesScripting {
    var error: AppleNotesScriptError?
    private(set) var sources: [String] = []

    init(error: AppleNotesScriptError? = nil) { self.error = error }

    func run(_ source: String) -> AppleNotesScriptError? {
        sources.append(source)
        return error
    }
}

@MainActor
@Suite("Apple Notes exporter through a fake scripter")
struct AppleNotesExporterFakeTests {
    @Test("requestAccess reports the mapped result and runs one read-only script")
    func requestAccessMaps() {
        let refused = FakeAppleNotesScripter(error: .init(number: -1743, message: "not allowed"))
        #expect(AppleNotesExporter.requestAccess(using: refused) == .notPermitted)
        #expect(refused.sources.count == 1)
        #expect(!refused.sources[0].contains("make new"))

        #expect(AppleNotesExporter.requestAccess(using: FakeAppleNotesScripter()) == .granted)
        #expect(AppleNotesExporter.requestAccess(using: FakeAppleNotesScripter(error: .init(number: -1712, message: ""))) == .timedOut)
    }

    @Test("export throws an error that carries the number")
    func exportThrowsNumber() {
        let fake = FakeAppleNotesScripter(error: .init(number: -600, message: "Notes isn't running"))
        let note = Note(title: "T", transcript: "words")
        do {
            try AppleNotesExporter.export(note, using: fake)
            Issue.record("expected a throw")
        } catch let error as AppleNotesExporter.ExportError {
            #expect(error.result == .notesUnavailable)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("export succeeds quietly when the script runs")
    func exportSucceeds() throws {
        let fake = FakeAppleNotesScripter()
        try AppleNotesExporter.export(Note(title: "T", transcript: "words"), using: fake)
        #expect(fake.sources.count == 1)
    }
}
