import CryptoKit
import Foundation

/// Offline-verifiable invite codes that grant Hushy Pro for a fixed period (182 days, six
/// months — founder decision 2026-09-28, down from a year), signed
/// with Ed25519. There is no server: the founder generates codes with `scripts/invite-codes`
/// (the `hushy-invites` target) from a PRIVATE key that never ships; the app embeds ONLY the
/// public key and verifies signatures locally. See docs/guide/INVITES.md for the workflow and
/// the honest limits (a code can't be single-use without a server).
///
/// Wire format: `HUSHY-` + Crockford base32 of `payload (19 bytes) ‖ signature (64 bytes)`,
/// grouped in fours with hyphens for readability. The signature covers
/// `"hushy-invite-v1" ‖ payload` so a signature can never be reused for another purpose.
///
/// Payload (big-endian):
/// - `version`   UInt8   — 1
/// - `codeID`    8 bytes — random, identifies the code in the local redemption record
/// - `grantDays` UInt16  — 182 by default
/// - `issuedAt`  UInt32  — Unix seconds
/// - `redeemBy`  UInt32  — Unix seconds, 0 = no deadline
public enum InviteCode {
    public static let prefix = "HUSHY"
    public static let currentVersion: UInt8 = 1
    public static let defaultGrantDays: UInt16 = 182

    /// The default grant in words for user-facing copy: "six months" for 182 days, otherwise the
    /// day count, so the sentence follows `defaultGrantDays` instead of repeating a number.
    public static var defaultGrantDescription: String {
        let words = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        let days = Double(defaultGrantDays)
        let months = Int((days / 30.4).rounded())
        if months >= 2, months < words.count, abs(days - Double(months) * 30.4) < 5 { return "\(words[months]) months" }
        return "\(defaultGrantDays) days"
    }
    static let signingDomain = Data("hushy-invite-v1".utf8)
    static let payloadLength = 1 + 8 + 2 + 4 + 4
    static let signatureLength = 64

    public struct Payload: Equatable, Sendable {
        public var version: UInt8
        public var codeID: Data
        public var grantDays: UInt16
        public var issuedAt: Date
        public var redeemBy: Date?

        public init(
            version: UInt8 = InviteCode.currentVersion, codeID: Data = Payload.randomCodeID(),
            grantDays: UInt16 = InviteCode.defaultGrantDays, issuedAt: Date = Date(), redeemBy: Date? = nil
        ) {
            self.version = version
            self.codeID = codeID
            self.grantDays = grantDays
            self.issuedAt = issuedAt
            self.redeemBy = redeemBy
        }

