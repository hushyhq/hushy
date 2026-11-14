import AppKit
import MurmurCore
import SwiftUI

/// "Coding": lets the user pick a project folder so Hushy can learn its identifiers and file names — used for ASR
/// boosting and for "@name.ext" file tagging in a code style context (see `ProjectVocabularyScanner`,
/// `CodeFileTags`). Self-contained: it reads the app-wide `ProjectVocabularySettings` (owned by `AppModel`, so a scan
/// started here keeps running and reaches `DictationController` after this card leaves the screen) from the
/// environment. With no project it is one drop zone (click to choose, or drop a folder on it); with one it shows the
/// project and what was learned from it.
struct CodingSettingsCard: View {
    @Environment(AppModel.self) private var model
    private var vocabularySettings: ProjectVocabularySettings { model.codingProjectVocabulary }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let name = vocabularySettings.projectName {
                ProjectCard(name: name, state: vocabularySettings.scanState, choose: chooseFolder,
                            rescan: vocabularySettings.rescan, remove: vocabularySettings.removeProject)
            } else {
                ProjectDropZone(choose: chooseFolder, drop: use)
            }
            HStack(spacing: Theme.Space.s) {
                BenefitPill(symbol: "waveform", text: VoiceStyleCopy.codingHears)
                BenefitPill(symbol: "at", text: VoiceStyleCopy.codingTags)
            }
        }
    }

    private func chooseFolder() {
        vocabularySettings.chooseFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = false
            panel.message = VoiceStyleCopy.codingPanelMessage
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }

    /// A folder dropped on the zone takes the same path as one chosen in the panel.
    private func use(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        vocabularySettings.chooseFolder { url }
        return true
    }
}

/// No project yet: a dashed zone that opens the folder panel on click and takes a folder dropped from Finder.
private struct ProjectDropZone: View {
    let choose: () -> Void
    let drop: (URL) -> Bool
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var targeted = false

    private var isHot: Bool { hovering || targeted }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let zone = Button(action: choose) {
            VStack(spacing: Theme.Space.m) {
                FolderMark(isHot: isHot)
                VStack(spacing: 4) {
                    Text(VoiceStyleCopy.codingPick).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(VoiceStyleCopy.codingPickLine).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 36)
            .background(shape.fill(targeted ? Theme.phosphorTint : (hovering ? Theme.bgRaised : Theme.well(scheme).opacity(0.7))))
            .overlay(shape.strokeBorder(isHot ? Theme.phosphor.opacity(0.7) : Theme.textTertiary.opacity(0.35),
                                        style: StrokeStyle(lineWidth: isHot ? 1.5 : 1, dash: [6, 5])))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: isHot)
        .accessibilityLabel(VoiceStyleCopy.codingPick)
        .accessibilityHint(VoiceStyleCopy.codingPickLine)
        if isSnapshot {
            zone
        } else {
            zone.dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return drop(url)
            } isTargeted: { targeted = $0 }
        }
    }
}

/// A folder with code brackets on it, lifting when the zone is under the pointer or a drag.
private struct FolderMark: View {
    let isHot: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(isHot ? Theme.phosphorFill : Theme.textTertiary.opacity(0.55))
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHot ? Theme.onPhosphor : Theme.bgRaised)
                .offset(y: 2)
        }
        .frame(width: 52, height: 44)
        .offset(y: isHot && !reduceMotion ? -2 : 0)
        .animation(Theme.Motion.lift, value: isHot)
        .accessibilityHidden(true)
    }
}

/// The chosen project: its name, the scan's state, what was learned, and the three things a person can do.
private struct ProjectCard: View {
    let name: String
    let state: ProjectVocabularySettings.ScanState
    let choose: () -> Void
    let rescan: () -> Void
    let remove: () -> Void

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.phosphor)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.phosphorTint))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        status
                    }
                    Spacer(minLength: Theme.Space.m)
                    IconButton(symbol: "arrow.clockwise", help: "Rescan", action: rescan)
                    Button("Change…", action: choose).buttonStyle(SecondaryButtonStyle())
                    IconButton(symbol: "xmark", help: "Remove project", tint: Theme.textTertiary, action: remove)
                }
                .padding(Theme.Space.l)
                if case .done(_, let identifiers, let fileNames) = state {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    HStack(spacing: Theme.Space.xxl) {
                        Stat(value: identifiers.formatted(), label: "identifiers")
                        Stat(value: fileNames.formatted(), label: "file names")
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .idle, .done:
            Text("Learned on this Mac").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        case .scanning:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Reading names…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption).foregroundStyle(Theme.warning)
        }
    }
}

/// One thing the project folder is used for, as a small quiet pill.
private struct BenefitPill: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.bgSunken))
        .accessibilityElement(children: .combine)
    }
}
