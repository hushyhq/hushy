import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// SwiftUI builds a view struct again whenever its parent re-evaluates (every frame of a window
/// resize). Building History must not run its database reads each time.
@Suite("History view construction")
@MainActor
struct HistoryViewBuildTests {
    @Test("building the History view again and again does not reload the first page")
    func constructionIsCheap() throws {
        let library = Library(store: try Store())
        let before = HistoryPager.firstPageLoadCount

        for _ in 0..<20 { _ = HistoryView(library: library) }

        #expect(HistoryPager.firstPageLoadCount == before, "\(HistoryPager.firstPageLoadCount - before) first-page loads from 20 constructions")
    }
}
