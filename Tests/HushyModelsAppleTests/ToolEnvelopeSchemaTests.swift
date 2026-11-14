import Foundation
import FoundationModels
import Testing
@testable import HushyModelsApple
@testable import MurmurCore

/// The tools-v1 flat envelope must be a schema Apple's guided generation accepts, so
/// `murmur-eval tools --mode catalog --backend apple` (and the app, later) can use it unchanged.
@Suite("tools-v1 envelope on Apple FM")
struct ToolEnvelopeSchemaTests {
    @Test("general grammar verifier schema is accepted by Apple guided generation")
    func grammarVerifierDecodes() throws {
        guard #available(macOS 26.0, *) else { return }
        _ = try AppleFoundationModel.decode(GeneralGrammarVerification.generationSchema)
    }

    @Test("both grammar proposal schemas decode for Apple")
    func grammarProposalsDecode() throws {
        guard #available(macOS 26.0, *) else { return }
        _ = try AppleFoundationModel.decode(GrammarEditProposal.generationSchema)
        _ = try AppleFoundationModel.decode(WholeGrammarProposal.generationSchema)
    }

    @Test("the envelope decodes into a GenerationSchema")
    func decodes() throws {
        guard #available(macOS 26.0, *) else { return }
        _ = try AppleFoundationModel.decode(VoiceToolCatalog.envelopeSchema)
    }
}
