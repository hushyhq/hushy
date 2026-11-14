import Foundation

/// The words on the shared-key card. Every string is a placeholder until the founder signs it off.
/// Rival names stay out of the shipped words: `namesRivals` is a compile-time switch that flips
/// only after legal and the founder agree to name other products in the app.
enum RivalKeyCopy {
    static let namesRivals = false

    static func title(offer: RivalKeyOffer, namesRivals: Bool = RivalKeyCopy.namesRivals) -> String {
        let key = offer.current.glyph
        guard namesRivals else { return "[placeholder] Another dictation app may be listening on \(key)" }
        return "[placeholder] \(names(offer.rivals)) may be listening on \(key)"
    }

    static let detail = "[placeholder] When two apps share one key, a single dictation can be typed twice."

    static func switchButton(offer: RivalKeyOffer) -> String {
        "[placeholder] Use \(offer.suggested.shortTitle) instead"
    }

    static func keepButton(offer: RivalKeyOffer) -> String {
        "[placeholder] Keep \(offer.current.glyph)"
    }

    static func names(_ rivals: [RivalDictationApp]) -> String {
        let all = rivals.map(\.name)
        guard all.count > 1 else { return all.first ?? "" }
        return all.dropLast().joined(separator: ", ") + " and " + all[all.count - 1]
    }
}
