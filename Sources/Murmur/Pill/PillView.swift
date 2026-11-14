import MurmurCore
import SwiftUI

/// The always-dark floating capsule that shows dictation state.
///
/// One design language for every recording mode (see docs/research/competitor-ux.md and the
/// Wispr Flow reference): a small capsule where the waveform is the visual focus and, when
/// there's something to confirm, a muted ✕ on the left and a phosphor ✓ on the right — never
/// a big standalone stop button.
struct PillView: View {
    @Bindable var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var shake: CGFloat = 0
    @State private var confirmingDiscard = false
    @Environment(\.pillHintStyle) private var hintStyle
    /// The system appearance around the always-dark pill (read before `body` forces dark).
    @Environment(\.colorScheme) private var hostScheme
    /// The showing hover hint's size, so it can be kept inside the panel.
    @State private var tooltipSize = CGSize(width: 60, height: 22)

    var body: some View {
        // Every dictation outcome is a one-line pill state (UI round 2026-09-28 §1). The only
        // thing that rises above the capsule is a question Hushy asked: a banner, or the rows of
        // a stacked confirm card, which sit directly on the capsule and share its left edge.
        // At the top edge everything opens downward; at a side edge the stack hugs that side.
        ZStack {
            if let card = stackedConfirmCard {
                VStack(alignment: layout.stackEdge, spacing: 0) {
                    if layout.opensDownward {
                        pill
                        confirmCard(card).pillHitRegion().onHover { if $0 { model.renewCardKeys() } }
                    } else {
                        confirmCard(card).pillHitRegion().onHover { if $0 { model.renewCardKeys() } }
                        pill
                    }
                }
                .transition(opening)
            } else if case .answer(let card) = model.state {
                // The answer card stacks on the capsule the same way and opens toward the
                // centre; the capsule is its footer (thinking shimmer, follow-up glow, keys).
                VStack(alignment: layout.stackEdge, spacing: 0) {
                    if layout.opensDownward {
                        pill
                        answerCard(card).pillHitRegion()
                    } else {
                        answerCard(card).pillHitRegion()
                        pill
                    }
                }
                .transition(opening)
            } else if case .noField(let mode) = model.state, let text = model.noFieldText {
                // The no-field card stacks on the capsule like the answer card. The pointer
                // resting on it holds the timer (`PillCoordinator.scheduleSelfDismiss`).
                VStack(alignment: layout.stackEdge, spacing: 0) {
                    if layout.opensDownward {
                        pill
                        noFieldCard(mode, text: text)
                    } else {
                        noFieldCard(mode, text: text)
                        pill
                    }
                }
                .transition(opening)
            } else if model.isVisible {
                pill
            }
        }
        .padding(.horizontal, layout.sidePadding)
        // Exactly the panel, never more: with no minimum the frame grows to fit a row wider than
        // the panel (a row arriving before the panel has grown, a row still leaving after it has
        // shrunk), the content is then centred in that larger box instead of in the panel, and
        // the shapes below are reported in the box's coordinates, not the panel's.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: layout.alignment)
        .coordinateSpace(name: PillLayout.space)
        // Hover hints are drawn here, over the whole panel and outside the capsule's clip,
        // centred on the button they describe (`PillTooltipPlacement`).
        .overlayPreferenceValue(PillTooltipPreferenceKey.self) { request in
            GeometryReader { proxy in
                if let request { hintView(request, button: proxy[request.anchor], container: proxy.size) }
            }
        }
        .onPreferenceChange(PillHitRegionKey.self) { regions in model.hitRegions = regions }
        .animation(motion.animation(model.changeRole, reduceMotion: reduceMotion), value: model.state)
        .animation(motion.animation(model.isVisible ? .open : .close, reduceMotion: reduceMotion), value: model.isVisible)
        .animation(motion.animation(model.banner == nil ? .fall : .rise, reduceMotion: reduceMotion), value: model.banner)
        .onChange(of: model.state) { oldState, newState in
            if case .error = newState, !reduceMotion { runShake() }
            // Once, as the failure appears: not again when its kept audio runs out and the words change.
            if newState.isFailure, !oldState.isFailure, !reduceMotion { runShake() }
            confirmingDiscard = false
        }
        .environment(\.colorScheme, .dark)
        .environment(\.pillMotion, motion)
        .environment(\.pillReduceMotionOverride, model.reduceMotionOverride)
    }

