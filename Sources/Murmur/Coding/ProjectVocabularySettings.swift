import Foundation
import MurmurCore
import Observation
import os

/// Owns the optional project folder for the "Coding" settings card: the security-scoped
/// bookmark, the background scan, and the resulting `ProjectVocabulary` that `AppSettings`'s
/// cleanup pipeline reads for a code-context dictation (see `CleanupOptions.projectVocabulary`).
///
/// A security-scoped bookmark (rather than the plain resolved path `FileTranscriber` uses for a
/// one-time file read) is the right tool here: the user picks the folder once and the app needs
/// to re-scan it across launches, which is exactly the "repeated, indefinite access to a
/// user-picked location" case bookmarks exist for.
@MainActor
@Observable
final class ProjectVocabularySettings {
    enum ScanState: Equatable {
        case idle
        case scanning
        case done(filesScanned: Int, identifiers: Int, fileNames: Int)
        case failed(String)
    }

    private(set) var projectName: String?
    private(set) var scanState: ScanState = .idle
    private(set) var vocabulary: ProjectVocabulary? {
        didSet { onVocabularyChange?(vocabulary) }
    }
    /// Called on the main actor whenever `vocabulary` changes (scan completes, project removed).
    /// `AppModel` uses this to push the result into `DictationController.projectVocabulary`
    /// without `DictationController` needing to observe this `@Observable` type directly.
    @ObservationIgnored var onVocabularyChange: ((ProjectVocabulary?) -> Void)?

    private let defaults: UserDefaults
    private let bookmarkKey = "codingProjectBookmark"
    private let log = Logger(subsystem: "app.hushy", category: "project-vocabulary")
    private var scanTask: Task<Void, Never>?
    private var accessedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let bookmark = defaults.data(forKey: bookmarkKey) {
            resolveAndScan(bookmark: bookmark)
        }
    }

    /// Presents the Open panel for choosing a project folder, stores a security-scoped bookmark
    /// to it, and kicks off a scan. Called from the "Coding" card's "Choose folder…" button.
    func chooseFolder(present: () -> URL?) {
        guard let url = present() else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: bookmarkKey)
            resolveAndScan(bookmark: bookmark)
        } catch {
            log.error("failed to create bookmark: \(error.localizedDescription)")
            scanState = .failed("Couldn't access that folder.")
        }
    }

    /// Removes the project: clears the bookmark and any scanned vocabulary, so cleanup falls
    /// back to no project boosting/tagging.
    func removeProject() {
        scanTask?.cancel()
        stopAccessingIfNeeded()
        defaults.removeObject(forKey: bookmarkKey)
        projectName = nil
        vocabulary = nil
        scanState = .idle
    }

    /// Snapshot-only: shows a project in a given scan state without touching a folder or the defaults.
    func pinForSnapshot(projectName: String?, scanState: ScanState) {
        scanTask?.cancel()
        self.projectName = projectName
        self.scanState = scanState
    }

    /// Re-runs the scan against the already-chosen folder (e.g. a "Rescan" button after the
    /// project changed on disk).
    func rescan() {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        resolveAndScan(bookmark: bookmark)
    }

    private func resolveAndScan(bookmark: Data) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else {
            scanState = .failed("Couldn't reopen that folder. Choose it again.")
            return
        }
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            defaults.set(refreshed, forKey: bookmarkKey)
        }

        stopAccessingIfNeeded()
        guard url.startAccessingSecurityScopedResource() else {
            scanState = .failed("Couldn't access that folder. Choose it again.")
            return
        }
        accessedURL = url
        projectName = url.lastPathComponent
        scanState = .scanning

        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let result = ProjectVocabularyScanner.scan(root: url)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.vocabulary = result.vocabulary
                self.scanState = .done(
                    filesScanned: result.filesScanned,
                    identifiers: result.vocabulary.identifiers.count,
                    fileNames: result.vocabulary.fileNames.count)
            }
        }
    }

    private func stopAccessingIfNeeded() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    // No deinit: `accessedURL` is `@MainActor`-isolated (the whole type is `@MainActor`), and a
    // deinit body runs nonisolated in Swift 6, so it cannot touch it directly. This type lives
    // for the app's lifetime as `AppModel.codingProjectVocabulary`, so the access grant is
    // released when the process exits — the same lifetime `AppModel` itself already assumes for
    // its other long-lived services (`Store`, `SpeechEngine`, …).
}
