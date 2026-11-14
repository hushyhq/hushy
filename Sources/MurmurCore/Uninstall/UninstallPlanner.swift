import Foundation

/// Builds the plan. Reads no file itself: the only thing it asks is `resolving`, which the app
/// answers from the disk (links followed, names in the letter case the volume stores) and tests
/// answer with a fake. It is used for one question only, whether a location touches the export
/// folder.
public enum UninstallPlanner {
    /// Everything the app writes directly inside its data folder, with the code that writes it.
    /// Used when the folder cannot be removed whole (a test run, or an export folder inside it).
    static let dataFolderChildren: [(name: String, group: UninstallStep.Group, title: String)] = [
        ("murmur.sqlite", .data, "History, notes, dictionary and learned words"),   // AppPaths.database
        ("murmur.sqlite-wal", .data, "Database working file"),                      // SQLite, beside the database
        ("murmur.sqlite-shm", .data, "Database working file"),
        (PreMeetingsBackup.fileName, .data, "Database copy kept after a failed upgrade"),
        ("Audio", .data, "Dictation recordings"),                                   // AppPaths.audioDirectory
        ("Notes", .data, "Note recordings"),                                        // AppPaths.notesAudioDirectory
        ("Memory", .data, "Person memory"),                                         // AppPaths.memoryDirectory
        ("Assistant", .data, "Assistant chat folders"),                             // AgentWorkspace.forChat
        ("UsageMetrics", .data, "Usage numbers waiting to be sent"),                // AppModel.init
        (DailyCountStore.fileName, .data, "The marker for the once-a-day count"),  // AppModel.init
        ("VoiceLab", .data, "Voice Lab recordings"),                                // VoiceLabStorage.root
        ("Models", .models, "Writing models"),                                      // ModelRegistry.directory
        ("account.keys", .signIn, "Your sign-in on this Mac"),                      // FileKeyStore.account
    ]

    /// The file that marks a folder as Hushy's data folder.
    static let dataMarkerName = "murmur.sqlite"

    /// What macOS and the app keep under the app's identifier, by path inside the home Library.
    static func libraryItems(for id: String) -> [(path: String, group: UninstallStep.Group, title: String)] {
        [
            ("Caches/\(id)", .caches, "Caches"),
            ("HTTPStorages/\(id)", .caches, "Network cache"),
            ("HTTPStorages/\(id).binarycookies", .caches, "Cookies"),
            ("Cookies/\(id).binarycookies", .caches, "Cookies"),
            ("WebKit/\(id)", .caches, "Update notes cache"),
            ("Preferences/\(id).plist", .settings, "Settings file"),
            ("Saved Application State/\(id).savedState", .settings, "Saved window positions"),
        ]
    }

    /// Where the speech engine keeps its models. The engine chooses the folder itself, so the
    /// app names each model by its place inside this one (`LiveUninstall.speechModelFolderNames`):
    /// a model the engine keeps anywhere else is not a plain name, and is left where it is.
    public static func speechModelsFolder(inHome home: URL) -> URL {
        UninstallPathPolicy.child(of: home, "Library/Application Support/FluidAudio/Models")
    }

    /// Every file and folder a plan for these roots may remove, each named in full: the data
    /// folder and the app's own files in it, the speech models by name, and the items under the
    /// app's identifier in the home Library. A test run has only the files in its data folder.
    /// The executor refuses a removal that is not one of these, whatever plan it is handed.
    static func removableLocations(for roots: UninstallRoots) throws -> [URL] {
        let places = try Places(roots)
        let children = dataFolderChildren.map { UninstallPathPolicy.child(of: places.support, $0.name) }
        guard !places.isTestRun else { return children }
        let speech = roots.speechModelFolderNames.filter(isPlainFolderName)
            .map { UninstallPathPolicy.child(of: places.speechModels, $0) }
        let library = libraryItems(for: roots.bundleIdentifier)
            .map { UninstallPathPolicy.child(of: places.library, $0.path) }
        return [places.support] + children + speech + library
    }

