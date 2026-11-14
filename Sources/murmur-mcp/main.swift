import Foundation
import MurmurCore

// Read-only MCP stdio server over the local Hushy database. With no `--scope` it serves usage totals only.
// AI clients launch this binary; it reads JSON-RPC lines from stdin and answers on stdout.

setvbuf(stdout, nil, _IOLBF, 0)

let databaseURL = AppPaths.database
guard FileManager.default.fileExists(atPath: databaseURL.path) else {
    FileHandle.standardError.write(Data("hushy-mcp: no database at \(databaseURL.path). Open Hushy once first.\n".utf8))
    exit(1)
}

let server: MCPServer
do {
    // `--scope notes` is how Hushy's own Assistant launches this helper: notes and proposals, no dictations.
    // A missing or unknown value fails closed (exit 1) instead of silently granting full
    // history access: a typo'd launcher flag must never widen into `.all`.
    let arguments = CommandLine.arguments
    let scope: MCPServer.Scope
    if let flagIndex = arguments.firstIndex(of: "--scope") {
        guard arguments.indices.contains(flagIndex + 1),
              let parsed = MCPServer.Scope(rawValue: arguments[flagIndex + 1]) else {
            FileHandle.standardError.write(Data("hushy-mcp: unknown or missing --scope value; refusing to run with full access.\n".utf8))
            exit(1)
        }
        scope = parsed
    } else {
        scope = .all
    }
    server = MCPServer(reader: try Store.openReadOnly(url: databaseURL), scope: scope)
} catch {
    FileHandle.standardError.write(Data("hushy-mcp: cannot open database: \(error)\n".utf8))
    exit(1)
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let response = server.handle(line: line) {
        print(response)
    }
}
