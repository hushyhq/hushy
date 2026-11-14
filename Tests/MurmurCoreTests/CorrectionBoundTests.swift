import Foundation
import Testing
@testable import MurmurCore

/// A spoken correction takes something back, so an answer to a draft that carries one may leave out a number, a
/// name or a negation. It may not hold one the speaker never said. Each test pairs what the answer may do (it
/// passes) with what it may not (it is refused), so every one fails when the bound is removed.
@Suite("Bound a spoken correction puts on a model answer")
struct CorrectionBoundTests {
    private func reason(_ answer: String, _ draft: String) -> String? {
        CriticalTokenGuard.violation(answer: answer, draft: draft)
    }

    // MARK: Numbers

    @Test("a number that is not one the speaker said is refused, a spoken one in any written form passes")
    func numberNotSaid() {
        let draft = "We would ship on the twentieth no wait the twenty seventh because the vendor needs another week."
        #expect(reason("We would ship on the 27th because the vendor needs another week.", draft) == nil)
        #expect(reason("We would ship on the twenty seventh because the vendor needs another week.", draft) == nil)
        #expect(reason("We would ship on the seventh because the vendor needs another week.", draft) == "changed digits")
        #expect(reason("We would ship on the 7th because the vendor needs another week.", draft) == "changed digits")
    }

    @Test("a fragment of the retracted number left beside its replacement is refused")
    func fragmentBesideReplacement() {
        let draft = "Set it to dot one dot forty two no sorry forty four then restart the router."
        #expect(reason("Set it to dot one dot forty four then restart the router.", draft) == nil)
        #expect(reason("Set it to dot one dot 44 then restart the router.", draft) == nil)
        #expect(reason("Set it to dot one dot forty forty four then restart the router.", draft) == "changed digits")
        #expect(reason("Set it to dot one dot 40 44 then restart the router.", draft) == "changed digits")
    }

    @Test("digits read aloud: a regrouping passes, half of the old and half of the new is refused")
    func digitsReadAloud() {
        let draft = "The room code is four one five no sorry four one six so type it twice."
        #expect(reason("The room code is 416, so type it twice.", draft) == nil)
        #expect(reason("The room code is 4 1 6, so type it twice.", draft) == nil)
        #expect(reason("The room code is 415 6, so type it twice.", draft) == "changed digits")
        #expect(reason("The room code is 4156, so type it twice.", draft) == "changed digits")
    }

    @Test("a number the model builds from two spoken ones is refused, a spoken total in a new format passes")
    func joinedNumbers() {
        let draft = "Send two hundred and fifty units no I mean two hundred and sixty units to the warehouse."
        #expect(reason("Send 260 units to the warehouse.", draft) == nil)
        #expect(reason("Send two hundred and sixty units to the warehouse.", draft) == nil)
        #expect(reason("Send 25,260 units to the warehouse.", draft) == "changed digits")
        let spelled = "The invoice for forty two hundred dollars is overdue actually it is for forty four hundred dollars."
        #expect(reason("The invoice for $4,400 is overdue.", spelled) == nil)
        #expect(reason("The invoice for $4,200 is overdue.", spelled) == nil)
        #expect(reason("The invoice for $4,404 is overdue.", spelled) == "changed digits")
    }

    @Test("a number the draft holds in digits is compared by value with the answer's words, and the reverse")
    func digitsAndWordsAgree() {
        let draft = "We have 35 seats no wait 36 seats booked for the dinner."
        #expect(reason("We have thirty-six seats booked for the dinner.", draft) == nil)
        #expect(reason("We have thirty-seven seats booked for the dinner.", draft) == "changed digits")
        let words = "We have thirty five seats no wait thirty six seats booked for the dinner."
        #expect(reason("We have 36 seats booked for the dinner.", words) == nil)
        #expect(reason("We have 63 seats booked for the dinner.", words) == "changed digits")
    }

