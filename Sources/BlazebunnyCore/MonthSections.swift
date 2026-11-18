import Foundation

/// A run of consecutive items that fall in the same calendar month.
public struct MonthSection: Sendable, Equatable {
    /// Positions in the list the section was made from.
    public var range: Range<Int>
    /// First instant of the month.
    public var monthStart: Date

    public init(range: Range<Int>, monthStart: Date) {
        self.range = range
        self.monthStart = monthStart
    }
}

public enum MonthSections {
    /// Splits dates (seconds since 1970) into runs of the same month, in the order given. For a list
    /// sorted by date this asks the calendar once per month instead of once per item, so 100k items
    /// cost about as much as their number of months.
    public static func split(_ dates: some Collection<Double>, calendar: Calendar = .current) -> [MonthSection] {
        var sections: [MonthSection] = []
        var start = 0
        var lower = 0.0, upper = -Double.infinity  // the current month as [lower, upper)
        var monthStart = Date.distantPast
        var i = 0
        for t in dates {
            if !(t >= lower && t < upper) {
                if i > start { sections.append(MonthSection(range: start..<i, monthStart: monthStart)) }
                start = i
                let date = Date(timeIntervalSince1970: t)
                if let month = calendar.dateInterval(of: .month, for: date) {
                    monthStart = month.start
                    lower = month.start.timeIntervalSince1970
                    upper = month.end.timeIntervalSince1970
                } else {
                    monthStart = date
                    lower = t
                    upper = t.nextUp
                }
            }
            i += 1
        }
        if i > start { sections.append(MonthSection(range: start..<i, monthStart: monthStart)) }
        return sections
    }

    /// "2025-03" for a month start, in the calendar's time zone.
    public static func key(_ monthStart: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: monthStart)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
