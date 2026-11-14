import CryptoKit
import Foundation
import MurmurCore

// Founder-only generator for Hushy Pro invite codes (docs/guide/INVITES.md). Run through
// `scripts/invite-codes`, never shipped in the app bundle.
//
//   invite-codes init                                   create the keypair, print the public key
//   invite-codes public-key                             save the public key for build-app.sh
//   invite-codes generate --count N [--redeem-by YYYY-MM-DD] [--days 182]
//   (both accept --key PATH; default ~/.config/hushy/invite_signing_key)
//
// The PRIVATE key is written only by `init`, only when the founder runs it, to the key path with
// mode 0600. It is never committed (.gitignore blocks the file name) and never leaves this Mac.
// The app embeds only the public key (Info.plist `HushyInvitePublicKey` via build-app.sh).

let defaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/hushy/invite_signing_key").path

struct Options {
    var command: String?
    var count = 1
    var days: UInt16 = InviteCode.defaultGrantDays
    var redeemBy: Date?
    var keyPath = defaultKeyPath
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("invite-codes: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    print("""
        usage: invite-codes init [--key PATH]
               invite-codes generate --count N [--days 182] [--redeem-by YYYY-MM-DD] [--key PATH]
        """)
    exit(0)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) needs a value") }
        return next
    }
    while let argument = iterator.next() {
        switch argument {
        case "init", "generate", "public-key", "--init": options.command = argument == "--init" ? "init" : argument
        case "--count":
            guard let n = Int(value(for: argument)), n > 0 else { fail("--count must be a positive integer") }
            options.count = n
        case "--days":
            guard let d = UInt16(value(for: argument)), d > 0 else { fail("--days must be 1…65535") }
            options.days = d
        case "--redeem-by":
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            guard let day = formatter.date(from: value(for: argument)) else { fail("--redeem-by must be YYYY-MM-DD") }
            // End of that day (UTC) so the date printed on the invite is inclusive.
            options.redeemBy = day.addingTimeInterval(86_400 - 1)
        case "--key": options.keyPath = value(for: argument)
        case "-h", "--help": usage()
        default: fail("unknown argument \(argument)")
        }
    }
    return options
}

func initialize(at path: String) {
    let url = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists — refusing to overwrite the signing key. Move it away first if you really mean to rotate (every already-issued code stops working).")
    }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try key.rawRepresentation.base64EncodedString().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
        fail("could not write \(path): \(error)")
    }
    print("""
        Private key written to \(path) (mode 0600).
        WARNING: never commit, paste, or share this file. Back it up privately; losing it means
        every future invite needs a new keypair and a new app release.

        Public key — export it before running scripts/build-app.sh:
          export HUSHY_INVITE_PUBLIC_KEY=\(key.publicKey.rawRepresentation.base64EncodedString())
        """)
}

/// Writes only the public half to ~/.config/hushy/invite_public_key (read by build-app.sh) and
/// prints it. The private key never leaves this process.
func writePublicKey(from path: String) {
    let publicKey = loadPrivateKey(at: path).publicKey.rawRepresentation.base64EncodedString()
    let out = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).appendingPathComponent("invite_public_key")
    do { try publicKey.write(to: out, atomically: true, encoding: .utf8) } catch { fail("could not write \(out.path): \(error)") }
    print("Public key written to \(out.path):\n  \(publicKey)")
}

func loadPrivateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("no usable signing key at \(path). Run `invite-codes init` first.") }
    return key
}

let options = parse(CommandLine.arguments)
switch options.command {
case "init":
    initialize(at: options.keyPath)
case "public-key":
    writePublicKey(from: options.keyPath)
case "generate":
    let privateKey = loadPrivateKey(at: options.keyPath)
    let dayFormatter = ISO8601DateFormatter()
    dayFormatter.formatOptions = [.withFullDate]
    print("code_id,redeem_by,code")
    for _ in 0..<options.count {
        let payload = InviteCode.Payload(grantDays: options.days, issuedAt: Date(), redeemBy: options.redeemBy)
        do {
            let code = try InviteCode.generate(payload, privateKey: privateKey)
            let by = options.redeemBy.map(dayFormatter.string(from:)) ?? ""
            print("\(payload.codeIDHex),\(by),\(code)")
        } catch {
            fail("signing failed: \(error)")
        }
    }
default:
    usage()
}
