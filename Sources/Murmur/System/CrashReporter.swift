import Foundation
import MetricKit
import MurmurCore

protocol CrashReportTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Int
}

struct URLSessionCrashReportTransport: CrashReportTransport {
    func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 500
    }
}

@MainActor
protocol CrashReporter: AnyObject {
    func start()
    func settingChanged(_ enabled: Bool)
}

/// MetricKit delivers once the system has prepared a diagnostic. Only scrubbed JSON reaches disk.
@MainActor
final class MetricKitCrashReporter: NSObject, CrashReporter, MXMetricManagerSubscriber {
    static let endpoint = URL(string: "https://tryhushy.com/api/crash")!
    private let settings: AppSettings
    private let directory: URL?
    private let transport: any CrashReportTransport
    private let now: () -> Date
    private let retryDelay: @Sendable (Duration) async throws -> Void
    private var sending: Task<Void, Never>?
    private var started = false

    init(settings: AppSettings, directory: URL?, now: @escaping () -> Date = Date.init,
         transport: any CrashReportTransport = URLSessionCrashReportTransport(),
         retryDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.settings = settings
        self.directory = directory
        self.now = now
        self.transport = transport
        self.retryDelay = retryDelay
        super.init()
        settings.onCrashSwitchChange = { [weak self] enabled in self?.settingChanged(enabled) }
        if !settings.shareCrashReports { clearQueue() }
    }

    func start() {
        guard !started, directory != nil else { return }
        started = true
        MXMetricManager.shared.add(self)
        flush()
    }

    func settingChanged(_ enabled: Bool) {
        if enabled { flush() }
        else {
            sending?.cancel()
            sending = nil
            clearQueue()
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Copy out only the typed fields we send; the payload objects go no further.
        let batches = payloads.map { payload in (payload.crashDiagnostics ?? []).map(Self.input) }.filter { !$0.isEmpty }
        Task { @MainActor [weak self] in batches.forEach { self?.accept($0) } }
    }

    private nonisolated static func input(_ crash: MXCrashDiagnostic) -> CrashInput {
        CrashInput(exceptionType: crash.exceptionType?.stringValue, exceptionCode: crash.exceptionCode?.stringValue,
                   signal: crash.signal?.stringValue, terminationReason: crash.terminationReason,
                   stackTree: crash.callStackTree.jsonRepresentation(), build: crash.metaData.applicationBuildVersion,
                   os: crash.metaData.osVersion, arch: crash.metaData.platformArchitecture)
    }

    /// Internal test seam; it is also the only entry from MetricKit to the queue.
    func accept(_ crashes: [CrashInput]) {
        let info = Bundle.main.infoDictionary
        guard settings.shareCrashReports, settings.crashConsentVersion == AppSettings.currentCrashConsentVersion,
              let directory, let body = CrashReportScrubber.report(
                  from: crashes, appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                  fallbackBuild: info?["CFBundleVersion"] as? String ?? "unknown", chip: Self.chip),
              body.count <= 64 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(Int(now().timeIntervalSince1970))-\(UUID().uuidString).json")
            try body.write(to: file, options: .atomic)
            flush()
        } catch { return }
    }

    private func clearQueue() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func queuedFiles() -> [URL] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let cutoff = now().timeIntervalSince1970 - 7 * 86_400
        return files.filter { file in
            guard file.pathExtension == "json" else { return false }
            guard let seconds = TimeInterval(file.lastPathComponent.split(separator: "-").first ?? "") else {
                try? FileManager.default.removeItem(at: file)
                return false
            }
            if seconds < cutoff { try? FileManager.default.removeItem(at: file); return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func flush() {
        guard started, settings.shareCrashReports, settings.crashConsentVersion == AppSettings.currentCrashConsentVersion,
              sending == nil else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            await self.sendQueued()
        }
    }

    /// Kept internal so tests can drain the queue deterministically with an injected transport.
    func sendQueued() async {
        defer { sending = nil }
        var failures = 0
        while !Task.isCancelled {
            guard let file = queuedFiles().first else { return }
            guard !Task.isCancelled, settings.shareCrashReports,
                  settings.crashConsentVersion == AppSettings.currentCrashConsentVersion,
                  let body = try? Data(contentsOf: file) else { return }
            if body.count > 64 * 1024 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let status = try await transport.send(request)
                guard !Task.isCancelled, settings.shareCrashReports else { break }
                if status == 204 || status == 400 || status == 413 {
                    try? FileManager.default.removeItem(at: file)
                    failures = 0
                    continue
                }
            } catch { /* Retry transient transport errors. */ }
            failures += 1
            let seconds = min(3_600, 5 * (1 << min(failures - 1, 9)))
            do { try await retryDelay(.seconds(seconds)) } catch { return }
        }
    }

    private static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes).prefix(200).description
    }
}