    @Test("a draft the rules split as '20 sixth' reads as twenty sixth, so the date passes and a different one does not")
    func splitOrdinalInTheDraft() {
        let draft = "Payroll closes on the 20 fifth sorry the 20 sixth so submit your hours before then."
        #expect(reason("Payroll closes on the 26th, so submit your hours before then.", draft) == nil)
        #expect(reason("Payroll closes on the 20 sixth, so submit your hours before then.", draft) == nil)
        #expect(reason("Payroll closes on the 6th, so submit your hours before then.", draft) == "changed digits")
        #expect(reason("Payroll closes on the 25th and the 26th, so submit your hours.", draft) == nil)
    }

    @Test("times, versions and percentages: the spoken parts in the written form pass, an unspoken one does not")
    func timesVersionsPercents() {
        let time = "Pick me up at six fifteen actually six fifty at the east entrance."
        #expect(reason("Pick me up at 6:50 at the east entrance.", time) == nil)
        #expect(reason("Pick me up at 6:05 at the east entrance.", time) == "changed digits")
        // A replacement may take the front or the end of the number it corrects.
        let hour = "The standup moves to nine thirty no wait ten starting Monday."
        #expect(reason("The standup moves to 10:30 starting Monday.", hour) == nil)
        #expect(reason("The standup moves to 10:15 starting Monday.", hour) == "changed digits")
        let version = "I think it was version 4.2 actually 4.3 that fixed it."
        #expect(reason("I think it was version 4.3 that fixed it.", version) == nil)
        #expect(reason("I think it was version 4.4 that fixed it.", version) == "changed digits")
        let percent = "Give the team a three percent raise sorry a five percent raise."
        #expect(reason("Give the team a 5% raise.", percent) == nil)
        #expect(reason("Give the team a 8% raise.", percent) == "changed digits")
    }

    @Test("leaving out a spoken number is a correction working, adding to the same stretch is not")
    func leavingOutIsAllowed() {
        let draft = "Add a line for the travel budget of nine thousand dollars no scratch that leave the travel line out."
        #expect(reason("Leave the travel line out.", draft) == nil)
        #expect(reason("Leave the travel line out of the 90 percent plan.", draft) == "changed digits")
    }

    @Test("a list marker the model adds is not a number the speaker did not say")
    func listMarkers() {
        let draft = "Buy milk actually buy oat milk then eggs and bread."
        #expect(reason("1. Buy oat milk\n2. Eggs\n3. Bread", draft) == nil)
        #expect(reason("3. Buy oat milk\n7. Eggs\n9. Bread", draft) == "changed digits")
    }

