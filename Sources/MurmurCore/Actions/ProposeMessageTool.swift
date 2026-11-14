import Foundation

/// `propose_message`: a chat message (Slack, Messages, WhatsApp, Teams, …) pre-filled for the
/// user to send. Hushy never posts on the user's behalf. Validate-and-acknowledge only.
public enum ProposeMessageTool {
    public static let name = "propose_message"

    static let maxChannelLength = 60
    static let maxRecipientLength = 200

    public static func validate(
        _ arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<MessageProposal, ProposalValidationError> {
        do {
            return .success(MessageProposal(
                channel: try ProposalFields.requiredText(arguments, "channel", limit: maxChannelLength).lowercased(),
                recipient: try ProposalFields.requiredFreeText(arguments, "recipient", limit: maxRecipientLength),
                text: try ProposalFields.requiredFreeText(arguments, "text", limit: ProposalFields.maxMessageLength),
                sourceText: sourceText))
        } catch let error as ProposalValidationError {
            return .failure(error)
        } catch {
            return .failure(ProposalValidationError(message: "Invalid proposal."))
        }
    }

    /// "slack message to #launch (43 characters)".
    public static func summary(of proposal: MessageProposal) -> String {
        "\(proposal.channel) message to \(proposal.recipient) (\(proposal.text.count) characters)"
    }
}
