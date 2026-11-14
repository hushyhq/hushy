import Foundation

/// Pure scoring helpers for `murmur-eval judge calibrate`: bad-output detection (precision /
/// recall with "bad" as the positive class), probability calibration (reliability bins, ECE,
/// Brier) and ranking quality (AUC). Unit-tested in `JudgeCalibrationTests`.
enum CalibrationMetrics {
    struct Detection: Equatable {
        var truePositive = 0, falsePositive = 0, trueNegative = 0, falseNegative = 0

        init(labelsBad: [Bool], predictedBad: [Bool]) {
            for (label, predicted) in zip(labelsBad, predictedBad) {
                switch (label, predicted) {
                case (true, true): truePositive += 1
                case (false, true): falsePositive += 1
                case (false, false): trueNegative += 1
                case (true, false): falseNegative += 1
                }
            }
        }

        var count: Int { truePositive + falsePositive + trueNegative + falseNegative }
        var accuracy: Double { ratio(truePositive + trueNegative, count) }
        var precision: Double { ratio(truePositive, truePositive + falsePositive) }
        var recall: Double { ratio(truePositive, truePositive + falseNegative) }
        /// Share of good outputs wrongly flagged bad.
        var falsePositiveRate: Double { ratio(falsePositive, falsePositive + trueNegative) }
        var f1: Double {
            let p = precision, r = recall
            return p + r == 0 ? 0 : 2 * p * r / (p + r)
        }
    }

    struct Bin: Equatable {
        let lower: Double
        let upper: Double
        let count: Int
        let meanPredicted: Double
        let observedRate: Double
    }

    /// Equal-width reliability bins over [0, 1]; empty bins are omitted.
    static func reliability(probabilities: [Double], labels: [Bool], bins: Int = 5) -> [Bin] {
        (0..<bins).compactMap { index in
            let lower = Double(index) / Double(bins)
            let upper = Double(index + 1) / Double(bins)
            let members = zip(probabilities, labels).filter { p, _ in
                p >= lower && (index == bins - 1 ? p <= upper : p < upper)
            }
            guard !members.isEmpty else { return nil }
            let mean = members.map(\.0).reduce(0, +) / Double(members.count)
            let observed = Double(members.filter(\.1).count) / Double(members.count)
            return Bin(lower: lower, upper: upper, count: members.count, meanPredicted: mean, observedRate: observed)
        }
    }

    /// Expected calibration error: count-weighted |mean predicted − observed| over the bins.
    static func expectedCalibrationError(probabilities: [Double], labels: [Bool], bins: Int = 5) -> Double {
        let total = Double(probabilities.count)
        guard total > 0 else { return 0 }
        return reliability(probabilities: probabilities, labels: labels, bins: bins)
            .reduce(0) { $0 + Double($1.count) / total * abs($1.meanPredicted - $1.observedRate) }
    }

    static func brier(probabilities: [Double], labels: [Bool]) -> Double {
        guard !probabilities.isEmpty else { return 0 }
        return zip(probabilities, labels).reduce(0) { $0 + pow($1.0 - ($1.1 ? 1 : 0), 2) } / Double(probabilities.count)
    }

    /// Probability a random positive outranks a random negative (ties count half). 0.5 when a
    /// class is empty.
    static func auc(scores: [Double], labels: [Bool]) -> Double {
        let positives = zip(scores, labels).filter(\.1).map(\.0)
        let negatives = zip(scores, labels).filter { !$0.1 }.map(\.0)
        guard !positives.isEmpty, !negatives.isEmpty else { return 0.5 }
        var wins = 0.0
        for p in positives {
            for n in negatives { wins += p > n ? 1 : (p == n ? 0.5 : 0) }
        }
        return wins / Double(positives.count * negatives.count)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}