    @Test("without a correction cue the bound is not applied")
    func noCueNoBound() {
        #expect(reason("We would ship on the seventh because the vendor needs another week.",
                       "We would ship on the twentieth because the vendor needs another week.") == nil)
        #expect(reason("We would ship on the seventh because the vendor needs another week.",
                       "We would ship on the twentieth no wait the twenty seventh because the vendor needs another week.")
                == "changed digits")
    }

    @Test("the same time or amount written with its zero minutes or cents is the same number")
    func zeroMinutesAndCents() {
        let time = "Move it to two pm no wait three pm."
        #expect(reason("Move it to 3:00 pm.", time) == nil)
        #expect(reason("Move it to 3:30 pm.", time) == "changed digits")
        let amount = "The fee is five dollars no wait six dollars."
        #expect(reason("The fee is $6.00.", amount) == nil)
        #expect(reason("The fee is $6.50.", amount) == "changed digits")
    }

    @Test("two whole numbers the speaker said are not joined into a third, the one they meant still passes")
    func wholeNumbersAreNotJoined() {
        let room = "Meet in room 4 no wait room 6."
        #expect(reason("Meet in room 6.", room) == nil)
        #expect(reason("Meet in room 46.", room) == "changed digits")
        let date = "Move it to the 3rd no wait the 5th."
        #expect(reason("Move it to the 5th.", date) == nil)
        #expect(reason("Move it to the 35th.", date) == "changed digits")
        let long = "Order number 12 no wait 13."
        #expect(reason("Order number 13.", long) == nil)
        #expect(reason("Order number 1234567890123456789012345.", long) == "changed digits")
    }

    @Test("a hyphen, a spoken point-zero and a decimal with a scale word keep the number they write")
    func hyphensZerosAndScales() {
        let timeout = "Set a 20 second timeout no wait a 30 second timeout."
        #expect(reason("Set a 30-second timeout.", timeout) == nil)
        #expect(reason("Set a 40-second timeout.", timeout) == "changed digits")
        let phone = "Call 5551234567 no wait 5551234568."
        #expect(reason("Call 555-123-4568.", phone) == nil)
        #expect(reason("Call 555-123-4569.", phone) == "changed digits")
        let version = "We are on version three point oh actually the rollout is next week."
        #expect(reason("We are on version 3.0, actually the rollout is next week.", version) == nil)
        #expect(reason("We are on version 3.5, actually the rollout is next week.", version) == "changed digits")
        let budget = "The budget is 1.5 million no wait 2.5 million."
        #expect(reason("The budget is 2.5 million.", budget) == nil)
        #expect(reason("The budget is $2,500,000.", budget) == nil)
        #expect(reason("The budget is $3,500,000.", budget) == "changed digits")
    }

    @Test("half, an amount with cents and a month with a day are read by what they stand for")
    func halfCentsAndMonths() {
        let half = "Use half a cup of sugar no wait half a cup of salt."
        #expect(reason("Use 0.5 cups of salt.", half) == nil)
        #expect(reason("Use 1/2 cup of salt.", half) == nil)
        #expect(reason("Use 0.75 cups of salt.", half) == "changed digits")
        let cents = "The fee is five dollars and fifty cents no wait six dollars and fifty cents."
        #expect(reason("The fee is $6.50.", cents) == nil)
        #expect(reason("The fee is $5.50.", cents) == nil)
        #expect(reason("The fee is $6.05.", cents) == "changed digits")
        let month = "The review is March 5 no wait March 6."
        #expect(reason("The review is 3/6.", month) == nil)
        #expect(reason("The review is 03/06.", month) == nil)
        #expect(reason("The review is 3/16.", month) == "changed digits")
    }

    @Test("the front of one number and the whole of another go together only across the same cue")
    func splicesAcrossTheCueOnly() {
        let far = "The code is four one five and the total is twenty no wait twenty seven."
        #expect(reason("The code is 4 and the total is 27.", far) == nil)
        #expect(reason("The code is 4 27.", far) == "changed digits")
        let near = "The code is four one five no wait four one six."
        #expect(reason("The code is 4 1 6.", near) == nil)
        let tail = "The total is ninety one no wait eighty."
        #expect(reason("The total is 80.", tail) == nil)
        #expect(reason("The total is 91, 80.", tail) == nil)
        #expect(reason("The total is 98.", tail) == "changed digits")
    }

    @Test("half licenses 1/2 and 0.5, not a 12 or a lone 2; a month name is a date only beside a day")
    func halfAndMonthsAreNarrow() {
        let half = "Use half a cup of sugar no wait half a cup of salt."
        #expect(reason("Use 1/2 cup of salt.", half) == nil)
        #expect(reason("Use 12 cups of salt.", half) == "changed digits")
        #expect(reason("Use 2 cups of salt.", half) == "changed digits")
        let verb = "May I move the review to Friday no wait Monday."
        #expect(reason("Move the review to the 5 team.", verb) == "changed digits")
        let date = "The review is May 5 no wait May 6."
        #expect(reason("The review is 5/6.", date) == nil)
        #expect(reason("The review is 5/7.", date) == "changed digits")
    }

    // MARK: Names

    @Test("a name the speaker did not say is refused, a retracted name may go")
    func nameNotSaid() {
        let draft = "Please send the deck to Sarah no I mean to Sandra in procurement."
        #expect(reason("Please send the deck to Sandra in procurement.", draft) == nil)
        #expect(reason("Please send the deck to Sarah in procurement.", draft) == nil)
        #expect(reason("Please send the deck to Sonia in procurement.", draft) == "changed name")
    }

    @Test("a product written out in full is not a new name, a different spelling of a person's name is")
    func productWrittenInFull() {
        let draft = "We move to postgres next quarter and there is no downtime, tell Marcus."
        #expect(reason("We move to PostgreSQL next quarter and there is no downtime, tell Marcus.", draft) == nil)
        #expect(reason("We move to PostgreSQL next quarter and there is no downtime, tell Marcos.", draft) == "changed name")
        #expect(reason("We move to Postgres next quarter and there is no downtime, tell Mark.", draft) == "changed name")
    }

    @Test("a name written in another form of what was said passes, one with no source in the draft does not")
    func namesWrittenInAnotherForm() {
        let product = "Use type script for the sdk no wait for the cli."
        #expect(reason("Use TypeScript for the CLI.", product) == nil)
        #expect(reason("Use JavaScript for the CLI.", product) == "changed name")
        let letters = "Ask the g p t team no wait the s r e team."
        #expect(reason("Ask the SRE team.", letters) == nil)
        #expect(reason("Ask the GPU team.", letters) == "changed name")
        let days = "Meet on tues no wait wed at ten."
        #expect(reason("Meet on Wednesday at 10.", days) == nil)
        #expect(reason("Meet on Thursday at 10.", days) == "changed name")
        let accents = "Send it to jose no wait to maria."
        #expect(reason("Send it to José.", accents) == nil)
        #expect(reason("Send it to JOSE.", accents) == nil)
        #expect(reason("Send it to Joel.", accents) == "changed name")
        // An expansion longer than six letters is not a spelling of what was said.
        #expect(reason("Send it to Mariana-Alexandra.", accents) == "changed name")
    }

    @Test("two ordinary words are not a name, a three-letter word extends only to a weekday or a month")
    func ordinaryWordsAndShortStems() {
        let people = "Send it to mary elizabeth no wait to sandra."
        #expect(reason("Send it to Mary Elizabeth.", people) == nil)
        #expect(reason("Send it to Maryelizabeth.", people) == "changed name")
        let days = "Meet on wed no wait thu at ten."
        #expect(reason("Meet on Wednesday at 10.", days) == nil)
        #expect(reason("Meet on Thursday at 10.", days) == nil)
        let sam = "Ask the sam no wait ben to approve it."
        #expect(reason("Ask Ben to approve it.", sam) == nil)
        #expect(reason("Ask Samuel to approve it.", sam) == "changed name")
    }

    @Test("a name at the start of a sentence the speaker did not say is refused, the speaker's own is not")
    func sentenceInitialName() {
        let draft = "Ask Priya no wait ask Meera to approve the invoice before Friday."
        #expect(reason("Meera will approve the invoice before Friday.", draft) == nil)
        #expect(reason("Maya will approve the invoice before Friday.", draft) == "changed name")
        #expect(reason("Ask Meera. Then Maya approves the invoice before Friday.", draft) == "changed name")
    }

    @Test("a spelled-out number at the start of a sentence is not a name, an invented surname with an apostrophe is")
    func spelledNumberAndApostropheName() {
        let count = "27 people came no wait 28 people came to the launch."
        #expect(reason("Twenty-eight people came to the launch.", count) == nil)
        #expect(reason("Twenty-nine people came to the launch.", count) == "changed digits")
        let deck = "Send the deck to Sarah no I mean Sandra."
        #expect(reason("Send the deck to Sandra.", deck) == nil)
        #expect(reason("Send the deck to O'Brien.", deck) == "changed name")
    }

    @Test("a name's possessive and a capitalised place the speaker said are the same word")
    func possessiveAndPlace() {
        let draft = "Move the review to the denver team no wait the Boston team and send Meera's notes."
        #expect(reason("Move the review to the Boston team and send Meera's notes.", draft) == nil)
        #expect(reason("Move the review to the Boston team and send Maya's notes.", draft) == "changed name")
        #expect(reason("Move the review to the Denver team and send Meera's notes.", draft) == nil)
    }

    // MARK: Negations

    @Test("an answer may drop a retracted negation but not hold one the speaker never said")
    func negationNotSaid() {
        let draft = "We will not extend the trial no wait we will extend the trial by a week."
        #expect(reason("We will extend the trial by a week.", draft) == nil)
        let plain = "The vendor is approved actually go ahead and pay the vendor on Friday."
        #expect(reason("The vendor is approved. Go ahead and pay the vendor on Friday.", plain) == nil)
        #expect(reason("The vendor is not approved. Go ahead and pay the vendor on Friday.", plain) == "added negation")
        #expect(reason("Do not pay the vendor on Friday.", plain) == "added negation")
    }

    @Test("a negation in the draft's own wording may be written as a contraction, not doubled")
    func negationContraction() {
        let draft = "The report is ready no it is not ready the data from finance is still missing."
        #expect(reason("The report isn't ready. The data from finance is still missing.", draft) == nil)
        #expect(reason("The report isn't ready. The data from finance isn't here and never will be.", draft) == "added negation")
    }

    // MARK: The forms numbers are written in

    @Test("a scale word, a range, a spoken zero and a label with a digit are read as the numbers they are")
    func writtenForms() {
        let scaled = "The goal is twenty five thousand no wait thirty thousand users."
        #expect(reason("The goal is 30 thousand users.", scaled) == nil)
        #expect(reason("The goal is 30,000 users.", scaled) == nil)
        #expect(reason("The goal is 35,000 users.", scaled) == "changed digits")
        let range = "We expect ten to fifteen people no wait ten to twenty people."
        #expect(reason("We expect 10-20 people.", range) == nil)
        #expect(reason("We expect 10-25 people.", range) == "changed digits")
        let zero = "The flight is three oh five no wait three oh six."
        #expect(reason("The flight is 306.", zero) == nil)
        #expect(reason("The flight is 3:06.", zero) == nil)
        #expect(reason("The flight is 305 6.", zero) == "changed digits")
        let label = "Plan it for Q3 no wait Q4 of next year."
        #expect(reason("Plan it for Q4 of next year.", label) == nil)
        #expect(reason("Plan it for Q2 of next year.", label) == "changed digits")
        let year = "The contract ends in twenty twenty six no wait twenty twenty seven."
        #expect(reason("The contract ends in 2027.", year) == nil)
        #expect(reason("The contract ends in 2067.", year) == "changed digits")
    }

    // MARK: Through the cleaner: what the person gets

    private func clean(_ spoken: String, edit: @escaping @Sendable (String) -> String) async -> SmartCleaner.Output {
        let cleaner = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: AnswerModel(edit), health: ModelHealth())
        return await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
    }

    @Test("an answer with a number the speaker never said is not used and the words as spoken stand")
    func cleanerRefusesUnsaidNumber() async {
        let spoken = "we would ship on the twentieth no wait the twenty eighth because the vendor needs another week"
        // The rules write "the twentieth no wait the 28th"; the answers are built from whichever form they got.
        func answering(_ replacement: String) -> @Sendable (String) -> String {
            { $0.replacingOccurrences(of: "the twentieth no wait the 28th", with: replacement)
                .replacingOccurrences(of: "the twentieth no wait the twenty eighth", with: replacement) }
        }
        let applied = await clean(spoken, edit: answering("the 28th"))
        #expect(applied.groups.first?.outcome == .used, "\(String(describing: applied.groups.first?.guardCode)) \(applied.text)")
        #expect(applied.text.contains("28th"), "\(applied.text)")
        #expect(!applied.text.contains("twentieth"), "\(applied.text)")

        let invented = await clean(spoken, edit: answering("the eighth"))
        let group = invented.groups.first
        #expect(group?.outcome == .rejectedByGuard, "\(String(describing: group?.outcome)) \(invented.text)")
        #expect(group?.guardCode == .changedDigits, "\(String(describing: group?.guardCode))")
        #expect(invented.text.contains("twentieth"), "\(invented.text)")
        #expect(!invented.text.contains("the eighth because"), "\(invented.text)")
    }
}

/// A model that answers every request with `edit(draft)`.
private final class AnswerModel: LanguageModel {
    private let edit: @Sendable (String) -> String
    init(_ edit: @escaping @Sendable (String) -> String) { self.edit = edit }
    var identifier: String { "answer-model" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": edit(draft)]), as: UTF8.self)
    }
}
