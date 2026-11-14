import Foundation
import Testing
@testable import MurmurCore

/// A model that writes the word a recogniser only wrote the sound of ("get hub" -> "GitHub") has repaired the
/// dictation. A model that writes a name the speaker never said, or puts a different name where one was said, has not.
/// Every sentence here is invented.
@Suite("A capitalised word that repairs a spoken span")
struct SpokenNameRepairTests {
    private func bound(_ answer: String, _ draft: String) -> String? {
        CorrectionBound.violation(answer: answer, draft: draft)
    }

    private func intent(_ answer: String, _ raw: String) -> String? {
        switch IntentOutputGuard.check(answer, raw: raw) {
        case .accepted: nil
        case .rejected(let reason): reason
        default: "other"
        }
    }

    @Test("two spoken words that sound like a product are repaired to it, in place")
    func splitProduct() {
        for (draft, answer) in [
            ("Open a pull request on get hub and tag Priya for review.", "Open a pull request on GitHub and tag Priya for review."),
            ("I will write the script in pie thon and schedule it with cron.", "I will write the script in Python and schedule it with cron."),
            ("We should containerize the service with doc her before shipping it to staging.",
             "We should containerize the service with Docker before shipping it to staging."),
            ("The standup moved to Google meat at nine thirty because the room is booked.",
             "The standup moved to Google Meet at 9:30 because the room is booked."),
        ] {
            #expect(bound(answer, draft) == nil, "\(answer)")
            #expect(intent(answer, draft) == nil, "\(answer)")
        }
    }

    @Test("one spoken word that is the sound of a word is repaired to it, a longer spelling and a missing syllable included")
    func singleWord() {
        #expect(bound("The appointment is next Wednesday at 10.", "The appointment is next Wensday at ten.") == nil)
        // A different day is not a repair of the one that sounds like "Wensday".
        #expect(bound("The appointment is next Thursday at 10.", "The appointment is next Wensday at ten.") == "changed name")
        #expect(bound("We use Postgres for the main database.", "we use postgress for the main database") == nil)
        #expect(intent("Please install the latest version of Node.js before the build.",
                       "Please install the latest version of no JS before the build.") == nil)
    }

    @Test("one spoken word re-spelled is the same word, two spoken words run together are not a repair")
    func respelled() {
        #expect(bound("We will be without Wi-Fi on Monday.", "we will be without wifi on monday") == nil)
        #expect(bound("Ask Maryann about the lease.", "Ask mary ann about the lease.") == nil) // an existing allowance (a spoken word it extends)
        #expect(bound("Meet at Sunrise for lunch.", "Meet at sun rise for lunch.") == "changed name")
    }

    @Test("a name with no spoken source is refused, however it is placed")
    func inventedName() {
        #expect(bound("Open a pull request on Bitbucket and tag Priya for review.",
                      "Open a pull request on get hub and tag Priya for review.") == "changed name")
        #expect(bound("We should containerize the service with Dropbox before shipping it.",
                      "We should containerize the service with doc her before shipping it.") == "changed name")
        #expect(bound("Ask Zephyra to review the draft.", "Ask the team to review the draft.") == "changed name")
        #expect(intent("Ask Zephyra to review the draft.", "Ask the team to review the draft.") == "changed name")
    }

    @Test("one spoken name written as a different one is a swap, even when the two sound close")
    func swappedName() {
        #expect(bound("Send the invoice to Maria today.", "Send the invoice to Sarah today.") == "changed name")
        #expect(bound("Tell Marcos the build is green.", "Tell Marcus the build is green.") == "changed name")
        #expect(intent("Tell Marcos the build is green.", "Tell Marcus the build is green.") == "changed name")
        // Lowercase text has no capital to say it was a name; only a different sound is a swap.
        #expect(bound("Send it to Joel.", "send it to jose") == "changed name")
    }

    @Test("a part of a full name the recogniser spelled by sound may be re-spelled in place; a lone name may not")
    func fullNameRepair() {
        // The recogniser capitalises the sound of a name it does not know; the model spells the person it knows.
        #expect(bound("I think Brannick Holmgren is the best player on that team.",
                      "I think Brannick Holgren is the best player on that team.") == nil)
        #expect(intent("I think Brannick Holmgren is the best player on that team.",
                       "I think Brannick Holgren is the best player on that team.") == nil)
        #expect(intent("Tavish Sabonis is questionable for tonight.", "Tavish Sabonus is questionable for tonight.") == nil)
        // Still a swap: a lone name, a name after a sentence-opening ordinary word, names in a list.
        #expect(bound("Tell Marcos the build is green.", "Tell Marcus the build is green.") == "changed name")
        #expect(bound("Yesterday Marcos said the build is green.", "Yesterday Marcus said the build is green.") == "changed name")
        #expect(bound("Invite Sarah, Marcos and Priya.", "Invite Sarah, Marcus and Priya.") == "changed name")
        // A full name still needs a sound-alike in place: a different surname is not a repair.
        #expect(bound("I think Brannick Dunmore is the best player.", "I think Brannick Holgren is the best player.") == "changed name")
    }

    @Test("letters said glued to a number are said: an ID, a unit or a clock mark written apart is not a new name")
    func lettersBesideDigits() {
        #expect(intent("The bug is tracked in TRY-95.", "The bug is tracked in TRY95.") == nil)
        #expect(intent("We need 64 GB of RAM.", "We need 64GB of RAM.") == nil)
        #expect(intent("The meeting is at 11 AM.", "The meeting is at 11am.") == nil)
        // Only letters that were said: a new code or a new name beside the number is still refused.
        #expect(intent("The bug is tracked in ENG-95.", "The bug is tracked in TRY95.") == "changed name")
        #expect(CorrectionBound.lettersBesideDigits("try95") == ["try"])
        #expect(CorrectionBound.lettersBesideDigits("tuesday").isEmpty)
    }

    @Test("a sound-alike word that is not where the spoken one stood is not a repair")
    func notInPlace() {
        let draft = "The get hub page is slow today."
        #expect(bound("The page is slow on GitHub today.", draft) == "changed name")
        #expect(bound("The GitHub page is slow today.", draft) == nil)
    }

    @Test("a short name is not found in a short word")
    func shortAndJoined() {
        #expect(bound("Ask Sal to check the report.", "Ask sale to check the report.") == "changed name")
    }

    @Test("the answer's other names still have to be spoken ones")
    func otherNamesStillChecked() {
        #expect(bound("Open GitHub and ask Tobias to review it.", "Open get hub and ask the team to review it.") == "changed name")
        #expect(bound("Open GitHub and ask Priya to review it.", "Open get hub and ask Priya to review it.") == nil)
    }
}
