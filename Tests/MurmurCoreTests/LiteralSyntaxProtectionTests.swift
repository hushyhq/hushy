import Testing
@testable import MurmurCore

@Suite("Balanced literal preservation")
struct LiteralSyntaxProtectionTests {
    @Test func delimiterRunsAndEscapesRoundTrip() {
        for input in ["Use ``a ` b``", "```swift\nlet value = \"um\";\n```", #"Use \`escaped and `um`"#, #"let quote = "a\"b";"#, "don't mask ordinary apostrophes"] {
            let protection = LiteralSyntaxProtection(input, codeContext: true)
            #expect(protection.restore(protection.masked) == input)
        }
        let escaped = #"Use \`um\`"#
        #expect(LiteralSyntaxProtection(escaped, codeContext: false).masked == escaped)
    }
    @Test func terminalLiteralRetainsPunctuationAndContent() {
        let result = TextCleaner(options: CleanupOptions(level: .clean, voiceCommandsEnabled: false)).clean("keep the token `um`")
        #expect(result.text == "Keep the token `um`")
        #expect(LiteralSyntaxProtection("a ``b ` c``", codeContext: false).endsInBacktickLiteral)
    }
    @Test func modelCannotDeleteOrRewriteDelimitedLiteral() {
        let draft = "Keep the token `um`"
        #expect(LiteralSyntaxProtection.violation(candidate: "Keep the token ``", draft: draft) != nil)
        if case .rejected(let reason) = OutputGuard.check("Keep the token `uh`", raw: draft, draft: draft) {
            #expect(reason == "changed backtick literal")
        } else { Issue.record("literal mutation accepted") }
        #expect(LiteralSyntaxProtection.violation(candidate: "Keep the token `um`.", draft: draft) == nil)
        #expect(LiteralSyntaxProtection.violation(candidate: "`e\u{301}`", draft: "`é`") != nil)
    }
    @Test func missingPlaceholderAbstains() {
        let protection = LiteralSyntaxProtection("`um`", codeContext: false)
        #expect(protection.restore("") == nil)
        #expect(protection.restore(protection.masked + protection.masked) == nil)
    }
}
