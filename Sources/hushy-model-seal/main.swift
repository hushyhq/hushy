import CryptoKit
import Foundation
import MurmurCore

// Build tool (not shipped): seals a model folder's weights into a new model id.
//
//   hushy-model-seal --model-dir <folder> --model-id <new id> --out <folder>
//                    [--key-dir <folder>] [--key-file <file>] [--chunk-mb 16] [--max-file-bytes 300000000] [--no-verify]
//
// Writes <out>/<new id>/ (the plain tokenizer and config files, and weights-NNNNN-of-NNNNN.hse), <out>/<new id>.listing.txt
// (sizes and SHA-256 to paste into ModelRegistry and models-gate/src/allowlist.js) and the key, base64, in
// <key-dir>/<new id>.key (mode 0600, refused unless git ignores the folder). The key is never printed.
// With --key-file the same key is reused, and the same plaintext gives byte-identical files.
// Docs: docs/engineering/SEALED-MODELS.md

struct Failure: Error, CustomStringConvertible { let description: String }

func argument(_ name: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: "--\(name)"), at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

func sha256(of url: URL) throws -> (String, Int64) {
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    var hasher = SHA256()
    var size: Int64 = 0
    while let data = try reader.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
        size += Int64(data.count)
    }
    return (hex(hasher.finalize()), size)
}

func gitIgnores(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", url.deletingLastPathComponent().path, "check-ignore", "-q", url.lastPathComponent]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func insideGitRepository(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", url.path, "rev-parse", "--is-inside-work-tree"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func run() throws {
    guard let modelPath = argument("model-dir"), let modelID = argument("model-id"), let outPath = argument("out") else {
        throw Failure(description: "usage: hushy-model-seal --model-dir <folder> --model-id <new id> --out <folder> [--key-dir <folder>] [--key-file <file>]")
    }
    guard modelID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
        throw Failure(description: "the model id may hold letters, digits, dot, underscore and dash only")
    }
    let source = URL(fileURLWithPath: modelPath, isDirectory: true)
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    let destination = out.appendingPathComponent(modelID, isDirectory: true)
    let chunkSize = (Int(argument("chunk-mb") ?? "") ?? 16) * 1024 * 1024
    let maxFile = Int64(argument("max-file-bytes") ?? "") ?? SealedFormat.defaultMaxFileBytes
    if FileManager.default.fileExists(atPath: destination.path) {
        throw Failure(description: "\(destination.path) exists; remove it first")
    }

    // The key: reused from --key-file, else new and saved where git will not take it.
    let key: Data
    var savedKeyPath: String?
    if let keyFile = argument("key-file") {
        let text = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: text), data.count == SealedFormat.keySize else {
            throw Failure(description: "--key-file does not hold a base64 256-bit key")
        }
        key = data
    } else {
        let keyDir = URL(fileURLWithPath: argument("key-dir") ?? ".secrets/model-keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyURL = keyDir.appendingPathComponent("\(modelID).key")
        if FileManager.default.fileExists(atPath: keyURL.path) {
            throw Failure(description: "\(keyURL.path) already exists: pass it as --key-file to rebuild, or remove it for a new key")
        }
        // Inside a repository the folder (and so the key file) must be ignored by git, or nothing is written.
        if insideGitRepository(keyDir), !gitIgnores(keyDir.appendingPathComponent("\(modelID).key")) {
            throw Failure(description: "\(keyDir.path) is not ignored by git; add it to .gitignore first")
        }
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let text = key.base64EncodedString() + "\n"
        guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure(description: "could not write \(keyURL.path)")
        }
        savedKeyPath = keyURL.path
    }

    let joiner = try SafetensorsJoiner(directory: source)
    let layout = try SealedLayout(totalPlain: joiner.totalBytes, chunkSize: chunkSize, maxFileBytes: maxFile)
    let writer = try SealedWeightsWriter(key: key, modelID: modelID, layout: layout, directory: destination)
    var plainHash = SHA256()
    try joiner.stream { piece in
        plainHash.update(data: piece)
        try writer.append(piece)
    }
    let parts = try writer.finish()
    let plainDigest = hex(plainHash.finalize())

    // The files that are not weights travel as they are (the tokenizer and the configs are public).
    var plainFiles: [(String, Int64, String)] = []
    for name in ["chat_template.jinja", "config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json"] {
        let from = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else { continue }
        try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name))
        let (digest, size) = try sha256(of: from)
        plainFiles.append((name, size, digest))
    }

    // Read it back with the key, all of it, and compare with what went in.
    if !CommandLine.arguments.contains("--no-verify") {
        let reader = try SealedWeightsReader(directory: destination, modelID: modelID)
        let stream = try reader.plainStream(key: key, parallelism: 4)
        var check = SHA256()
        while stream.remaining > 0 { check.update(data: try stream.read(count: Int(min(stream.remaining, 8 * 1024 * 1024)))) }
        guard hex(check.finalize()) == plainDigest else { throw Failure(description: "read-back does not match what was sealed") }
    }

    // What to paste where. Sizes and hashes only.
    var listing = "model id: \(modelID)\nplaintext stream: \(joiner.totalBytes) bytes, SHA-256 \(plainDigest)\n"
    listing += "chunk size \(chunkSize), \(layout.chunkCount) chunks, \(layout.partCount) part files\n\n"
    listing += "// ModelRegistry (name, bytes, sha256)\n"
    for (name, size, digest) in (plainFiles + parts.map { ($0.name, $0.bytes, $0.sha256) }).sorted(by: { $0.0 < $1.0 }) {
        listing += "(\"\(name)\", \(size), \"\(digest)\"),\n"
    }
    listing += "\n// models-gate/src/allowlist.js\n  '\(modelID)': Object.freeze({\n"
    for (name, size, _) in (plainFiles + parts.map { ($0.name, $0.bytes, $0.sha256) }).sorted(by: { $0.0 < $1.0 }) {
        listing += "    '\(name)': \(size),\n"
    }
    listing += "  }),\n"
    try listing.write(to: out.appendingPathComponent("\(modelID).listing.txt"), atomically: true, encoding: .utf8)

    print("Sealed \(modelID): \(parts.count) part files in \(destination.path)")
    print("Listing (sizes and SHA-256 to paste): \(out.appendingPathComponent("\(modelID).listing.txt").path)")
    if let savedKeyPath {
        let secret = SealedFormat.workerSecretName(for: modelID)
        let fromWorker = savedKeyPath.hasPrefix("/") ? savedKeyPath : "../" + savedKeyPath
        print("""

        The key is in \(savedKeyPath) (mode 0600, ignored by git). It is not printed. To roll out:
          1. Upload \(destination.path)/ to the hushy-models bucket under cleanup/\(modelID)/.
          2. cd models-gate && npx wrangler secret put \(secret) < \(fromWorker)
          3. Copy the key into your password manager, then delete the file:  rm \(savedKeyPath)
        Cloudflare cannot show a secret again. Without the key file or a copy, the same files cannot be rebuilt.
        """)
    } else {
        print("Used the key from --key-file; nothing new was saved.")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("hushy-model-seal: \(error)\n".utf8))
    exit(1)
}
