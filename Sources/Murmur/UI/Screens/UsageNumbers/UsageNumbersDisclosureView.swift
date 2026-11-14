import MurmurCore
import SwiftUI

/// "What's sent": a short, calm summary first (one line and a few plain bullets, then what is never
/// sent), with today's batch field by field one quiet link away, collapsed by default. The summary
/// does not claim to be the full list; the detail is. Pure: it shows what it is given, so the live
/// sheet and the snapshots share one layout.
struct UsageNumbersDisclosureView: View {
    enum Phase: Equatable {
        /// The switch is off (the default): nothing is recorded or sent. The summary still shows, as
        /// what turning it on would record.
        case off
        /// On, but nothing has been recorded today yet.
        case empty
        /// On, with today's batch as titled groups of plain sentences, every field it holds.
        case sections([MetricsDisclosure.Section])
    }

    @Environment(\.isSnapshot) private var isSnapshot
    let phase: Phase
    /// Whether this build has somewhere to send them. False today: they wait on this Mac.
    let isUploadConfigured: Bool
    /// The exact body of the once-a-day count, with this build's number.
    var dailyCountExample = DailyCountDisclosure.exampleBody(build: DailyCountSender.bundleBuild())
    /// One real row of the edit-rate table, made by the encoder that makes the batch.
    var editRateExample = EditRateDisclosure.exampleRow
    var onDone: () -> Void = {}
    @State private var showDetails: Bool

    init(phase: Phase, isUploadConfigured: Bool, startsExpanded: Bool = false, onDone: @escaping () -> Void = {}) {
        self.phase = phase
        self.isUploadConfigured = isUploadConfigured
        self.onDone = onDone
        _showDetails = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("What's sent", systemImage: "chart.bar.doc.horizontal")
                .font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(intro).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            bullets
            dailyCount
            editRate
            if case .sections(let sections) = phase { detailsLink; if showDetails { details(sections) } }
            neverSent
            HStack {
                Spacer()
                Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }

    private var intro: String {
        switch phase {
        case .off:
            "Usage numbers are off: nothing is recorded, and the daily count below is the only thing sent. If you turn usage numbers on, this is what Hushy records:"
        case .empty, .sections:
            isUploadConfigured
                ? "Small daily batches of counts and timings. Never your words."
                : "Small daily batches of counts and timings. This version doesn't send these batches anywhere yet; they stay on this Mac and are deleted after a week. The daily count below is the only thing it sends."
        }
    }

    private var bullets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(MetricsDisclosure.SummaryBullet.allCases, id: \.rawValue) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("•").foregroundStyle(Theme.textTertiary)
                    Text(bullet.text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if phase == .empty {
                Text("Nothing recorded yet today. Numbers appear as you use Hushy.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.xs)
            }
        }
    }

    /// The once-a-day count, in full: what it says, when, and the exact message. Shown whether the
    /// usage-numbers switch is on or off: the daily count has a switch of its own.
    private var dailyCount: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(DailyCountDisclosure.title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text(DailyCountDisclosure.summary).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Card(padding: 0) {
                Text(dailyCountExample).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(DailyCountDisclosure.firstDayNote + " " + DailyCountDisclosure.switchNote)
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How often the person edits what Hushy wrote: what is counted, how it is grouped, and one real line.
    private var editRate: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(EditRateDisclosure.title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text(EditRateDisclosure.summary).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(EditRateDisclosure.exampleIntro).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Card(padding: 0) {
                Text(editRateExample).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(EditRateDisclosure.exampleMeaning).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A quiet link, not a button: the detail is for checking, not for everyone.
    private var detailsLink: some View {
        LinkLikeButton(title: showDetails ? "Hide today's batch" : "Show today's batch") {
            showDetails.toggle()
        }
    }

    @ViewBuilder private func details(_ sections: [MetricsDisclosure.Section]) -> some View {
        let list = VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Today's batch so far, field by field. This is the whole list of what a batch holds.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in sectionView(section) }
        }
        if isSnapshot {
            list   // a snapshot draws the whole list; a scroll view would not render
        } else {
            ScrollView { list }.frame(maxHeight: Self.maxListHeight)
        }
    }

    private static let maxListHeight: CGFloat = 360

    private func sectionView(_ section: MetricsDisclosure.Section) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(section.title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    }
                }
            }
        }
    }

    private var neverSent: some View {
        Label {
            Text(MetricsDisclosure.neverSent).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield").foregroundStyle(Theme.success)
        }
    }
}

/// The live sheet: asks the recorder for today's numbers when it opens.
struct UsageNumbersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var sections: [MetricsDisclosure.Section]?

    var body: some View {
        UsageNumbersDisclosureView(
            phase: phase, isUploadConfigured: model.usageMetrics.isUploadConfigured, onDone: { dismiss() })
            // Nothing is recorded while the sheet is open. Closing it is the answer: from then on the
            // numbers may be recorded (`AppSettings.usageNumbersNoticeSeen`).
            .onDisappear { if !isSnapshot { model.settings.usageNumbersNoticeSeen = true } }
            .task { sections = await model.usageMetrics.todaysSections() }
    }

    private var phase: UsageNumbersDisclosureView.Phase {
        guard model.settings.shareUsageNumbers else { return .off }
        guard let sections, !sections.isEmpty else { return .empty }
        return .sections(sections)
    }
}
