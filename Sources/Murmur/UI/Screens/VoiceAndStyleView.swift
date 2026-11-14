import Combine
import MurmurCore
import SwiftUI

/// One settings page with five discoverable sections. Its Style section is where a person sets
/// how Hushy writes; other screens point here (`WritingHome`) instead of repeating its controls.
struct VoiceAndStyleView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case style, formats, dictionary, snippets, coding
        var id: String { rawValue }
        var title: String {
            switch self {
            case .style: "Style"
            case .formats: "Formats"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .coding: "Coding"
            }
        }
        var subtitle: String {
            switch self {
            case .style: "How each app reads"
            case .formats: "One-off shapes from the pill"
            case .dictionary: "Names and words"
            case .snippets: "Reusable phrases"
            case .coding: "Code dictation"
            }
        }
        var symbol: String {
            switch self {
            case .style: "textformat"
            case .formats: "rectangle.3.group"
            case .dictionary: "character.book.closed"
            case .snippets: "text.bubble"
            case .coding: "chevron.left.forwardslash.chevron.right"
            }
        }
        /// The one line under the section bar.
        var detail: String {
            switch self {
            case .style: "Drag an app to the tone it should write in."
            case .formats: VoiceStyleCopy.formatsLine
            case .dictionary: "Names and terms Hushy should spell your way."
            case .snippets: "Say a phrase, get the text."
            case .coding: "Your project's names, heard right."
            }
        }
    }

    @State private var tab: Tab = WritingHome.tab
    @Environment(\.snapshotVoiceStyleTab) private var snapshotTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Namespace private var plate

    private var selectedTab: Tab { snapshotTab ?? tab }

    nonisolated static func showsSectionSymbols(at width: CGFloat) -> Bool { width >= 620 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ScreenHeader(title: "Voice & style", subtitle: VoiceStyleCopy.pageSubtitle)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(Tab.allCases) { item in
                            VoiceStyleTab(item: item, isSelected: selectedTab == item,
                                          showsSymbol: Self.showsSectionSymbols(at: geometry.size.width),
                                          plate: plate) {
                                withAnimation(Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion)) { tab = item }
                            }
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card + 1).fill(Theme.well(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 1)
                        .strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 0.5))
                }
                .frame(height: 40)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Voice and style sections")

                Text(selectedTab.detail)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .id(selectedTab)
                    .transition(.opacity)
            }

            Group {
                switch selectedTab {
                case .style: StyleTabContent()
                case .formats: FormatsTabContent()
                case .dictionary: DictionaryTabContent()
                case .snippets: SnippetsTabContent()
                case .coding: CodingSettingsCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(selectedTab)
            .transition(.opacity)
        }
        .screen()
        // A pointer elsewhere (Settings → Writing) asked for a section while this page was showing.
        .onReceive(NotificationCenter.default.publisher(for: WritingHome.show)) { notification in
            if let requested = WritingHome.tab(in: notification) { tab = requested }
        }
    }
}

/// One of the five section tabs: a segment whose raised plate slides to it when picked. Not private, so a test can
/// host it and click it.
struct VoiceStyleTab: View {
    let item: VoiceAndStyleView.Tab
    let isSelected: Bool
    let showsSymbol: Bool
    /// Shared by the tabs of one bar so the selection plate travels between them.
    var plate: Namespace.ID?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsSymbol {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.phosphor : Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected || hovering ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background { selectionGround }
            // The whole tab takes the click, not only its words (its ground is clear until selected).
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card - 2))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(item.title), \(item.subtitle). \(item.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(item.subtitle)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
    }

    @ViewBuilder private var selectionGround: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card - 2)
        if isSelected {
            let raised = shape.fill(Theme.bgRaised)
                .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.07) : Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 3, y: 1)
            if let plate { raised.matchedGeometryEffect(id: "plate", in: plate) } else { raised }
        } else if hovering {
            shape.fill(Theme.selection.opacity(0.6))
        }
    }
}
