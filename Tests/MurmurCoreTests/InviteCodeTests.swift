import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Offline invite-code verification (`InviteCode`). A throwaway dev keypair is generated per
/// test; nothing here touches the production placeholder key or any persisted state.
@Suite("InviteCode")
struct InviteCodeTests {
    let signer = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(redeemBy: Date? = nil) -> InviteCode.Payload {
        InviteCode.Payload(issuedAt: now, redeemBy: redeemBy)
    }

    @Test("a freshly generated code verifies and round-trips its payload")
    func validCode() throws {
        let original = payload(redeemBy: now.addingTimeInterval(30 * 86_400))
        let code = try InviteCode.generate(original, privateKey: signer)
        #expect(code.hasPrefix("HUSHY-"))
        #expect(code.dropFirst(6).allSatisfy { $0 == "-" || CrockfordBase32.alphabet.contains($0) })

        let verified = try InviteCode.verify(code, publicKey: signer.publicKey, now: now).get()
        #expect(verified == original)
        #expect(verified.grantDays == 182, "six months, the default grant")
        #expect(verified.codeIDHex.count == 16)
    }

    @Test("pasting is forgiving: lowercase, spaces, missing hyphens, and I/L/O confusions")
    func lenientInput() throws {
        let code = try InviteCode.generate(payload(), privateKey: signer)
        let sloppy = " " + code.lowercased().replacingOccurrences(of: "-", with: " ") + "\n"
        #expect((try? InviteCode.verify(sloppy, publicKey: signer.publicKey, now: now).get()) != nil)
        let confused = code.replacingOccurrences(of: "1", with: "I").replacingOccurrences(of: "0", with: "O")
        #expect((try? InviteCode.verify(confused, publicKey: signer.publicKey, now: now).get()) != nil)
    }

    @Test("a tampered code fails with badSignature")
    func tampered() throws {
        let code = try InviteCode.generate(payload(), privateKey: signer)
        // Change one payload character (inside the first groups after the prefix) to a
        // different alphabet character.
        var chars = Array(code)
        let index = 8
        chars[index] = chars[index] == "A" ? "B" : "A"
        let result = InviteCode.verify(String(chars), publicKey: signer.publicKey, now: now)
        #expect(result == .failure(.badSignature))
    }

    @Test("a code signed with another key fails with badSignature")
    func wrongKey() throws {
        let code = try InviteCode.generate(payload(), privateKey: signer)
        let other = Curve25519.Signing.PrivateKey()
        #expect(InviteCode.verify(code, publicKey: other.publicKey, now: now) == .failure(.badSignature))
    }

    @Test("redeem-by is inclusive: valid at the deadline, expired one second later")
    func redeemBy() throws {
        let deadline = now.addingTimeInterval(7 * 86_400)
        let code = try InviteCode.generate(payload(redeemBy: deadline), privateKey: signer)
        #expect((try? InviteCode.verify(code, publicKey: signer.publicKey, now: deadline).get()) != nil)
        #expect(InviteCode.verify(code, publicKey: signer.publicKey, now: deadline.addingTimeInterval(1))
            == .failure(.expired(redeemBy: deadline)))
        let open = try InviteCode.generate(payload(redeemBy: nil), privateKey: signer)
        #expect((try? InviteCode.verify(open, publicKey: signer.publicKey, now: now.addingTimeInterval(10 * 365 * 86_400)).get()) != nil)
    }

    @Test("malformed input is reported as malformed, never as a signature problem")
    func malformed() {
        #expect(InviteCode.verify("", publicKey: signer.publicKey, now: now) == .failure(.malformed))
        #expect(InviteCode.verify("HUSHY-", publicKey: signer.publicKey, now: now) == .failure(.malformed))
        #expect(InviteCode.verify("HUSHY-ABCD-EFGH", publicKey: signer.publicKey, now: now) == .failure(.malformed))
        #expect(InviteCode.verify("HUSHY-ABCU-EFGH", publicKey: signer.publicKey, now: now) == .failure(.malformed), "U is not in the alphabet")
        #expect(InviteCode.verify("NOTHUSHY-ABCD", publicKey: signer.publicKey, now: now) == .failure(.malformed))
    }

    @Test("an unknown payload version is refused before the signature check")
    func unsupportedVersion() throws {
        let future = InviteCode.Payload(version: 9, issuedAt: now)
        let code = try InviteCode.generate(future, privateKey: signer)
        #expect(InviteCode.verify(code, publicKey: signer.publicKey, now: now) == .failure(.unsupportedVersion(9)))
    }

    @Test("the production placeholder is not a usable key, so this build accepts no code")
    func placeholderKey() {
        #expect(InviteCode.publicKey(base64: InviteCode.productionPublicKeyBase64) == nil)
        #expect(InviteCode.embeddedPublicKey == nil)
        #expect(InviteCode.publicKey(base64: signer.publicKey.rawRepresentation.base64EncodedString()) != nil)
    }

    @Test("Crockford base32 round-trips arbitrary bytes")
    func base32RoundTrip() {
        for length in [0, 1, 2, 5, 19, 64, 83] {
            let data = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            #expect(CrockfordBase32.decode(CrockfordBase32.encode(data)) == data)
        }
        #expect(CrockfordBase32.decode("U") == nil)
    }
}
