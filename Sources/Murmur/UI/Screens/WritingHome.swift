import Foundation

/// The one place a person sets how Hushy writes (tone, a tone for each app, voice commands,
/// spelling): the Voice & style page, on its Style section. Other screens send people here
/// instead of repeating its controls.
enum WritingHome {
    static let section: AppModel.Section = .style
    static let tab: VoiceAndStyleView.Tab = .style

    /// Posted with a `VoiceAndStyleView.Tab` object to switch a Voice & style page that is already
    /// on screen to that section; a page created afterwards opens on `tab` by itself.
    static let show = Notification.Name("app.hushy.voiceStyle.showTab")

    static func tab(in notification: Notification) -> VoiceAndStyleView.Tab? {
        notification.object as? VoiceAndStyleView.Tab
    }
}

