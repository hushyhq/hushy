import AppKit
import Foundation
import Testing
@testable import Murmur

/// The pill preview (`--pill-preview`): the real pill played from a script of invented states.
@Suite("Pill preview — every state, invented text, nothing real touched", .serialized)
@MainActor
struct PillPreviewTests {
    private func makeRunner() -> PillPreviewRunner {
        _ = NSApplication.shared
        let runner = PillPreviewRunner(sleep: { _ in await Task.yield() })
        runner.show(makePanel: { PillPanel(model: $0, environment: PillPanelInteractionTests.fakeEnvironment()) })
        return runner
    }

    // MARK: The launch argument

    @Test("only the exact flag asks for the preview; every ordinary launch starts the app as before")
    func argumentAbsentMeansTheApp() {
        let binary = "/Applications/Hushy.app/Contents/MacOS/Hushy"
        let ordinary: [[String]] = [
            [binary],
            [binary, "-NSDocumentRevisionsDebugMode", "YES"],
            [binary, "--snapshots", "/tmp/out"],
            [binary, "--mock-mic", "/tmp/report"],
            [binary, "pill-preview"],
            [binary, "--pill-previews"],
            [binary, "-pill-preview"],
            [binary, "--scene", "quick", "--speed", "0.5", "--loop"],
            [],
        ]
        for arguments in ordinary {
            #expect(!PillPreviewArguments.requested(arguments), "\(arguments)")
            #expect(PillPreviewArguments.parse(arguments) == nil)
        }
        #expect(PillPreviewArguments.requested([binary, "--pill-preview"]))
    }

