import Foundation

/// Pure decision logic for whether Hushy should swallow a raw fn (Globe) `flagsChanged` event
/// so macOS never sees a *solo* fn press/hold — which is what macOS uses to decide whether to
/// run the Globe key's configured action (emoji picker, input source switch, Start Dictation)
/// and whether a fn-fn double-press should start Apple's own Dictation.
///
/// ## Why this is enough (and what it deliberately does not do)
///
/// The fn/Globe key has no `keyDown`/`keyUp` of its own — it only ever appears as a
/// `flagsChanged` event carrying `maskSecondaryFn` (keycode `kVK_Function`, 0x3F). macOS's own
/// Globe-key handling and its "press 🌐 twice" Dictation shortcut are driven entirely by that
/// bare modifier signal reaching AppKit/the system; there is no separate system-level keyDown to
/// intercept. (Confirmed independently by two unrelated projects: kitty's issue tracker
/// documents that swallowing bare `flagsChanged` events in a similar way is exactly what
/// prevents AppKit from recognizing the double-Fn dictation sequence — see
/// https://github.com/kovidgoyal/kitty/issues/9661 — and the Open-Less feature request notes fn
/// "generates a `flagsChanged` event rather than a standard `keyDown` event" — see
/// https://github.com/Open-Less/openless/issues/1083. Karabiner-Elements achieves the same
/// result at the kernel-extension/virtual-HID layer instead of a CGEventTap, which is a stronger
/// but much heavier mechanism Hushy doesn't need since it already runs a `.defaultTap`
/// `CGEventTap` capable of consuming events.)
///
/// So: consuming the fn `flagsChanged` down event (returning "swallow" from the tap callback,
/// i.e. `nil` instead of the event) for a *solo* press is sufficient to stop both the Globe
/// action and the Dictation double-press — there is no additional `keyDown` for keycode 0x3F (or
/// any alternate keycode) that also needs consuming, because fn never sends one. (The task brief
/// asked us to check whether a newer-keyboard keycode 0xB3 also needs handling; no source found
/// during research substantiates that Apple ships a second Globe-key keycode, and Hushy's own
/// `HotkeyMonitor.handleFlags` — already shipping and working — only ever tests `kVK_Function`.
/// This decider is keycode-agnostic in any case: the caller is responsible for filtering to the
/// fn keycode before calling in, exactly as `HotkeyMonitor.handleFlags` already does for its
/// other trigger keys.)
///
/// ## The combo problem, and the re-post design
///
/// Swallowing fn unconditionally would break `fn`+arrow (Page Up/Down/Home/End), `fn`+F-key,
/// `fn`+Delete (forward delete) and `fn`+E (emoji picker as a *combo*, which some users bind
/// deliberately) — those all depend on the frontmost app/AppKit having actually seen fn go down
/// before the second key's `keyDown` arrives. If Hushy swallows fn-down and macOS/the app never
/// finds out fn is down, `fn`+Left just becomes a plain `Left` arrow.
///
/// The fix: swallow fn's `flagsChanged` optimistically (so a solo hold never reaches macOS), but
/// the moment another key is pressed while fn is being swallowed, tell the caller to **re-post a
/// synthetic fn-down `flagsChanged`** immediately before letting that key's `keyDown` through.
/// This hands the combo back to macOS exactly as if Hushy had never swallowed the original
/// fn-down: the target app sees fn down, then the letter/arrow/F-key down, in the normal order.
/// When fn is finally released after a combo, Hushy also swallows *that* flagsChanged (since a
/// synthetic down was already delivered, a real "fn up" still needs to reach the app to balance
/// it — see `Action.releaseAfterRepost` — but never a second down).
///
/// fn+Control (Hushy's own voice-action chord, `ActionHotkeyMonitor`) is handled entirely
/// upstream: that monitor uses a `.listenOnly` tap and never consumes anything, so it is
/// unaffected by any of this by construction. This decider only ever sees calls routed through
/// `HotkeyMonitor`'s primary tap, and `HotkeyMonitor` only calls in when `trigger == .fn`.
public enum FnCaptureDecider {
    /// What the caller should do with the current event, and (for combos) an additional
    /// action to take before delivering the interrupting key.
    public enum Action: Equatable {
        /// Swallow this flagsChanged event; don't let macOS see it.
        case swallow
        /// Let this flagsChanged event through unmodified.
        case pass
        /// Swallow this flagsChanged (the real fn-up), but first the caller must have already
        /// posted a synthetic fn-down before the interrupting key — this case is only reached
        /// on the matching "fn up" after that repost, so the net effect the app sees is a clean
        /// down/up bracketing the combo.
        case passRelease
    }

    /// Internal state after handling fn-down: whether we're still swallowing (no other key seen
    /// yet) or already handed off to a combo (a key was pressed, so a synthetic down was posted
    /// and the eventual fn-up must pass through for real).
    public enum HoldState: Equatable, Sendable {
        case idle
        /// fn is down and currently swallowed; no other key has interrupted it yet.
        case swallowingSolo
        /// fn is down, but a combo key already interrupted it — a synthetic fn-down was posted,
        /// so the real fn-up must be allowed through to balance it.
        case comboActive
    }

    /// A pure state machine instance. Not thread-safe; callers (the `@MainActor` event tap
    /// handler) own a single instance and mutate it serially, matching how CGEventTap delivers
    /// events on the tap's run loop.
    public struct State: Equatable, Sendable {
        public private(set) var hold: HoldState = .idle

        public init() {}

        /// Call when the fn `flagsChanged` transitions to down. Always swallow: we don't yet
        /// know if this will turn out to be a solo press/hold or the start of a combo.
        @discardableResult
        public mutating func fnDown() -> Action {
            hold = .swallowingSolo
            return .swallow
        }

        /// Call when the fn `flagsChanged` transitions to up.
        @discardableResult
        public mutating func fnUp() -> Action {
            defer { hold = .idle }
            switch hold {
            case .idle:
                // Shouldn't normally happen (up without a matching down), but never swallow an
                // orphaned up — passing it through is the safer default.
                return .pass
            case .swallowingSolo:
                // Solo press/hold, released without any other key: this is exactly the case we
                // must hide from macOS (both the Globe action and the Dictation double-press
                // fire on this pattern), so swallow the up too.
                return .swallow
            case .comboActive:
                // A synthetic down was already posted for the combo; the real up must reach the
                // app/macOS to balance it, or fn would appear stuck down.
                return .passRelease
            }
        }

        /// Call when any other key (`keyDown`) arrives while fn's `flagsChanged` state is
        /// currently down. Returns whether the caller must re-post a synthetic fn-down
        /// `flagsChanged` before delivering that key event, so the combo behaves normally.
        @discardableResult
        public mutating func otherKeyPressed() -> Bool {
            switch hold {
            case .idle:
                // fn isn't down (or we've already handed off) — nothing to repost.
                return false
            case .swallowingSolo:
                hold = .comboActive
                return true
            case .comboActive:
                // Already handed off for this hold; subsequent keys in the same combo (e.g.
                // holding fn and tapping multiple arrows) need no further repost.
                return false
            }
        }
    }
}
