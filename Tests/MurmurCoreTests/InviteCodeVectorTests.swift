import CryptoKit
import Foundation
import Testing
import MurmurCore

@Suite("Admin invite vectors")
struct InviteCodeVectorTests {
    @Test(.enabled(if: PrivateFiles.present("admin/test/invite-vectors.json"), "needs a private file: admin/test/invite-vectors.json")) func workerCodeVerifiesInApp() throws {
        struct Vector: Decodable {
            let publicKeyBase64: String
            let id: String
            let days: UInt16
            let issuedAt: UInt32
            let redeemBy: UInt32
            let code: String
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../admin/test/invite-vectors.json").standardizedFileURL
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        let key = try #require(InviteCode.publicKey(base64: vector.publicKeyBase64))
        let payload = try InviteCode.verify(vector.code, publicKey: key,
            now: Date(timeIntervalSince1970: TimeInterval(vector.issuedAt))).get()
        #expect(payload.codeIDHex == vector.id)
        #expect(payload.grantDays == vector.days)
        #expect(payload.issuedAt == Date(timeIntervalSince1970: TimeInterval(vector.issuedAt)))
        #expect(payload.redeemBy == Date(timeIntervalSince1970: TimeInterval(vector.redeemBy)))
    }
}
