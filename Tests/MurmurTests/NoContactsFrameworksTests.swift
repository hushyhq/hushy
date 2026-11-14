import Foundation
import MachO
import Testing

/// Tests never reach the person's Contacts. Hushy has no Contacts code, but a linked framework can
/// bring it in: AuthenticationServices links ContactsUI → ContactsUICore, and an unfiltered XCTest
/// run walks every loaded class (`+[XCTestCase allSubclasses]`). Realizing a ContactsUICore class
/// messages `CNContactStore`, whose `+initialize` opens the AddressBook store in the background.
/// swift-huggingface 0.11 imported AuthenticationServices for OAuth, which autolinked it into
/// every target using Hub or Tokenizers; 0.13 moved OAuth to its own product.
///
/// Reads the test bundle's own link commands, not the loaded images: a framework loaded later by
/// a running test is too late for XCTest's class walk, and depends on which tests ran first.
@Suite("Test bundle — no Contacts frameworks linked")
struct NoContactsFrameworksTests {
    /// Frameworks whose presence at launch lets XCTest's class walk reach `CNContactStore`.
    private static let forbidden = [
        "/AuthenticationServices.framework/", "/ContactsUI.framework/", "/ContactsUICore.framework/",
    ]

    private static let requiresDyld: UInt32 = 0x8000_0000
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
    private static let dylibCommands: Set<UInt32> = [0xC, 0x18 | requiresDyld, 0x1F | requiresDyld, 0x20, 0x23 | requiresDyld]

    /// The install names of every library this image links, read from its Mach-O header.
    private static func linkedLibraries() -> [String] {
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self).pointee
        var command = #dsohandle.advanced(by: MemoryLayout<mach_header_64>.size)
        var names: [String] = []
        for _ in 0..<header.ncmds {
            let load = command.load(as: load_command.self)
            if dylibCommands.contains(load.cmd) {
                let offset = Int(command.load(as: dylib_command.self).dylib.name.offset)
                names.append(String(cString: command.advanced(by: offset).assumingMemoryBound(to: CChar.self)))
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return names
    }

    @Test("the test bundle does not link AuthenticationServices, ContactsUI or ContactsUICore")
    func noContactsUI() {
        let libraries = Self.linkedLibraries()
        #expect(libraries.contains { $0.hasSuffix("/Foundation.framework/Versions/C/Foundation") },
                "the header was read: \(libraries.count) libraries")
        let linked = libraries.filter { library in Self.forbidden.contains { library.contains($0) } }
        #expect(linked.isEmpty, "a dependency links a Contacts framework: \(linked)")
    }
}
