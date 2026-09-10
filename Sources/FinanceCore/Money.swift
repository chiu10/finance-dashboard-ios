import Foundation

public enum MoneyError: Error, Equatable, Sendable {
    case invalidCurrency
    case invalidFraction
    case overflow
    case currencyMismatch
}

public struct Money: Codable, Hashable, Comparable, Sendable {
    public let minorUnits: Int64
    public let currencyCode: String

    private init(knownValidMinorUnits: Int64, knownValidCurrencyCode: String) {
        minorUnits = knownValidMinorUnits
        currencyCode = knownValidCurrencyCode
    }

    public init(minorUnits: Int64, currencyCode: String = "TWD") throws {
        let normalizedCurrency = currencyCode.uppercased()
        guard normalizedCurrency.count == 3 else { throw MoneyError.invalidCurrency }
        self.minorUnits = minorUnits
        self.currencyCode = normalizedCurrency
    }

    public static func twd(_ amount: Int64) -> Money {
        // TWD is treated as a zero-fraction display currency in the initial app.
        Money(knownValidMinorUnits: amount, knownValidCurrencyCode: "TWD")
    }

    public static func usdCents(_ cents: Int64) -> Money {
        Money(knownValidMinorUnits: cents, knownValidCurrencyCode: "USD")
    }

    public static func zero(currencyCode: String = "TWD") -> Money {
        let normalized = currencyCode.uppercased()
        return Money(knownValidMinorUnits: 0, knownValidCurrencyCode: normalized.count == 3 ? normalized : "TWD")
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currencyCode == rhs.currencyCode, "Cannot compare different currencies")
        return lhs.minorUnits < rhs.minorUnits
    }

    public func adding(_ other: Money) throws -> Money {
        guard currencyCode == other.currencyCode else { throw MoneyError.currencyMismatch }
        let result = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyError.overflow }
        return try Money(minorUnits: result.partialValue, currencyCode: currencyCode)
    }

    public func subtracting(_ other: Money) throws -> Money {
        guard currencyCode == other.currencyCode else { throw MoneyError.currencyMismatch }
        let result = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw MoneyError.overflow }
        return try Money(minorUnits: result.partialValue, currencyCode: currencyCode)
    }

    public func negated() throws -> Money {
        guard minorUnits != .min else { throw MoneyError.overflow }
        return try Money(minorUnits: -minorUnits, currencyCode: currencyCode)
    }

    public var isPositive: Bool { minorUnits > 0 }
    public var isZero: Bool { minorUnits == 0 }

    public func decimalValue(fractionDigits: Int) -> Decimal {
        let divisor = Decimal.powerOfTen(fractionDigits)
        return Decimal(minorUnits) / divisor
    }

    public static func from(decimal: Decimal, currencyCode: String, fractionDigits: Int) throws -> Money {
        let scaled = decimal * Decimal.powerOfTen(fractionDigits)
        var rounded = Decimal()
        var source = scaled
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded == scaled else { throw MoneyError.invalidFraction }
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber else { throw MoneyError.invalidFraction }
        let value = number.int64Value
        guard NSDecimalNumber(value: value).decimalValue == rounded else { throw MoneyError.overflow }
        return try Money(minorUnits: value, currencyCode: currencyCode)
    }
}

public enum CurrencyScale {
    public static func fractionDigits(for currencyCode: String) -> Int {
        switch currencyCode.uppercased() {
        case "TWD", "JPY", "KRW": return 0
        default: return 2
        }
    }
}

private extension Decimal {
    static func powerOfTen(_ exponent: Int) -> Decimal {
        guard exponent >= 0 else { return 1 }
        return (0 ..< exponent).reduce(Decimal(1)) { result, _ in result * 10 }
    }
}
