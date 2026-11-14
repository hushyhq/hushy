// Standalone Apple Foundation Models error/latency probe (no Hushy code).
// Build: scripts/fm-probe/build.sh (adds Hushy's exact Clean/Polished prompts as Prompts.swift)
// Usage: fm-probe --instr clean|polished|short|none --prompt short|medium|long|xlong
//                --session fresh|reused --mode string|schema --guard default|permissive
//                --n 20 --gap-ms 250 --label X
// Prints one JSON line per call, then a summary line.
import Foundation
import FoundationModels
import Darwin

let prompts: [String: String] = [
    "short": "Can you uh send me the notes?",
    "medium": "so I think we should ship the new pill on friday no thursday",
    "long": "so um the thing is we need to get the quarterly numbers to finance by wednesday and I think Priya has the spreadsheet but actually no Raj has it now and we should also loop in the design team about the new onboarding screens",
    "xlong": String(repeating: "so um the thing is we need to get the quarterly numbers to finance by wednesday and I think Priya has the spreadsheet but actually no Raj has it now and we should also loop in the design team about the new onboarding screens. ", count: 4),
]

let shortInstructions = "Remove filler words and stutters from the dictation transcript. Keep everything else."

let cleanedSchemaJSON = #"{"additionalProperties":false,"properties":{"text":{"description":"The cleaned text only","type":"string"}},"required":["text"],"title":"Cleaned","type":"object","x-order":["text"]}"#

func arg(_ name: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + name), i + 1 < a.count { return a[i + 1] }
    return fallback
}

func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : -1
}

func swapUsedMB() -> Int {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int(usage.xsu_used / 1_048_576) : -1
}

func load1() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) == 3 ? loads[0] : -1
}

/// Case name plus the whole NSError underlying chain, so SCA error 15 / ModelManagerError 1013
/// show up whatever Swift type wraps them.
func describe(_ error: Error) -> (kind: String, chain: String) {
    var kind = String(describing: type(of: error))
    if let generation = error as? LanguageModelSession.GenerationError {
        switch generation {
        case .exceededContextWindowSize: kind = "exceededContextWindowSize"
        case .assetsUnavailable: kind = "assetsUnavailable"
        case .guardrailViolation: kind = "guardrailViolation"
        case .unsupportedGuide: kind = "unsupportedGuide"
        case .unsupportedLanguageOrLocale: kind = "unsupportedLanguageOrLocale"
        case .decodingFailure: kind = "decodingFailure"
        case .rateLimited: kind = "rateLimited"
        case .concurrentRequests: kind = "concurrentRequests"
        case .refusal: kind = "refusal"
        @unknown default: kind = "unknownGenerationError"
        }
    }
    var parts: [String] = []
    var current: NSError? = error as NSError
    var depth = 0
    while let e = current, depth < 6 {
        parts.append("\(e.domain)#\(e.code)")
        current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    if let generation = error as? LanguageModelSession.GenerationError {
        switch generation {
        case .exceededContextWindowSize(let c), .assetsUnavailable(let c), .guardrailViolation(let c),
             .unsupportedGuide(let c), .unsupportedLanguageOrLocale(let c), .decodingFailure(let c),
             .rateLimited(let c), .concurrentRequests(let c), .refusal(_, let c):
            parts.append("ctx=" + c.debugDescription.prefix(300))
        @unknown default: break
        }
    }
    return (kind, parts.joined(separator: " > "))
}

func jsonLine(_ dict: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

@main
struct Probe {
    static func main() async {
        let instrName = arg("instr", "clean")
        let promptName = arg("prompt", "medium")
        let sessionMode = arg("session", "fresh")
        let mode = arg("mode", "schema")
        let guardName = arg("guard", "default")
        let n = Int(arg("n", "10")) ?? 10
        let gapMs = Int(arg("gap-ms", "250")) ?? 250
        let label = arg("label", "")

        let instructions: String? = switch instrName {
        case "clean": hushyCleanInstructions
        case "polished": hushyPolishedInstructions
        case "short": shortInstructions
        case "none": nil
        default: (try? String(contentsOfFile: instrName, encoding: .utf8)) ?? shortInstructions
        }
        let draft = prompts[promptName] ?? promptName
        let prompt = "Transcript: \(draft)\nOutput:"
        let guardrails: SystemLanguageModel.Guardrails = guardName == "permissive" ? .permissiveContentTransformations : .default
        let model = SystemLanguageModel(guardrails: guardrails)
        let options = GenerationOptions(sampling: .greedy, temperature: 0)
        let schema: GenerationSchema
        do {
            schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(cleanedSchemaJSON.utf8))
        } catch {
            print("schema decode failed: \(error)")
            return
        }
        print(jsonLine(["event": "start", "availability": String(describing: model.availability),
                        "instr": instrName, "prompt": promptName, "session": sessionMode, "mode": mode,
                        "guard": guardName, "n": n, "label": label]))

        func makeSession() -> LanguageModelSession {
            if let instructions { return LanguageModelSession(model: model, instructions: instructions) }
            return LanguageModelSession(model: model)
        }
        var reused = makeSession()
        var ok = 0
        var latencies: [Double] = []
        var kinds: [String: Int] = [:]
        for i in 0..<n {
            let session = sessionMode == "reused" ? reused : makeSession()
            let pressure = sysctlInt("kern.memorystatus_vm_pressure_level")
            let start = ContinuousClock.now
            var record: [String: Any] = ["i": i, "load1": (load1() * 100).rounded() / 100,
                                         "pressure": pressure, "swapMB": swapUsedMB(), "label": label]
            do {
                let text: String
                if mode == "string" {
                    text = try await session.respond(to: prompt, options: options).content
                } else {
                    text = try await session.respond(to: prompt, schema: schema, options: options).content.jsonString
                }
                ok += 1
                record["ok"] = true
                record["out"] = String(text.prefix(120))
                kinds["ok", default: 0] += 1
            } catch {
                let d = describe(error)
                record["ok"] = false
                record["kind"] = d.kind
                record["chain"] = d.chain
                kinds[d.kind, default: 0] += 1
                // A reused session whose transcript overflowed must be replaced.
                if sessionMode == "reused" { reused = makeSession() }
            }
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            record["ms"] = ms.rounded()
            if record["ok"] as? Bool == true { latencies.append(ms) }
            print(jsonLine(record))
            fflush(stdout)
            if gapMs > 0 { try? await Task.sleep(for: .milliseconds(gapMs)) }
        }
        let sorted = latencies.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))].rounded() }
        print(jsonLine(["event": "summary", "label": label, "instr": instrName, "prompt": promptName, "session": sessionMode,
                        "mode": mode, "guard": guardName, "n": n, "ok": ok, "kinds": kinds,
                        "p50": pct(0.5), "p90": pct(0.9), "max": sorted.last.map { $0.rounded() } ?? -1]))
    }
}
