import Foundation

/// A billing date is a civil Gregorian date, not a timestamp at midnight.
struct CalendarDate: Codable, Equatable, Hashable {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        let calendar = Self.gregorian(in: TimeZone(secondsFromGMT: 0)!)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init?(date: Date, calendar: Calendar = .current) {
        let parts = Self.gregorian(in: calendar.timeZone).dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    func date(in calendar: Calendar = .current) -> Date? {
        let local = Self.gregorian(in: calendar.timeZone)
        guard let date = local.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              let roundTrip = CalendarDate(date: date, calendar: local), roundTrip == self else { return nil }
        return date
    }

    fileprivate static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        guard let value = Self(year: year, month: month, day: day) else {
            throw DecodingError.dataCorruptedError(forKey: .day, in: container, debugDescription: "Invalid Gregorian calendar date")
        }
        self = value
    }
}

enum MonthlyRenewal {
    /// Estimates each month from the original day, so Jan 31 → Feb 28 → Mar 31.
    static func next(anchor: CalendarDate, now: Date, calendar: Calendar = .current) -> Date? {
        let local = CalendarDate.gregorian(in: calendar.timeZone)
        guard let anchorDate = anchor.date(in: local), let today = CalendarDate(date: now, calendar: local) else { return nil }
        let current = (today.year, today.month, today.day)
        if (anchor.year, anchor.month, anchor.day) >= current { return anchorDate }

        func occurrence(year: Int, month: Int) -> Date? {
            guard let first = CalendarDate(year: year, month: month, day: 1)?.date(in: local),
                  let days = local.range(of: .day, in: .month, for: first) else { return nil }
            return CalendarDate(year: year, month: month, day: min(anchor.day, days.count))?.date(in: local)
        }
        guard let thisMonth = occurrence(year: today.year, month: today.month),
              let thisMonthParts = CalendarDate(date: thisMonth, calendar: local) else { return nil }
        if thisMonthParts.day >= today.day { return thisMonth }
        let nextMonth = today.month == 12 ? 1 : today.month + 1
        let nextYear = today.month == 12 ? today.year + 1 : today.year
        return occurrence(year: nextYear, month: nextMonth)
    }
}

