import Foundation

public enum CalculatorOperation: String, Codable, CaseIterable, Sendable {
    case add = "+"
    case subtract = "−"
    case multiply = "×"
    case divide = "÷"
}

public enum CalculatorError: Error, Equatable, Sendable { case invalidExpression, divisionByZero }

public struct AmountCalculator: Sendable {
    public private(set) var display: String = "0"
    private var accumulator: Decimal?
    private var pendingOperation: CalculatorOperation?
    private var startsNewOperand = true

    public init() {}

    public mutating func input(_ digit: Character) {
        guard digit.isNumber else { return }
        if startsNewOperand || display == "0" {
            display = String(digit)
            startsNewOperand = false
        } else {
            display.append(digit)
        }
    }

    public mutating func decimalPoint() {
        if startsNewOperand {
            display = "0."
            startsNewOperand = false
        } else if !display.contains(".") {
            display.append(".")
        }
    }

    public mutating func deleteLast() {
        guard !startsNewOperand else { return }
        display.removeLast()
        if display.isEmpty || display == "-" { display = "0"; startsNewOperand = true }
    }

    public mutating func clear() {
        display = "0"
        accumulator = nil
        pendingOperation = nil
        startsNewOperand = true
    }

    public mutating func apply(_ operation: CalculatorOperation) throws {
        let current = try parsedDisplay()
        if let accumulator, let pendingOperation {
            let result = try evaluate(accumulator, pendingOperation, current)
            self.accumulator = result
            display = decimalString(result)
        } else {
            accumulator = current
        }
        pendingOperation = operation
        startsNewOperand = true
    }

    @discardableResult
    public mutating func equals() throws -> Decimal {
        let current = try parsedDisplay()
        guard let accumulator, let operation = pendingOperation else { return current }
        let result = try evaluate(accumulator, operation, current)
        display = decimalString(result)
        self.accumulator = nil
        pendingOperation = nil
        startsNewOperand = true
        return result
    }

    public func value() throws -> Decimal { try parsedDisplay() }

    private func parsedDisplay() throws -> Decimal {
        guard let value = Decimal(string: display, locale: Locale(identifier: "en_US_POSIX")) else { throw CalculatorError.invalidExpression }
        return value
    }

    private func evaluate(_ lhs: Decimal, _ operation: CalculatorOperation, _ rhs: Decimal) throws -> Decimal {
        switch operation {
        case .add: return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        case .divide:
            guard rhs != 0 else { throw CalculatorError.divisionByZero }
            return lhs / rhs
        }
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
