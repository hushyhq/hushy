import Foundation
import MurmurCore

/// Eval-only: assemble the five post-recogniser checkpoints from one `PipelineResult` (one `clean` call).
enum PipelineStepCapture {
    static func assemble(
        recognizer: String, boosted: String, fixers: String, result: PipelineResult
    ) -> [MadeWorseScorer.PipelineStep: String] {
        let model = result.groups.compactMap(\.measured.firstPassText).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let modelText = model.isEmpty ? result.text : model
        return [
            .recognizer: recognizer,
            .boosted: boosted,
            .fixers: fixers,
            .model: modelText,
            .checks: result.text,
        ]
    }
}
