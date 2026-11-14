import MurmurCore
import SwiftUI

/// Snapshot-only: the Dictionary tab mid-search, or with no words yet.
struct DictionarySnapshot: Equatable {
    var query = ""
    var heardAs = ""
    var entries: [DictionaryEntry]?
    var hidesLearned = false
}

extension EnvironmentValues {
    @Entry var snapshotDictionary: DictionarySnapshot?
}

/// Dictionary tab of Voice & style: one field that both finds a word and adds it, the person's words as chips under
/// it, and what Hushy learned from their edits below. Typing narrows the chips; Return adds what was typed.
struct DictionaryTabContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotDictionary) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var term = ""
    @State private var soundsLike = ""

    private var query: String { snapshot?.query ?? term }
    private var entries: [DictionaryEntry] { snapshot?.entries ?? model.library.dictionary }

    private var shown: [DictionaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.term.localizedCaseInsensitiveContains(needle)
                || $0.soundsLike.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// Learned words in use, shown among the person's own words; a forgotten one stays in place with Undo.
    private var learned: [LearnedReview.Row] {
        if snapshot?.hidesLearned == true { return [] }
        return model.learned.sections(items: model.library.learnedItems).inUse.filter { $0.item.kind == .term }
    }

    private var shownLearned: [LearnedReview.Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return learned }
        return learned.filter {
            $0.item.value.localizedCaseInsensitiveContains(needle)
                || $0.item.heardAs.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var appNames: [Int64: String] {
        var names: [Int64: String] = [:]
        for dictation in model.library.dictations {
            if let id = dictation.id, let name = dictation.appName { names[id] = name }
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                AddWordBar(term: $term, soundsLike: $soundsLike,
                           snapshotTerm: snapshot?.query, snapshotHeardAs: snapshot?.heardAs, add: add)
                if !entries.isEmpty || !learned.isEmpty { counts }
                wall
            }
            LearnedFromEditsSection(showsInUse: false)
        }
    }

    private var counts: some View {
        HStack(spacing: Theme.Space.s) {
            Label(VoiceStyleCopy.wordCount(entries.count), systemImage: "person.fill")
                .help(VoiceStyleCopy.addedByYou)
            if !learned.isEmpty {
                Text("·").accessibilityHidden(true)
                Label(VoiceStyleCopy.learnedCount(learned.count), systemImage: "sparkles")
                    .foregroundStyle(Theme.working)
            }
        }
        .labelStyle(CountLabelStyle())
        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder private var wall: some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if entries.isEmpty && learned.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    ExampleChip(from: "super base", to: "Supabase")
                    ExampleChip(from: "pria", to: "Priya")
                }
                .opacity(0.7)
                .accessibilityHidden(true)
                Text(VoiceStyleCopy.dictionaryEmpty).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.Space.xs)
        } else if shown.isEmpty && shownLearned.isEmpty {
            Label(VoiceStyleCopy.noMatch(needle), systemImage: "return")
                .labelStyle(FootnoteLabelStyle())
                .padding(.vertical, Theme.Space.s)
        } else {
            WrapLayout(spacing: Theme.Space.s) {
                ForEach(shown) { entry in
                    WordChip(entry: entry, match: needle) {
                        if let id = entry.id { try? model.store.deleteDictionaryEntry(id: id) }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
                ForEach(shownLearned) { row in
                    LearnedWordChip(row: row, detail: LearnedPresentation.provenance(row.item, appNames: appNames),
                                    forget: { model.learned.forget(row.item, from: .list) },
                                    undo: { model.learned.undo(row.id) })
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(Theme.Motion.spatial(Theme.Motion.snappy, reduceMotion: reduceMotion),
                       value: shown.map(\.id) + shownLearned.map(\.id))
        }
    }

    private func add() {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let variants = soundsLike.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        _ = try? model.store.save(DictionaryEntry(term: trimmed, soundsLike: variants))
        term = ""
        soundsLike = ""
    }
}

/// The find-or-add field: the word, what it is often heard as, and Add. Return in either field adds.
private struct AddWordBar: View {
    @Binding var term: String
    @Binding var soundsLike: String
    let snapshotTerm: String?
    let snapshotHeardAs: String?
    let add: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focus: Field?

    private enum Field { case term, heardAs }

    private var typed: String { (snapshotTerm ?? term).trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: typed.isEmpty ? "magnifyingglass" : "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(typed.isEmpty ? Theme.textTertiary : Theme.phosphor)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            field(.term)
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18)
            Image(systemName: "ear").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            field(.heardAs).frame(maxWidth: 190)
            Button("Add", action: add)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(typed.isEmpty)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(shape.fill(Theme.bgRaised))
        .overlay(shape.strokeBorder(focus != nil ? Theme.phosphor.opacity(0.55) : Theme.hairline, lineWidth: focus != nil ? 1 : 0.5))
        .shadow(color: scheme == .dark ? .clear : Theme.cardShadow.opacity(Theme.cardShadowOpacity), radius: 10, y: 2)
        .animation(Theme.Motion.hover, value: focus)
    }

    @ViewBuilder private func field(_ which: Field) -> some View {
        let placeholder = which == .term ? VoiceStyleCopy.addWordPlaceholder : VoiceStyleCopy.heardAsPlaceholder
        if isSnapshot {
            SnapshotTextField((which == .term ? snapshotTerm : snapshotHeardAs) ?? "", placeholder: placeholder)
        } else {
            TextField(placeholder, text: which == .term ? $term : $soundsLike)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($focus, equals: which)
                .onSubmit(add)
                .accessibilityLabel(which == .term ? "Word" : "Often heard as")
        }
    }
}

/// One of the person's words: the word, what it is often heard as, and on hover a small ✕ that removes it.
private struct WordChip: View {
    let entry: DictionaryEntry
    let match: String
    let onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Text(entry.term).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            if !entry.soundsLike.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "ear").font(.system(size: 9, weight: .medium))
                    Text(entry.soundsLike.joined(separator: ", ")).lineLimit(1)
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.bgRaised))
        .overlay(Capsule().strokeBorder(isMatch ? Theme.phosphor.opacity(0.55) : (hovering ? Theme.textTertiary.opacity(0.5) : Theme.hairline),
                                        lineWidth: isMatch ? 1 : 0.75))
        .shadow(color: .black.opacity(scheme == .dark ? (hovering ? 0.35 : 0) : (hovering ? 0.1 : 0.04)),
                radius: hovering ? 5 : 1.5, y: hovering ? 2.5 : 1)
        .overlay(alignment: .topTrailing) {
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.bgRaised))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Remove \(entry.term)")
            .accessibilityHidden(true)
        }
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.lift, value: hovering)
        .contextMenu { Button("Remove \(entry.term)", role: .destructive, action: onDelete) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.soundsLike.isEmpty ? entry.term : "\(entry.term), heard as \(entry.soundsLike.joined(separator: ", "))")
        .accessibilityAction(named: "Remove") { onDelete() }
    }

    private var isMatch: Bool { !match.isEmpty }
}