    private var layout: PillLayout { PillLayout(anchor: model.anchor) }

    /// The pill's timings and whether it holds still (`PillMotion`); the preview can swap both.
    private var motion: PillMotion { model.motion }
    private var reduceMotion: Bool { model.reduceMotionOverride ?? systemReduceMotion }

    /// How anything that opens from the capsule arrives and leaves: from the capsule's side, or
    /// in place under Reduce Motion.
    private var opening: AnyTransition {
        reduceMotion ? .opacity : .move(edge: layout.openingEdge).combined(with: .opacity)
    }

    /// Hover expansion and hint labels are off while the pill is being dragged.
    private var isHoverShown: Bool { model.isHovered && !model.isDragging }

    /// The capsule stands vertical at a side edge (not while a text row like "Discard note?"
    /// shows). While dragging it follows the edge being approached.
    private var vertical: Bool {
        let edge = PillLayout(anchor: model.isDragging ? model.dragAnchor ?? model.anchor : model.anchor)
        return edge.isVertical(model.state) && !confirmingDiscard
    }

    /// The capsule's content stack: a row, or a column when the pill stands vertical.
    private func stack<Content: View>(_ spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        return layout(content)
    }

    /// The hover hint, centred on its button (clamped inside the panel) with its notch on the
    /// button. Compact: 8 pt clear, a fade. A/B/C: 9 pt to the notch tip; C scales in from the
    /// button (a fade under Reduce Motion).
    @ViewBuilder
    private func hintView(_ request: PillTooltipRequest, button: CGRect, container: CGSize) -> some View {
        if request.expand {
            ExpandedConfirmCapsule(hint: request.hint)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                .position(ExpandedConfirmCapsule.centre(button: button, width: tooltipSize.width, container: container,
                                                        growsRight: vertical && model.anchor == .left))
                .transition(.opacity)
        } else {
            hintBubble(request, button: button, container: container)
        }
    }