    @Test("options: a scene, a speed that is offered, looping; anything unusable is refused")
    func options() {
        let flag = PillPreviewArguments.flag
        #expect(PillPreviewArguments.parse(["Hushy", flag]) == PillPreviewArguments())
        #expect(PillPreviewArguments.parse(["Hushy", flag, "--scene", "stall", "--speed", "0.25", "--loop"])
            == PillPreviewArguments(scene: .stall, speed: 0.25, loops: true))
        #expect(PillPreviewArguments.parse(["Hushy", flag, "--scene", "nope"]) == nil)
        #expect(PillPreviewArguments.parse(["Hushy", flag, "--scene"]) == nil)
        #expect(PillPreviewArguments.parse(["Hushy", flag, "--speed", "3"]) == nil)
        #expect(PillPreviewArguments.parse(["Hushy", flag, "--speed", "fast"]) == nil)
    }

    // MARK: The script

    @Test("the reel shows every state the pill has")
    func coversEveryState() {
        let shown = Set(PillPreviewScript.allSteps.map { PillStateKind($0.state) })
        #expect(shown == Set(PillStateKind.allCases), "missing: \(Set(PillStateKind.allCases).subtracting(shown))")
    }

    @Test("every scene has steps that say what is happening and last some time")
    func scenesAreComplete() {
        for scene in PillPreviewScene.allCases {
            let steps = PillPreviewScript.steps(for: scene)
            #expect(!steps.isEmpty, "\(scene)")
            #expect(!scene.title.isEmpty)
            for step in steps {
                #expect(!step.caption.isEmpty)
                #expect(step.hold > .zero)
            }
        }
    }

    @Test("the only words behind a card or a held row are the invented ones")
    func inventedTextOnly() {
        let invented: Set<String> = [PillPreviewScript.inventedShort, PillPreviewScript.inventedLong, PillPreviewScript.inventedName]
        for step in PillPreviewScript.allSteps {
            if let text = step.text { #expect(invented.contains(text)) }
        }
    }

    @Test("the microphone is open only where the pill says it is")
    func voiceMatchesState() {
        for step in PillPreviewScript.allSteps where step.voice != .none {
            let kind = PillStateKind(step.state)
            #expect([.listening, .handsFree, .recordingNote, .actionListening].contains(kind), "\(step.caption)")
        }
    }

    @Test("the invented voice is the same every run, quiet in silence and never clipped")
    func voiceLevels() {
        #expect(PillPreviewVoice.none.rms(at: 1) == 0)
        #expect(PillPreviewVoice.silence.rms(at: 1) < 0.002)
        var peak: Float = 0
        for tick in 0..<200 {
            let time = Double(tick) * 0.03
            let level = PillPreviewVoice.speech.rms(at: time)
            #expect(level == PillPreviewVoice.speech.rms(at: time))
            #expect(level > 0 && level < 0.1)
            peak = max(peak, level)
        }
        #expect(peak > 0.03, "speech moves the bars")
    }

    @Test("timers start when the step is shown, not at the placeholder")
    func stamping() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(PillPreviewScript.stamped(.handsFree(startedAt: PillPreviewScript.placeholder), now: now) == .handsFree(startedAt: now))
        #expect(PillPreviewScript.stamped(.recordingNote(startedAt: PillPreviewScript.placeholder), now: now) == .recordingNote(startedAt: now))
        #expect(PillPreviewScript.stamped(.done(words: 3), now: now) == .done(words: 3))
    }

    // MARK: Playing it on the real pill

    @Test("every step shows on the real pill, and its Copy buttons are counted, never sent anywhere")
    func stepsShowAndCopiesGoNowhere() {
        let runner = makeRunner()
        var shown: Set<PillStateKind> = []
        var pressed = 0
        for step in PillPreviewScript.allSteps {
            runner.apply(step)
            #expect(PillStateKind(runner.pill.state) == PillStateKind(step.state))
            #expect(runner.caption == step.caption)
            shown.insert(PillStateKind(runner.pill.state))
            if case .noField(let mode) = runner.pill.state, mode.afterCopy != nil {
                runner.pill.copyNoFieldText()
                pressed += 1
            }
            if runner.pill.state == .held(copied: false) {
                runner.pill.copyHeldText()
                pressed += 1
            }
        }
        #expect(shown == Set(PillStateKind.allCases))
        #expect(pressed >= 2)
        #expect(runner.copies == pressed)
    }

    @Test("a scene plays to its end and leaves the pill at rest")
    func playsToRest() async {
        let runner = makeRunner()
        await runner.run([.quick, .notPasted])
        #expect(runner.playing == nil)
        #expect(runner.pill.state == .idle)
        #expect(runner.caption == PillPreviewScript.rest.caption)
    }

    @Test("speed, the old timings and Reduce Motion are the pill's own switches, set from the control window")
    func switches() {
        let runner = makeRunner()
        #expect(runner.pill.motion == .standard, "as the app has it until a switch is moved")
        #expect(runner.pill.reduceMotionOverride == nil)
        runner.speed = 0.25
        #expect(runner.pill.motion.speed == 0.25)
        #expect(runner.pill.motion.open == PillMotion.standard.open)
        runner.usesOldTimings = true
        var old = PillMotion.legacy
        old.speed = 0.25
        #expect(runner.pill.motion == old)
        runner.usesOldTimings = false
        runner.speed = 1
        #expect(runner.pill.motion == .standard)
        runner.reduceMotion = .on
        #expect(runner.pill.reduceMotionOverride == true)
        runner.reduceMotion = .off
        #expect(runner.pill.reduceMotionOverride == false)
        runner.reduceMotion = .system
        #expect(runner.pill.reduceMotionOverride == nil)
    }

    @Test("a dictation in the reel starts as a real one does: grey bars until the invented microphone's first level")
    func startsGrey() {
        let runner = makeRunner()
        runner.apply(PillPreviewScript.steps(for: .quick)[0])
        #expect(runner.pill.state == .listening)
        #expect(runner.pill.awaitsFirstAudio)
        runner.pill.push(rms: PillPreviewVoice.speech.rms(at: 0.2))
        #expect(!runner.pill.awaitsFirstAudio)
    }

    @Test("the long waits carry invented progress: in order, more than one group, never more done than there are")
    func progressInTheScript() {
        for scene in [PillPreviewScene.longWait, .stall] {
            let waits = PillPreviewScript.steps(for: scene).filter { !$0.progress.isEmpty }
            #expect(waits.count == 1, "\(scene)")
            for wait in waits {
                #expect(PillStateKind(wait.state) == .processing)
                #expect(wait.progress.map(\.at) == wait.progress.map(\.at).sorted())
                #expect(wait.progress.map(\.done) == wait.progress.map(\.done).sorted())
                #expect(wait.progress.first?.done == 0, "the first report is nothing done yet")
                #expect(wait.progress.allSatisfy { $0.done <= $0.count && $0.count > 1 })
                #expect((wait.progress.last?.at ?? 0) < Double(wait.hold.components.seconds) + 1)
            }
        }
        #expect(PillPreviewScript.steps(for: .quick).allSatisfy { $0.progress.isEmpty }, "a quick dictation has no line")
    }

    @MainActor
    final class Watcher {
        var fills: [Double] = []
        func look(at pill: PillModel) async {
            if let fill = pill.waitProgress?.fill { fills.append(fill) }
            await Task.yield()
        }
    }

    @Test("played, the stalled wait's line grows on the real pill, stops short of full, and goes with the wait")
    func progressPlays() async {
        _ = NSApplication.shared
        let watcher = Watcher()
        let pill = PillModel()
        let runner = PillPreviewRunner(pill: pill, sleep: { _ in await watcher.look(at: pill) })
        await runner.run([.stall])
        #expect(watcher.fills == watcher.fills.sorted(), "never backwards")
        #expect((watcher.fills.max() ?? 0) > 0.5)
        #expect((watcher.fills.max() ?? 1) < 1)
        #expect(pill.waitProgress == nil)
        #expect(pill.state == .idle)
    }

    @Test("stop returns the pill to rest at once")
    func stopRests() {
        let runner = makeRunner()
        runner.apply(PillPreviewScript.steps(for: .stall)[1])
        #expect(PillStateKind(runner.pill.state) == .processing)
        runner.stop()
        #expect(runner.pill.state == .idle)
        #expect(runner.playing == nil)
    }

    // MARK: Nothing real

    @Test("the data folder is one the environment chose, else a new temporary one; never the real one")
    func homeFolder() {
        let temporary = URL(fileURLWithPath: "/private/tmp/preview-test")
        #expect(PillPreviewHome.folder(environment: ["HUSHY_HOME": "/private/tmp/chosen"], temporary: temporary) == "/private/tmp/chosen")
        #expect(PillPreviewHome.folder(environment: ["MURMUR_HOME": "/private/tmp/older"], temporary: temporary) == "/private/tmp/older")
        let fresh = PillPreviewHome.folder(environment: [:], temporary: temporary)
        #expect(fresh.hasPrefix("/private/tmp/preview-test/hushy-pill-preview-"))
        #expect(!fresh.contains("Application Support"))
        #expect(fresh != PillPreviewHome.folder(environment: [:], temporary: temporary))
    }

    @Test("the preview pill sits above the real one's place, on every display")
    func lifted() {
        let display = PillDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                  visible: CGRect(x: 0, y: 70, width: 1440, height: 800), topLimit: 870)
        let lifted = PillPanelEnvironment.lifted(display)
        #expect(lifted.visible.minY == 70 + PillPanelEnvironment.previewLift)
        #expect(lifted.visible.maxY == display.visible.maxY)
        let small = PillDisplay(id: 2, frame: .zero, visible: CGRect(x: 0, y: 0, width: 300, height: 180), topLimit: 180)
        #expect(PillPanelEnvironment.lifted(small).visible.height >= 180)
    }

    @Test("it cannot be taken for the real app: no Dock icon or menu bar, a title that says preview, and links are not answered")
    func notMistakenForTheApp() {
        #expect(PillPreviewAppDelegate.activationPolicy == .accessory)
        #expect(PillPreviewAppDelegate.windowTitle.lowercased().contains("preview"))
        #expect(PillPreviewAppDelegate.windowTitle.contains("not the real Hushy"))
        let delegate = PillPreviewAppDelegate(arguments: PillPreviewArguments())
        #expect(!delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))))
    }

    @Test("the preview's own code names nothing that records, recognises, cleans, pastes or stores")
    func sourcesNameNothingReal() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Murmur/Pill/Preview")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 4)
        let forbidden = [
            "NSPasteboard", "TextInserter", "ClipboardPaster", "AudioCapture", "AVAudio", "SpeechEngine", "SmartCleaner",
            "DictationController", "DictationPipeline", "HotkeyMonitor", "AppModel(", "AppSettings", "AppPaths", "Store(",
            "LanguageModels", "KeyStore", "UserDefaults.standard", "SingleInstance", "NSStatusItem", "MenuBarExtra",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                #expect(!source.contains(word), "\(file.lastPathComponent) names \(word)")
            }
        }
    }
}
