import Foundation

/// Where the plan is built from. Every value comes from the system or from the app's own
/// constants, never from something the person typed.
public struct UninstallRoots: Sendable, Equatable {
    /// The person's home folder.
    public var home: URL
    /// The app's data folder (`AppPaths.supportDirectory`, which follows `HUSHY_HOME` / `MURMUR_HOME`).
    public var supportDirectory: URL
    /// True when `HUSHY_HOME` or `MURMUR_HOME` chose the data folder.
    public var supportIsOverridden: Bool
    public var bundleIdentifier: String
    /// The running `.app`, or nil when the process is not running from an app bundle.
    public var bundleURL: URL?
    /// Where notes are exported as Markdown. Never removed, and nothing inside it is removed.
    public var exportDirectory: URL
    /// Folder names of the speech models this build uses, inside the speech engine's model folder.
    public var speechModelFolderNames: [String]
    /// False when the person chose to leave the speech models, which other apps may share.
    public var removesSpeechModels: Bool
    /// False when the person chose to keep macOS's list of permissions (Microphone, Accessibility
    /// and the rest) for Hushy. It is reset by `tccutil`, and never in a test run.
    public var resetsPermissions: Bool
    /// True for a snapshot, test or mock-microphone run, or one on a throwaway settings suite.
    /// A data folder chosen by an environment override makes a test run by itself.
    public var isTestRun: Bool

    public init(
        home: URL, supportDirectory: URL, supportIsOverridden: Bool, bundleIdentifier: String,
        bundleURL: URL?, exportDirectory: URL, speechModelFolderNames: [String],
        removesSpeechModels: Bool = true, resetsPermissions: Bool = true, isTestRun: Bool = false
    ) {
        self.home = home
        self.supportDirectory = supportDirectory
        self.supportIsOverridden = supportIsOverridden
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.exportDirectory = exportDirectory
        self.speechModelFolderNames = speechModelFolderNames
        self.removesSpeechModels = removesSpeechModels
        self.resetsPermissions = resetsPermissions
        self.isTestRun = isTestRun
    }
}

/// Why nothing, or one location, was left alone.
public enum UninstallRefusal: Error, Equatable, Sendable {
    /// The home folder is empty, `/` or otherwise not a person's folder.
    case unusableHome(String)
    /// The data folder is the home folder, a parent of it, or a system folder.
    case unusableDataFolder(String)
    case invalidBundleIdentifier(String)
    /// The data folder was chosen by `HUSHY_HOME` / `MURMUR_HOME` and does not hold Hushy's database.
    case notAHushyDataFolder(String)
    /// The path is empty, `/`, relative, or not written in its plain form.
    case notAPlainPath(String)
    /// The path is not inside any folder the plan may remove from.
    case outsideAllowedFolders(String)
    /// The path is a link. Neither the link nor what it points to is removed.
    case isALink(String)
    /// A folder on the way to the path is a link that leads somewhere else.
    case leadsOutside(String)
    /// The step is not one this plan may run (wrong domain, wrong folder, not the app).
    case notPartOfThePlan(String)
    /// The location is, holds or is inside the export folder once links and letter case are worked out.
    case touchesExportFolder(String)
    /// A test run that has no data folder of its own: there is nothing it may remove.
    case testRunWithoutItsOwnFolder

    /// One plain sentence for the person.
    public var explanation: String {
        switch self {
        case .unusableHome: "Hushy could not work out where your home folder is."
        case .unusableDataFolder(let path): "The data folder is set to \(path), which Hushy will not remove."
        case .invalidBundleIdentifier: "This copy of Hushy does not know its own identifier."
        case .notAHushyDataFolder(let path): "The data folder is set to \(path), and that folder does not hold Hushy's data."
        case .notAPlainPath: "The location is not a plain path."
        case .outsideAllowedFolders: "The location is outside Hushy's own folders."
        case .isALink: "This is a link to another place. Hushy left the link and what it points to."
        case .leadsOutside: "A folder on the way is a link to another place, so Hushy left this alone."
        case .notPartOfThePlan: "This is not something Hushy may remove."
        case .touchesExportFolder: "This is, holds or is inside your export folder, so Hushy left it alone."
        case .testRunWithoutItsOwnFolder:
            "This is a test run without a data folder of its own, so there is nothing for it to remove."
        }
    }
}

/// A folder the plan may remove things from, and how deep below it a removal must be. That is
/// the first check only: a removal must also be one of `UninstallPlanner.removableLocations`.
public struct UninstallAllowedRoot: Sendable, Equatable {
    public let url: URL
    /// 1 allows the folder's direct children; 2 allows only what is inside one of its children.
    public let minimumDepth: Int
}

