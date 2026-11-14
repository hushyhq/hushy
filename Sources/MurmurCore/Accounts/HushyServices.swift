import Foundation

/// Which hosted Hushy services this build talks to. Set once, at build time: `scripts/build-app.sh`
/// writes `HushyServices` into Info.plist from `HUSHY_SERVICES` (default `none`).
///
/// - `official`: the build the maintainers sign and ship. It signs in to the Hushy account service,
///   downloads Hushy-hosted models after sign-in, and sends what the person allowed (daily count,
///   crash reports) to the Hushy site.
/// - `none`: every other build, including a copy built from source. No account, no sign-in gate,
///   no daily count, no crash upload. Dictation, cleanup with Apple's on-device model or the rules,
///   and the public Hugging Face models all work.
///
/// Anything missing or unrecognised reads as `none`, so a build has to opt in to our services.
public enum HushyServices: String, Sendable {
    case official
    case none

    public static let infoPlistKey = "HushyServices"

    public init(bundle: Bundle) {
        self.init(infoValue: bundle.object(forInfoDictionaryKey: Self.infoPlistKey))
    }

    public init(infoValue: Any?) {
        self = (infoValue as? String) == HushyServices.official.rawValue ? .official : .none
    }

    /// This process's build.
    public static let current = HushyServices(bundle: .main)

    /// Whether the build may use the Hushy account service and the endpoints on the Hushy site.
    public var isOfficial: Bool { self == .official }
}
