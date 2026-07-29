// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Core Data uses a reference date of January 1, 2001 (Apple epoch).
/// These helpers convert between Core Data's NSTimeInterval and ISO 8601 date strings.
///
/// Banktivity date-only fields are calendar labels stored at local midnight, not
/// UTC instants. Date-only parsing and formatting therefore use the host calendar
/// time zone, while full ISO 8601 timestamps remain UTC.
public enum DateConversion {
    /// Apple's reference date: January 1, 2001 00:00:00 UTC
    private static let appleReferenceDate: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func dateOnlyFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func dateOnlyDate(
        from isoString: String,
        timeZone: TimeZone
    ) -> Date? {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].utf8.count == 4,
              parts[1].utf8.count == 2,
              parts[2].utf8.count == 2,
              parts.allSatisfy({ part in
                  part.utf8.allSatisfy { byte in (48...57).contains(byte) }
              }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return nil
        }

        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else {
            return nil
        }
        return date
    }

    /// Convert a Core Data timestamp to a date-only `YYYY-MM-DD` calendar label.
    public static func toISO(
        _ coreDataTimestamp: Double,
        timeZone: TimeZone = .current
    ) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return dateOnlyFormatter(timeZone: timeZone).string(from: date)
    }

    /// Convert a Core Data timestamp to a full ISO 8601 datetime string in UTC.
    public static func toISODateTime(_ coreDataTimestamp: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return isoFormatter.string(from: date)
    }

    /// Convert a date-only `YYYY-MM-DD` label or full ISO 8601 timestamp to Core Data time.
    ///
    /// Date-only values become local midnight in `timeZone`; full timestamps retain
    /// their explicit offset and continue to use ISO 8601 instant semantics.
    public static func fromISO(
        _ isoString: String,
        timeZone: TimeZone = .current
    ) -> Double? {
        if isoString.count == 10 {
            guard let date = dateOnlyDate(from: isoString, timeZone: timeZone) else {
                return nil
            }
            return date.timeIntervalSinceReferenceDate
        }
        if let date = isoFormatter.date(from: isoString) {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// Convert a Date to Core Data timestamp
    public static func fromDate(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// Convert Core Data timestamp to Date
    public static func toDate(_ coreDataTimestamp: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
    }
}