/// One thing the uninstall does. The executor runs these, in order, and nothing else.
public struct UninstallStep: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        case stopActivity
        case signOut
        case unregisterLoginItem
        case clearNotifications
        /// Every generic-password item of one Keychain service the app created.
        case deleteKeychainItems(service: String)
        case removeItem(URL)
        /// Removes the folder only when nothing is left in it.
        case removeFolderIfEmpty(URL)
        case clearDefaults(domain: String)
        case moveAppToTrash(URL)
        /// Asks macOS to forget every permission it holds for this app (`tccutil reset All`).
        /// Only ever Hushy's own identifier: see `UninstallPlan.permissionsBundleIdentifier`.
        case resetPermissions(bundleIdentifier: String)
    }

    /// What the person is shown the step under.
    public enum Group: String, Sendable, CaseIterable {
        /// `models` are the writing models in the data folder; `speechModels` sit in the speech
        /// engine's folder, which other apps may share.
        case activity, data, models, speechModels, signIn, settings, caches, app
    }

    public let action: Action
    public let group: Group
    /// Plain words for the list of locations.
    public let title: String
    /// Run only when every removal of history and recordings before it succeeded. Set for the
    /// recording-encryption key: recordings left behind must stay readable.
    public let onlyAfterDataRemoved: Bool

    init(_ action: Action, _ group: Group, _ title: String, onlyAfterDataRemoved: Bool = false) {
        self.action = action
        self.group = group
        self.title = title
        self.onlyAfterDataRemoved = onlyAfterDataRemoved
    }

    /// True for the step that must succeed before anything is removed.
    public var mustSucceedFirst: Bool { action == .stopActivity }

    /// True for a removal of history, notes or recordings.
    public var removesData: Bool { group == .data && fileURL != nil }

    /// Run again just before the app quits. Until then the app is still running and can write a
    /// file or a setting back; removing something that is already gone does nothing.
    public var repeatsAtQuit: Bool {
        switch action {
        case .removeItem, .removeFolderIfEmpty, .clearDefaults: true
        case .stopActivity, .signOut, .unregisterLoginItem, .clearNotifications, .deleteKeychainItems, .moveAppToTrash,
            .resetPermissions: false
        }
    }

    /// Where the thing is, for the list before and the report after.
    public var location: String {
        switch action {
        case .stopActivity: "Hushy itself"
        case .signOut: "Your Hushy account, on this Mac only"
        case .unregisterLoginItem: "System Settings, General, Login Items"
        case .clearNotifications: "Notification Center"
        case .deleteKeychainItems(let service): "Keychain Access, items named \(service)"
        case .removeItem(let url), .removeFolderIfEmpty(let url), .moveAppToTrash(let url): url.path
        case .clearDefaults(let domain): "Settings stored under \(domain)"
        case .resetPermissions: "System Settings, Privacy & Security (Microphone, Accessibility and the rest)"
        }
    }

    public var id: String { "\(group.rawValue):\(title):\(location)" }

    /// The file or folder the step removes, when it removes one.
    public var fileURL: URL? {
        if case .removeItem(let url) = action { return url }
        return nil
    }
}

/// Something the uninstall leaves where it is, and why.
public struct UninstallKept: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        case exportFolder
        case insideExportFolder
        case holdsExportFolder
        case notAPlainFolderName
        /// The person chose to leave the speech models, which other apps may share.
        case speechModelsLeftByChoice
        /// The encryption key stays because recordings stay.
        case recordingsStay
        /// The person chose to leave macOS's list of permissions for Hushy.
        case permissionsLeftByChoice
    }

    public let title: String
    public let location: String
    public let reason: Reason

    public var id: String { "\(title):\(location)" }
}

/// The exact list of what an uninstall removes and what it leaves. Only `UninstallPlanner` makes one.
public struct UninstallPlan: Sendable, Equatable {
    public let roots: UninstallRoots
    public let allowedRoots: [UninstallAllowedRoot]
    public let steps: [UninstallStep]
    public let kept: [UninstallKept]
    /// The file that must exist in the data folder before anything runs, when the folder was
    /// chosen by an environment override. Nil for the standard folder.
    public let requiredDataMarker: URL?
    /// A snapshot, test, mock-microphone or override run: only the named files in its own data
    /// folder are removed, and the app does not quit.
    public let isTestRun: Bool

    /// The speech models' steps, when they are being removed.
    public var speechModelSteps: [UninstallStep] { steps.filter { $0.group == .speechModels } }

    /// The removals and the settings, which the still-running app could undo; run again just before quitting.
    public var stepsRepeatedAtQuit: [UninstallStep] { steps.filter(\.repeatsAtQuit) }

    /// Keychain services whose items the app creates. Each is the app's own, named in full.
    /// `app.hushy.account` held the sign-in before it moved to a file in the data folder.
    public static let keychainServices = [
        KeychainKeyStore.encryptionService, OAuthTokenStore.keychainService, "app.hushy.account",
        SealedFormat.keychainService,
    ]

    /// The one identifier whose permissions the uninstall resets. Fixed: it is never read from
    /// the environment, a plan or the person, so `tccutil` is never pointed at another app.
    public static let permissionsBundleIdentifier = "app.hushy.Hushy"

    /// Left where they are, and not locations the plan could list one by one.
    public static let alsoUntouched = [
        "Notes you saved to Apple Notes stay in its “Hushy” folder.",
        "A recovery key you saved to Passwords stays in iCloud Keychain.",
        "If you connected Hushy to Claude, Cursor or Codex, its entry stays in their settings. Remove it there.",
    ]
}
