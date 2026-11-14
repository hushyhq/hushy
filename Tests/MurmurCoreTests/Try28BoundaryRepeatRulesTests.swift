import Testing
@testable import MurmurCore

/// TRY-28 / Task 169: the rules draft must not fuse two sentences when the second starts with the
/// noun that ended the first, while still removing unambiguous stutters whole.
@Suite("TRY-28 boundary repeats and stutter collapse")
struct Try28BoundaryRepeatRulesTests {
    private let cleaner = TextCleaner()

    private func ruled(_ spoken: String) -> String {
        cleaner.clean(spoken).text
    }

    private func ruledLower(_ spoken: String) -> String {
        cleaner.clean(spoken).text.lowercased()
    }

    // MARK: Boundary repeats — both copies stay (invented)

    @Test("keeps a repeated noun phrase across an unpunctuated clausal boundary", arguments: [
        ("sent it to the landlord the landlord wants a reply this week", "landlord"),
        ("please check the budget budget numbers look off after the audit", "budget"),
        ("we shipped the build build two is next on the roadmap", "build"),
        ("dana will send the report report edits by noon tomorrow", "report"),
        ("open the invoice invoice line items need another pass", "invoice"),
        ("i emailed the contractor contractor rates changed again", "contractor"),
        ("they moved the deadline deadline details are in the thread", "deadline"),
        ("review the proposal proposal section still reads too long", "proposal"),
        ("call the vendor vendor support is closed until monday", "vendor"),
        ("update the roadmap roadmap owners already signed off", "roadmap"),
        ("share the spreadsheet spreadsheet formulas broke overnight", "spreadsheet"),
        ("file the receipt receipt total does not match the card", "receipt"),
        ("schedule the interview interview panel is only free friday", "interview"),
        ("track the milestone milestone notes live in the doc", "milestone"),
        ("publish the changelog changelog bullets need one more edit", "changelog"),
        ("merge the branch branch checks are still running", "branch"),
        ("deploy the hotfix hotfix window closes at five", "hotfix"),
        ("archive the ticket ticket history mentions the regression", "ticket"),
        ("attach the screenshot screenshot caption is still missing", "screenshot"),
        ("confirm the reservation reservation code never arrived", "reservation"),
        ("extend the trial trial limits reset at midnight", "trial"),
        ("cancel the subscription subscription page throws an error", "subscription"),
        ("rename the project project slug is already taken", "project"),
        ("rotate the password password policy blocks that one", "password"),
        ("export the dataset dataset schema changed yesterday", "dataset"),
        ("import the contacts contacts file uses the wrong delimiter", "contacts"),
        ("validate the payload payload signature fails on staging", "payload"),
        ("summarize the meeting meeting notes are still rough", "meeting"),
        ("escalate the incident incident commander asked for updates", "incident"),
        ("pin the message message thread moved to another channel", "message"),
    ])
    func boundaryPhraseRepeatsStay(spoken: String, anchor: String) {
        #expect(StutterCollapse.apply(spoken) == spoken)
        let lower = ruledLower(spoken)
        let count = lower.split(whereSeparator: \.isWhitespace).filter { LegitDoubles.key(String($0)) == anchor }.count
        #expect(count >= 2, "expected two \(anchor) tokens in \(lower)")
    }

    @Test("keeps both copies when the recogniser already punctuated the boundary", arguments: [
        ("Please check the budget. Budget numbers look off.", "budget"),
        ("Dana will send the report. The report is late again.", "report"),
        ("We shipped the build. Build two is next.", "build"),
    ])
    func punctuatedBoundary(spoken: String, anchor: String) {
        let out = ruled(spoken)
        #expect(BoundaryRepeatGuard.repeatedWords(in: out).contains(anchor))
        let count = out.split(whereSeparator: \.isWhitespace).filter { LegitDoubles.key(String($0)) == anchor }.count
        #expect(count >= 2)
    }

    // MARK: True stutters — collapsed whole

    @Test("collapses article and contraction stutters", arguments: [
        ("the the main issue is latency", "the main issue is latency"),
        ("it's it's a three second thing", "it's a three second thing"),
        ("show a a gentle reminder", "show a gentle reminder"),
        ("the the the file is locked", "the file is locked"),
    ])
    func wordStuttersCollapse(input: String, expectedFragment: String) {
        #expect(StutterCollapse.apply(input).contains(expectedFragment))
        #expect(!StutterCollapse.apply(input).contains("the the"))
    }

    @Test("collapses phrase disfluencies that are not boundary anchors", arguments: [
        ("we should we should probably ship", "we should probably ship"),
        ("the problem is the problem is that it hangs", "the problem is that it hangs"),
        ("when you when you drag a file", "when you drag a file"),
        ("i'm not i'm not sure yet", "i'm not sure yet"),
    ])
    func phraseStuttersCollapse(input: String, expectedFragment: String) {
        let out = StutterCollapse.apply(input)
        #expect(out.contains(expectedFragment))
        #expect(out != input)
    }

    @Test("removes a repeated onset run in one pass, not halfway")
    func wholeOnsetRunRemoved() {
        #expect(ruledLower("th th the report is ready").contains("the report is ready"))
        #expect(!ruledLower("th th the report is ready").contains("th the"))
        #expect(ruledLower("c c calculate the total").contains("calculate the total"))
        #expect(!ruledLower("c c calculate the total").contains("c calculate"))
    }

    // MARK: Deliberately unchanged shapes

    @Test("leaves legitimate doubles and pronoun object repeats", arguments: [
        "It was very very cold in the office.",
        "She had had the same problem before.",
        "He said that that approach would not scale.",
        "I told you you were right.",
        "I gave her her keys back.",
    ])
    func protectedDoubles(spoken: String) {
        #expect(StutterCollapse.apply(spoken) == spoken)
    }

    @Test("grammar fallback does not collapse a boundary phrase repeat")
    func grammarFallbackPreservesBoundary() {
        let spoken = "sent it to the landlord the landlord wants updates"
        #expect(SpokenGrammar.collapseUnambiguousPhraseRepeat(spoken) == spoken)
    }
}
