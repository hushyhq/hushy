import Foundation

/// Calendar-day arithmetic on `MetricsDay` that needs no `Calendar`, so the retention numbers
/// cannot be bent by a locale, a time zone or a non-Gregorian system calendar.
extension MetricsDay {
    /// Days since 1970-01-01 in the proleptic Gregorian calendar (negative before it).
    public var dayNumber: Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day `dayNumber` days after 1970-01-01. Throws for a day outside the supported years.
    public init(dayNumber: Int) throws {
        guard (-10_000_000...10_000_000).contains(dayNumber) else { throw MetricsValidationError.invalidDay }
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        try self.init(year: year, month: month, day: day)
    }

    public func adding(days: Int) throws -> MetricsDay {
        let (sum, overflow) = dayNumber.addingReportingOverflow(days)
        guard !overflow else { throw MetricsValidationError.invalidDay }
        return try MetricsDay(dayNumber: sum)
    }

    /// Whole days from `earlier` to this day (negative when this day is before `earlier`).
    public func days(since earlier: MetricsDay) -> Int { dayNumber - earlier.dayNumber }
}
