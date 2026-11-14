import Testing
@testable import MurmurCore

@Suite("Style literal fidelity")
struct StyleLiteralFidelityTests {
    @Test("all styles retain a trailing ellipsis")
    func trailingEllipsisIsStableAcrossStyles() {
        for context in StyleContext.allCases {
            for style in WritingStyle.allCases {
                let output = StyleFormatter.apply(style, to: "hello there...", in: context)
                #expect(output.hasSuffix("..."), "\(context.rawValue)/\(style.rawValue): \(output)")
            }
        }
    }

    @Test("style formatting fails closed when it would alter a balanced backtick literal")
    func balancedBacktickLiteralIsPreserved() {
        let input = "hello. `MyID` works..."
        for context in StyleContext.allCases {
            let output = StyleFormatter.apply(.veryCasual, to: input, in: context)
            #expect(output == input, "\(context.rawValue): \(output)")
        }
    }

    @Test("unchanged inline literals do not block surrounding formatting")
    func surroundingFormattingStillAppliesWhenLiteralSurvives() {
        let output = StyleFormatter.apply(.formal, to: "hello `MyID` works", in: .personalMessages)
        #expect(output == "Hello `MyID` works.")
    }
}
