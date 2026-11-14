import Foundation
import MurmurCore
import Observation
import UniformTypeIdentifiers

/// Runs a batch of imported audio/video files through `FileTranscriber` sequentially — one file
/// transcribing at a time, queued in drop order — so a folder of imports doesn't contend with
/// itself for CPU/Neural-Engine time the way running them all concurrently would. The Notes list
/// shows every queued file's progress via `items`; a finished item is removed once its note is
/// visible in the list (the note itself, not this queue, is the durable record from then on).
@MainActor
@Observable
final class ImportQueue {
    /// File extensions this feature accepts, matching the spec's supported formats. Checked
    /// case-insensitively against a dropped/opened file's extension.
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4", "mov", "m4v"]

    static let supportedContentTypes: [UTType] = [
        .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie, .audio, .movie,
    ]

    private(set) var items: [FileTranscriber] = []

    @ObservationIgnored private let makeTranscriber: (URL) -> FileTranscriber
    @ObservationIgnored private var runner: Task<Void, Never>?

    init(makeTranscriber: @escaping (URL) -> FileTranscriber) {
        self.makeTranscriber = makeTranscriber
    }

    /// Filters `urls` down to supported media files (by extension) and appends them to the
    /// queue in order. Unsupported files are silently skipped — the caller (drop handler / open
    /// panel) is responsible for telling the user if that leaves nothing to import.
    @discardableResult
    func enqueue(_ urls: [URL]) -> Int {
        let accepted = Self.supported(urls)
        guard !accepted.isEmpty else { return 0 }
        items += accepted.map(makeTranscriber)
        runNext()
        return accepted.count
    }

    /// The subset of `urls` this feature can transcribe, in order — what `enqueue` would accept.
    /// Exposed so `AppModel.importFiles` can return the supported-file count. Imports are notes,
    /// not call-detected meetings.
    static func supported(_ urls: [URL]) -> [URL] {
        urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    func cancel(_ item: FileTranscriber) {
        item.cancel()
    }

    /// Uninstall: drops every file still waiting, cancels the one being transcribed, and returns
    /// once nothing is running, so no import writes a recording afterwards.
    func stopAll() async {
        items.removeAll { if case .idle = $0.state { return true } else { return false } }
        items.forEach { $0.cancel() }
        await runner?.value
        while items.contains(where: \.isRunning) {
            try? await Task.sleep(for: Self.stopPoll)
        }
    }

    /// True while a file is being decoded or transcribed, or is waiting its turn.
    var isBusy: Bool {
        items.contains { item in
            if case .idle = item.state { return true }
            return item.isRunning
        }
    }

    private static let stopPoll: Duration = .milliseconds(100)

    /// Removes a finished (done/failed/cancelled) item from the visible queue. The app calls
    /// this once the user has seen the result (e.g. the note appears selected in Notes) or
    /// explicitly dismisses it; done/failed items are not auto-removed so a batch's outcomes
    /// stay visible until acknowledged.
    func dismiss(_ item: FileTranscriber) {
        items.removeAll { $0 === item }
    }

    private func runNext() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self {
                guard let next = self.nextPending() else { break }
                next.start()
                _ = await self.waitUntilFinished(next)
            }
            self?.runner = nil
        }
    }

    private func nextPending() -> FileTranscriber? {
        items.first { if case .idle = $0.state { return true } else { return false } }
    }

    /// Polls (cheaply — `@Observable` state changes are infrequent here, at most a few times a
    /// second during decoding) until `item` leaves its running states, so the queue can move on
    /// to the next file. A `withObservationTracking` continuation would be more elegant, but this
    /// stays simple and correct for what is at most a handful of queued files.
    private func waitUntilFinished(_ item: FileTranscriber) async -> FileTranscriber.State {
        while item.isRunning {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return item.state
    }
}
