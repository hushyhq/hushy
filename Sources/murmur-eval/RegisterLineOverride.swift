import Foundation
import HushyModelsMLX
import MurmurCore

/// Eval only (`intent-app`): measures other wordings of a register line on the shipped path without touching the app.
///
/// `HUSHY_EVAL_REGISTER_LINES=<path>` names a JSON object from register name (`casual`, `professional`, `prompt`) to the
/// line to send in its place. A cleanup call whose instructions carry that register's shipped line is answered with
/// `IntentCleanupPrompt.system(register:)`, the shipped line swapped for the replacement, through
/// `MLXLanguageModel.respondVerbatim`: the same schema grammar, greedy decoding and prefix cache as `respond`. Every other
/// call (Refined, the plain second ask without a line, a register not in the file) goes through untouched.
struct RegisterLineOverride: Sendable {
    let lines: [IntentRegister: String]
    let mlx: MLXLanguageModel

    static func fromEnvironment(mlx: MLXLanguageModel) throws -> RegisterLineOverride? {
        guard let path = ProcessInfo.processInfo.environment["HUSHY_EVAL_REGISTER_LINES"], !path.isEmpty else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw EvalError.missing("HUSHY_EVAL_REGISTER_LINES must hold a JSON object of register name to line: \(path)")
        }
        var lines = [IntentRegister: String]()
        for (name, line) in object {
            guard let register = IntentRegister(rawValue: name) else {
                throw EvalError.missing("HUSHY_EVAL_REGISTER_LINES: unknown register \(name)")
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\n") else {
                throw EvalError.missing("HUSHY_EVAL_REGISTER_LINES: the \(name) line must be one non-empty line")
            }
            lines[register] = trimmed
        }
        return RegisterLineOverride(lines: lines, mlx: mlx)
    }

    /// The system prompt to send instead, or nil when this call is not one the file replaces.
    func system(instructions: String, schema: GenerationSchemaSpec) -> String? {
        guard schema.name == SmartCleaner.cleanedSchema.name,
              let register = IntentRegister.detecting(in: instructions), let line = lines[register] else { return nil }
        let shipped = IntentCleanupPrompt.system(register: register)
        return shipped.replacingOccurrences(of: register.line, with: line)
    }
}
