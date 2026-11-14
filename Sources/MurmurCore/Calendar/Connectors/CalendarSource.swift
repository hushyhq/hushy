import Foundation

/// EventKit plus any direct connectors, read as one calendar (`docs/product/CONNECTORS.md`
/// §6.6). Readers are queried concurrently; one failing (offline, token revoked) doesn't hide
/// the others' events. The same meeting seen through two paths is collapsed by
/// `CalendarEventDeduplicator`.
public actor AggregateCalendarReader: CalendarReading {
    private let readers: [any CalendarReading]
    /// Errors from the most recent `events(from:to:)`, by reader index, for diagnostics/UI.
    public private(set) var lastFailures: [Int: any Error] = [:]

    public init(readers: [any CalendarReading]) {
        self.readers = readers
    }

    public func authorization() async -> CalendarAuthorization {
        var first: CalendarAuthorization?
        for reader in readers {
            let status = await reader.authorization()
            if status.canRead { return .fullAccess }
            first = first ?? status
        }
        return first ?? .notDetermined
    }

    /// Forwarded to every reader (only EventKit ever prompts; connectors answer unchanged).
    public func requestAccess() async -> CalendarAuthorization {
        var first: CalendarAuthorization?
        for reader in readers {
            let status = await reader.requestAccess()
            if status.canRead { return .fullAccess }
            first = first ?? status
        }
        return first ?? .notDetermined
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let results = await withTaskGroup(of: (Int, Result<[CalendarEvent], any Error>?).self) { group in
            for (index, reader) in readers.enumerated() {
                group.addTask {
                    guard await reader.authorization().canRead else { return (index, nil) }
                    do { return (index, .success(try await reader.events(from: from, to: to))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<[CalendarEvent], any Error>?)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var failures: [Int: any Error] = [:]
        var events: [CalendarEvent] = []
        var anySucceeded = false
        for (index, result) in results {
            switch result {
            case .success(let readerEvents)?: anySucceeded = true; events += readerEvents
            case .failure(let error)?: failures[index] = error
            case nil: break
            }
        }
        lastFailures = failures
        if !anySucceeded {
            if let firstFailure = failures.sorted(by: { $0.key < $1.key }).first { throw firstFailure.value }
            throw CalendarReadError.notAuthorized(await authorization())
        }
        return CalendarEventDeduplicator.merge(events)
    }
}

/// Collapses copies of the same meeting read through different paths (EventKit and a direct
/// connector for the same account, or two connectors).
///
/// Two copies are the same event when:
/// 1. both carry an `iCalUID` and the normalized UIDs match **and** they start in the same
///    minute (each occurrence of a recurring series shares the UID, so the start keeps them
///    apart); or
/// 2. normalized title, start minute and end minute match, and either copy lacks a UID or they
///    come from different sources (providers don't always expose the same UID to EventKit and
///    to their own API; the same title at the same time from two different paths is the same
///    meeting). Two same-source events with different UIDs are never merged on title.
///
/// The survivor is the copy with the most other attendees, then the most attendees; ties go to
/// EventKit (the zero-cost path), then to whichever came first in the input. Output is sorted by
/// start.
public enum CalendarEventDeduplicator {
    public static func merge(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var clusters: [(keeper: CalendarEvent, members: [CalendarEvent])] = []
        for event in events {
            if let index = clusters.firstIndex(where: { cluster in cluster.members.contains { isSame($0, event) } }) {
                clusters[index].members.append(event)
                if isRicher(event, than: clusters[index].keeper) { clusters[index].keeper = event }
            } else {
                clusters.append((event, [event]))
            }
        }
        // Stable sort by start keeps input order for simultaneous events.
        return clusters.map(\.keeper).enumerated()
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
            .map(\.element)
    }

    static func isSame(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if let uidA = normalizedUID(a.iCalUID), let uidB = normalizedUID(b.iCalUID), uidA == uidB,
           minute(a.start) == minute(b.start) {
            return true
        }
        guard titleKey(a) == titleKey(b) else { return false }
        return a.iCalUID == nil || b.iCalUID == nil || a.source != b.source
    }

    static func isRicher(_ candidate: CalendarEvent, than keeper: CalendarEvent) -> Bool {
        if candidate.otherAttendees.count != keeper.otherAttendees.count {
            return candidate.otherAttendees.count > keeper.otherAttendees.count
        }
        if candidate.attendees.count != keeper.attendees.count {
            return candidate.attendees.count > keeper.attendees.count
        }
        return candidate.source == .eventKit && keeper.source != .eventKit
    }

    /// Lower-cased, trimmed, with a trailing `@host` (e.g. `@google.com`) removed.
    static func normalizedUID(_ uid: String?) -> String? {
        guard var value = uid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        if let at = value.lastIndex(of: "@"), at != value.startIndex { value = String(value[..<at]) }
        return value
    }

    static func titleKey(_ event: CalendarEvent) -> String {
        let title = event.title.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\(title)|\(minute(event.start))|\(minute(event.end))"
    }

    static func minute(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
