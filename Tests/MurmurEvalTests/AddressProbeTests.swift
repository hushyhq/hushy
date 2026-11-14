import Foundation
import XCTest
@testable import murmur_eval

final class AddressProbeTests: XCTestCase {
    func testLoadsPreparedClipManifest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = """
        [{"file":"clip.wav","said":"a dot com","voice":"Samantha","tailSeconds":2,"noise":0.004}]
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("clips.json"))
        let clips = try AddressProbeRunner.loadClips(folder: folder)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].voice, "Samantha")
        XCTAssertEqual(clips[0].tailSeconds, 2)
    }

    func testRepeatedEndingDetection() {
        XCTAssertTrue(AddressProbeRunner.hasRepeatedEnding("Sample.com.com", said: "sample dot com"))
        XCTAssertTrue(AddressProbeRunner.hasRepeatedEnding("sample dot com dot com", said: "sample dot com"))
        XCTAssertFalse(AddressProbeRunner.hasRepeatedEnding("Sample.com", said: "sample dot com"))
        XCTAssertFalse(AddressProbeRunner.hasRepeatedEnding("Please send the notes tomorrow", said: "please send the notes tomorrow"))
    }
}
