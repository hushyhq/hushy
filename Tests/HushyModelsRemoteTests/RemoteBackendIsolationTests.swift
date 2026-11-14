import Foundation
import Testing

/// The remote backend is eval-only: the shipping app must never gain a network model backend
/// (.claude/AGENTS.md rule 1). These checks read Package.swift and the app's sources, so a change
/// that wires `HushyModelsRemote` into the app — directly or through a library the app links —
/// fails here before it can ship.
@Suite("Remote backend stays out of the app")
struct RemoteBackendIsolationTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Package.swift split into target declarations: name → declaration text.
    static func targets() throws -> [String: String] {
        let text = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)""#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let start = Range(match.range, in: text)!.lowerBound
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: text)!.lowerBound : text.endIndex
            let name = String(text[Range(match.range(at: 2), in: text)!])
            result[name] = String(text[start..<end])
        }
        return result
    }

    /// Everything the app target links, transitively (local targets only).
    static func appClosure(_ targets: [String: String]) -> Set<String> {
        var seen: Set<String> = []
        var queue = ["Murmur"]
        while let name = queue.popLast() {
            guard seen.insert(name).inserted, let declaration = targets[name] else { continue }
            let body = declaration.components(separatedBy: "dependencies:").dropFirst().joined()
            for other in targets.keys where other != name && body.contains("\"\(other)\"") {
                queue.append(other)
            }
        }
        return seen
    }

    @Test func appTargetNeverLinksTheRemoteBackend() throws {
        let targets = try Self.targets()
        #expect(targets["HushyModelsRemote"] != nil, "the remote target moved; update this test")
        #expect(targets["Murmur"] != nil)
        let closure = Self.appClosure(targets)
        #expect(closure.contains("HushyModelsMLX"), "closure walk broken: the app links HushyModelsMLX")
        #expect(!closure.contains("HushyModelsRemote"), "the app must never link HushyModelsRemote (eval-only)")
    }

    @Test func onlyEvalTargetsDependOnIt() throws {
        let dependents = try Self.targets().filter { name, declaration in
            name != "HushyModelsRemote" && declaration.contains("\"HushyModelsRemote\"")
        }.keys
        #expect(Set(dependents) == ["murmur-eval", "HushyModelsRemoteTests"])
    }

    @Test func notAProduct() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let products = text.components(separatedBy: "products:").dropFirst().first?.components(separatedBy: "dependencies:").first ?? ""
        #expect(!products.contains("HushyModelsRemote"))
    }

    @Test func noAppSourceMentionsIt() throws {
        for folder in ["Sources/Murmur", "Sources/MurmurCore", "Sources/HushyModelsApple", "Sources/HushyModelsMLX"] {
            let directory = Self.root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "\(folder) has no Swift files; path broken")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("import HushyModelsRemote"), "\(file.lastPathComponent) imports the remote backend")
                #expect(!text.contains("RemoteLanguageModel"), "\(file.lastPathComponent) mentions RemoteLanguageModel")
            }
        }
    }
}