    /// A text hint (controls that keep one, or the `.hint` affordance): above/below the pill, or
    /// beside a vertical pill toward the screen centre, centred on its button, notch on it.
    private func hintBubble(_ request: PillTooltipRequest, button: CGRect, container: CGSize) -> some View {
        // A hint that names a key is always the small row, whatever the hint style.
        let compact = hintStyle == .compact || request.namesKey
        let gap: CGFloat = compact ? PillTooltipPlacement.gap : 9
        let beside = vertical
        let toRight = model.anchor == .left
        let centre = beside
            ? PillTooltipPlacement.centreBeside(button: button, bubble: tooltipSize, container: container,
                                                toRight: toRight, gap: gap)
            : PillTooltipPlacement.centre(button: button, bubble: tooltipSize, container: container,
                                          opensDownward: layout.opensDownward, gap: gap)
        let notch = beside
            ? PillTooltipPlacement.notchOffset(along: button.midY - centre.y, length: tooltipSize.height, inset: 8)
            : PillTooltipPlacement.notchOffset(button: button, centre: centre, bubbleWidth: tooltipSize.width)
        let pointing: Edge = beside ? (toRight ? .leading : .trailing) : (layout.opensDownward ? .top : .bottom)
        return Group {
            if compact {
                TooltipBubble(text: request.hint.compact)
            } else {
                PillHintBubble(hint: request.hint, style: hintStyle, hostScheme: hostScheme,
                               pointing: pointing, notchOffset: notch)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .position(centre)
        .transition(hintStyle == .solid && !reduceMotion && !compact
            ? .scale(scale: 0.9, anchor: layout.opensDownward ? .top : .bottom).combined(with: .opacity)
            : .opacity)
    }

    /// The capsule plus what opens from it (banner, hint label, format chip), stacked toward the
    /// screen centre.
    private var pill: some View {
        VStack(alignment: layout.horizontal, spacing: 6) {
            if layout.opensDownward {
                capsule
                accessories
            } else {
                accessories
                capsule
            }
        }
        .animation(hoverAnimation, value: model.isHovered)
        .animation(hoverAnimation, value: model.hoveredIdleControl)
    }

    @ViewBuilder
    private var accessories: some View {
        if let banner = model.banner, stackedConfirmCard == nil {
            CallDetectionBanner(
                banner: banner,
                onRecord: { model.onBannerRecord?($0) },
                onDismiss: { model.onBannerDismiss?() },
                onNever: { model.onBannerNever?($0) },
                onCancelCountdown: { model.onBannerCancelCountdown?() })
                .pillHitRegion()
                .transition(opening)
        } else if isIdle && isHoverShown {
            // One hint label, then (only when a format is forced) the chip, then the pill —
            // stacked in the VStack so nothing overlaps: the hint *replaces* its text when
            // the pointer moves from mic to ⚡ instead of a second bubble appearing on top.
            idleHintLabel
                .pillHitRegion()
                .transition(opening)
            if model.showsModeChip {
                modeChip
                    .pillHitRegion()
                    .transition(opening)
            }
        } else if isHoverShown, let detail = model.state.hoverDetail {
            // What a compact action row leaves out (a done chip's time and place, the action that
            // failed), in the idle hint's place and shape, while the pointer rests on the capsule.
            hintLabel {
                Text(detail).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.hoverDetailLimit)
            }
                .transition(opening)
        }
    }

    private var capsule: some View {
        // Vertical at a side edge: the same capsule turned on its end (10×40 at rest).
        content
            .frame(minWidth: minimumContentWidth)
            .frame(width: contentWidth, height: contentHeight)
            .padding(vertical ? .vertical : .horizontal, horizontalPadding)
            // Growing for the live words is one move; under Reduce Motion the pill is simply wider.
            .animation(reduceMotion ? nil : motion.animation(.morph), value: model.live.isWide && !vertical)
            // Real cleanup progress, when there is some: a hairline along the capsule's lower edge.
            .overlay(alignment: .bottom) { if isWriting, !vertical { PillWritingProgress(model: model) } }
            .background(background)
            .clipShape(Capsule())
            .pillHitRegion()
            .overlay(
                // A light hairline border at rest so the pill reads on both light and dark
                // backgrounds (see the "nearly invisible over a dark UI" feedback) — the
                // dark fill plus a bright edge holds up either way, unlike the previous
                // low-opacity phosphor outline that vanished on dark chrome.
                Capsule().strokeBorder(.white.opacity(isIdle && !isHoverShown ? 0.28 : 0.08), lineWidth: isIdle && !isHoverShown ? 1 : 0.5))
            .shadow(color: .black.opacity(isIdle ? 0.28 : 0.35), radius: isIdle ? 6 : 10, y: isIdle ? 2 : 4)
            // Afterglow: only a live pill glows (mic open). It cools, rather than blinks off,
            // when the key is released (DESIGN-LANGUAGE.md §1, rule 1).
            .overlay(Capsule().strokeBorder(Theme.phosphorFill.opacity(isLive ? 0.32 : 0), lineWidth: 0.75))
            // The pill floats over any app, light or dark: a crisp phosphor rim carries "live"
            // on paper, and a small, low halo adds the glow on dark hosts without reading as
            // a muddy shadow on light ones.
            .shadow(color: Theme.phosphorFill.opacity(isLive ? 0.16 : 0), radius: isLive ? 6 : 0)
            .animation(motion.animation(isLive ? .fade : .cool, reduceMotion: reduceMotion), value: isLive)
            .scaleEffect(isIdle && isHoverShown && !reduceMotion ? 1.08 : 1)
            .offset(x: shake)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            .onHover { hovering in
                withAnimation(hoverAnimation) { model.isHovered = hovering }
                if hovering, isIdle { model.onModeChipWillShow?() }
                // Looking at a confirm card (inline row or footer) re-opens its ⏎/esc window.
                if hovering { model.renewCardKeys() }
            }
            .contentShape(Capsule())
            .onTapGesture { if isIdle { model.onTapIdle?() } }
            // A drag (≥ 4 pt) carries the pill; on release it snaps to the nearest edge centre.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in model.onDragChanged?() }
                    .onEnded { _ in model.onDragEnded?() })
            .contextMenu {
                // The format menu lives here too, so it stays reachable while the chip is
                // hidden (nothing forced → no chip, see `PillModel.showsModeChip`).
                if !model.modeChoices.isEmpty {
                    Menu("Format the next dictation as") { formatMenuItems(titled: false) }
                    Divider()
                }
                Button("Reset position") { model.onResetPosition?() }
                Button("Hide pill when idle") { model.onHide?() }
            }
            // Rows with their own buttons keep them reachable; everything else reads as one.
            .accessibilityElement(children: rowHasControls ? .contain : .combine)
            .accessibilityLabel(model.accessibilityLabel)
            .recoveryAccessibilityActions(model)
    }

