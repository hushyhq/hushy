import AppKit
import MurmurCore
import SwiftUI

/// Voice & style → Dictionary → "Learned from your edits": what Hushy picked up from the
/// user's fixes (suggestions waiting for ✓, terms in use, per-app habits), each with its
/// provenance and a Forget/Confirm, plus the controls for learning itself.
struct LearnedFromEditsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    /// Off on the Dictionary tab, whose word chips already show the learned words in use (with Forget).
    var showsInUse = true

    var body: some View {
        @Bindable var settings = model.settings
        let sections = model.learned.sections(items: model.library.learnedItems)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header(isOn: $settings.learnFromEdits)
            if !settings.learnFromEdits {
                offNote
            }
            if sections.isEmpty {
                Card(padding: 0) { emptyLine }
            } else if showsInUse || !sections.suggestions.isEmpty || !sections.habits.isEmpty {
                Card(padding: 0) {
                    LearnedItemsList(sections: sections, appNames: appNamesByDictation, appName: appName(for:),
                                     showsInUse: showsInUse)
                }
            }
            BackwardTermReviewSection(library: model.library)
            KeepHeardSection(library: model.library)
            LearningControlsCard(onDelete: { confirmDelete = true })
        }
        .deleteLearningDataConfirmation(isPresented: $confirmDelete) { model.learned.deleteAllLearningData() }
    }

    private func header(isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.working)
                    .accessibilityHidden(true)
                Text(VoiceStyleCopy.learnedHeader).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .help(VoiceStyleCopy.learnedHelp)
            .accessibilityElement(children: .combine)
            .accessibilityHint(VoiceStyleCopy.learnedHelp)
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: Theme.Space.s) {
                Text("Learn from my edits").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                SwitchToggle(isOn: isOn)
                    .accessibilityLabel("Learn from my edits")
            }
            .fixedSize()
        }
    }

    private var offNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle").font(.system(size: 11, weight: .medium))
            Text("Paused. Hushy isn't reading fields after pasting. Words below stay in use until you forget them.")
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.textTertiary)
    }

    /// The empty state: one line that says what the feature does.
    private var emptyLine: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Fix a word after dictating. Known terms need one fix; other terms need two.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.l + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appNamesByDictation: [Int64: String] {
        var names: [Int64: String] = [:]
        for dictation in model.library.dictations {
            if let id = dictation.id, let name = dictation.appName { names[id] = name }
        }
        return names
    }

    private func appName(for bundleID: String?) -> String {
        LearnedAppName.name(for: bundleID, dictations: model.library.dictations)
    }
}

/// Human names for bundle IDs: the name Hushy recorded when dictating there, else the app's
/// name on disk, else the last part of the bundle ID.
@MainActor
enum LearnedAppName {
    static func name(for bundleID: String?, dictations: [Dictation]) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "this app" }
        if let recorded = dictations.first(where: { $0.appBundleID == bundleID })?.appName, !recorded.isEmpty {
            return recorded
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// The three groups, in one card separated by hairlines. Groups with nothing in them aren't
/// drawn (no empty sections).
private struct LearnedItemsList: View {
    @Environment(AppModel.self) private var model
    let sections: LearnedReview.Sections
    let appNames: [Int64: String]
    let appName: (String?) -> String
    var showsInUse = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("Suggestions", rows: sections.suggestions, isFirst: true)
            group("In use", rows: showsInUse ? sections.inUse : [], isFirst: sections.suggestions.isEmpty)
            group("Habits in your apps", rows: sections.habits,
                  isFirst: sections.suggestions.isEmpty && (sections.inUse.isEmpty || !showsInUse),
                  note: "Offered before use. Your styles stay your choice.")
        }
    }

    @ViewBuilder
    private func group(_ title: String, rows: [LearnedReview.Row], isFirst: Bool, note: String? = nil) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold).width(.expanded))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, isFirst ? Theme.Space.m + 2 : Theme.Space.l)
                .padding(.bottom, Theme.Space.xs)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    LearnedItemRow(
                        row: row, detail: rowDetail(for: row.item), title: rowTitle(for: row.item),
                        appBundleID: row.item.kind == .styleSignal ? row.item.appBundleID : nil,
                        appName: row.item.kind == .styleSignal ? appName(row.item.appBundleID) : nil,
                        isLast: index == rows.count - 1)
                }
            }
            .overlay(alignment: .top) {
                if !isFirst { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            }
        }
    }

    private func rowTitle(for item: LearnedItem) -> String {
        guard item.kind == .styleSignal else { return item.value }
        return LearnedPresentation.styleSentence(item, appName: appName(item.appBundleID)) ?? item.value
    }

    private func rowDetail(for item: LearnedItem) -> String {
        if item.kind == .styleSignal {
            let count = (item.observations > 0 ? item.observations : item.sourceDictationIDs.count)
            let choice = LearnedPresentation.canUseHabit(item)
                ? (item.confirmed ? "used in this app" : "use this habit in this app?")
                : "noted, not applied"
            return "seen \(LearnedPresentation.times(count)) · \(choice)"
        }
        return LearnedPresentation.provenance(item, appNames: appNames)
    }
}

