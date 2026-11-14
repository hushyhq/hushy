import Foundation

/// "Ask Claude …", "ask ChatGPT …": Hushy hands the question to that service by opening it
/// with the question filled in. The URL comes from a fixed template per service; the model (or
/// `AskRouter`) supplies only the service and the question, never a host, scheme or path.
/// Whether the service sends without the user pressing Return is per-service (`linkSubmitsAutomatically`);
/// until verified, Hushy says the link only opened. Hushy holds no account or token for any of them.
public enum AIHandoffLink {
    public enum Service: String, CaseIterable, Sendable, Codable {
        case claude, chatgpt, perplexity, gemini

        /// When true, the hand-off URL is treated as sending the question without Return, and the
        /// done chip may say "Asked …". Flip per service only after checking the live link by hand.
        public nonisolated(unsafe) static var claudeLinkSubmitsAutomatically = false
        public nonisolated(unsafe) static var chatgptLinkSubmitsAutomatically = false
        public nonisolated(unsafe) static var perplexityLinkSubmitsAutomatically = false
        public nonisolated(unsafe) static var geminiLinkSubmitsAutomatically = false

        public var linkSubmitsAutomatically: Bool {
            switch self {
            case .claude: Self.claudeLinkSubmitsAutomatically
            case .chatgpt: Self.chatgptLinkSubmitsAutomatically
            case .perplexity: Self.perplexityLinkSubmitsAutomatically
            case .gemini: Self.geminiLinkSubmitsAutomatically
            }
        }

        public var displayName: String {
            switch self {
            case .claude: "Claude"
            case .chatgpt: "ChatGPT"
            case .perplexity: "Perplexity"
            case .gemini: "Gemini"
            }
        }

        /// The template's fixed part. Gemini's own app has no query parameter that submits, so
        /// "ask Gemini" opens Google's AI Mode (Gemini-powered), which does.
        public var urlPrefix: String {
            switch self {
            case .claude: "https://claude.ai/new?q="
            case .chatgpt: "https://chatgpt.com/?q="
            case .perplexity: "https://www.perplexity.ai/search?q="
            case .gemini: "https://www.google.com/search?udm=50&q="
            }
        }

        public var domain: String {
            switch self {
            case .claude: "claude.ai"
            case .chatgpt: "chatgpt.com"
            case .perplexity: "perplexity.ai"
            case .gemini: "google.com"
            }
        }

        /// Spoken forms, longest first so "chat gpt" wins over "gpt". Includes what speech
        /// recognition makes of the names: "Claude" comes back as "cloud" or "claud", "ChatGPT"
        /// as "chat gbt" (founder test, 2026-09-28).
        public var spokenNames: [String] {
            switch self {
            case .claude: ["claude", "cloud ai", "claude ai", "cloud", "claud", "clawed", "clod", "anthropic claude", "anthropic"]
            case .chatgpt: ["chat gpt", "chatgpt", "chat g p t", "chat gbt", "chatgbt", "chat gtp", "chat gpd", "gpt", "openai", "open ai"]
            case .perplexity: ["perplexity", "perplexity ai"]
            case .gemini: ["gemini", "google gemini", "bard", "jemini"]
            }
        }

        /// The service's own site, for "open Claude" when the Mac app isn't installed. No
        /// question is carried, so nothing is submitted.
        public var homeURL: URL {
            switch self {
            case .claude: URL(string: "https://claude.ai/new")!
            case .chatgpt: URL(string: "https://chatgpt.com/")!
            case .perplexity: URL(string: "https://www.perplexity.ai/")!
            case .gemini: URL(string: "https://gemini.google.com/app")!
            }
        }

        /// The service a spoken name means, if any.
        public static func named(_ spoken: String) -> Service? {
            let needle = spoken.lowercased().trimmingCharacters(in: .whitespaces)
            return allCases.first { $0.spokenNames.contains(needle) }
        }
    }

    /// The service whose template prefix matches `url`, if any.
    public static func service(for url: String?) -> Service? {
        guard let url else { return nil }
        return Service.allCases.first { url.hasPrefix($0.urlPrefix) }
    }

    /// The done-chip line after a hand-off. Never says the question was sent unless
    /// `linkSubmitsAutomatically` is true for that service.
    public static func doneChipTitle(service: Service) -> String {
        if service.linkSubmitsAutomatically { return "Asked \(service.displayName)" }
        return "Opened in \(service.displayName) — press ↩"   // short enough for the pill chip; "— press Return to send" was cut off in the 2026-11-03 render
    }

    /// Done-chip titles from `doneChipTitle`; History uses the same wording without a second "Opened".
    public static func isHandoffDoneChipTitle(_ title: String) -> Bool {
        title.hasPrefix("Opened in ") || title.hasPrefix("Asked ")
    }

    /// The link for one question, or nil for an empty question.
    public static func build(service: Service, question: String) -> DeepLinkBuilder.Link? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: queryAllowed),
              let url = URL(string: service.urlPrefix + encoded) else { return nil }
        return DeepLinkBuilder.Link(
            url: url, summary: "Ask \(service.displayName)", serviceName: service.displayName, domain: service.domain)
    }

    /// Unreserved characters only: `&`, `=`, `+`, `#` and `?` in a question are encoded, so the
    /// question can't add or split parameters.
    static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
