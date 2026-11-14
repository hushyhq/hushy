import Foundation

/// One dictation's distance between what the recogniser heard and what was delivered, for the log: counts
/// only, never a word. With it a wrong word can be told apart without reading anyone's dictation: when the
/// delivered text is made of the recogniser's text the recogniser misheard, and when it is not the cleanup
/// changed it. `text` says whose text was delivered.
public struct RewriteDistance: Sendable, Equatable {
    /// Whose text the dictation was delivered as.
    public enum Delivered: String, Sendable {
        /// The model's answer, for every group.
        case model
        /// The rules draft: the model was not asked, or a check kept its answer out.
        case rules
        /// The rules draft because the model gave no answer in time, or wrote something that was not a rewrite of
        /// what was said (the pill's "as heard").
        case asHeard = "as-heard"
        /// A long dictation with groups of more than one kind.
        case mixed
    }

    public let heardWords: Int
    public let draftWords: Int
    public let account: RewriteAccount
    public let delivered: Delivered
    public let groups: Int
    public let modelGroups: Int
    public let usedMode: Bool

    public init(raw: String, text: String, groups: [GroupTrace], asHeard: Bool, usedMode: Bool = false) {
        heardWords = RewriteAccount.keys(raw).count
        draftWords = groups.reduce(0) { $0 + $1.words }
        account = RewriteAccount.measure(text, against: raw)
        self.groups = groups.count
        modelGroups = groups.filter { $0.outcome == .used }.count
        self.usedMode = usedMode
        delivered = if !groups.isEmpty, modelGroups == groups.count {
            .model
        } else if modelGroups > 0 {
            .mixed
        } else {
            asHeard ? .asHeard : .rules
        }
    }

    /// `rewrite heard=6 draft=6 delivered=5 in-order=4 elsewhere=0 new=1 share=83 text=model groups=1 model=1`.
    /// `in-order`, `elsewhere` and `new` are the delivered words that stand in the recogniser's text in its order,
    /// that are in it but not in that order, and that are not in it; `share` is the percent of the delivered
    /// letters the recogniser's text accounts for.
    public var line: String {
        var parts = [
            "rewrite heard=\(heardWords)", "draft=\(draftWords)", "delivered=\(account.words)",
            "in-order=\(account.inOrder)", "elsewhere=\(account.elsewhere)", "new=\(account.added)",
            "share=\(account.share)", "text=\(delivered.rawValue)", "groups=\(groups)", "model=\(modelGroups)",
        ]
        if usedMode { parts.append("mode=1") }
        return parts.joined(separator: " ")
    }
}
