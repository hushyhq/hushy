import Foundation
import Testing

@testable import murmur_eval

/// `--help` must print usage and stop. Before this, a subcommand treated it as an unknown flag
/// and started a default run (which, for `voice-trace`, fetched a dataset).
@Suite("murmur-eval help request")
struct ArgumentsHelpTests {
    private func wantsHelp(_ arguments: [String]) -> Bool {
        Arguments(ArraySlice(arguments)).wantsHelp
    }

    @Test func helpFlagAnywhereIsAHelpRequest() {
        #expect(wantsHelp(["--help"]))
        #expect(wantsHelp(["-h"]))
        #expect(wantsHelp(["voice-trace", "--help"]))
        #expect(wantsHelp(["voice-trace", "-h"]))
        #expect(wantsHelp(["voice-trace", "--limit", "3", "--help"]))
        #expect(wantsHelp(["voice-trace", "--help", "--no-web"]))
    }

    @Test func helpFollowedByAValueIsStillAHelpRequest() {
        #expect(wantsHelp(["voice-trace", "--help", "extra"]))
    }

    @Test func ordinaryRunsAreNotHelpRequests() {
        #expect(!wantsHelp([]))
        #expect(!wantsHelp(["voice-trace"]))
        #expect(!wantsHelp(["voice-trace", "--local-dir", "clips", "--no-web"]))
        #expect(!wantsHelp(["cleanup", "--backend", "none"]))
    }

    @Test func aValueNamedHelpIsNotAHelpRequest() {
        #expect(!wantsHelp(["voice-trace", "--local-dir", "help"]))
        #expect(!wantsHelp(["voice-trace", "--report", "-h"]))
    }

    @Test func usageNamesTheCommandThatTrippedThis() {
        #expect(Eval.usage.contains("voice-trace"))
        #expect(Eval.usage.hasPrefix("usage: murmur-eval"))
    }
}
