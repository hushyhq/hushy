import Foundation
import Testing
@testable import MurmurCore

@Suite("FileScope")
struct FileScopeTests {
    private let home = "/Users/tester"

    @Test("what is excluded", arguments: [
        "/Users/tester/Library/Preferences/x.plist", "/Users/tester/.ssh/id", "/Users/tester/Documents/.git/config",
        "/Users/tester/Desktop/Foo.app/Contents/Info.plist", "/Users/tester/Desktop/Foo.app",
        "/Users/tester/Documents/proj/node_modules/x/readme.md", "/Users/tester/Documents/Hushy/log.txt",
        "/Users/tester/Pictures/Photos.photoslibrary/originals/a.jpg", "/Users/tester/Applications/Thing.app",
        "/Applications/Safari.app", "/Users/tester", "/Users/tester2/Documents/a.pdf", "/private/tmp/a.pdf",
    ])
    func excluded(path: String) {
        #expect(FileScope.isExcluded(path: path, home: home))
    }

    @Test("what is kept", arguments: [
        "/Users/tester/Documents/Resume.pdf", "/Users/tester/Desktop/a.png", "/Users/tester/Downloads/x/y/z.csv",
        "/Users/tester/Documents/Library of congress.pdf", "/Users/tester/Documents/projects/murmur/spec.pdf",
        "/Users/tester/resume.pdf",
    ])
    func kept(path: String) {
        #expect(!FileScope.isExcluded(path: path, home: home))
    }

    @Test("roots")
    func roots() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        #expect(FileScope.roots(for: nil, home: home).map(\.path) == ["/Users/tester"])
        #expect(FileScope.roots(for: .downloads, home: home).map(\.path) == ["/Users/tester/Downloads"])
    }

    @Test("a program or script is never opened")
    func programs() {
        for path in ["/a/b.command", "/a/Tool.app", "/a/x.sh", "/a/y.pkg", "/a/z.WORKFLOW", "/a/q.py"] {
            #expect(FileScope.runsWhenOpened(path: path))
        }
        for path in ["/a/Resume.pdf", "/a/a.docx", "/a/b.key", "/a/c.png", "/a/noext"] {
            #expect(!FileScope.runsWhenOpened(path: path))
        }
    }

    @Test("kinds from a Spotlight content-type tree")
    func kinds() {
        #expect(FileKind.kinds(forContentTypeTree: ["com.adobe.pdf", "public.data", "public.item"]) == [.pdf, .document])
        #expect(FileKind.kinds(forContentTypeTree: ["public.jpeg", "public.image"]) == [.image])
        #expect(FileKind.kinds(forContentTypeTree: ["public.folder"]) == [.folder])
    }
}

@Suite("SpotlightPredicate")
struct SpotlightPredicateTests {
    @Test("terms are matched on the display name with wildcards, kinds on the type tree")
    func nameAndKind() {
        let spec = FileSearchSpec(
            pass: .nameAll, termGroups: [["resume", "cv"], ["acme"]], kind: .pdf,
            roots: [URL(fileURLWithPath: "/Users/tester")], limit: 200, timeBox: .seconds(1))
        let text = SpotlightPredicate.make(spec).predicateFormat
        #expect(text.contains("kMDItemDisplayName LIKE[cd] \"*resume*\""))
        #expect(text.contains("kMDItemDisplayName LIKE[cd] \"*cv*\""))
        #expect(text.contains("kMDItemDisplayName LIKE[cd] \"*acme*\""))
        #expect(text.contains("kMDItemContentTypeTree == \"com.adobe.pdf\""))
        #expect(text.contains("AND"))
    }

    @Test("the any pass ORs the terms; the content pass reads text, not names")
    func passes() {
        let roots = [URL(fileURLWithPath: "/Users/tester")]
        let any = FileSearchSpec(pass: .nameAny, termGroups: [["a1"], ["b1"]], kind: .any, roots: roots, limit: 10, timeBox: .seconds(1))
        #expect(SpotlightPredicate.make(any).predicateFormat.contains("OR"))
        let content = FileSearchSpec(pass: .content, termGroups: [["kafka"]], kind: .any, roots: roots, limit: 10, timeBox: .seconds(1))
        let text = SpotlightPredicate.make(content).predicateFormat
        #expect(text.contains("kMDItemTextContent"))
        #expect(!text.contains("kMDItemDisplayName"))
    }

    @Test("a request with no terms still has a predicate")
    func noTerms() {
        let spec = FileSearchSpec(pass: .nameAll, termGroups: [], kind: .any, roots: [], limit: 10, timeBox: .seconds(1))
        #expect(!SpotlightPredicate.make(spec).predicateFormat.isEmpty)
    }
}
