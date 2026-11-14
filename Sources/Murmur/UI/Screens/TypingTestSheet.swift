import MurmurCore
import SwiftUI

/// A short typing test so "time saved" compares against the user's real typing speed rather
/// than an assumed average. Only this sheet's text field is measured; nothing is logged.
struct TypingTestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passage = TypingTest.passages.randomElement() ?? TypingTest.passages[0]
    @State private var typed = ""
    @State private var startedAt: Date?
    @State private var result: TypingTest.Result?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("How fast do you type?").font(Theme.Font.section)
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
            }
            Text("Type the passage below at your normal pace. The timer starts on your first key.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            Text(passage)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgSunken))
            if let result {
                resultView(result)
            } else {
                TextEditor(text: $typed)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 1))
                    .focused($focused)
                    .onChange(of: typed) { _, text in
                        if startedAt == nil, !text.isEmpty { startedAt = Date() }
                        if text.split(whereSeparator: \.isWhitespace).count >= passage.split(whereSeparator: \.isWhitespace).count,
                           text.hasSuffix(String(passage.last ?? ".")) { finish() }
                    }
                HStack {
                    Text("Finishes when you reach the end, or press Done.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Done") { finish() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(startedAt == nil)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.bgBase)
        .onAppear { focused = true }
    }

    private func resultView(_ result: TypingTest.Result) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(result.wordsPerMinute.rounded()))")
                    .font(.system(size: 44, weight: .light, design: .serif).monospacedDigit())
                Text("wpm, \(Int((result.accuracy * 100).rounded()))% accurate")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            Text("Time saved now uses this speed. You can measure again any time.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Try again") {
                    typed = ""; startedAt = nil; self.result = nil
                    passage = TypingTest.passages.filter { $0 != passage }.randomElement() ?? passage
                    focused = true
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        guard result == nil, let startedAt,
              let scored = TypingTest.score(typed: typed, passage: passage, seconds: Date().timeIntervalSince(startedAt))
        else { return }
        result = scored
        model.settings.typingWPM = scored.wordsPerMinute.rounded()
    }
}
