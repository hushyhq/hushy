import Foundation

/// The word-by-word state machine of Whisper's `EnglishNumberNormalizer.process_words`, split out of
/// `WhisperNumberNormalizer` so each branch stays readable. Mirrors the Python generator: `out` is
/// what it yields, `value`/`prefix` are its `nonlocal` state, `skip` skips the next word.
extension WhisperNumberNormalizer {
    struct State {
        var out: [String] = []
        var prefix: String?
        var value: Value?
        var skip = false

        /// Python's `output()`: prepend the pending prefix, reset value and prefix.
        mutating func emit(_ result: String) {
            out.append((prefix ?? "") + result)
            value = nil
            prefix = nil
        }

        mutating func flush() {
            if let value { emit(value.string) }
        }

        mutating func step(prev: String?, current: String, next: String?) {
            let nextIsNumeric = next.map { numeric.matches($0) } ?? false
            let first = current.unicodeScalars.first.map { String($0) } ?? ""
            let hasPrefix = prefixes.contains(first)
            let bare = hasPrefix ? String(current.unicodeScalars.dropFirst()) : current
            let prevIsOnes = prev.map { ones[$0] != nil } ?? false
            let prevIsTens = prev.map { tens[$0] != nil } ?? false

            if numeric.matches(bare) {
                arabic(current: current, bare: bare, prefixChar: hasPrefix ? first : nil)
            } else if !words.contains(current) {
                flush()
                emit(current)
            } else if zeros.contains(current) {
                value = .text(orEmpty(value) + "0")
            } else if let number = ones[current] {
                onesWord(number, prevIsOnes: prevIsOnes, prevIsTens: prevIsTens)
            } else if let (number, suffix) = onesSuffixed[current] {
                onesSuffixedWord(number, suffix, prevIsOnes: prevIsOnes, prevIsTens: prevIsTens)
            } else if let number = tens[current] {
                tensWord(number)
            } else if let (number, suffix) = tensSuffixed[current] {
                tensSuffixedWord(number, suffix)
            } else if let multiplier = multipliers[current] {
                multiplierWord(multiplier)
            } else if let (multiplier, suffix) = multipliersSuffixed[current] {
                multiplierSuffixedWord(multiplier, suffix)
            } else if let sign = precedingPrefixers[current] {
                flush()
                if let next, words.contains(next) || nextIsNumeric { prefix = sign } else { emit(current) }
            } else if let symbol = followingPrefixers[current] {
                if let value {
                    prefix = symbol
                    emit(value.string)
                } else {
                    emit(current)
                }
            } else if suffixers.contains(current) {
                suffixWord(current, next: next)
            } else {
                special(current, prev: prev, next: next, nextIsNumeric: nextIsNumeric)
            }
        }

        private mutating func arabic(current: String, bare: String, prefixChar: String?) {
            if let value {
                if case .text(let text) = value, text.hasSuffix(".") {
                    // concatenate decimals / IP address components
                    self.value = .text(text + current)
                    return
                }
                emit(value.string)
            }
            prefix = prefixChar ?? prefix
            if let fraction = fraction(bare), let whole = integral(fraction), case .int = whole {
                value = whole
            } else {
                value = .text(bare)
            }
        }

        private mutating func onesWord(_ number: Int, prevIsOnes: Bool, prevIsTens: Bool) {
            guard let current = value else {
                value = .int(number)
                return
            }
            switch current {
            case .text, _ where prevIsOnes:
                let text = current.string
                if prevIsTens, number < 10, text.hasSuffix("0") {
                    value = .text(String(text.dropLast()) + String(number))
                } else {
                    value = .text(text + String(number))
                }
            case .int(let whole):
                let base = number < 10 ? 10 : 100
                value = whole % base == 0 ? .int(whole + number) : .text(String(whole) + String(number))
            }
        }

        private mutating func onesSuffixedWord(_ number: Int, _ suffix: String, prevIsOnes: Bool, prevIsTens: Bool) {
            guard let current = value else {
                emit(String(number) + suffix)
                return
            }
            switch current {
            case .text, _ where prevIsOnes:
                let text = current.string
                if prevIsTens, number < 10, text.hasSuffix("0") {
                    emit(String(text.dropLast()) + String(number) + suffix)
                } else {
                    emit(text + String(number) + suffix)
                }
            case .int(let whole):
                let base = number < 10 ? 10 : 100
                emit((whole % base == 0 ? String(whole + number) : String(whole) + String(number)) + suffix)
            }
            value = nil
        }

        private mutating func tensWord(_ number: Int) {
            switch value {
            case nil: value = .int(number)
            case .text(let text): value = .text(text + String(number))
            case .int(let whole): value = whole % 100 == 0 ? .int(whole + number) : .text(String(whole) + String(number))
            }
        }

        private mutating func tensSuffixedWord(_ number: Int, _ suffix: String) {
            switch value {
            case nil: emit(String(number) + suffix)
            case .text(let text): emit(text + String(number) + suffix)
            case .int(let whole):
                emit((whole % 100 == 0 ? String(whole + number) : String(whole) + String(number)) + suffix)
            }
        }

        private mutating func multiplierWord(_ multiplier: Decimal) {
            switch value {
            case nil:
                value = integral(multiplier)
            case .text, .int(0):
                let text = value?.string ?? ""
                if let fraction = fraction(text), let product = integral(fraction * multiplier) {
                    value = product
                } else {
                    emit(text)
                    value = integral(multiplier)
                }
            case .int(let whole):
                value = integral(scaled(whole, by: multiplier))
            }
        }

        private mutating func multiplierSuffixedWord(_ multiplier: Decimal, _ suffix: String) {
            let multiplierText = integral(multiplier)?.string ?? "\(multiplier)"
            switch value {
            case nil:
                emit(multiplierText + suffix)
            case .text(let text):
                if let fraction = fraction(text), let product = integral(fraction * multiplier) {
                    emit(product.string + suffix)
                } else {
                    emit(text)
                    emit(multiplierText + suffix)
                }
            case .int(let whole):
                emit((integral(scaled(whole, by: multiplier))?.string ?? "") + suffix)
            }
            value = nil
        }

        /// `value // 1000 * 1000 + (value % 1000) * multiplier`
        private func scaled(_ whole: Int, by multiplier: Decimal) -> Decimal {
            Decimal(whole / 1000 * 1000) + Decimal(whole % 1000) * multiplier
        }

        private mutating func suffixWord(_ current: String, next: String?) {
            guard let value else {
                emit(current)
                return
            }
            if current == "percent" {
                emit(value.string + "%")
            } else if next == "cent" {
                emit(value.string + "%")
                skip = true
            } else {
                emit(value.string)
                emit(current)
            }
        }

        private mutating func special(_ current: String, prev: String?, next: String?, nextIsNumeric: Bool) {
            let nextIsWord = next.map { words.contains($0) } ?? false
            if !nextIsWord && !nextIsNumeric {
                flush()
                emit(current)
                return
            }
            switch current {
            case "and":
                // "and" after hundreds, thousands, … is dropped
                if !(prev.map { multipliers[$0] != nil } ?? false) {
                    flush()
                    emit(current)
                }
            case "double", "triple":
                if let next, ones[next] != nil || zeros.contains(next) {
                    let repeats = current == "double" ? 2 : 3
                    value = .text(orEmpty(value) + String(repeating: String(ones[next] ?? 0), count: repeats))
                    skip = true
                } else {
                    flush()
                    emit(current)
                }
            default: // "point"
                if let next, decimals.contains(next) || nextIsNumeric {
                    value = .text(orEmpty(value) + ".")
                }
            }
        }
    }
}