/// One learned thing: name (dry ink), provenance (secondary), and its one action. A ready
/// suggestion gets the lime ✓ Add (it waits for the user); one seen once gets a quiet Add.
/// Decided rows cool to a single line with Undo, in place.
private struct LearnedItemRow: View {
    @Environment(AppModel.self) private var model
    let row: LearnedReview.Row
    let detail: String
    let title: String
    let appBundleID: String?
    var appName: String?
    let isLast: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if let appBundleID {
                // The real icon when installed, else a tinted initial (never a dashed blank).
                AppBadge(bundleID: appBundleID, appName: appName)
            }
            content
            Spacer(minLength: Theme.Space.m)
            trailing
        }
        .frame(minHeight: 34)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(hovering ? Theme.selection.opacity(0.45) : .clear)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.pop, value: row.outcome)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 0.5).padding(.leading, Theme.Space.l)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch row.outcome {
        case nil:
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if !detail.isEmpty {
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .added?:
            decided(LearnedPresentation.addedLine(row.item), checked: true)
        case .dismissed?:
            decided(LearnedPresentation.dismissedLine(row.item), checked: false)
        case .forgotten?:
            decided(LearnedPresentation.forgottenLine(row.item), checked: false)
        }
    }

    /// "✓ Added Okta to your dictionary · Undo": the decision and its Undo on one line, in place.
    private func decided(_ line: String, checked: Bool) -> some View {
        HStack(spacing: 6) {
            if checked { CoolingCheckmark() }
            Text(line).font(.system(size: 14)).foregroundStyle(checked ? Theme.textPrimary : Theme.textSecondary)
            Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            UndoLink(accessibilityText: "Undo for \(LearnedPresentation.displayName(row.item))") {
                model.learned.undo(row.id)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var trailing: some View {
        let item = row.item
        if row.outcome != nil {
            EmptyView()
        } else if (item.kind == .term && item.status == .candidate)
                    || (LearnedPresentation.canUseHabit(item) && !item.confirmed) {
            HStack(spacing: 6) {
                ConfirmGlyphButton(
                    symbol: "xmark", accessibilityText: "Don't suggest \(LearnedPresentation.displayName(item)) again",
                    help: "Don't suggest this again") { model.learned.dismiss(item, from: .list) }
                if item.kind == .styleSignal {
                    ConfirmVerbButton(verb: "Use", accessibilityText: "Use this habit in this app") {
                        model.learned.add(item, from: .list)
                    }
                } else if item.isReadySuggestion {
                    ConfirmVerbButton(verb: "Add", accessibilityText: "Add \(item.value) to your dictionary") {
                        model.learned.add(item, from: .list)
                    }
                } else {
                    Button("Add") { model.learned.add(item, from: .list) }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityLabel("Add \(item.value) to your dictionary")
                }
            }
            .fixedSize()
        } else {
            // A quiet link, not a capsule: a column of identical buttons would outweigh the words.
            UndoLink(title: "Forget", accessibilityText: "Forget \(LearnedPresentation.displayName(item))") {
                model.learned.forget(item, from: .list)
            }
                .help(item.kind == .term
                      ? "Stop using \(item.value) and never learn it from these edits again"
                      : "Stop noting this habit")
        }
    }
}

/// "Don't learn in these apps" and "Delete learning data".
private struct LearningControlsCard: View {
    @Environment(AppModel.self) private var model
    let onDelete: () -> Void

    var body: some View {
        SettingsGroup {
            SettingsRow(
                title: "Don't learn in these apps",
                detail: "Hushy never reads password fields, password managers, code editors or terminals.") {
                LearningExclusionsPicker()
            }
            SettingsRow(
                title: "Delete learning data",
                detail: "Removes every word and habit Hushy learned from your edits. Words you added to the dictionary yourself stay.") {
                Button("Delete…", action: onDelete).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// Excluded apps as removable chips, plus an "Add app" menu of apps the user recently
/// dictated into (and "Choose an app…" for any other).
struct LearningExclusionsPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let excluded = model.settings.learningExcludedApps.sorted { name($0) < name($1) }
        HStack(spacing: 6) {
            ForEach(excluded, id: \.self) { bundleID in
                ExcludedAppChip(name: name(bundleID), bundleID: bundleID) {
                    LearningExclusions.include(bundleID, in: model.settings)
                }
            }
            addMenu
        }
        .fixedSize()
    }

    @ViewBuilder
    private var addMenu: some View {
        if isSnapshot {
            // `ImageRenderer` can't draw a `Menu`; show its resting look.
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Add app")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        } else {
            Menu {
                let candidates = LearnedPresentation.exclusionCandidates(
                    dictations: model.library.dictations, excluded: model.settings.learningExcludedApps)
                if !candidates.isEmpty {
                    Section("Recently dictated into") {
                        ForEach(candidates) { app in
                            Button(app.name) { LearningExclusions.exclude(app.bundleID, in: model.settings) }
                        }
                    }
                }
                Button("Choose an app…", action: chooseApp)
            } label: {
                Label("Add app", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add an app to not learn in")
        }
    }

    private func name(_ bundleID: String) -> String {
        LearnedAppName.name(for: bundleID, dictations: model.library.dictations)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Don't learn in this app"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        LearningExclusions.exclude(bundleID, in: model.settings)
    }
}

private struct ExcludedAppChip: View {
    let name: String
    let bundleID: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            AppIcon(bundleID: bundleID).frame(width: 14, height: 14)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Learn in \(name) again")
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.bgSunken))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
    }
}

extension View {
    /// The one confirmation for "Delete learning data", shared by Voice & style and Settings.
    func deleteLearningDataConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog("Delete all learning data?", isPresented: isPresented) {
            Button("Delete learning data", role: .destructive, action: onConfirm)
        } message: {
            Text(LearningCopy.deleteConfirmation(keepsChanges: FeatureFlags.personMemory))
        }
    }
}
