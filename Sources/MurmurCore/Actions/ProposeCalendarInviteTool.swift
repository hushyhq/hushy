import Foundation

/// `propose_calendar_invite`: an event **with attendees**, to be sent through the user's own
/// calendar account by their agent's connector — after a confirmation card in Hushy, which is
/// not built yet. Like `propose_action`, this validates and acknowledges only: the MCP server
/// has nothing that could send an invite, and the Assistant only keeps the parsed proposal.
public enum ProposeCalendarInviteTool {
    public static let name = "propose_calendar_invite"

    public static func validate(
        _ arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<CalendarInviteProposal, ProposalValidationError> {
        do {
            let title = try ProposalFields.requiredFreeText(arguments, "title", limit: ProposalFields.maxTitleLength)
            let start = try ProposalFields.requiredDate(arguments, "start", now: now, purpose: name)
            let minutes = try ProposalFields.durationMinutes(arguments)
            let attendees = try Self.attendees(arguments)
            return .success(CalendarInviteProposal(
                title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                attendees: attendees,
                notes: try ProposalFields.optionalFreeText(arguments, "notes", limit: ProposalFields.maxNotesLength),
                location: try ProposalFields.optionalFreeText(arguments, "location", limit: ProposalFields.maxNameLength),
                calendarHint: try ProposalFields.optionalText(arguments, "calendarHint", limit: ProposalFields.maxHintLength),
                sourceText: sourceText))
        } catch let error as ProposalValidationError {
            return .failure(error)
        } catch {
            return .failure(ProposalValidationError(message: "Invalid proposal."))
        }
    }

    /// Attendees may be strings ("dana@example.com", "Priya", "Dana Lee <dana@example.com>")
    /// or objects (`{"name": …, "email": …}`). At least one is required; every email must be
    /// well-formed; a name must not look like a mistyped address.
    static func attendees(_ arguments: [String: Any]) throws -> [ProposedAttendee] {
        guard let raw = arguments["attendees"], !(raw is NSNull) else {
            throw ProposalValidationError(message: "Missing argument: attendees (email addresses and/or names).")
        }
        let items: [Any] = (raw as? [Any]) ?? [raw]
        guard items.count <= ProposalFields.maxAttendeeCount else {
            throw ProposalValidationError(message: "attendees has too many entries (max \(ProposalFields.maxAttendeeCount)).")
        }
        let parsed = try items.compactMap(attendee)
        guard !parsed.isEmpty else {
            throw ProposalValidationError(message: "attendees must name at least one person (email address or name).")
        }
        return parsed
    }

    private static func attendee(_ item: Any) throws -> ProposedAttendee? {
        if let object = item as? [String: Any] {
            let name = try ProposalFields.optionalText(object, "name", limit: ProposalFields.maxNameLength)
            let email = try ProposalFields.optionalText(object, "email", limit: ProposalFields.maxEmailLength)
            if let email, !ProposalFields.isValidEmail(email) {
                throw ProposalValidationError(message: "Attendee email “\(ProposalFields.clip(email, 60))” isn't an email address.")
            }
            if let name, name.contains("@") {
                throw ProposalValidationError(message: "Attendee name “\(ProposalFields.clip(name, 60))” looks like an address; put it in email.")
            }
            guard name != nil || email != nil else { return nil }
            return ProposedAttendee(name: name, email: email)
        }
        guard let string = item as? String else {
            throw ProposalValidationError(message: "attendees must contain strings (email or name) or {name, email} objects.")
        }
        let cleaned = ProposalFields.clean(string)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= ProposalFields.maxEmailLength + ProposalFields.maxNameLength + 3 else {
            throw ProposalValidationError(message: "An attendee entry is too long.")
        }
        // "Dana Lee <dana@example.com>"
        if cleaned.hasSuffix(">"), let open = cleaned.lastIndex(of: "<") {
            let email = String(cleaned[cleaned.index(after: open)..<cleaned.index(before: cleaned.endIndex)])
            let name = cleaned[..<open].trimmingCharacters(in: .whitespaces)
            guard ProposalFields.isValidEmail(email) else {
                throw ProposalValidationError(message: "Attendee “\(ProposalFields.clip(cleaned, 60))” doesn't contain a valid email address.")
            }
            guard name.count <= ProposalFields.maxNameLength, !name.contains("@") else {
                throw ProposalValidationError(message: "Attendee name in “\(ProposalFields.clip(cleaned, 60))” is invalid.")
            }
            return ProposedAttendee(name: name.isEmpty ? nil : name, email: email)
        }
        if cleaned.contains("@") {
            guard ProposalFields.isValidEmail(cleaned) else {
                throw ProposalValidationError(message: "Attendee “\(ProposalFields.clip(cleaned, 60))” isn't a valid email address.")
            }
            return ProposedAttendee(email: cleaned)
        }
        guard cleaned.count <= ProposalFields.maxNameLength else {
            throw ProposalValidationError(message: "Attendee name “\(ProposalFields.clip(cleaned, 60))” is too long (max \(ProposalFields.maxNameLength) characters).")
        }
        return ProposedAttendee(name: cleaned)
    }

    /// "invite “Roadmap sync” at 2026-09-27T15:00:00-07:00 for 30 min to Priya, dana@example.com".
    public static func summary(of proposal: CalendarInviteProposal) -> String {
        let when = ProposalFields.isoFormatter().string(from: proposal.start)
        let who = proposal.attendees.map(\.display).joined(separator: ", ")
        return "invite “\(proposal.title)” at \(when) for \(proposal.durationMinutes) min to \(who)"
    }
}
