import Foundation
import Testing
@testable import MurmurCore

/// The headless mock-microphone mode points `FeatureFlags.source` at a throwaway suite so it never
/// reads the user's own defaults. The app itself leaves it on `.standard`.
@Suite("FeatureFlags.source", .serialized)
struct FeatureFlagsSourceTests {
    @Test("flags read from the source, which is the standard defaults unless something changes it")
    func readsFromSource() throws {
        #expect(FeatureFlags.source === UserDefaults.standard)
        let name = "app.hushy.test.featureflags.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer {
            FeatureFlags.source = .standard
            suite.removePersistentDomain(forName: name)
        }
        suite.set(false, forKey: FeatureFlags.askActionsKey)
        FeatureFlags.source = suite
        #expect(!FeatureFlags.askActions)
        #expect(FeatureFlags.speakerLabels, "a key absent from the source falls back to the default, not to the standard defaults")
    }
}
