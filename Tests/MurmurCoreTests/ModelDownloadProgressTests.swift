import Foundation
import Testing
@testable import MurmurCore

@Suite("Model download progress")
struct ModelDownloadProgressTests {
    private let expected: Int64 = 465_000_000

    @Test("formats bytes, percent and file counts")
    func formatting() {
        let progress = ModelDownloadProgress(
            fraction: 0.42, expectedBytes: expected, completedFiles: 1, totalFiles: 4, estimatedSecondsRemaining: 38)
        #expect(progress.percent == 42)
        #expect(progress.percentText == "42%")
        #expect(progress.estimatedBytes == 195_300_000)
        #expect(progress.bytesText == "195 MB of about 465 MB")
        #expect(progress.filesText == "1 of 4 files")
        #expect(progress.remainingText == "about 40 s left")
        #expect(progress.summaryLine == "Downloading speech model · 42% · about 40 s left")
    }

    @Test("says estimating before a rate exists and hides files when unknown")
    func beforeEstimate() {
        let progress = ModelDownloadProgress(fraction: 0.01, expectedBytes: expected)
        #expect(progress.remainingText == "estimating time left…")
        #expect(progress.filesText == nil)
        #expect(progress.bytesText == "4.7 MB of about 465 MB")
    }

    @Test("clamps the fraction")
    func clamps() {
        #expect(ModelDownloadProgress(fraction: 1.7, expectedBytes: expected).percent == 100)
        #expect(ModelDownloadProgress(fraction: -1, expectedBytes: expected).estimatedBytes == 0)
    }

    @Test("byte formatting picks a sensible unit")
    func bytes() {
        #expect(ModelDownloadProgress.formatBytes(0) == "0.0 MB")
        #expect(ModelDownloadProgress.formatBytes(9_500_000) == "9.5 MB")
        #expect(ModelDownloadProgress.formatBytes(465_000_000) == "465 MB")
        #expect(ModelDownloadProgress.formatBytes(2_500_000_000) == "2.50 GB")
    }

    @Test("time remaining is coarse")
    func remaining() {
        #expect(ModelDownloadProgress.formatRemaining(3) == "10 s")
        #expect(ModelDownloadProgress.formatRemaining(37) == "40 s")
        #expect(ModelDownloadProgress.formatRemaining(61) == "2 min")
        #expect(ModelDownloadProgress.formatRemaining(60) == "1 min")
        #expect(ModelDownloadProgress.formatRemaining(600) == "10 min")
    }
}

@Suite("Download rate estimator")
struct DownloadRateEstimatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let expected: Int64 = 400_000_000

    @Test("offers no estimate until the minimum span of samples exists")
    func waitsForSpan() {
        let estimator = DownloadRateEstimator(expectedBytes: expected)
            .observing(fraction: 0, at: t0)
            .observing(fraction: 0.05, at: t0.addingTimeInterval(1))
        #expect(estimator.bytesPerSecond == nil)
        #expect(estimator.estimatedSecondsRemaining == nil)
    }

    @Test("estimates remaining time from the observed rate")
    func estimates() throws {
        // 10% of 400 MB in 4 s = 10 MB/s; 90% (360 MB) remains → 36 s.
        let estimator = DownloadRateEstimator(expectedBytes: expected)
            .observing(fraction: 0, at: t0)
            .observing(fraction: 0.05, at: t0.addingTimeInterval(2))
            .observing(fraction: 0.10, at: t0.addingTimeInterval(4))
        let rate = try #require(estimator.bytesPerSecond)
        #expect(abs(rate - 10_000_000) < 1)
        let remaining = try #require(estimator.estimatedSecondsRemaining)
        #expect(abs(remaining - 36) < 0.01)
    }

    @Test("uses a sliding window so a ramp-up does not drag the estimate")
    func slidingWindow() throws {
        var estimator = DownloadRateEstimator(expectedBytes: expected, window: 4)
            .observing(fraction: 0, at: t0)
        // Slow first 10 s (1%/s), then fast (5%/s).
        for second in 1...10 {
            estimator = estimator.observing(fraction: Double(second) * 0.01, at: t0.addingTimeInterval(Double(second)))
        }
        for second in 11...16 {
            let fraction = 0.10 + Double(second - 10) * 0.05
            estimator = estimator.observing(fraction: fraction, at: t0.addingTimeInterval(Double(second)))
        }
        let rate = try #require(estimator.bytesPerSecond)
        // Window covers only the fast phase: 5% of 400 MB per second = 20 MB/s.
        #expect(abs(rate - 20_000_000) < 1)
        #expect(estimator.samples.count <= 5)
    }

    @Test("a stalled download yields no rate rather than infinity")
    func stalled() {
        let estimator = DownloadRateEstimator(expectedBytes: expected)
            .observing(fraction: 0.3, at: t0)
            .observing(fraction: 0.3, at: t0.addingTimeInterval(5))
        #expect(estimator.bytesPerSecond == nil)
        #expect(estimator.estimatedSecondsRemaining == nil)
    }

    @Test("observing never mutates the original")
    func immutable() {
        let original = DownloadRateEstimator(expectedBytes: expected).observing(fraction: 0, at: t0)
        _ = original.observing(fraction: 0.5, at: t0.addingTimeInterval(3))
        #expect(original.samples.count == 1)
    }
}
