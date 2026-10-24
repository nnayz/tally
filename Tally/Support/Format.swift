import Foundation

enum Format {
    static func money(_ value: Double, digits: Int = 2, code: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    /// Drops the fraction when the amount is a whole number ($25), otherwise two places.
    static func moneyCompact(_ value: Double, code: String = "USD") -> String {
        let digits = value.rounded() == value ? 0 : 2
        return money(value, digits: digits, code: code)
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func tokens(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            let scaled = Double(value) / 1_000_000
            return scaled >= 10 ? String(format: "%.0fM", scaled) : String(format: "%.1fM", scaled)
        }
        if absolute >= 1_000 {
            let scaled = Double(value) / 1_000
            return scaled >= 10 ? String(format: "%.0fK", scaled) : String(format: "%.1fK", scaled)
        }
        return count(value)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func clock(_ date: Date) -> String {
        timestamp(date, format: "HH:mm")
    }

    static func dayMonth(_ date: Date) -> String {
        timestamp(date, format: "d MMM")
    }

    static func requestTime(_ date: Date) -> String {
        timestamp(date, format: "d MMM HH:mm:ss")
    }

    private static func timestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
