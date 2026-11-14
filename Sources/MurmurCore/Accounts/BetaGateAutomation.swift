import Foundation

/// When the sign-in gate may be skipped. Only a build made for automation (a debug build, or one
/// compiled with HUSHY_AUTOMATION_BUILD) can answer yes; the shipped build passes `false` and
/// gets `false` whatever the environment, bundle name or process name says. The question is a
/// pure function so a test can ask it for a shipped build without launching anything.
public enum BetaGateAutomation {
    public static func bypasses(
        buildAllowsBypass: Bool,
        snapshotRequested: Bool,
        bundlePath: String,
        processName: String,
        environment: [String: String],
        temporaryDirectory: URL
    ) -> Bool {
        guard buildAllowsBypass else { return false }
        if snapshotRequested { return true }
        if bundlePath.hasSuffix(".xctest") || processName == "murmur-eval" { return true }
        let roots = [temporaryDirectory.path, "/tmp", "/private/tmp"].flatMap(spellings)
        for key in ["HUSHY_HOME", "MURMUR_HOME"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            let candidates = spellings(value)
            if candidates.contains(where: { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }) { return true }
        }
        return false
    }

    /// The path with `..` removed, with symlinks resolved, and with both the /private and the
    /// plain spelling of /tmp, /var and /etc. Resolving or standardizing may drop or add /private
    /// (/private/tmp becomes /tmp), so a literal comparison against one spelling misses the other.
    private static func spellings(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var forms = Set([url.path, url.resolvingSymlinksInPath().path])
        for form in forms {
            for top in ["/tmp", "/var", "/etc"] where form == top || form.hasPrefix(top + "/") { forms.insert("/private" + form) }
            for top in ["/private/tmp", "/private/var", "/private/etc"] where form == top || form.hasPrefix(top + "/") {
                forms.insert(String(form.dropFirst("/private".count)))
            }
        }
        return Array(forms)
    }
}
