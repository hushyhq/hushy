@preconcurrency import EventKit
import Foundation
import MurmurCore

/// Reads the macOS calendar through the same full-access grant the Calendar voice action uses
/// (`EventKitActionBackend`), so there is exactly one permission and one System Settings switch.
/// Reads only. Event titles and attendee names pass through here and are never logged.
final class EventKitCalendarReader: CalendarReading, @unchecked Sendable {
    private let store = EKEventStore()
    /// `EKEventStore.events(matching:)` blocks, so reads run here rather than on a cooperative thread.
    private let readQueue = DispatchQueue(label: "app.hushy.calendar-read", qos: .userInitiated)

    /// The current grant without touching an event store or showing a prompt.
    static func currentAuthorization() -> CalendarAuthorization {
        authorization(from: EKEventStore.authorizationStatus(for: .event))
    }

    func authorization() async -> CalendarAuthorization { Self.currentAuthorization() }

    /// Shows the system prompt only while macOS has never been asked; after any decision the user
    /// changes it in System Settings, so this just reports the current state.
    func requestAccess() async -> CalendarAuthorization {
        guard Self.currentAuthorization().canPrompt else { return Self.currentAuthorization() }
        _ = try? await store.requestFullAccessToEvents()
        return Self.currentAuthorization()
    }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let status = Self.currentAuthorization()
        guard status.canRead else { throw CalendarReadError.notAuthorized(status) }
        return await withCheckedContinuation { continuation in
            readQueue.async {
                let predicate = self.store.predicateForEvents(withStart: from, end: to, calendars: nil)
                continuation.resume(returning: self.store.events(matching: predicate).map(Self.calendarEvent(from:)))
            }
        }
    }

    // MARK: - Mapping

    static func authorization(from status: EKAuthorizationStatus) -> CalendarAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        @unknown default: .denied
        }
    }

    static func status(from status: EKParticipantStatus) -> CalendarAttendee.ParticipantStatus {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
    }

    /// Participants carry their address as a `mailto:` URL.
    static func emailAddress(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count).prefix { $0 != "?" }
        return address.isEmpty ? nil : String(address)
    }

    private static func calendarEvent(from event: EKEvent) -> CalendarEvent {
        let attendees = (event.attendees ?? []).map { participant in
            CalendarAttendee(
                name: participant.name ?? "", email: emailAddress(from: participant.url),
                isCurrentUser: participant.isCurrentUser, status: status(from: participant.participantStatus))
        }
        let locationAndURL = [event.location, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        return CalendarEvent(
            eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            attendees: attendees, locationAndURL: locationAndURL, calendarTitle: event.calendar?.title ?? "",
            iCalUID: event.calendarItemExternalIdentifier, source: .eventKit)
    }
}
