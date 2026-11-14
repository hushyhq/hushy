import Foundation
import Testing
@testable import MurmurCore

/// The credential/payment screen behind every free-text `propose_*` field: catches the shapes
/// that must never ride in a proposal, and stays quiet on everyday sentences that merely use
/// the same words.
@Suite("Sensitive content screen")
struct SensitiveContentScreenTests {
    @Test("credentials and payment data are caught", arguments: [
        ("my password is hunter2!", "a password"),
        ("Password: correct-horse", "a password"),
        ("passphrase = tr0ub4dor&3", "a password"),
        ("the passcode is 'letmein'", "a password"),
        ("PIN is 4491", "a PIN"),
        ("card 4111 1111 1111 1111 exp 12/28", "a payment card number"),
        ("4111-1111-1111-1111", "a payment card number"),
        ("5555555555554444", "a payment card number"),
        ("cvv 123", "a card security code"),
        ("security code: 1234", "a card security code"),
        ("account number 12345678 at Chase", "a bank account number"),
        ("IBAN: GB82 WEST 1234 5698 7654 32", "a bank account number"),
        ("GB82WEST12345698765432", "a bank account number"),
        ("sort code is 40-47-84", "a bank account number"),
        ("SSN 123-45-6789", "a Social Security number"),
        ("use sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "an API key or token"),
        ("key sk_live_4eC39HqLyjWDarjtT1zdp7dc", "an API key or token"),
        ("ghp_abcdefghijklmnopqrstuvwxyz1234", "an API key or token"),
        ("xoxb-1234567890-abcdefgh", "an API key or token"),
        ("AKIAIOSFODNN7EXAMPLE", "an API key or token"),
        ("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "an API key or token"),
        ("api key: a1b2c3d4e5f6g7h8", "an API key or token"),
        ("the token is eyJhbGciOiJIUzI1", "an API key or token"),
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIE", "an API key or token"),
        ("your verification code is 482913", "a one-time code"),
        ("OTP 123456", "a one-time code"),
    ])
    func catches(_ text: String, _ expected: String) {
        #expect(SensitiveContentScreen.finding(in: text)?.description == expected, "\(text)")
    }

    @Test("ordinary sentences with the same words pass", arguments: [
        "Can you reset your password before Monday?",
        "The password is wrong, try again.",
        "I forgot my password again",
        "Pin the message to the channel",
        "The account is closed; send the account number for Dana's team by Friday",
        "The token is expiring soon, so rotate it",
        "The secret is out: we launch Tuesday",
        "Call me at 415 555 0100 or +44 20 7946 0958",
        "Order 1234567890 shipped; tracking 9400 1000 0000 0000 0000 00",
        "Meet in room 2026-09-27 at 15:00 (ticket HUSHY-1234)",
        "Security code review is at 3pm",
        "The verification code page is broken",
        "Bearer of bad news: the demo is at 4",
        "2FA code arrives by SMS; ask Dana if it doesn't",
        "Budget line: 12,345,678,901,234 (that's the whole forecast)",
        "",
    ])
    func passes(_ text: String) {
        #expect(SensitiveContentScreen.finding(in: text) == nil, "\(text)")
    }

    @Test("a 13–19 digit run is a card only when it passes Luhn")
    func luhn() {
        #expect(SensitiveContentScreen.passesLuhn("4111111111111111"))
        #expect(!SensitiveContentScreen.passesLuhn("4111111111111112"))
        #expect(SensitiveContentScreen.paymentCardNumber(in: "4111111111111112") == nil)
        // 12 digits: too short to be a card, even if Luhn-valid.
        #expect(SensitiveContentScreen.paymentCardNumber(in: "411111111111") == nil)
        // A run longer than 19 digits is not a card.
        #expect(SensitiveContentScreen.paymentCardNumber(in: "4111 1111 1111 1111 1234 5678") == nil)
    }
}