        public static func randomCodeID() -> Data {
            Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })
        }

        /// Hex id used in the local redemption record and the founder's issuance log.
        public var codeIDHex: String { codeID.map { String(format: "%02x", $0) }.joined() }

        var bytes: Data {
            var data = Data()
            data.append(version)
            data.append(codeID.prefix(8))
            data.append(contentsOf: [UInt8(grantDays >> 8), UInt8(grantDays & 0xFF)])
            data.append(contentsOf: Self.be32(UInt32(clamping: Int64(issuedAt.timeIntervalSince1970.rounded(.down)))))
            let by = redeemBy.map { UInt32(clamping: Int64($0.timeIntervalSince1970.rounded(.down))) } ?? 0
            data.append(contentsOf: Self.be32(by))
            return data
        }

        init?(bytes: Data) {
            guard bytes.count == InviteCode.payloadLength else { return nil }
            let b = [UInt8](bytes)
            version = b[0]
            codeID = Data(b[1..<9])
            grantDays = UInt16(b[9]) << 8 | UInt16(b[10])
            issuedAt = Date(timeIntervalSince1970: TimeInterval(Self.u32(b, at: 11)))
            let by = Self.u32(b, at: 15)
            redeemBy = by == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(by))
        }

        private static func be32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }

        private static func u32(_ b: [UInt8], at i: Int) -> UInt32 {
            UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        /// Not a Hushy code: wrong prefix, bad characters, or wrong length.
        case malformed
        case unsupportedVersion(UInt8)
        /// The bytes don't verify against the embedded public key: tampered, or signed with a
        /// different key.
        case badSignature
        /// The code's redeem-by date has passed.
        case expired(redeemBy: Date)
        /// This build has no invite public key configured (the production placeholder is unset).
        case noPublicKey

        public var message: String {
            switch self {
            case .malformed: "That doesn't look like a Hushy invite code. Check for missing characters and try again."
            case .unsupportedVersion: "This invite code needs a newer version of Hushy."
            case .badSignature: "This invite code isn't valid."
            case .expired(let by): "This invite code expired on \(by.formatted(date: .abbreviated, time: .omitted))."
            case .noPublicKey: "Invite codes aren't enabled in this build."
            }
        }
    }

    // MARK: Generate (founder-side; the app never calls this)

    public static func generate(_ payload: Payload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let bytes = payload.bytes
        let signature = try privateKey.signature(for: signingDomain + bytes)
        return format(CrockfordBase32.encode(bytes + signature))
    }

    /// `HUSHY-XXXX-XXXX-…`
    static func format(_ base32: String) -> String {
        let groups = stride(from: 0, to: base32.count, by: 4).map { start -> String in
            let s = base32.index(base32.startIndex, offsetBy: start)
            let e = base32.index(s, offsetBy: 4, limitedBy: base32.endIndex) ?? base32.endIndex
            return String(base32[s..<e])
        }
        return ([prefix] + groups).joined(separator: "-")
    }

    // MARK: Verify (in the app)

    /// Strips the prefix, hyphens, spaces and case, then checks length, version, signature and
    /// the redeem-by deadline, in that order.
    public static func verify(_ code: String, publicKey: Curve25519.Signing.PublicKey, now: Date = Date()) -> Result<Payload, Error> {
        guard let raw = normalize(code), let bytes = CrockfordBase32.decode(raw),
              bytes.count == payloadLength + signatureLength,
              let payload = Payload(bytes: bytes.prefix(payloadLength))
        else { return .failure(.malformed) }
        guard payload.version == currentVersion else { return .failure(.unsupportedVersion(payload.version)) }
        let signature = bytes.suffix(signatureLength)
        guard publicKey.isValidSignature(signature, for: signingDomain + bytes.prefix(payloadLength)) else {
            return .failure(.badSignature)
        }
        if let by = payload.redeemBy, now > by { return .failure(.expired(redeemBy: by)) }
        return .success(payload)
    }

    /// The base32 body without the `HUSHY` prefix, separators or lowercase; `nil` if the text
    /// doesn't carry the prefix (pasting an unrelated string shouldn't be reported as "invalid
    /// signature").
    static func normalize(_ code: String) -> String? {
        let compact = code.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        guard compact.hasPrefix(prefix) else { return nil }
        let body = String(compact.dropFirst(prefix.count))
        return body.isEmpty ? nil : body
    }

    // MARK: Embedded public key

    /// PLACEHOLDER fallback. The real key reaches the app through the signed bundle's Info.plist
    /// (`HushyInvitePublicKey`, substituted by `scripts/build-app.sh` from
    /// `HUSHY_INVITE_PUBLIC_KEY` — see docs/guide/INVITES.md); this constant is only consulted
    /// when that entry is absent or unsubstituted. While neither is a valid 32-byte key,
    /// `embeddedPublicKey` is `nil` and the Redeem field reports `.noPublicKey` instead of
    /// accepting anything. There is deliberately no environment-variable or defaults override.
    public static let productionPublicKeyBase64 = "REPLACE-WITH-PRODUCTION-INVITE-PUBLIC-KEY"

    /// Info.plist key `build-app.sh` fills in.
    public static let infoPlistKey = "HushyInvitePublicKey"

    public static var embeddedPublicKey: Curve25519.Signing.PublicKey? {
        if let fromBundle = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
           let key = publicKey(base64: fromBundle) {
            return key
        }
        return publicKey(base64: productionPublicKeyBase64)
    }

    public static func publicKey(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}

/// Crockford base32: `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — no I, L, O or U, so a code read aloud or
/// typed from paper can't be mis-copied between 1/I/l and 0/O. Decoding folds I/L→1 and O→0.
public enum CrockfordBase32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let values: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        map["I"] = 1; map["L"] = 1; map["O"] = 0
        return map
    }()

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int(buffer >> UInt32(bits) & 0x1F)])
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 0x1F)]) }
        return out
    }

    public static func decode(_ text: String) -> Data? {
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for char in text.uppercased() {
            guard let value = values[char] else { return nil }
            buffer = buffer << 5 | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(buffer >> UInt32(bits) & 0xFF))
            }
        }
        return out
    }
}
