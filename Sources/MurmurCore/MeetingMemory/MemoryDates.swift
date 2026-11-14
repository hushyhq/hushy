import Foundation

/// The time a question names, read against the question's clock. Questions about meetings look
/// back, so a bare date ("October 13", "Monday") is the most recent one, not the next.
enum MemoryDates {
    enum Reference: Equatable {
        /// Meetings inside this window.
        case window(DateInterval)
        /// Meetings from this moment on ("since October 20").
        case since(Date)
    }

    static func reference(in question: String, context: DateContext) -> Reference? {
        let text = " " + MemoryText.words(question).joined(separator: " ") + " "
        var calendar = context.calendar
        calendar.firstWeekday = 2
        let now = context.now
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func week(_ offset: Int) -> DateInterval {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            let shifted = calendar.date(byAdding: .weekOfYear, value: offset, to: start)!
            return DateInterval(start: shifted, end: calendar.date(byAdding: .day, value: 7, to: shifted)!)
        }
        func month(_ offset: Int) -> DateInterval {
            let start = calendar.dateInterval(of: .month, for: now)!.start
            let shifted = calendar.date(byAdding: .month, value: offset, to: start)!
            return DateInterval(start: shifted, end: calendar.date(byAdding: .month, value: 1, to: shifted)!)
        }
        if let range = text.range(of: #" since (.+)$"#, options: .regularExpression) {
            let phrase = String(text[range]).replacingOccurrences(of: " since ", with: "")
            if phrase.hasPrefix("last week") { return .since(week(-1).start) }
            if phrase.hasPrefix("yesterday") { return .since(day(-1)) }
            if let date = pastDate(in: phrase, context: context) { return .since(calendar.startOfDay(for: date)) }
        }
        if text.contains(" yesterday ") { return .window(DateInterval(start: day(-1), end: today)) }
        if text.contains(" today ") || text.contains(" this morning ") { return .window(DateInterval(start: today, end: day(1))) }
        if text.contains(" tomorrow ") { return .window(DateInterval(start: day(1), end: day(2))) }
        if text.contains(" last week ") || text.contains(" past week ") { return .window(week(-1)) }
        if text.contains(" this week ") { return .window(week(0)) }
        if text.contains(" next week ") { return .window(week(1)) }
        if text.contains(" last month ") { return .window(month(-1)) }
        if text.contains(" this month ") { return .window(month(0)) }
        if let range = text.range(of: #" (last|past) (\d+|two|three|four|five|six|seven|ten|fourteen|thirty) (day|days|week|weeks) "#, options: .regularExpression) {
            let parts = text[range].split(separator: " ")
            let numbers = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "ten": 10, "fourteen": 14, "thirty": 30]
            let count = Int(parts[1]) ?? numbers[String(parts[1])] ?? 1
            let days = parts[2].hasPrefix("week") ? count * 7 : count
            return .window(DateInterval(start: day(-days), end: day(1)))
        }
        let months = ["january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
                      "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
        let namesDay = months.contains { text.contains(" \($0) ") } || text.range(of: #" on (monday|tuesday|wednesday|thursday|friday) "#, options: .regularExpression) != nil
        if namesDay, let date = pastDate(in: question, context: context) {
            let start = calendar.startOfDay(for: date)
            return .window(DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!))
        }
        return nil
    }

    /// A date in `text`, moved into the past when the parser read it forward.
    static func pastDate(in text: String, context: DateContext) -> Date? {
        guard let anchor = DateAnchor.firstDate(in: text, context: context) else { return nil }
        var date = anchor.start
        let calendar = context.calendar
        let names = MemoryText.words(text)
        let weekday = names.contains { ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].contains($0) }
        while date > context.now {
            date = calendar.date(byAdding: weekday ? .day : .year, value: weekday ? -7 : -1, to: date)!
        }
        return date
    }

    /// "Oct 13".
    static func label(_ date: Date, context: DateContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}
