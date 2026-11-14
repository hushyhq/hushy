import Foundation

/// One thing Hushy downloads once and keeps: the speech model today; the vocabulary model when
/// the Dictionary has words; the MLX cleanup model (~1 GB, `MODEL-STRATEGY.md` M4/M5) and
/// profession packs later. The queue treats them uniformly, so a new model is a new entry, not
/// a new code path.
public struct DownloadableAsset: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case speechModel, vocabularyModel, cleanupModel, professionPack
    }

    /// Required assets gate dictation and start at launch; optional ones start only after every
    /// required asset is ready and never block onboarding (Apple FM / rules cover cleanup until
    /// a cleanup model lands).
    public enum Importance: Int, Comparable, Codable, Sendable {
        case required = 0, recommended = 1, optional = 2

        public static func < (lhs: Importance, rhs: Importance) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Whether an optional asset starts by itself once the required ones are done, or waits
    /// until the user accepts an offer (M5: "Faster cleanup on this Mac — one-time 1.2 GB").
    public enum StartPolicy: String, Codable, Sendable {
        case automatic, whenAccepted
    }

    /// One file of a managed asset: where it comes from, where it goes (relative to the asset's
    /// directory), its exact size and SHA-256. `AssetDownloader` resumes it with HTTP ranges and
    /// refuses to keep it unless the hash matches.
    public struct File: Equatable, Sendable {
        public let remoteURL: URL
        public let relativePath: String
        public let bytes: Int64
        public let sha256: String

        public init(remoteURL: URL, relativePath: String, bytes: Int64, sha256: String) {
            self.remoteURL = remoteURL
            self.relativePath = relativePath
            self.bytes = bytes
            self.sha256 = sha256.lowercased()
        }
    }

    public enum Source: Equatable, Sendable {
        /// Files Hushy downloads itself (`AssetDownloader`: range resume, SHA-256, backoff).
        case files([File])
        /// Fetched by a framework that owns its own cache (FluidAudio for Parakeet): resume and
        /// retries are the framework's; Hushy verifies checksums after (see
        /// `ChecksumManifest`) and adds the outer retry/backoff and pacing.
        case external
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let importance: Importance
    public let startPolicy: StartPolicy
    /// Total download size (exact for `.files`, measured on-disk size for `.external`).
    public let expectedBytes: Int64
    /// The RAM tier rule (M5): not offered on Macs with less memory than this. nil = any Mac.
    public let minimumMemoryGB: Int?
    public let source: Source

    public init(
        id: String, title: String, kind: Kind, importance: Importance, startPolicy: StartPolicy = .automatic,
        expectedBytes: Int64, minimumMemoryGB: Int? = nil, source: Source
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.importance = importance
        self.startPolicy = importance == .required ? .automatic : startPolicy
        self.expectedBytes = expectedBytes
        self.minimumMemoryGB = minimumMemoryGB
        self.source = source
    }

    public func isEligible(physicalMemoryGB: Int) -> Bool {
        guard let minimumMemoryGB else { return true }
        return physicalMemoryGB >= minimumMemoryGB
    }
}

/// The download queue as a value: each asset's progress and state, the order they run in
/// (required first, in registration order; optional after *every* required asset is ready),
/// and time-remaining estimates for the required set and for everything queued.
public struct AssetQueue: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case queued
        /// Optional asset waiting for the user to accept its offer.
        case offered
        case downloading
        /// Stopped with its partial bytes kept (metered network, offline, user pause).
        case paused
        case ready
        case failed(String)
    }

    public struct Entry: Equatable, Sendable {
        public let asset: DownloadableAsset
        public var state: State
        public var receivedBytes: Int64

        public var remainingBytes: Int64 {
            state == .ready ? 0 : max(0, asset.expectedBytes - receivedBytes)
        }
    }

    public private(set) var entries: [Entry]

    /// Assets not eligible on this Mac (RAM tier) are left out entirely.
    public init(assets: [DownloadableAsset], physicalMemoryGB: Int = 16) {
        entries = assets.filter { $0.isEligible(physicalMemoryGB: physicalMemoryGB) }.map {
            Entry(asset: $0, state: $0.startPolicy == .whenAccepted ? .offered : .queued, receivedBytes: 0)
        }
    }

    public subscript(id: String) -> Entry? { entries.first { $0.asset.id == id } }

    public var requiredReady: Bool {
        entries.filter { $0.asset.importance == .required }.allSatisfy { $0.state == .ready }
    }

    /// The next asset that may start now: a queued required asset first; optional ones only
    /// once every required asset is ready. nil while something is already downloading.
    public var nextToStart: DownloadableAsset? {
        guard !entries.contains(where: { $0.state == .downloading }) else { return nil }
        if let required = entries.first(where: { $0.asset.importance == .required && $0.state == .queued }) {
            return required.asset
        }
        guard requiredReady else { return nil }
        return entries.filter { $0.asset.importance != .required && $0.state == .queued }
            .min { $0.asset.importance < $1.asset.importance }?.asset
    }

    public func updating(_ id: String, state: State? = nil, receivedBytes: Int64? = nil) -> AssetQueue {
        var next = self
        guard let index = next.entries.firstIndex(where: { $0.asset.id == id }) else { return self }
        if let state { next.entries[index].state = state }
        if let receivedBytes { next.entries[index].receivedBytes = max(0, receivedBytes) }
        if state == .ready { next.entries[index].receivedBytes = next.entries[index].asset.expectedBytes }
        return next
    }

    /// Adds an asset if it isn't already queued (e.g. the vocabulary model once the Dictionary
    /// gains a word).
    public func adding(_ asset: DownloadableAsset, physicalMemoryGB: Int = 16) -> AssetQueue {
        guard self[asset.id] == nil, asset.isEligible(physicalMemoryGB: physicalMemoryGB) else { return self }
        var next = self
        next.entries.append(Entry(asset: asset, state: asset.startPolicy == .whenAccepted ? .offered : .queued, receivedBytes: 0))
        return next
    }

    /// Drops an asset from the queue (the user deleted the cleanup model or switched to another).
    public func removing(_ id: String) -> AssetQueue {
        var next = self
        next.entries.removeAll { $0.asset.id == id }
        return next
    }

    public var requiredRemainingBytes: Int64 {
        entries.filter { $0.asset.importance == .required }.reduce(0) { $0 + $1.remainingBytes }
    }

    /// Everything that will download without further input (offers not yet accepted excluded).
    public var queuedRemainingBytes: Int64 {
        entries.filter { $0.state != .offered }.reduce(0) { $0 + $1.remainingBytes }
    }

    /// Seconds until the required assets are ready at `bytesPerSecond`; 0 when they are.
    public func requiredSecondsRemaining(bytesPerSecond: Double?) -> TimeInterval? {
        Self.seconds(requiredRemainingBytes, at: bytesPerSecond)
    }

    /// Seconds until every queued asset is done — assets download one at a time, so this is
    /// simply all remaining bytes over the measured rate.
    public func allSecondsRemaining(bytesPerSecond: Double?) -> TimeInterval? {
        Self.seconds(queuedRemainingBytes, at: bytesPerSecond)
    }

    private static func seconds(_ bytes: Int64, at rate: Double?) -> TimeInterval? {
        guard bytes > 0 else { return 0 }
        guard let rate, rate > 1 else { return nil }
        return min(Double(bytes) / rate, ThroughputMeter.maximumSeconds)
    }
}
