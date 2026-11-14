#if DEBUG
import Foundation

/// The invented scripts. No digits or abbreviations, so what `say` speaks and what the reference
/// says are the same words.
extension MockMicSayPlan {
    static let standard = MockMicSayPlan(
        dictation: [
            .init(id: "dictation-1", voice: "Samantha",
                  text: "Please send the budget summary to the design team before Thursday afternoon and let me know if anything looks wrong."),
            .init(id: "dictation-2", voice: "Daniel",
                  text: "I think we should move the planning meeting to the following week because two of the engineers will be traveling and the schedule is already tight."),
            .init(id: "dictation-3", voice: "Karen",
                  text: "Remind me to buy oat milk, fresh basil and a small notebook on the way home, then call the dentist to confirm the appointment."),
        ],
        meetings: [
            meeting("meeting-1", a: "Samantha", b: "Daniel", lines: onboardingLines),
            meeting("meeting-2", a: "Tessa", b: "Daniel", lines: pilotLines),
            meeting("meeting-3", a: "Moira", b: "Rishi", lines: partyLines),
        ],
        voice: .init(from: "meeting-1", speaker: "B", name: "Marlow Quince", later: [
            .init(meeting: "meeting-2", containsSpeaker: true),
            .init(meeting: "meeting-3", containsSpeaker: false),
        ]))

    private static func meeting(_ id: String, a: String, b: String, lines: [String]) -> SpokenMeeting {
        let turns = lines.enumerated().map { index, text in
            index.isMultiple(of: 2)
                ? SpokenTurn(speaker: "A", voice: a, text: text)
                : SpokenTurn(speaker: "B", voice: b, text: text)
        }
        return SpokenMeeting(id: id, turns: turns)
    }

    private static let onboardingLines = [
        "Thanks for joining everyone, today I would like to review the launch plan for the new onboarding flow.",
        "Sure, the main risk I see is the tutorial screens, because testers kept skipping them during the last session.",
        "That matches what we saw in the survey, so maybe we should shorten the tutorial to three short steps.",
        "I agree, and we could also add a progress bar so people know how much is left.",
        "Good idea, who can build a prototype of that before the end of next week?",
        "I can take it, as long as the design team sends me the final illustrations by Monday.",
        "Perfect, I will ask them today and then schedule a short review on Friday morning.",
        "Great, then I will write up the open questions and share them in the project channel tonight.",
    ]

    private static let pilotLines = [
        "Welcome back, this week we need to decide how to handle the feedback from the pilot customers.",
        "Most of the comments were about speed, so I would start by fixing the slow search results.",
        "Agreed, and the second most common request was a darker theme for working at night.",
        "That one is easy, we already have the colors defined, it only needs a few hours of work.",
        "Wonderful, can we promise both changes to the pilot group by the end of the month?",
        "I think so, provided nobody asks for new features while we are fixing the old ones.",
        "I will make that clear in my email, and I will copy the whole team on it.",
        "Thanks, I will start on the search improvements tomorrow morning and report back on Wednesday.",
    ]

    private static let partyLines = [
        "Today's agenda is short, we need to talk about the garden party and the shared calendar.",
        "I booked the community hall for Saturday afternoon, and the caterer has confirmed the vegetarian menu.",
        "Excellent, then the only open item is music, and I know a local band that might be free.",
        "Please ask them soon, because the last time we waited too long and lost the venue.",
        "I will call them this evening, and I will also order the paper lanterns online.",
        "Make sure the lanterns are the battery kind, since the hall does not allow open flames.",
        "Good point, I will check the order twice before I confirm anything with the shop.",
        "Wonderful, then I think we are done, and I will send a summary to everyone tonight.",
    ]
}
#endif
