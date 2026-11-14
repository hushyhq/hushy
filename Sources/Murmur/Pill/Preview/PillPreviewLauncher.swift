import AppKit
import SwiftUI

/// `--pill-preview`: play the pill's states and motion with invented text instead of starting Hushy.
///
///     Hushy --pill-preview [--scene <name>] [--speed 1|0.5|0.25] [--loop]
///
/// Without the flag nothing here runs and the app starts exactly as it always has.
struct PillPreviewArguments: Equatable {
    static let flag = "--pill-preview"
    static let speeds: [Double] = [1, 0.5, 0.25]

    /// One scene to start with; the whole reel when nil.
    var scene: PillPreviewScene?
    var speed: Double = 1
    var loops = false

    /// Only the exact flag asks for the preview.
    static func requested(_ arguments: [String]) -> Bool {
        arguments.contains(flag)
    }

    /// `nil` when the options are unusable (an unknown scene, a speed that is not offered, a missing value).
    static func parse(_ arguments: [String]) -> PillPreviewArguments? {
        guard requested(arguments) else { return nil }
        var parsed = PillPreviewArguments()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let value: String? = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            switch argument {
            case "--scene":
                guard let value, let scene = PillPreviewScene(rawValue: value) else { return nil }
                parsed.scene = scene
                index += 1
            case "--speed":
                guard let value, let speed = Double(value), speeds.contains(speed) else { return nil }
                parsed.speed = speed
                index += 1
            case "--loop":
                parsed.loops = true
            default:
                break
            }
            index += 1
        }
        return parsed
    }

    static var usage: String {
        let scenes = PillPreviewScene.allCases.map(\.rawValue).joined(separator: "|")
        return "usage: Hushy \(flag) [--scene \(scenes)] [--speed 1|0.5|0.25] [--loop]"
    }
}

/// Where a preview's data folder points. A preview reads and writes no app data at all; this is
/// the second lock on that door: if anything ever asked for the data folder it would get an
/// empty temporary one, never the person's.
enum PillPreviewHome {
    static let variables = ["HUSHY_HOME", "MURMUR_HOME"]

    /// The folder to use: one already chosen by the environment, else a new temporary one.
    static func folder(environment: [String: String], temporary: URL = FileManager.default.temporaryDirectory) -> String {
        for variable in variables {
            if let chosen = environment[variable], !chosen.isEmpty { return chosen }
        }
        return temporary.appendingPathComponent("hushy-pill-preview-\(UUID().uuidString)").path
    }

    static func prepare() {
        let folder = folder(environment: ProcessInfo.processInfo.environment)
        for variable in variables { setenv(variable, folder, 1) }
    }
}

/// The preview's own small application: one control window and the pill. `AppModel` is never
/// built, so no database, model, microphone, hotkey or update check exists in this process.
@MainActor
enum PillPreviewLauncher {
    static func launch(_ arguments: [String]) -> Never {
        guard let parsed = PillPreviewArguments.parse(arguments) else {
            FileHandle.standardError.write(Data((PillPreviewArguments.usage + "\n").utf8))
            exit(64)
        }
        PillPreviewHome.prepare()
        let application = NSApplication.shared
        let delegate = PillPreviewAppDelegate(arguments: parsed)
        application.delegate = delegate
        application.setActivationPolicy(PillPreviewAppDelegate.activationPolicy)
        withExtendedLifetime(delegate) { application.run() }
        exit(0)
    }
}

/// It deliberately has no `application(_:open:)`: a `hushy://` link that macOS hands to a preview
/// is dropped, never acted on. And it is an accessory application: no Dock icon and no menu bar of
/// its own, so nothing about it can be taken for the real Hushy except the window that says what it is.
@MainActor
final class PillPreviewAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let activationPolicy = NSApplication.ActivationPolicy.accessory
    static let windowTitle = "Pill preview (invented text, not the real Hushy)"

    private let arguments: PillPreviewArguments
    private let runner = PillPreviewRunner()
    private var window: NSWindow?
    /// Anchors saved by dragging the preview pill go here and are thrown away on quit.
    private let defaultsSuite = "app.hushy.pill-preview.\(UUID().uuidString)"
    private var anchorDefaults: UserDefaults?

    init(arguments: PillPreviewArguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.menu()
        runner.speed = arguments.speed
        runner.loops = arguments.loops
        // A suite of its own: where a dragged preview pill is dropped is never saved with the app's.
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            FileHandle.standardError.write(Data("pill-preview: could not make throwaway settings\n".utf8))
            exit(70)
        }
        anchorDefaults = defaults
        runner.show(makePanel: { PillPanel(model: $0, environment: .preview(anchorDefaults: defaults)) })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Self.windowTitle
        window.contentView = NSHostingView(rootView: PillPreviewControls(runner: runner))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        if let scene = arguments.scene { runner.play([scene]) } else { runner.playAll() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        anchorDefaults?.removePersistentDomain(forName: defaultsSuite)
    }

    /// Never shown (an accessory application has no menu bar): it only gives the window ⌘Q and ⌘W.
    private static func menu() -> NSMenu {
        let main = NSMenu()
        let item = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Quit Pill Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = app
        main.addItem(item)
        return main
    }
}

extension PillPanelEnvironment {
    /// How far above its usual place the preview pill sits, so it never covers the real Hushy's pill.
    static let previewLift: CGFloat = 120

    /// The Mac's displays with the bottom edge lifted, and throwaway anchor storage.
    @MainActor
    static func preview(anchorDefaults: UserDefaults) -> PillPanelEnvironment {
        var environment = PillPanelEnvironment.live
        environment.anchorDefaults = anchorDefaults
        environment.displays = { NSScreen.screens.map { lifted(PillDisplay.of($0)) } }
        return environment
    }

    static func lifted(_ display: PillDisplay) -> PillDisplay {
        var display = display
        let lift = min(previewLift, max(0, display.visible.height - 200))
        display.visible = CGRect(x: display.visible.minX, y: display.visible.minY + lift,
                                 width: display.visible.width, height: display.visible.height - lift)
        return display
    }
}
