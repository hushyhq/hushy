import Foundation

/// `propose_issue`: a tracker issue (Linear, Jira, GitHub, Notion, …) the user's agent creates
/// through its own connector after a confirmation card. Validate-and-acknowledge only.
public enum ProposeIssueTool {
    public static let name = "propose_issue"

    static let maxTrackerLength = 60

    public static func validate(
        _ arguments: [String: Any], sourceText: String = "", now: Date = Date()
    ) -> Result<IssueProposal, ProposalValidationError> {
        do {
            let labels = try ProposalFields.stringList(
                arguments, "labels", maxCount: ProposalFields.maxLabelCount, itemLimit: ProposalFields.maxLabelLength)
            for label in labels { try ProposalFields.screen(label, "labels") }
            return .success(IssueProposal(
                tracker: try ProposalFields.requiredText(arguments, "tracker", limit: maxTrackerLength).lowercased(),
                project: try ProposalFields.requiredFreeText(arguments, "project", limit: ProposalFields.maxNameLength),
                title: try ProposalFields.requiredFreeText(arguments, "title", limit: ProposalFields.maxTitleLength),
                description: try ProposalFields.optionalFreeText(arguments, "description", limit: ProposalFields.maxDescriptionLength),
                labels: labels, sourceText: sourceText))
        } catch let error as ProposalValidationError {
            return .failure(error)
        } catch {
            return .failure(ProposalValidationError(message: "Invalid proposal."))
        }
    }

    /// "linear issue in Hushy “Paste fails in Figma comments”".
    public static func summary(of proposal: IssueProposal) -> String {
        "\(proposal.tracker) issue in \(proposal.project) “\(proposal.title)”"
    }
}
