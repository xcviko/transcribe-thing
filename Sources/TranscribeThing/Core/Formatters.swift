import Foundation

/// Display formatting shared by every surface. English UI, so number formats are fixed to en_US.
enum Fmt {
    private static let locale = Locale(identifier: "en_US")

    /// Decimal (Finder-style) units: "632 MB", "1.2 GB", "48.5 MB", "12 KB".
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(count, 0))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (scale, unit) in units where value >= scale {
            let scaled = value / scale
            let digits = (unit == "KB" || scaled >= 100) ? 0 : 1
            return "\(decimal(scaled, fractionDigits: digits)) \(unit)"
        }
        return count == 1 ? "1 byte" : "\(Int64(value)) bytes"
    }

    /// Clock-style duration: "0:14", "12:05", "1:02:03".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "a few seconds left", "about 30 s left", "about 4 min left", "about 1 h 20 min left".
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "almost done" }
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 {
            let rounded = max(10, Int((seconds / 5).rounded()) * 5)
            return rounded >= 60 ? "about 1 min left" : "about \(rounded) s left"
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(max(1, minutes)) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
    }

    /// "1 word", "0 words", "1,234 words".
    static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(number(count)) words"
    }

    /// "Today", "Yesterday", a weekday within the past week, else "Sep 12" (or "Sep 12, 2025" in another year).
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if days > 1 && days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        }
        return formatter.string(from: date)
    }

    /// Short time in the user's 12/24-hour preference: "3:42 PM" or "15:42".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Grouped integer: "1,234".
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "42%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// "$12.40"; tiny amounts keep two significant digits: "$0.0031".
    static func usd(_ amount: Double) -> String {
        let magnitude = abs(amount)
        if magnitude > 0 && magnitude < 0.01 {
            let digits = max(2, Int(-log10(magnitude).rounded(.down)) + 2)
            return (amount < 0 ? "-$" : "$") + decimal(magnitude, fractionDigits: min(digits, 6))
        }
        return (amount < 0 ? "-$" : "$") + decimal(magnitude, fractionDigits: 2, minimumFractionDigits: 2)
    }

    /// Short elapsed-time label for processing times: "0.8 s", "12 s", "2 min".
    static func seconds(_ value: TimeInterval) -> String {
        if value < 10 { return "\(decimal(max(0, value), fractionDigits: 1, minimumFractionDigits: 1)) s" }
        if value < 90 { return "\(Int(value.rounded())) s" }
        return "\(Int((value / 60).rounded())) min"
    }

    /// Token counts: "820", "17.7k", "120k", "1.2M".
    static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value < 1_000 { return "\(Int(value))" }
        if value < 1_000_000 {
            let k = value / 1_000
            return "\(decimal(k, fractionDigits: k < 100 ? 1 : 0))k"
        }
        return "\(decimal(value / 1_000_000, fractionDigits: 1))M"
    }

    private static func decimal(_ value: Double, fractionDigits: Int, minimumFractionDigits: Int = 0) -> String {
        value.formatted(.number.locale(locale)
            .precision(.fractionLength(minimumFractionDigits...max(minimumFractionDigits, fractionDigits))))
    }
}
