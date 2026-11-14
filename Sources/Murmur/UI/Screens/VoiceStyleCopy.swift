import MurmurCore

/// The words on Voice & style, short by rule: one line at most under a heading; the rest is in hover help or a
/// popover (founder, 2026-10-28: "too much information").
enum VoiceStyleCopy {
    static let pageSubtitle = "How your words read, the words Hushy knows, and the phrases it expands."

    // Style
    static let voiceCommandsLine = "“new line”, “scratch that”, “press enter”"
    static let americanSpellingLine = "colour → color, programme → program"
    static let specimenHelp = "See what was said and what Hushy wrote"

    // Formats
    static let formatsLine = "Pick one in the pill for your next dictation. Tones still decide how each app reads."
    static let newFormat = "New format"
    static let plainFormatLine = "Just cleaned up"
    /// The one line under a built-in format's name: the shape, not the instruction.
    static func formatLine(_ shape: FormatShape) -> String? {
        switch shape {
        case .plain: plainFormatLine
        case .email: "Greeting, body, sign-off"
        case .message: "Short and casual"
        case .note: "Clear, short sentences"
        case .bullets: "One point per line"
        case .custom: nil
        }
    }
    static let formatEditorTitle = "Format"
    static let formatNameField = "Format name"
    static let instructionTitle = "Instruction"
    static let instructionHelp = "Hushy reshapes the cleaned text this way. Your words are never invented or dropped."
    static let instructionPlaceholder = "Format as a short email with a greeting"
    static let previewTitle = "Preview"
    static let previewSample =
        "So the meeting moved to um 3pm on Thursday, and we still need the budget from Alex, no wait, from Priya."
    static func alsoAutomatic(_ count: Int) -> String {
        count == 1 ? "Also used on its own in 1 app." : "Also used on its own in \(count) apps."
    }
    static let stopAutomatic = "Stop"

    // Dictionary
    static let addWordPlaceholder = "Add a word, or find one"
    static let heardAsPlaceholder = "heard as… (optional)"
    static let dictionaryEmpty = "Add names, products and acronyms. Hushy spells them your way, offline."
    static func noMatch(_ term: String) -> String { "Nothing matches. Press Return to add “\(term)”." }
    static func wordCount(_ count: Int) -> String { "\(count) added" }
    static func learnedCount(_ count: Int) -> String { "\(count) learned" }
    static let addedByYou = "Added by you"
    static let learnedHeader = "Learned from your edits"
    static let learnedHelp = "When you fix a word right after dictating, Hushy remembers the fix on this Mac."

    // Snippets
    static let whenISay = "When I say"
    static let insert = "Insert"
    static let triggerPlaceholder = "my calendar link"
    static let insertPlaceholder = "Paste the text to insert"
    static let saveSnippet = "Save"
    static let tryLabel = "Try"
    static let snippetsEmpty = "Your address, a sign-off, a prompt you type every day."

    // Coding
    static let codingPick = "Choose a project folder"
    static let codingPickLine = "or drop one here. Hushy learns its names and file names."
    static let codingHears = "Hears your identifiers"
    static let codingTags = "Tags @files in Cursor and Windsurf"
    static let codingPanelMessage = "Choose a project folder for Hushy to learn its identifiers and file names."
}
