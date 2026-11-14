import Foundation

/// Where usage numbers would be sent, read from one build setting. Empty (the default), a
/// placeholder that was never substituted, or anything that is not a plain `https` address means
/// "not configured": the app then makes no network call for usage numbers at all.
public enum MetricsEndpoint {
    /// The Info.plist key, filled in by `scripts/build-app.sh` from `HUSHY_USAGE_METRICS_ENDPOINT`.
    public static let infoPlistKey = "HushyUsageMetricsEndpoint"

    public static func parse(_ raw: String?) -> URL? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains("__"),
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func configured(in bundle: Bundle = .main) -> URL? {
        parse(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }
}
