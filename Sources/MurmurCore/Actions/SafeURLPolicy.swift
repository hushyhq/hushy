import Foundation

/// Screens a model-supplied address against the actual spoken command before any card is shown.
public enum SafeURLPolicy {
    public static let knownSites: Set<String> = ["google.com", "youtube.com", "gmail.com", "github.com", "notion.so", "slack.com"]

    public static func approvedURL(_ raw: String, transcript: String) -> URL? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty, !host.hasSuffix("."),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              host.split(separator: ".").count >= 2,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }),
              let url = components.url else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        let domain = labels.suffix(2).joined(separator: ".")
        // Domain words embedded in note content are not an opening instruction: the command
        // frame (lead-ins stripped) must open with an open verb.
        let frame = AskRouter.frame(transcript)
        guard ["open", "go to", "goto", "visit", "launch", "show", "pull up", "bring up"].contains(where: { frame.hasPrefix($0 + " ") }) else { return nil }
        let spoken = frame.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " slash ", with: "/")
            .replacingOccurrences(of: " ", with: "")
        guard knownSites.contains(domain) || spoken.contains(domain) else { return nil }
        return url
    }

    public static func destination(_ raw: String, transcript: String) -> URL? {
        if let safe = approvedURL(raw, transcript: transcript) { return safe }
        return DeepLinkBuilder.build(service: .google, action: .search, query: transcript)?.url
    }
}
