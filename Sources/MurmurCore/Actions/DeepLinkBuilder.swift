import Foundation

/// Builds navigations from fixed service hosts. Slot values never supply a host or scheme.
public enum DeepLinkBuilder {
    public enum Service: String, CaseIterable, Sendable {
        case gmail, googleCalendar = "google_calendar", googleMaps = "google_maps"
        case google, youtube, slack, github, notion
    }

    public enum Action: String, CaseIterable, Sendable {
        case open, search, compose, day, directions, channel, repo, issues, pulls
    }

    public struct Link: Sendable, Equatable {
        public let url: URL
        public let summary: String
        public let serviceName: String
        public let domain: String
    }

    public static func build(
        service: Service, action: Action, query: String? = nil, date: String? = nil,
        destination: String? = nil, to: String? = nil, subject: String? = nil,
        context: DateContext = .current(), slackInstalled: Bool = false
    ) -> Link? {
        let value = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "https"
        var summary: String
        let name: String
        switch service {
        case .gmail:
            name = "Gmail"; components.host = "mail.google.com"
            switch action {
            case .open: components.path = "/mail/u/0/"; summary = "Open Gmail"
            case .search:
                guard let value, !value.isEmpty else { return nil }
                components.path = "/mail/u/0/"; components.percentEncodedFragment = "search/\(encodeFragment(value))"
                summary = "Search Gmail for \"\(value)\""
            case .compose:
                components.path = "/mail/u/0/"
                var items = [URLQueryItem(name: "view", value: "cm")]
                if let to, !to.isEmpty { items.append(URLQueryItem(name: "to", value: to)) }
                if let subject, !subject.isEmpty { items.append(URLQueryItem(name: "su", value: subject)) }
                components.queryItems = items; summary = "Compose in Gmail"
            default: return nil
            }
        case .googleCalendar:
            name = "Google Calendar"; components.host = "calendar.google.com"
            guard action == .day, let date, let anchored = DateAnchor.firstDate(in: date, context: context) else { return nil }
            let day = context.calendar.dateComponents([.year, .month, .day], from: anchored.start)
            guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
            components.path = String(format: "/calendar/u/0/r/day/%04d/%d/%d", year, month, dayOfMonth)
            summary = "Open Google Calendar for \(date)"
        case .googleMaps:
            name = "Google Maps"; components.host = "www.google.com"; components.path = "/maps/\(action == .directions ? "dir/" : "search/")"
            if action == .directions, let destination, !destination.isEmpty {
                components.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: destination)]
                summary = "Directions to \"\(destination)\""
            } else if action == .search, let value, !value.isEmpty {
                components.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: value)]
                summary = "Search Google Maps for \"\(value)\""
            } else { return nil }
        case .google, .youtube, .notion:
            name = service == .google ? "Google" : service == .youtube ? "YouTube" : "Notion"
            components.host = service == .google ? "www.google.com" : service == .youtube ? "www.youtube.com" : "www.notion.so"
            guard action == .search, let value, !value.isEmpty else { return nil }
            components.path = service == .google ? "/search" : "/search"
            components.queryItems = [URLQueryItem(name: service == .youtube ? "search_query" : "q", value: value)]
            summary = "Search \(name) for \"\(value)\""
        case .slack:
            name = "Slack"
            guard action == .channel, let value, !value.isEmpty else { return nil }
            if slackInstalled { components.scheme = "slack"; components.host = "channel"; components.queryItems = [URLQueryItem(name: "name", value: value.replacingOccurrences(of: "#", with: ""))] }
            else { components.host = "app.slack.com"; components.path = "/client" }
            summary = "Open Slack channel \"\(value)\""
        case .github:
            name = "GitHub"; components.host = "github.com"
            guard [.repo, .issues, .pulls].contains(action), let value else { return nil }
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ($0.unicodeScalars.count == 1 && $0.unicodeScalars.first?.isASCII == true) && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") } }) else { return nil }
            components.path = "/\(parts[0])/\(parts[1])" + (action == .repo ? "" : action == .issues ? "/issues" : "/pulls")
            summary = "Open GitHub \(action.rawValue) for \"\(value)\""
        }
        guard let url = components.url, let domain = components.host else { return nil }
        return Link(url: url, summary: summary, serviceName: name, domain: domain)
    }

    private static func encodeFragment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
