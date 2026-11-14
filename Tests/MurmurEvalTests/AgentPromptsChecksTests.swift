import Foundation
import Testing

@testable import murmur_eval

@Suite("Agent prompts scoring")
struct AgentPromptsChecksTests {
    private func decode(_ json: String) throws -> AgentPromptsChecks.Case {
        try JSONDecoder().decode(AgentPromptsChecks.Case.self, from: Data(json.utf8))
    }

    @Test("identifiers must match exactly")
    func identifiersExact() throws {
        let item = try decode("""
        {"id":"ap-test-01","app":"cursor","bundle":"com.todesktop.230313mzl4w4u92","spoken":"x",\
        "intended":"y","identifiers":["AuthService.swift"],"requirements":[],"screen_terms":[]}
        """)
        let good = AgentPromptsChecks.score(item, output: "AuthService.swift is the target.")
        #expect(good.identifierExactRate == 1)
        let bad = AgentPromptsChecks.score(item, output: "auth service swift")
        #expect(bad.identifierExactRate == 0)
    }

    @Test("requirements use normalized phrase match")
    func requirementsPhrase() throws {
        let item = try decode("""
        {"id":"ap-test-02","app":"cursor","bundle":"com.todesktop.230313mzl4w4u92","spoken":"x",\
        "intended":"y","identifiers":[],"requirements":["public method names"],"screen_terms":[]}
        """)
        let ok = AgentPromptsChecks.score(item, output: "Keep the PUBLIC method names intact.")
        #expect(ok.requirementsKeptRate == 1)
    }

    @Test("answered-instead detects assistant replies")
    func answeredInstead() throws {
        let item = try decode("""
        {"id":"ap-test-03","app":"cursor","bundle":"com.todesktop.230313mzl4w4u92","spoken":"x",\
        "intended":"y","identifiers":[],"requirements":[],"screen_terms":[]}
        """)
        #expect(AgentPromptsChecks.score(item, output: "Sure, I'll move that for you.").answeredInsteadOfCleaned)
        #expect(!AgentPromptsChecks.score(item, output: "Move the auth logic.").answeredInsteadOfCleaned)
    }

    @Test("list shape counts enumerated items")
    func listShape() throws {
        let item = try decode("""
        {"id":"ap-test-04","app":"cursor","bundle":"com.todesktop.230313mzl4w4u92","spoken":"x",\
        "intended":"y","identifiers":[],"requirements":[],"screen_terms":[],"list_items":3}
        """)
        let ok = AgentPromptsChecks.score(
            item,
            output: "First, fix the race; second, add logging; third, update the handbook page.")
        #expect(ok.listShapeOK)
    }
}
