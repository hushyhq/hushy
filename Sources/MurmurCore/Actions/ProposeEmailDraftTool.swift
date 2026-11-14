import Foundation

/// `propose_email_draft`: a draft the user opens in their own mail client and sends
/// themselves — never auto-sent (ASSISTANT-ACTIONS.md §1, "Never"). Validate-and-acknowledge
/// only, on both sides of the bridge.
public enum ProposeEmailDraftTool {
    public static let name = "propose_email_draft"

    public static func validate(
        _ arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<EmailDraftProposal, ProposalValidationError> {
        do {
            let to = try ProposalFields.emailList(arguments, "to", maxCount: ProposalFields.maxRecipientCount)
            guard !to.isEmpty else {
                throw ProposalValidationError(message: "to must contain at least one email address.")
            }
            let cc = try ProposalFields.emailList(arguments, "cc", maxCount: ProposalFields.maxRecipientCount)
            let replyTo = try ProposalFields.optionalText(arguments, "replyToMessageId", limit: ProposalFields.maxIdentifierLength)
            if let replyTo, replyTo.contains(where: \.isWhitespace) {
                throw ProposalValidationError(message: "replyToMessageId must be a single Message-ID without spaces.")
            }
            return .success(EmailDraftProposal(
                to: to, cc: cc,
                subject: try ProposalFields.requiredFreeText(arguments, "subject", limit: ProposalFields.maxSubjectLength),
                body: try ProposalFields.requiredFreeText(arguments, "body", limit: ProposalFields.maxBodyLength),
                replyToMessageID: replyTo, sourceText: sourceText))
        } catch let error as ProposalValidationError {
            return .failure(error)
        } catch {
            return .failure(ProposalValidationError(message: "Invalid proposal."))
        }
    }

    /// "email draft to dana@example.com “Deck on Monday”".
    public static func summary(of proposal: EmailDraftProposal) -> String {
        let reply = proposal.replyToMessageID == nil ? "" : " (a reply)"
        return "email draft to \(proposal.to.joined(separator: ", ")) “\(proposal.subject)”\(reply)"
    }
}
