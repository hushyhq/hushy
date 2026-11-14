@testable import Murmur
import Testing

struct AppBadgeHueTests {
    @Test func hueIsFixedPerAppAcrossLaunches() {
        #expect(AppBadge.hue(for: "com.tinyspeck.slackmacgap") == 149.0 / 360)
        #expect(AppBadge.hue(for: "com.anthropic.claude") == 12.0 / 360)
    }

    @Test func differentAppsGetDifferentHues() {
        #expect(AppBadge.hue(for: "com.tinyspeck.slackmacgap") != AppBadge.hue(for: "com.anthropic.claude"))
    }
}
