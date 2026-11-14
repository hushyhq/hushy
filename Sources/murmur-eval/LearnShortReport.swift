import Foundation
import MurmurCore

extension LearnRunner {
    static func reportShort(_ results: [ShortModeResult]) {
        print("")
        print("### Learn from corrections · short dictations (1-2 words)")
        print("")
        print("| Metric | " + results.map(\.mode.rawValue).joined(separator: " | ") + " |")
        print("|---|" + results.map { _ in "---|" }.joined())
        func row(_ label: String, _ value: (ShortModeResult) -> String) {
            print("| \(label) | " + results.map(value).joined(separator: " | ") + " |")
        }
        func learnable(_ result: ShortModeResult) -> [ShortTermResult] { result.terms.filter(\.term.learnable) }
        row("Before: fixes captured by the single-read path") { r in
            "\(r.terms.map(\.legacyCaptures).reduce(0, +))/\(r.terms.map(\.attempts).reduce(0, +))"
        }
        row("After: learnable terms in use") { r in
            "\(learnable(r).filter { $0.fixesToLearn != nil }.count)/\(learnable(r).count)"
        }
        row("After: fixes before in use, mean / max") { r in
            let counts = learnable(r).compactMap(\.fixesToLearn)
            guard !counts.isEmpty else { return "n/a" }
            return String(format: "%.2f / %d", Double(counts.reduce(0, +)) / Double(counts.count), counts.max() ?? 0)
        }
        row("False learns (adversarial → active)") { r in
            "\(r.adversarial.filter { !$0.activated.isEmpty }.count)/\(r.adversarial.count)"
        }
        row("Adversarial → any suggestion") { r in
            "\(r.adversarial.filter { !$0.candidates.isEmpty }.count)/\(r.adversarial.count)"
        }
        for result in results {
            print("\(result.mode.rawValue) — short-dictation fixes until in use (— = not in \(maxAttempts); * = known limit):")
            print("  " + result.terms.map { "\($0.term.learnable ? "" : "*")\($0.term.term) \($0.fixesToLearn.map(String.init) ?? "—")" }
                .joined(separator: " · "))
            let flagged = result.adversarial.filter { !$0.activated.isEmpty || !$0.candidates.isEmpty }
            for item in flagged {
                print("  [\(item.scenario.category)] \(item.scenario.name): "
                      + (item.activated.isEmpty ? "ok" : "FALSE LEARN \(item.activated)") + " · suggestion \(item.candidates)")
            }
        }
        let falseLearns = results.flatMap(\.adversarial).filter { !$0.activated.isEmpty }.count
        if falseLearns > 0 {
            FileHandle.standardError.write(Data("learn: \(falseLearns) short-dictation scenario(s) taught an active item\n".utf8))
            exit(1)
        }
    }
}
