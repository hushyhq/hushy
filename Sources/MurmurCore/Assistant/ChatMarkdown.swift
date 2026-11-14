import Foundation

/// Splits an assistant reply into the few block shapes the chat renders — paragraphs,
/// headings, bullet/numbered items and fenced code — leaving inline Markdown (bold, italics,
/// `code`, links) inside each block for `AttributedString(markdown:)`. SwiftUI's `Text` only
/// understands inline Markdown, so without this a list arrives as one run-on paragraph.
public enum ChatMarkdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(String)
        /// `marker` is "•" for bullets or "3." for numbered items.
        case listItem(marker: String, text: String, depth: Int)
        case code(String)
    }

    public static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(heading))
            } else if let item = listItem(in: rawLine) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(in line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }
        guard text.first == " " else { return nil }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func listItem(in line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let depth = min(indent / 2, 3)
        let body = line.dropFirst(indent)
        for bullet in ["- ", "* ", "• "] where body.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(body.dropFirst(bullet.count)), depth: depth)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", text: String(rest.dropFirst(2)), depth: depth)
            }
        }
        return nil
    }
}