    public static func plan(
        for roots: UninstallRoots, resolving: @escaping (URL) -> URL = { $0 }
    ) throws -> UninstallPlan {
        let places = try Places(roots)
        var builder = Builder(export: UninstallPathPolicy.plain(roots.exportDirectory), resolving: resolving)
        builder.add(.stopActivity, .activity, "Stop recording, imports, downloads and the models")
        if places.isTestRun {
            return testRunPlan(roots, places, builder)
        }
        builder.add(.signOut, .signIn, "Sign out on this Mac")
        builder.add(.unregisterLoginItem, .settings, "Open at login")
        builder.add(.clearNotifications, .settings, "Hushy's notifications")
        for service in UninstallPlan.keychainServices where service != KeychainKeyStore.encryptionService {
            builder.add(.deleteKeychainItems(service: service), .signIn, "Saved keys")
        }
        addDataFolder(places.support, wholeFolder: true, to: &builder)
        addEncryptionKey(to: &builder)
        addSpeechModels(roots, in: places.speechModels, to: &builder)
        addLibraryItems(for: roots.bundleIdentifier, in: places.library, to: &builder)
        if let bundle = roots.bundleURL.map(UninstallPathPolicy.plain), bundle.pathExtension == "app" {
            builder.add(.moveAppToTrash(bundle), .app, "The Hushy app")
        }
        addPermissions(roots, to: &builder)
        return UninstallPlan(
            roots: roots, allowedRoots: [UninstallAllowedRoot(url: places.library, minimumDepth: 2)],
            steps: builder.steps, kept: builder.allKept, requiredDataMarker: nil, isTestRun: false)
    }

    /// A test run touches nothing but the named files in its own data folder: no Keychain, no
    /// sign-out, no login item, nothing in the home Library, no Trash.
    private static func testRunPlan(_ roots: UninstallRoots, _ places: Places, _ start: Builder) -> UninstallPlan {
        var builder = start
        addDataFolder(places.support, wholeFolder: false, to: &builder)
        return UninstallPlan(
            roots: roots, allowedRoots: [UninstallAllowedRoot(url: places.support, minimumDepth: 1)],
            steps: builder.steps, kept: builder.allKept,
            requiredDataMarker: UninstallPathPolicy.child(of: places.support, dataMarkerName), isTestRun: true)
    }

    /// The folders a plan is built in, checked: a home that is a person's folder, an identifier
    /// that cannot be a path, and a data folder that is not the home folder or above it.
    private struct Places {
        let library: URL
        let support: URL
        let speechModels: URL
        /// The data folder was chosen by an environment override, or the run is a snapshot, test
        /// or mock-microphone run. Anything but `~/Library/Application Support/Hushy` counts too.
        let isTestRun: Bool

        init(_ roots: UninstallRoots) throws {
            let home = UninstallPathPolicy.plain(roots.home)
            guard roots.home.isFileURL, UninstallPathPolicy.components(home).count >= 2 else {
                throw UninstallRefusal.unusableHome(roots.home.path)
            }
            guard UninstallPlanner.isBundleIdentifier(roots.bundleIdentifier) else {
                throw UninstallRefusal.invalidBundleIdentifier(roots.bundleIdentifier)
            }
            let library = UninstallPathPolicy.child(of: home, "Library")
            let applicationSupport = UninstallPathPolicy.child(of: library, "Application Support")
            let support = UninstallPathPolicy.plain(roots.supportDirectory)
            let refused = [home, library, applicationSupport]
            guard roots.supportDirectory.isFileURL, UninstallPathPolicy.components(support).count >= 2,
                  !refused.contains(where: { UninstallPathPolicy.isSame($0, support) }),
                  !UninstallPathPolicy.isInside(home, support)
            else { throw UninstallRefusal.unusableDataFolder(roots.supportDirectory.path) }
            let standard = UninstallPathPolicy.child(of: applicationSupport, AppPaths.appName)
            let isStandardFolder = !roots.supportIsOverridden && UninstallPathPolicy.isSame(support, standard)
            // A test run on the real data folder has nothing of its own to remove.
            if roots.isTestRun, isStandardFolder { throw UninstallRefusal.testRunWithoutItsOwnFolder }
            self.library = library
            self.support = support
            speechModels = UninstallPlanner.speechModelsFolder(inHome: home)
            isTestRun = roots.isTestRun || !isStandardFolder
        }
    }

    /// The data folder goes whole only when asked and the export folder is not inside it.
    /// Otherwise the app's own files in it go one by one, then the folder if it is empty.
    private static func addDataFolder(_ support: URL, wholeFolder: Bool, to builder: inout Builder) {
        let title = "History, notes, recordings and writing models"
        switch builder.relation(of: support) {
        case .same, .insideExport:
            builder.keep(title, location: support.path, reason: .insideExportFolder)
            builder.keepsRecordings = true
            return
        case .apart where wholeFolder:
            builder.remove(support, .data, title)
            return
        case .apart, .holdsExport:
            break
        }
        for child in dataFolderChildren {
            builder.remove(UninstallPathPolicy.child(of: support, child.name), child.group, child.title)
        }
        // A data folder that holds the export folder can never be empty, so it is not tried.
        guard builder.relation(of: support) == .apart else { return }
        builder.add(.removeFolderIfEmpty(UninstallPathPolicy.plain(support)), .data, "The data folder, once empty")
    }