    /// Hover in/out is spatial (the pill grows, labels slide up), so it is a plain fade under
    /// Reduce Motion.
    private var hoverAnimation: Animation { motion.animation(.morph, reduceMotion: reduceMotion) }

    /// The one hint label above the hovered idle pill, like Wispr's "Dictate fn" — its text
    /// follows `model.idleHint` ("Action fn ⌃" while the ⚡ button is hovered), so there is
    /// never a second tooltip to stack behind it or to cover the chip.
    private var idleHintLabel: some View {
        hintLabel {
            Text(model.idleHint.title).foregroundStyle(.white.opacity(0.85))
            ForEach(model.idleHint.keys, id: \.self) { KeyCap(label: $0) }
        }
    }

    /// The widest a hover detail may be, so it stays inside the row panel (`PillPanel.rowSize`).
    private static let hoverDetailLimit: CGFloat = 300

    /// The small capsule that opens from the pill toward the screen centre: the idle hint, and a
    /// compact action row's detail. VoiceOver reads the pill's own label instead.
    private func hintLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5, content: content)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// The format chip: "Format: Email" while a mode is forced for the *next* dictation, with
    /// a menu to pick another or (for a one-shot override) go back to Automatic. Hidden when
    /// nothing is forced — Hushy matching the app needs no label. In snapshot mode the chip is
    /// drawn as a static label, since `ImageRenderer` can't draw a `Menu`.
    @ViewBuilder
    private var modeChip: some View {
        if isSnapshot {
            modeChipLabel
        } else {
            Menu { formatMenuItems(titled: true) } label: { modeChipLabel }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    private var modeChipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.phosphorFill)
            Text(model.modeChipLabel ?? "").foregroundStyle(.white.opacity(0.85))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .accessibilityLabel("\(model.modeChipLabel ?? "Format") for the next dictation. Tap to change.")
    }

    /// "Format the next dictation as" — every mode, plus "Automatic" when a one-shot override
    /// is set. Shared by the chip and the pill's context menu. Picking a mode sets the manual
    /// override (`AppSettings.manualModeOverrideID`) consumed by the very next recording.
    @ViewBuilder
    private func formatMenuItems(titled: Bool) -> some View {
        // The chip menu needs the header to say what the list is; the context-menu submenu
        // already carries that title, so repeating it there would read twice.
        if titled {
            Section("Format the next dictation as") { formatChoices }
        } else {
            formatChoices
        }
        if model.canResetMode {
            Divider()
            Button { model.onResetMode?() } label: {
                Label("Automatic (match the app)", systemImage: "wand.and.stars")
            }
        }
    }

    private var formatChoices: some View {
        ForEach(model.modeChoices, id: \.id) { choice in
            Button { model.onPickMode?(choice.id) } label: {
                Label(choice.name, systemImage: choice.icon)
            }
        }
    }

    private var isIdle: Bool { model.state == .idle }

    /// A confirm card with more than one row: drawn above the capsule, which becomes its footer.
    private var stackedConfirmCard: ActionConfirmationCardState? {
        guard case .actionConfirm(let card) = model.state,
              ActionConfirmationCard.Layout(rowCount: card.rows.count) == .stacked else { return nil }
        return card
    }

    /// Outcome rows whose buttons VoiceOver must reach individually.
    private var rowHasControls: Bool {
        switch model.state {
        case .held(copied: false), .actionConfirm, .answer, .noField, .failed, .pastedUnchecked: true
        case .nameOffer(let phase, _, _): phase != .added
        case .actionDone(let chip): chip.canUndo
        case .voiceEdit(let chip): chip.canUndo
        case .restyle: true
        // ✕ and ✓ are separate things to VoiceOver, each with its key in its hint.
        case .actionListening: ActionPillLayout.listening(model.actionListeningMode).hasCancelControl
        case .actionProcessing: true
        default: false
        }
    }

    private func answerCard(_ card: AnswerCardState) -> AnswerCard {
        AnswerCard(
            card: card,
            onCopy: { model.onAnswerCopy?() },
            onSaveNote: { model.onAnswerSaveNote?() },
            onOpenSource: { model.onAnswerOpenSource?() },
            onOpenInAssistant: { model.onAnswerOpenInAssistant?() },
            onSuggestion: { model.onAnswerSuggestion?() },
            onClose: { model.onAnswerClose?() },
            onFileReveal: { model.onFileReveal?($0) },
            onFileOpen: { model.onFileOpen?($0) })
    }

    private func noFieldCard(_ mode: NoFieldMode, text: String) -> some View {
        NoFieldCard(
            mode: mode, text: text,
            onCopy: { model.copyNoFieldText() },
            onDismiss: { model.state = .idle })
            .recoveryAccessibilityActions(model)
            .pillHitRegion()
            .onHover { model.isPointerOverCard = $0 }
    }

    private func confirmCard(_ card: ActionConfirmationCardState) -> ActionConfirmationCard {
        ActionConfirmationCard(
            card: card,
            onConfirm: { model.onActionConfirmRow?($0) },
            onCancel: { model.onActionCancelRow?($0) },
            onEdit: { model.onActionEditRow?($0) },
            onOffer: { model.onActionOfferRow?($0) },
            onConfirmAll: { model.onActionConfirmAll?() },
            onCancelAll: { model.onActionCancelAll?() })
    }

    /// One action is the pill itself (inline row); more are a card above a footer capsule.
    @ViewBuilder
    private func confirmContent(_ card: ActionConfirmationCardState) -> some View {
        if let problem = card.soleProblemRow {
            ActionProblemRow(
                row: problem, keysLive: model.showsCardKeys,
                onRetry: { model.onActionConfirmRow?(problem) },
                onAcceptOffer: { model.onActionOfferRow?(problem) },
                onDismiss: { model.onActionCancelRow?(problem) })
        } else if stackedConfirmCard == nil {
            confirmCard(card)
        } else {
            ActionCardFooter(
                count: card.rows.count,
                isChoice: card.isChoice,
                keysLive: model.showsCardKeys,
                onConfirmAll: { model.onActionConfirmAll?() },
                onCancelAll: { model.onActionCancelAll?() })
        }
    }

    /// A dictation's bars, or, while a headset's microphone is still connecting, the grey dots
    /// and the words saying so. Grey, not lime: lime means Hushy is hearing.
    @ViewBuilder private var dictationWaveform: some View {
        if let waiting = model.inputCue.label {
            PillWritingView(since: .now, vertical: vertical, label: { _ in waiting }, tint: Theme.pillIdleMark)
                .accessibilityElement()
                .accessibilityLabel(waiting)
        } else if let words = model.liveWords(vertical: vertical) {
            PillLiveRow(text: words, variant: model.liveVariant, tint: .white.opacity(0.92)) {
                if model.liveVariant == .waveAndWords { dictationBars } else { PillLiveDot(level: model.levels.max()) }
            }
        } else {
            dictationBars
        }
    }

    /// The mic is open and heard: the only states that glow.
    private var isLive: Bool {
        switch model.state {
        case .listening, .handsFree: model.inputCue == .hearing && !model.awaitsFirstAudio
        case .recordingNote, .actionListening: true
        case .answer(let card): card.isListening
        default: false
        }
    }

    /// The single-action row grows the capsule once, to 44 pt; every other row is 30 pt, and so
    /// is a card that only reports what went wrong (`ActionProblemRow`).
    private var isInlineConfirm: Bool {
        if case .actionConfirm(let card) = model.state { return stackedConfirmCard == nil && card.soleProblemRow == nil }
        return false
    }

    /// Listening is a fixed-size capsule (`PillMetrics`, horizontal only): the padding is part
    /// of the size, so the content gets what is left of it.
    private var fixedCapsule: CGSize? {
        guard !vertical else { return nil }
        // An action heard with the chord held is dictation's Listening capsule with a bolt in it.
        if model.state == .actionListening { return ActionPillLayout.listening(model.actionListeningMode).fixedSize }
        if isLiveWide { return PillLiveWords.capsule }
        // The words need more room than the bars: the capsule fits them until sound arrives.
        if model.inputCue != .hearing { return nil }
        return PillMetrics.size(for: model.state)
    }

    /// Listening and Hands-free draw the larger v3 bars; the side pill keeps its compact ones.
    private var dictationMetrics: WaveformMetrics { vertical ? .standard : .dictation }

    /// Dictation's bars: grey until the microphone is heard, gliding between levels, and breathing
    /// a little in silence so an open microphone never looks frozen.
    private var dictationBars: Waveform {
        Waveform(levels: model.levels, peaks: model.peaks, metrics: dictationMetrics, vertical: vertical,
                 previous: model.previousLevels, updatedAt: model.levelsUpdatedAt,
                 isLive: !model.awaitsFirstAudio, breathesInSilence: !isSnapshot)
    }

    private var contentWidth: CGFloat? {
        if let fixed = fixedCapsule { return fixed.width - 2 * horizontalPadding }
        return vertical ? height : nil
    }

    private var contentHeight: CGFloat? {
        if let fixed = fixedCapsule { return fixed.height }
        if isWriting, !vertical { return PillMetrics.listening.height }
        return vertical ? nil : height
    }

    private var isWriting: Bool { model.state.isWriting }

    /// Push-to-talk or the wait after it, grown to fit the live words: a fixed width from the first words on, so
    /// the capsule never follows the text (hands-free fits its row instead).
    private var isLiveWide: Bool {
        guard model.state == .listening && model.inputCue.label == nil || isWriting else { return false }
        return model.liveWords(vertical: vertical) != nil
    }

    /// The wait keeps at least the listening capsule's size, so on release the pill does not
    /// shrink to its dots and then grow again for "Writing…". It still grows for longer words.
    private var minimumContentWidth: CGFloat? {
        isWriting && !vertical ? PillMetrics.listening.width - 2 * horizontalPadding : nil
    }

    private var height: CGFloat {
        switch model.state {
        case .idle: isHoverShown ? 34 : PillMetrics.idle.height
        default: isInlineConfirm ? 44 : 30
        }
    }

    private var horizontalPadding: CGFloat {
        switch model.state {
        case .idle: isHoverShown ? 5 : PillIdleMark.endPadding
        default: isInlineConfirm ? 14 : 10
        }
    }

    /// Idle-at-rest fill opacity: the mock's 80%. Dark and translucent enough to stay a Space,
    /// opaque enough to hold contrast over both light and dark host UIs — the earlier 55% outer
    /// opacity made the whole pill (fill *and* border) fade into dark chrome.
    private static let idleRestFillOpacity: Double = 0.8

    @ViewBuilder
    private var background: some View {
        // ImageRenderer can't draw NSVisualEffectView (VisualEffectBlur), so snapshot mode
        // takes the same solid-color path Reduce Transparency does.
        if reduceTransparency || isSnapshot {
            Theme.pill.opacity(isIdle && !isHoverShown ? Self.idleRestFillOpacity : 1)
        } else {
            ZStack {
                VisualEffectBlur()
                Theme.pillSurface
            }
            .opacity(isIdle && !isHoverShown ? Self.idleRestFillOpacity : 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            if isHoverShown {
                // Two controls, one focus: whichever the pointer is over takes the lime fill
                // and the other drops back to graphite, so the mic can't look "selected" while
                // ⚡ is hovered. Neither hovered (pointer on the capsule itself) reads as
                // dictate, the pill's click action.
                stack(6) {
                    IdleControlButton(
                        glyph: "mic.fill", glyphSize: 14, diameter: 28,
                        isFocused: model.hoveredIdleControl != .action,
                        action: { model.onTapIdle?() })
                        .onHover { model.hoveredIdleControl = $0 ? .dictate : nil }
                        .accessibilityLabel("Dictate")
                    // Action button next to the mic (brief: click to start an action utterance).
                    IdleControlButton(
                        glyph: "bolt.fill", glyphSize: 11, diameter: 24,
                        isFocused: model.hoveredIdleControl == .action,
                        action: { model.onActionButtonTap?() })
                        .onHover { model.hoveredIdleControl = $0 ? .action : nil }
                        .accessibilityLabel("Start an action")
                }
            } else {
                // Resting (design v3): five quiet grey marks, static. Present, never loud, and
                // no lime — lime means the mic is open.
                PillIdleMark(vertical: vertical)
            }
        case .listening:
            // Push-to-talk: the waveform alone, no chrome. Releasing the key finishes it.
            dictationWaveform
        case .handsFree(let start):
            // ✕ · bars · timer · ✓ (design v3, symbols not word caps). Standing vertical there is
            // no room for a timer: the three stack as before.
            stack(8) {
                PillCircleButton(glyph: "xmark", tint: .muted, tooltip: .cancel, namesKey: true) { model.onCancel?() }
                    .accessibilityLabel("Cancel")
                dictationWaveform
                if !vertical {
                    ElapsedTime(since: start)
                        .accessibilityLabel("Recording time")
                }
                PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: .paste, namesKey: true) { model.onStop?() }
                    .accessibilityLabel("Paste")
            }
            .fixedSize(horizontal: !vertical, vertical: false)
        case .recordingNote(let start):
            if confirmingDiscard {
                DiscardConfirmRow(
                    onKeep: { withAnimation(hoverAnimation) { confirmingDiscard = false } },
                    onDiscard: { model.onCancel?() })
            } else {
                stack(8) {
                    PillCircleButton(glyph: "xmark", tint: .muted, tooltip: .discardNote) {
                        withAnimation(hoverAnimation) { confirmingDiscard = true }
                    }
                    .accessibilityLabel("Discard note")
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.phosphorFill.opacity(0.9))
                    if model.isCapturingCallAudio {
                        // Call-audio indicator: a second, distinct glyph next to the mic one, so
                        // the recording banner clearly shows both streams are being captured
                        // (task requirement: "clearly indicate in the recording banner when call
                        // audio is being captured").
                        Image(systemName: "phone.arrow.down.left.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.phosphorFill.opacity(0.75))
                            .help("Recording call audio")
                            .accessibilityLabel("Recording call audio")
                    }
                    Waveform(levels: model.levels, vertical: vertical)
                    ElapsedTime(since: start)
                    PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: .saveNote) { model.onStop?() }
                        .accessibilityLabel("Stop and save")
                }
                .fixedSize(horizontal: !vertical, vertical: false)
            }
        case .processing:
            // Between key release and paste the user sees one thing: their words are being
            // written (design v3). Three purple dots; from 1 s the last few words already heard;
            // from 5 s a line that the wait is unusual and the words will still be pasted.
            // Standing vertical, the dots alone. After live words the words carry on at once, beside
            // the dots: what was heard, then what is written (`PillModel.liveWords`).
            if let words = model.liveWords(vertical: vertical) {
                PillLiveRow(text: words, variant: model.liveVariant, tint: Theme.pillWorking) {
                    if model.liveVariant == .waveAndWords {
                        PillWritingView(since: model.processingStartedAt ?? .now, label: { _ in nil },
                                        levels: model.foldLevels, progress: model.waitProgress)
                    } else {
                        PillLiveDot()
                    }
                }
            } else {
                PillWritingView(
                    since: model.processingStartedAt ?? .now, vertical: vertical,
                    label: { WritingPhase.label(after: $0, ink: model.ink?.text) },
                    levels: model.foldLevels, progress: model.waitProgress)
            }
        case .done(let words, let usedContext, let asHeard, let notSent, let notARewrite):
            PillDoneRow(words: words, usedContext: usedContext, asHeard: asHeard, notSent: notSent, notARewrite: notARewrite)
        case .copied(let reason):
            NotPastedRow(kind: .copied(reason))
        case .held(let copied):
            NotPastedRow(kind: .held(copied: copied), onCopy: { model.copyHeldText() },
                         onHistory: { model.openHeldInHistory() })
        case .actionConfirm(let card):
            confirmContent(card)
        case .answer(let card):
            AnswerCardFooter(
                card: card, levels: model.levels, peaks: model.peaks,
                actionKey: model.actionKeyCap,
                onFollowUp: { model.onAnswerFollowUp?() },
                onClose: { model.onAnswerClose?() })
        case .noField(let mode):
            NoFieldFooter(mode: mode, isLocked: model.isAppLocked())
        case .pastedUnchecked:
            PastedUncheckedRow(opensDownward: layout.opensDownward) { model.showUncheckedWords() }
        case .nameOffer(let phase, let words, let usedContext):
            PillNameOfferRow(phase: phase, words: words, usedContext: usedContext, model: model)
        case .actionDone(let chip):
            DoneChipRow(chip: chip, compact: true, onUndo: { model.onDoneUndo?() })
        case .voiceEdit(let chip):
            VoiceEditRow(chip: chip, onUndo: { model.onVoiceEditUndo?() }, onKeep: { model.state = .idle })
        case .restyle(let chooser):
            RestyleRow(chooser: chooser, onPick: { model.onRestylePick?($0) }, onToggleCopy: { model.onRestyleToggleCopy?() },
                       onCancel: { model.onRestyleCancel?() })
        case .failed(let failure):
            FailureRow(failure: failure, onRetry: { model.retryFailure() }, onUseMic: { model.useOfferedMic() }, onUseAutomatic: { model.useAutomatic() },
                       onDismiss: { model.dismissFailure() })
        case .error(let message):
            HStack(spacing: 8) {
                Circle().fill(Theme.error).frame(width: 6, height: 6)
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
            .fixedSize()
        case .actionListening:
            // Dictation's capsule with a bolt in it. Held: bolt and bars, and letting go sends.
            // Latched (the key twice, or the ⚡ button): ✕ · bolt · bars · ✓. ⏎ sends and esc
            // discards through the event tap (`PillKeyScope.finish`) either way; a hover on ✕ or ✓
            // names the key.
            ActionListeningRow(
                mode: model.actionListeningMode, levels: model.levels, peaks: model.peaks, vertical: vertical,
                onCancel: { model.onActionDiscardListening?() },
                onSend: { model.onActionStopListening?() })
        case .actionProcessing:
            // The stop is acknowledged at once: ✕ stays where it was, the bolt turns purple and the
            // bars become dots. ✕ (or esc) cancels before anything is created; ⏎ does nothing here.
            ActionWorkingRow(
                since: model.actionProcessingStartedAt ?? .now, vertical: vertical,
                onCancel: { model.onActionCancelProcessing?() })
        }
    }

    private func runShake() {
        let (distance, step, animation) = (CGFloat(motion.shakeDistance), motion.shakeStep / motion.speed, motion.shake)
        for (index, value) in [-distance, distance, -distance, distance, 0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * step) {
                withAnimation(animation) { shake = value }
            }
        }
    }
}

/// One of the idle pill's two round controls (mic, ⚡). `isFocused` is the whole design: the
/// focused one is filled phosphor with graphite ink, the other is a graphite disc whose glyph
/// keeps its identity tint (lime mic, white bolt) — hover moves the fill, not just a tooltip.
/// Pressing dips the disc slightly; under Reduce Motion the swap is a plain fade.
private struct IdleControlButton: View {
    let glyph: String
    let glyphSize: CGFloat
    let diameter: CGFloat
    let isFocused: Bool
    let action: () -> Void
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.onPhosphor : idleGlyphTint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(isFocused ? Theme.phosphorFill : .white.opacity(0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.1), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(IdleControlButtonStyle(reduceMotion: reduceMotion, fade: motion.animation(.fade)))
        .animation(motion.animation(.morph, reduceMotion: reduceMotion), value: isFocused)
    }

    private var idleGlyphTint: Color {
        glyph == "mic.fill" ? Theme.phosphorFill : .white.opacity(0.85)
    }
}

private struct IdleControlButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    let fade: Animation

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(fade, value: configuration.isPressed)
    }
}
