import Foundation

enum Format {
    struct CurrencyOption: Identifiable, Hashable {
        var code: String
        var label: String
        var id: String { code }
    }

    /// ISO codes and symbols from Foundation. USD stays first. The rest follow the Mac’s language.
    static let currencies: [CurrencyOption] = {
        let locale = Locale.current
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        let options = Locale.commonISOCurrencyCodes.map { code in
            formatter.currencyCode = code
            let name = locale.localizedString(forCurrencyCode: code) ?? code
            let symbol = formatter.currencySymbol ?? code
            let shown = symbol.isEmpty ? code : symbol
            return CurrencyOption(code: code, label: "\(name) · \(shown)")
        }
        return options.sorted { lhs, rhs in
            if lhs.code == "USD" { return true }
            if rhs.code == "USD" { return false }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }()

    /// Display multiplier against USD amounts. USD ignores the rate.
    static func rate(code: String, unitsPerUSD: Double) -> Double {
        code == "USD" || unitsPerUSD <= 0 ? 1 : unitsPerUSD
    }

    static func money(_ value: Double, digits: Int = 2, code: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(value)"
    }

    #if DEBUG
    static func checkCurrencies() {
        assert(rate(code: "USD", unitsPerUSD: 90) == 1)
        assert(rate(code: "INR", unitsPerUSD: 90) == 90)
        assert(rate(code: "EUR", unitsPerUSD: 0) == 1)
        assert(currencies.first?.code == "USD")
        assert(currencies.contains { $0.code == "INR" })
        assert(currencies.contains { $0.code == "EUR" })
        let rupee = money(1, digits: 0, code: "INR")
        assert(rupee.contains("₹") || rupee.contains("INR"), rupee)
        let euro = money(1, digits: 0, code: "EUR")
        assert(euro.contains("€") || euro.contains("EUR"), euro)
    }
    #endif

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