    /// The recording-encryption key (`EncryptionKeyManager`) goes after the recordings, and only
    /// if they went. When the plan already keeps recordings, the key is kept with them.
    private static func addEncryptionKey(to builder: inout Builder) {
        let service = KeychainKeyStore.encryptionService
        let step = UninstallStep(
            .deleteKeychainItems(service: service), .signIn, "Recording encryption key", onlyAfterDataRemoved: true)
        if builder.keepsRecordings {
            builder.keep(step.title, location: step.location, reason: .recordingsStay)
        } else {
            builder.steps.append(step)
        }
    }

    /// The speech models this build uses (`SpeechEngine`, `SpeakerDiarizer`), each by its own
    /// folder name. The speech engine's folder itself is never removed, and the person can
    /// choose to leave the models: other apps built on the same engine may share them.
    private static func addSpeechModels(_ roots: UninstallRoots, in folder: URL, to builder: inout Builder) {
        var seen = Set<String>()
        for name in roots.speechModelFolderNames where seen.insert(name).inserted {
            // A model outside the folder comes named by its whole path.
            let location = name.hasPrefix("/") ? name : folder.path + "/" + name
            if !isPlainFolderName(name) {
                builder.keep("Speech model", location: location, reason: .notAPlainFolderName)
            } else if !roots.removesSpeechModels {
                builder.keep("Speech model", location: location, reason: .speechModelsLeftByChoice)
            } else {
                builder.remove(UninstallPathPolicy.child(of: folder, name), .speechModels, "Speech model")
            }
        }
    }

    /// The last step: macOS forgets the Microphone, Accessibility and every other permission it
    /// holds for Hushy. Only for Hushy's own identifier, and unless the person leaves them.
    private static func addPermissions(_ roots: UninstallRoots, to builder: inout Builder) {
        guard roots.bundleIdentifier == UninstallPlan.permissionsBundleIdentifier else { return }
        let title = "Permissions (Microphone, Accessibility and the rest)"
        let action = UninstallStep.Action.resetPermissions(bundleIdentifier: UninstallPlan.permissionsBundleIdentifier)
        if roots.resetsPermissions {
            builder.add(action, .settings, title)
        } else {
            builder.keep(title, location: UninstallStep(action, .settings, title).location, reason: .permissionsLeftByChoice)
        }
    }

    /// What macOS and the app keep under the app's identifier in the home Library.
    private static func addLibraryItems(for id: String, in library: URL, to builder: inout Builder) {
        let items = libraryItems(for: id)
        for item in items where item.group == .caches {
            builder.remove(UninstallPathPolicy.child(of: library, item.path), item.group, item.title)
        }
        builder.add(.clearDefaults(domain: id), .settings, "Settings")
        for item in items where item.group == .settings {
            builder.remove(UninstallPathPolicy.child(of: library, item.path), item.group, item.title)
        }
    }

    /// Reverse-DNS letters, digits and hyphens, in at least two parts: never a path.
    static func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
            }
        }
    }

    /// One folder name: no separator, not `.` or `..`, only the characters model folders use.
    static func isPlainFolderName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    /// Collects steps, and turns any removal that touches the export folder into something kept.
    private struct Builder {
        let export: URL
        let resolving: (URL) -> URL
        var steps: [UninstallStep] = []
        var kept: [UninstallKept] = []
        /// True once history or recordings are being kept, so their encryption key is kept too.
        var keepsRecordings = false

        var allKept: [UninstallKept] {
            [UninstallKept(title: "Your export folder", location: export.path, reason: .exportFolder)] + kept
        }

        func relation(of url: URL) -> UninstallPathPolicy.ExportRelation {
            UninstallPathPolicy.relation(of: url, toExport: export, resolving: resolving)
        }

        mutating func add(_ action: UninstallStep.Action, _ group: UninstallStep.Group, _ title: String) {
            steps.append(UninstallStep(action, group, title))
        }

        mutating func keep(_ title: String, location: String, reason: UninstallKept.Reason) {
            kept.append(UninstallKept(title: title, location: location, reason: reason))
        }

        mutating func remove(_ url: URL, _ group: UninstallStep.Group, _ title: String) {
            switch relation(of: url) {
            case .apart:
                add(.removeItem(UninstallPathPolicy.plain(url)), group, title)
                return
            case .same, .insideExport: keep(title, location: url.path, reason: .insideExportFolder)
            case .holdsExport: keep(title, location: url.path, reason: .holdsExportFolder)
            }
            if group == .data { keepsRecordings = true }
        }
    }
}
