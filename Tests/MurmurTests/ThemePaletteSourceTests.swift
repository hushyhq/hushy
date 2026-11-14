import Foundation
import Testing
@testable import Murmur

@Suite("Site palette source")
struct ThemePaletteSourceTests {
    private struct CSSColor: Equatable {
        let light: UInt32
        let dark: UInt32?
    }

    @Test("Theme.Hex follows tokens.css, with two light AA steps", .enabled(if: PrivateFiles.present("site/src/styles/tokens.css"), "needs a private file: site/src/styles/tokens.css"))
    func followsSiteTokens() throws {
        let css = try String(contentsOf: Self.tokensURL, encoding: .utf8)
        #expect(css.contains("--said: var(--phosphor);"))
        #expect(css.contains("--wrote: var(--working);"))
        let parsed = Self.parse(css)
        let rows: [(String, Theme.HexPair)] = [
            ("--bg", Theme.Hex.bgBase),
            ("--bg-raised", Theme.Hex.bgRaised),
            ("--bg-sunken", Theme.Hex.bgSunken),
            ("--hairline", Theme.Hex.hairline),
            ("--hairline-strong", Theme.Hex.hairlineStrong),
            ("--ink", Theme.Hex.textPrimary),
            ("--ink-2", Theme.Hex.textSecondary),
            ("--ink-3", Theme.Hex.textTertiary),
            ("--phosphor", Theme.Hex.phosphor),
            ("--phosphor-fill", Theme.Hex.phosphorFill),
            ("--phosphor-tint", Theme.Hex.phosphorTint),
            ("--on-phosphor", Theme.Hex.onPhosphor),
            ("--working", Theme.Hex.working),
            ("--on-working", Theme.Hex.onWorking),
            ("--working-tint", Theme.Hex.workingTint),
            ("--said-ink", Theme.Hex.saidInk),
            ("--warning", Theme.Hex.warning),
            ("--error", Theme.Hex.error),
            ("--pill", Theme.Hex.pill),
            ("--pill-ink", Theme.Hex.pillInk),
            ("--pill-ink-2", Theme.Hex.pillInkSecondary),
            ("--pill-ink-3", Theme.Hex.pillInkTertiary),
            ("--action", Theme.Hex.action),
            ("--on-action", Theme.Hex.onAction),
        ]
        for row in rows {
            let site = try #require(parsed[row.0], "missing \(row.0)")
            #expect(site.light == row.1.light, "\(row.0) light")
            #expect(site.dark == row.1.dark, "\(row.0) dark")
        }

        let drop = try #require(parsed["--drop"])
        #expect(drop.light == 0xA86A00)
        #expect(drop.dark == Theme.Hex.drop.dark)
        #expect(Theme.Hex.drop.light == 0x9E5C00)

        let success = try #require(parsed["--success"])
        #expect(success.light == 0x17804F)
        #expect(success.dark == Theme.Hex.success.dark)
        #expect(Theme.Hex.success.light == 0x1D7B4B)

        let saidMark = try #require(parsed["--said-mark"])
        #expect(saidMark.light == Theme.Hex.saidMarkLight)
        #expect(saidMark.dark == nil)
    }

    private static var tokensURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("site/src/styles/tokens.css")
    }

    private static func parse(_ css: String) -> [String: CSSColor] {
        var colors: [String: CSSColor] = [:]
        for raw in css.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("--"), let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            if value.hasPrefix("var(") { continue }
            if value.hasPrefix("light-dark(") {
                guard let light = firstHex(in: value) else { continue }
                let after = value[value.index(value.startIndex, offsetBy: "light-dark(".count)...]
                guard let comma = after.firstIndex(of: ",") else { continue }
                let darkPart = after[after.index(after: comma)...]
                colors[name] = CSSColor(light: light, dark: firstHex(in: String(darkPart)))
            } else if let hex = firstHex(in: String(value)) {
                colors[name] = CSSColor(light: hex, dark: hex)
            }
        }
        return colors
    }

    private static func firstHex(in text: String) -> UInt32? {
        guard let hash = text.firstIndex(of: "#") else { return nil }
        let start = text.index(after: hash)
        guard text.distance(from: start, to: text.endIndex) >= 6 else { return nil }
        let end = text.index(start, offsetBy: 6)
        return UInt32(text[start..<end], radix: 16)
    }
}