/// A word Hushy learned from the person's edits: marked with the model's sparkle, its provenance on hover, Forget
/// under the pointer. Once forgotten it stays where it was, struck through, with Undo.
private struct LearnedWordChip: View {
    let row: LearnedReview.Row
    let detail: String
    let forget: () -> Void
    let undo: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isForgotten: Bool { row.outcome == .forgotten }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isForgotten ? Theme.textTertiary : Theme.working)
                .accessibilityHidden(true)
            Text(row.item.value).font(.system(size: 13, weight: .medium))
                .foregroundStyle(isForgotten ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(isForgotten, color: Theme.textTertiary)
            if isForgotten {
                UndoLink(accessibilityText: "Undo for \(row.item.value)", action: undo)
            } else if let heard = LearnedPresentation.heardAs(row.item) {
                HStack(spacing: 3) {
                    Image(systemName: "ear").font(.system(size: 9, weight: .medium))
                    Text(heard).lineLimit(1)
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(isForgotten ? Color.clear : Theme.workingTint.opacity(scheme == .dark ? 0.7 : 0.55)))
        .overlay(Capsule().strokeBorder(
            hovering && !isForgotten ? Theme.working.opacity(0.45) : Theme.working.opacity(isForgotten ? 0.15 : 0.22),
            style: StrokeStyle(lineWidth: 0.75, dash: isForgotten ? [3, 2] : [])))
        .overlay(alignment: .topTrailing) {
            if !isForgotten {
                Button(action: forget) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.bgRaised))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .help("Forget \(row.item.value)")
                .accessibilityHidden(true)
            }
        }
        .offset(y: hovering && !reduceMotion && !isForgotten ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.lift, value: hovering)
        .animation(Theme.Motion.fade, value: isForgotten)
        .help(detail)
        .contextMenu {
            if isForgotten { Button("Undo", action: undo) } else { Button("Forget \(row.item.value)", role: .destructive, action: forget) }
        }
        .accessibilityElement(children: isForgotten ? .contain : .ignore)
        .accessibilityLabel(isForgotten ? LearnedPresentation.forgottenLine(row.item) : "\(row.item.value), learned from your edits. \(detail)")
        .accessibilityAction(named: isForgotten ? "Undo" : "Forget") { isForgotten ? undo() : forget() }
    }
}

/// A count with a small glyph before it.
private struct CountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}
