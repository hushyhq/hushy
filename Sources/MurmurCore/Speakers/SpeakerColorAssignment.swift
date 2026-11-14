import Foundation

/// Assigns a stable color index to each speaker in a note, so the same speaker always gets the
/// same colored name chip within that note (and re-renders don't shuffle colors). Pure and
/// framework-agnostic: returns an index into a caller-owned palette (`Theme`'s speaker colors in
/// the app target) rather than a `Color` itself, so `MurmurCore` stays UI-framework-free.
///
/// Deterministic by speaker id, not array position — so a merge (which removes a speaker) or a
/// re-fetch (which may return speakers in a different order) never reassigns colors to the
/// speakers that survive.
public enum SpeakerColorAssignment {
    /// Maps `speakerId` to a stable index in `0..<paletteSize`, via the id's own value rather
    /// than position in a list — see the type doc comment. `paletteSize` must be positive;
    /// passing 0 or a negative value always returns 0 (never traps), since a caller with an empty
    /// palette should just get one degenerate "no distinct colors" bucket rather than a crash.
    public static func colorIndex(forSpeakerId speakerId: Int64, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        let modulus = Int64(paletteSize)
        let remainder = speakerId % modulus
        return Int(remainder >= 0 ? remainder : remainder + modulus)
    }
}
