import AppKit
import MurmurCore
import SwiftUI

extension EnvironmentValues {
    /// A live meeting for the Meetings snapshots; nil in the app, which reads the recorder.
    @Entry var snapshotMeetingLive: LiveMeetingState?
    @Entry var snapshotMeetingNow: Date?
}

/// Stills for the meetings round (2026-11-06): start, during, after and between meetings, light
/// and dark, plus a contact sheet of all of them. `HUSHY_SNAPSHOT_ONLY=mtg-` renders just these.
/// Every name, company and line below is invented.
extension Snapshots {
    static func renderMeetings(model: AppModel, size: CGSize, directory: URL) async {
        guard FeatureFlags.meetings, wantsAny(prefix: "mtg-") else { return }
        let seeded = MeetingFixtures.seed(into: model.store, now: model.dayClock.now)
        try? await Task.sleep(for: .seconds(1))
        model.meetings.calendar = StaticCalendarReader(events: [MeetingFixtures.upcoming(now: model.dayClock.now)])
        await model.meetings.refreshOverview(now: model.dayClock.now)
        for scheme in [ColorScheme.light, .dark] {
            await renderMeetings(model: model, seeded: seeded, scheme: scheme, size: size, directory: directory)
        }
    }

    private static func renderMeetings(
        model: AppModel, seeded: MeetingFixtures.Seeded, scheme: ColorScheme, size: CGSize, directory: URL
    ) async {
        model.section = .notes
        model.selectedNoteID = nil
        model.meetings.focus = .overview
        model.settings.assistantCollapsed = true

        await capture(MainView().environment(model), name: "mtg-overview", scheme: scheme, size: size, directory: directory)
        if model.meetings.crossMeetingMemory {
            await model.meetings.pinAnswerForSnapshot("What did we decide with Dana about the pilot?", now: model.dayClock.now)
            await capture(MainView().environment(model), name: "mtg-overview-ask", scheme: scheme, size: size, directory: directory)
            model.meetings.clearAnswer()
        }

        let now = model.dayClock.now
        for (name, live) in [("mtg-live", MeetingFixtures.live(now: now, callHeard: true)),
                             ("mtg-live-call-silent", MeetingFixtures.live(now: now, callHeard: false))] {
            await capture(
                MainView().environment(model).environment(\.snapshotMeetingLive, live).environment(\.snapshotMeetingNow, now),
                name: name, scheme: scheme, size: size, directory: directory)
        }

        if let pricing = seeded.pricing {
            model.selectedNoteID = pricing
            await capture(MainView().environment(model), name: "mtg-page", scheme: scheme, size: CGSize(width: size.width, height: 1500), directory: directory)
        }
        if let processing = seeded.processing {
            model.selectedNoteID = processing
            await capture(MainView().environment(model), name: "mtg-page-writing", scheme: scheme, size: size, directory: directory)
        }
        model.selectedNoteID = nil
        if model.meetings.crossMeetingMemory {
            model.meetings.focus = .person("Dana Kim")
            await capture(MainView().environment(model), name: "mtg-person", scheme: scheme, size: size, directory: directory)
            model.meetings.focus = .overview
        }

        let prompt = PillModel()
        prompt.state = .idle
        prompt.banner = .callDetected(app: .zoom, expiresAt: now.addingTimeInterval(18))
        await capture(
            PillView(model: prompt).padding(40).background(Theme.bgSunken).environment(\.colorScheme, scheme),
            name: "mtg-start-call-detected", scheme: scheme, size: CGSize(width: 560, height: 160), directory: directory, fixedSize: true)
        model.settings.assistantCollapsed = false
    }

    static func wantsAny(prefix: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["HUSHY_SNAPSHOT_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { prefix.hasPrefix($0) || $0.hasPrefix(prefix) }
    }

    /// One PNG with every `mtg-` still, light above dark, each labelled, for review at a glance.
    static func writeMeetingsContactSheet(directory: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("mtg-") && $0.hasSuffix(".png") && !$0.hasPrefix("mtg-contact") }.sorted()
        guard !files.isEmpty else { return }
        let thumbWidth: CGFloat = 660, columns = 4, label: CGFloat = 28, gap: CGFloat = 24
        let images = files.compactMap { name in NSImage(contentsOf: directory.appendingPathComponent(name)).map { (name, $0) } }
        let heights = images.map { thumbWidth * $0.1.size.height / max(1, $0.1.size.width) }
        let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for (index, height) in heights.enumerated() { rowHeights[index / columns] = max(rowHeights[index / columns], min(height, 1100)) }
        let width = CGFloat(columns) * thumbWidth + CGFloat(columns + 1) * gap
        let height = rowHeights.reduce(0) { $0 + $1 + label + gap } + gap
        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height - gap
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < images.count else { break }
                let x = gap + CGFloat(column) * (thumbWidth + gap)
                let (name, image) = images[index]
                let drawHeight = min(heights[index], 1100)
                let source = NSRect(x: 0, y: image.size.height * (1 - drawHeight / heights[index]), width: image.size.width,
                                    height: image.size.height * drawHeight / heights[index])
                image.draw(in: NSRect(x: x, y: top - label - drawHeight, width: thumbWidth, height: drawHeight), from: source, operation: .copy, fraction: 1)
                (name.replacingOccurrences(of: ".png", with: "") as NSString).draw(
                    at: NSPoint(x: x, y: top - label + 6),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
            }
            top -= rowHeights[row] + label + gap
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent("mtg-contact-sheet.png"))
    }
}
