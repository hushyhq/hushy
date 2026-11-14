#if DEBUG
import AppKit
import Carbon.HIToolbox
import Foundation
import MurmurCore

/// The device tier reuses the mock-microphone rig, capture and player. The only window belongs to
/// this process. Keyboard dispatch is confined to its text view; no event is posted system-wide.
private struct AppE2EExpectations: Decodable {
    struct Scenario: Decodable {
        let id: String
        let spoken: String
        let mustContain: [String]
        let mustNotContain: [String]
    }
    let version: Int
    let scenarios: [Scenario]
}

@MainActor
private final class AppE2EWindow {
    enum Route: String, CaseIterable { case editable, pasteOnly, refuses, noField, moved }
    final class RouteBox { var value: Route = .editable }
    let window: NSWindow
    let textView: NSTextView
    let board: NSPasteboard
    let paster: ClipboardPaster
    private let routeBox: RouteBox
    var route: Route {
        get { routeBox.value }
        set { routeBox.value = newValue }
    }

    init() {
        let routeBox = RouteBox()
        self.routeBox = routeBox
        board = NSPasteboard(name: NSPasteboard.Name("app-e2e-\(UUID().uuidString)"))
        board.setString("private original", forType: .string)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.title = "Hushy app test target"
        let view = textView
        let pasteboard = board
        paster = ClipboardPaster(pasteboard: board, postKey: { key, flags in
            if key == CGKeyCode(kVK_ANSI_V) && flags.contains(.maskCommand) {
                guard routeBox.value != .refuses else { return false }
                guard let text = pasteboard.string(forType: .string) else { return false }
                view.insertText(text, replacementRange: view.selectedRange())
                return true
            }
            return key == CGKeyCode(kVK_Return)
        }, restoreDelay: .milliseconds(50), returnDelay: .zero)
        window.makeKeyAndOrderFront(nil)
    }

    func reset() {
        textView.string = ""
        board.clearContents()
        board.setString("private original", forType: .string)
    }

    func close() {
        window.orderOut(nil)
    }
}

extension MockMicHarness {
    func runAppE2E() async -> MockMicReport {
        let title = "Virtual microphone through app tone and package target"
        guard let path = ProcessInfo.processInfo.environment["HUSHY_APP_E2E_EXPECTATIONS"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let expected = try? JSONDecoder().decode(AppE2EExpectations.self, from: data),
              expected.version == 1 else {
            record(skipped("app-e2e", title, "missing or invalid shared expectations"))
            return report()
        }
        let missing = MockMicPreflight.missingForDictation()
        guard missing.isEmpty, rig.cleanupModel.availability.isAvailable else {
            record(skipped("app-e2e", title, "model files missing: \(missing.joined(separator: ", "))"))
            return report()
        }
        guard let deviceID = rig.verifiedDeviceID() else {
            record(skipped("app-e2e", title, "virtual microphone not verified"))
            return report()
        }
        do { try await rig.prepareSpeech() } catch {
            record(failed("app-e2e", title, error, seconds: 0))
            return report()
        }
        _ = NSApplication.shared
        let target = AppE2EWindow()
        defer { target.close() }
        for clip in manifest.dictation {
            let start = ContinuousClock.now
            guard let scenario = expected.scenarios.first(where: { $0.id == clip.id }) else {
                record(skipped(clip.id, title, "no matching expected result"))
                continue
            }
            do {
                let files = try resolve(clip.wavs)
                let samples = try await capture(files, deviceID: deviceID)
                let transcript = try await rig.speech.transcribeWithConfidence(
                    LoudnessNormalizer.normalize(samples), vocabulary: .empty)
                let pipeline = DictationPipeline(transcriber: rig.speech,
                    cleaner: SmartCleaner(model: rig.cleanupModel, abandoned: .shared))
                let kinds: [(String, AppCategory)] = clip.id == "tones" ? [
                    ("work", .workMessages), ("email", .email), ("personal", .personalMessages),
                    ("ai", .aiPrompts), ("other", .other), ("override", .workMessages)
                ] : [(clip.id, clip.id == "moved-group" ? .personalMessages : .workMessages)]
                for (kind, category) in kinds {
                    let toneChoices: [DictationTone] = clip.id == "tones" ? DictationTone.allCases : [.refined]
                    for tone in toneChoices {
                        let bundleID = clip.id == "moved-group" ? "test.hushy.work" : "test.hushy.\(kind)"
                        var tones = ToneSettings.standard
                        if clip.id == "as-spoken" { tones.choice = .asSpoken }
                        else if let context = StyleContext.from(category) {
                            tones = tones.settingTone(tone, for: context)
                        }
                        if kind == "override" { tones = tones.settingApp(.tone(.casual), bundleIDs: [bundleID]) }
                        let plan = tones.plan(for: category, bundleID: bundleID)
                        let personalizer = clip.id == "taught-word"
                            ? Personalizer(dictionary: [DictionaryEntry(term: "Zindle", soundsLike: ["zindel"])])
                            : Personalizer()
                        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: plan.level),
                                                        personalizer: personalizer, style: plan.style, tone: plan.tone)
                        let output = await pipeline.clean(transcript.text, confidences: transcript.confidences, settings: settings)
                        let properties = scenario.mustContain.allSatisfy { output.text.localizedCaseInsensitiveContains($0) }
                            && scenario.mustNotContain.allSatisfy { !output.text.localizedCaseInsensitiveContains($0) }
                        for route in AppE2EWindow.Route.allCases {
                            target.reset()
                            target.route = route
                            let delivery = await TargetedDelivery.deliver(text: output.text, pressReturn: false,
                                hasTextInput: route != .noField,
                                check: { route == .moved ? .changed(.field) : .unchanged }, paster: target.paster)
                            try? await Task.sleep(for: .milliseconds(100))
                            let landed = target.textView.string
                            let expectedLanding = route == .editable || route == .pasteOnly
                            let found = expectedLanding ? (delivery.reachedTarget && landed == output.text)
                                                        : (!delivery.reachedTarget && landed.isEmpty)
                            let clipboard = target.board.string(forType: .string)
                            let clipboardRight = clipboard == (expectedLanding ? "private original" : output.text)
                            let checks = [check("landed in package target", found, delivery.logSummary),
                                          check("text properties", properties, "\(scenario.mustContain.count) required"),
                                          check("private clipboard rule", clipboardRight, expectedLanding ? "restored" : "copied")]
                            record(MockMicScenarioResult(id: "\(clip.id).\(kind).\(tone.rawValue).\(route.rawValue)", title: title,
                                status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
                                detail: delivery.logSummary, checks: checks,
                                metrics: ["cleanupMs": output.timings.cleanupMs],
                                // Fixture speech is invented, so what was heard and written may be kept.
                                texts: ["reference": scenario.spoken, "raw": transcript.text, "cleaned": output.text]))
                        }
                    }
                }
            } catch {
                record(failed(clip.id, title, error, seconds: mockMicSeconds(since: start)))
            }
        }
        return report()
    }
}
#endif
