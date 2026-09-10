import Foundation

public enum AnalysisPeriod: String, CaseIterable, Identifiable {
    case week, month, lastMonth, threeMonths, sixMonths, year, oneYear, custom
    public var id: Self { self }

    public func range(asOf today: Date, calendar: Calendar = .current, customStart: Date, customEnd: Date) throws -> LedgerDateRange {
        var ledgerCalendar = Calendar(identifier: .gregorian)
        ledgerCalendar.timeZone = calendar.timeZone
        ledgerCalendar.firstWeekday = calendar.firstWeekday
        ledgerCalendar.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        let calendar = ledgerCalendar
        let start: Date?
        var end = today
        switch self {
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: today)?.start
        case .month: start = calendar.dateInterval(of: .month, for: today)?.start
        case .lastMonth:
            guard let currentStart = calendar.dateInterval(of: .month, for: today)?.start,
                  let previousEnd = calendar.date(byAdding: .day, value: -1, to: currentStart) else { throw LedgerError.invalidDate }
            start = calendar.dateInterval(of: .month, for: previousEnd)?.start
            end = previousEnd
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: today)
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: today)
        case .year: start = calendar.dateInterval(of: .year, for: today)?.start
        case .oneYear: start = calendar.date(byAdding: .year, value: -1, to: today)
        case .custom:
            start = customStart
            end = customEnd
        }
        func local(_ date: Date) throws -> LocalDate {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { throw LedgerError.invalidDate }
            return try LocalDate(year: year, month: month, day: day)
        }
        guard let start else { throw LedgerError.invalidDate }
        return try LedgerDateRange(start: local(start), end: local(end))
    }
}

public struct InvestmentPosition: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var quantity: Decimal
    public var totalCost: Money
    public var investedCapital: Money
    public var realizedPnL: Money
    public var dividendIncome: Money

    public init(assetID: UUID, quantity: Decimal, totalCost: Money, investedCapital: Money, realizedPnL: Money, dividendIncome: Money) {
        self.assetID = assetID
        self.quantity = quantity
        self.totalCost = totalCost
        self.investedCapital = investedCapital
        self.realizedPnL = realizedPnL
        self.dividendIncome = dividendIncome
    }
}

public struct PositionValuation: Hashable, Sendable {
    public var position: InvestmentPosition
    public var averageCost: Money?
    public var marketValue: Money?
    public var unrealizedPnL: Money?
    public var totalReturn: Money?
    public var returnPercentage: Decimal?
    public var quoteTimestamp: Date?
    public var isStale: Bool
}

public enum InvestmentCalculator {
    public static func positions(in state: LedgerState, through date: LocalDate? = nil) throws -> [UUID: InvestmentPosition] {
        var positions: [UUID: InvestmentPosition] = [:]
        let orderedTransactions = state.transactions
            .filter { transaction in
                transaction.deletedAt == nil && (date.map { transaction.draft.occurredOn <= $0 } ?? true)
            }
            .sorted { lhs, rhs in
                if lhs.draft.occurredOn != rhs.draft.occurredOn { return lhs.draft.occurredOn < rhs.draft.occurredOn }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        for transaction in orderedTransactions {
            let draft = transaction.draft
            guard let assetID = draft.assetID else { continue }
            switch draft.kind {
            case .investmentBuy:
                let zero = try Money(minorUnits: 0, currencyCode: draft.amount.currencyCode)
                var position = positions[assetID] ?? InvestmentPosition(assetID: assetID, quantity: 0, totalCost: zero, investedCapital: zero, realizedPnL: zero, dividendIncome: zero)
                position.quantity += draft.quantity ?? 0
                position.totalCost = try position.totalCost.adding(draft.amount)
                position.investedCapital = try position.investedCapital.adding(draft.amount)
                positions[assetID] = position
            case .investmentSell:
                guard let costBasis = draft.costBasis else { throw LedgerError.invalidAmount }
                let zero = try Money(minorUnits: 0, currencyCode: draft.amount.currencyCode)
                var position = positions[assetID] ?? InvestmentPosition(assetID: assetID, quantity: 0, totalCost: zero, investedCapital: zero, realizedPnL: zero, dividendIncome: zero)
                position.quantity -= draft.quantity ?? 0
                guard position.quantity >= 0 else { throw LedgerError.invalidQuantity }
                position.totalCost = try position.totalCost.subtracting(costBasis)
                guard position.totalCost.minorUnits >= 0 else { throw LedgerError.invalidAmount }
                position.realizedPnL = try position.realizedPnL.adding(try draft.amount.subtracting(costBasis))
                positions[assetID] = position
            case .dividend:
                let zero = try Money(minorUnits: 0, currencyCode: draft.amount.currencyCode)
                var position = positions[assetID] ?? InvestmentPosition(assetID: assetID, quantity: 0, totalCost: zero, investedCapital: zero, realizedPnL: zero, dividendIncome: zero)
                position.dividendIncome = try position.dividendIncome.adding(draft.amount)
                positions[assetID] = position
            default:
                break
            }
        }
        return positions
    }

    public static func costBasis(for assetID: UUID, sellQuantity: Decimal, in state: LedgerState, through date: LocalDate) throws -> Money {
        guard sellQuantity > 0 else { throw LedgerError.invalidQuantity }
        let positions = try positions(in: state, through: date)
        guard let position = positions[assetID], sellQuantity <= position.quantity else {
            throw LedgerError.invalidQuantity
        }
        if sellQuantity == position.quantity { return position.totalCost }
        let scale = CurrencyScale.fractionDigits(for: position.totalCost.currencyCode)
        var roundedCost = Decimal()
        var unroundedCost = position.totalCost.decimalValue(fractionDigits: scale) * sellQuantity / position.quantity
        NSDecimalRound(&roundedCost, &unroundedCost, scale, .plain)
        return try Money.from(
            decimal: roundedCost,
            currencyCode: position.totalCost.currencyCode,
            fractionDigits: scale
        )
    }

    public static func valuation(for asset: InvestmentAsset, position: InvestmentPosition, quotes: [PriceQuote]) -> PositionValuation {
        let averageCost = averageCost(for: position)
        let realizedAndDividend = try? position.realizedPnL.adding(position.dividendIncome)
        guard let quote = quotes.filter({ $0.assetID == asset.id }).max(by: { $0.timestamp < $1.timestamp }) else {
            return PositionValuation(position: position, averageCost: averageCost, marketValue: nil, unrealizedPnL: nil, totalReturn: realizedAndDividend, returnPercentage: returnPercentage(totalReturn: realizedAndDividend, position: position), quoteTimestamp: nil, isStale: true)
        }
        let valuationPrice = quote.baseCurrencyPrice ?? quote.price
        let valuationCurrency = quote.baseCurrencyCode ?? quote.currencyCode
        guard valuationCurrency == position.totalCost.currencyCode else {
            return PositionValuation(position: position, averageCost: averageCost, marketValue: nil, unrealizedPnL: nil, totalReturn: realizedAndDividend, returnPercentage: returnPercentage(totalReturn: realizedAndDividend, position: position), quoteTimestamp: quote.timestamp, isStale: true)
        }
        let valuationScale = CurrencyScale.fractionDigits(for: valuationCurrency)
        guard let marketValue = try? Money.from(
            decimal: position.quantity * valuationPrice,
            currencyCode: valuationCurrency,
            fractionDigits: valuationScale
        ), let unrealized = try? marketValue.subtracting(position.totalCost) else {
            return PositionValuation(position: position, averageCost: averageCost, marketValue: nil, unrealizedPnL: nil, totalReturn: realizedAndDividend, returnPercentage: returnPercentage(totalReturn: realizedAndDividend, position: position), quoteTimestamp: quote.timestamp, isStale: true)
        }
        let totalReturn = try? unrealized.adding(position.realizedPnL).adding(position.dividendIncome)
        return PositionValuation(position: position, averageCost: averageCost, marketValue: marketValue, unrealizedPnL: unrealized, totalReturn: totalReturn, returnPercentage: returnPercentage(totalReturn: totalReturn, position: position), quoteTimestamp: quote.timestamp, isStale: quote.isStale)
    }

    private static func averageCost(for position: InvestmentPosition) -> Money? {
        guard position.quantity > 0 else { return nil }
        let scale = CurrencyScale.fractionDigits(for: position.totalCost.currencyCode)
        return try? Money.from(
            decimal: position.totalCost.decimalValue(fractionDigits: scale) / position.quantity,
            currencyCode: position.totalCost.currencyCode,
            fractionDigits: scale
        )
    }

    private static func returnPercentage(totalReturn: Money?, position: InvestmentPosition) -> Decimal? {
        guard let totalReturn, position.investedCapital.minorUnits > 0 else { return nil }
        return Decimal(totalReturn.minorUnits) / Decimal(position.investedCapital.minorUnits) * 100
    }
}

public struct NetWorthResult: Equatable, Sendable {
    public var totalAssets: Money
    public var totalLiabilities: Money
    public var netWorth: Money
    public var cashValue: Money
    public var stockValue: Money
    public var cryptoValue: Money
    public var otherAssetValue: Money
    public var liabilityValue: Money
    public var warnings: [String]
}

public enum NetWorthCalculator {
    public static func calculate(in state: LedgerState) throws -> NetWorthResult {
        let currency = state.baseCurrencyCode
        let zero = try Money(minorUnits: 0, currencyCode: currency)
        var totalAssets = zero
        var totalLiabilities = zero
        var cashValue = zero
        var stockValue = zero
        var cryptoValue = zero
        var otherAssetValue = zero
        var warnings: [String] = []
        let balances = try AccountBalanceCalculator.balances(in: state)

        for account in state.accounts where account.deletedAt == nil && account.includeInNetWorth && !account.type.isInvestment {
            guard account.currencyCode == currency, let balance = balances[account.id] else {
                warnings.append("\(account.name) 未計入：缺少基準幣別換算")
                continue
            }
            if account.type.isLiability || balance.minorUnits < 0 {
                let liability: Money
                if balance.minorUnits < 0 {
                    liability = try balance.negated()
                } else {
                    liability = balance
                }
                totalLiabilities = try totalLiabilities.adding(liability)
            } else {
                totalAssets = try totalAssets.adding(balance)
                switch account.type {
                case .cash, .bank: cashValue = try cashValue.adding(balance)
                case .otherAsset: otherAssetValue = try otherAssetValue.adding(balance)
                default: break
                }
            }
        }

        let positions = try InvestmentCalculator.positions(in: state)
        for asset in state.assets where asset.deletedAt == nil {
            guard let account = state.accounts.first(where: { $0.id == asset.accountID && $0.deletedAt == nil }), account.includeInNetWorth else { continue }
            guard let position = positions[asset.id] else { continue }
            let valuation = InvestmentCalculator.valuation(for: asset, position: position, quotes: state.quotes)
            let marketValue: Money
            if let quotedValue = valuation.marketValue, quotedValue.currencyCode == currency {
                marketValue = quotedValue
            } else if position.quantity > 0, position.totalCost.currencyCode == currency {
                marketValue = position.totalCost
                warnings.append("\(asset.symbol) 價格尚未更新：暫以已記錄成本計入淨資產")
            } else {
                warnings.append("\(asset.symbol) 未計入：缺少可用報價或幣別換算")
                continue
            }
            totalAssets = try totalAssets.adding(marketValue)
            if account.type == .stock { stockValue = try stockValue.adding(marketValue) }
            if account.type == .crypto { cryptoValue = try cryptoValue.adding(marketValue) }
        }

        return NetWorthResult(
            totalAssets: totalAssets,
            totalLiabilities: totalLiabilities,
            netWorth: try totalAssets.subtracting(totalLiabilities),
            cashValue: cashValue,
            stockValue: stockValue,
            cryptoValue: cryptoValue,
            otherAssetValue: otherAssetValue,
            liabilityValue: totalLiabilities,
            warnings: warnings
        )
    }
}

public enum BudgetStatus: String, Codable, Sendable { case underHalf, warning50, warning80, atLimit, overLimit }

extension CashFlowCalculator {
    public static func spendingBreakdown(in range: LedgerDateRange, state: LedgerState, byMember: Bool) throws -> [String: Money] {
        var totals: [String: Money] = [:]
        for transaction in state.transactions where transaction.deletedAt == nil && range.contains(transaction.draft.occurredOn) {
            let draft = transaction.draft
            guard draft.amount.currencyCode == state.baseCurrencyCode else { continue }
            let amount: Money?
            switch draft.kind {
            case .expense, .creditCardCharge: amount = draft.amount
            case .loanPayment: amount = draft.interest
            case .transfer: amount = draft.fee
            default: amount = nil
            }
            guard let amount else { continue }
            let key = byMember ? ((draft.member?.isEmpty == false ? draft.member : nil) ?? "未指定成員") : (state.accounts.first { $0.id == draft.accountID }?.name ?? "已刪除帳戶")
            totals[key] = try (totals[key] ?? .zero(currencyCode: state.baseCurrencyCode)).adding(amount)
        }
        return totals
    }
}

public enum BudgetService {
    public static func overview(budgets: [Budget], spending: [UUID: Money], currency: String, remainingDays: Int) throws -> (limit: Money, spent: Money, remaining: Money, perDay: Money) {
        var limit = Money.zero(currencyCode: currency)
        var spent = Money.zero(currencyCode: currency)
        for budget in budgets where budget.deletedAt == nil {
            limit = try limit.adding(budget.limit)
            spent = try spent.adding(spending[budget.categoryID] ?? .zero(currencyCode: currency))
        }
        let remaining = try limit.subtracting(spent)
        let perDay = try Money.from(decimal: remaining.decimalValue(fractionDigits: CurrencyScale.fractionDigits(for: currency)) / Decimal(max(1, remainingDays)), currencyCode: currency, fractionDigits: CurrencyScale.fractionDigits(for: currency))
        return (limit, spent, remaining, perDay)
    }
    public static func notice(categoryName: String, spent: Money, limit: Money) throws -> String? {
        let state = try status(spent: spent, limit: limit)
        guard state != .underHalf else { return nil }
        var percentage = Decimal(spent.minorUnits) / Decimal(limit.minorUnits) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &percentage, 1, .plain)
        let value = NSDecimalNumber(decimal: rounded).stringValue
        let suffix = state == .overLimit ? "，已超標。" : "。"
        return "新增本筆後，\(categoryName) 預算已使用 \(value)%\(suffix)"
    }

    public static func status(spent: Money, limit: Money) throws -> BudgetStatus {
        guard limit.isPositive, spent.currencyCode == limit.currencyCode else { throw LedgerError.invalidAmount }
        let percent = Decimal(spent.minorUnits) / Decimal(limit.minorUnits)
        if percent > 1 { return .overLimit }
        if percent == 1 { return .atLimit }
        if percent >= Decimal(8) / 10 { return .warning80 }
        if percent >= Decimal(5) / 10 { return .warning50 }
        return .underHalf
    }
}

public struct AnomalyResult: Equatable, Sendable {
    public var isAnomalous: Bool
    public var historicalAverage: Money?
    public var ratio: Decimal?
}

public enum AnomalyDetectionService {
    public static func detect(currentProgressSpend: Money, priorProgressSpends: [Money]) throws -> AnomalyResult {
        let samples = priorProgressSpends.filter { $0.currencyCode == currentProgressSpend.currencyCode }
        guard !samples.isEmpty else { return AnomalyResult(isAnomalous: false, historicalAverage: nil, ratio: nil) }
        let total = try samples.reduce(Money.zero(currencyCode: currentProgressSpend.currencyCode)) { try $0.adding($1) }
        let average = try Money(minorUnits: total.minorUnits / Int64(samples.count), currencyCode: currentProgressSpend.currencyCode)
        guard average.minorUnits > 0 else { return AnomalyResult(isAnomalous: false, historicalAverage: average, ratio: nil) }
        let ratio = Decimal(currentProgressSpend.minorUnits) / Decimal(average.minorUnits)
        return AnomalyResult(isAnomalous: ratio > Decimal(13) / 10, historicalAverage: average, ratio: ratio)
    }
}

public enum ForecastConfidence: String, Codable, Sendable { case high, medium, low, unavailable }

public struct ForecastResult: Equatable, Sendable {
    public var projectedMonthEnd: Money?
    public var confidence: ForecastConfidence
    public var historicalProgressFraction: Decimal?
}

public enum ForecastService {
    public static func forecast(
        currentSpend: Money,
        elapsedDays: Int,
        daysInMonth: Int,
        historicalProgressFractions: [Decimal]
    ) throws -> ForecastResult {
        guard elapsedDays > 0, daysInMonth >= elapsedDays else { throw LedgerError.invalidDate }
        let fractions = historicalProgressFractions.filter { $0 >= 0 && $0 <= 1 }
        let historicalAverage = fractions.isEmpty ? nil : fractions.reduce(0, +) / Decimal(fractions.count)
        let fraction: Decimal
        let confidence: ForecastConfidence
        if let historicalAverage, historicalAverage > 0 {
            fraction = historicalAverage
            confidence = fractions.count >= 6 ? .high : fractions.count >= 3 ? .medium : .low
        } else {
            fraction = Decimal(elapsedDays) / Decimal(daysInMonth)
            confidence = .low
        }
        guard fraction > 0 else { return ForecastResult(projectedMonthEnd: nil, confidence: .unavailable, historicalProgressFraction: nil) }
        let projectedMinor = Decimal(currentSpend.minorUnits) / fraction
        var rounded = Decimal()
        var source = projectedMinor
        NSDecimalRound(&rounded, &source, 0, .plain)
        let projected = try Money.from(decimal: rounded, currencyCode: currentSpend.currencyCode, fractionDigits: 0)
        return ForecastResult(projectedMonthEnd: projected, confidence: confidence, historicalProgressFraction: fraction)
    }
}

public struct CategorySpendingInsight: Sendable {
    public var currentSpend: Money
    public var anomaly: AnomalyResult
    public var forecast: ForecastResult

    public init(currentSpend: Money, anomaly: AnomalyResult, forecast: ForecastResult) {
        self.currentSpend = currentSpend
        self.anomaly = anomaly
        self.forecast = forecast
    }
}

/// Computes comparisons at the same calendar-day progress, rather than comparing a partial month with historical full months.
public enum SpendingInsightService {
    public static func insight(categoryID: UUID, asOf date: LocalDate, in state: LedgerState, months: Int = 6) throws -> CategorySpendingInsight {
        let elapsedDays = date.day
        let daysThisMonth = try date.monthKey.daysInMonth()
        let currentRange = try LedgerDateRange(start: LocalDate(year: date.year, month: date.month, day: 1), end: date)
        let currentSpend = try spending(categoryID: categoryID, in: currentRange, state: state)
        var priorProgressSpends: [Money] = []
        var historicalProgressFractions: [Decimal] = []

        if months > 0 {
            for offset in 1 ... months {
                guard let historicalMonth = month(offset: -offset, from: date.monthKey) else { continue }
                let days = try historicalMonth.daysInMonth()
                let progressEnd = try LocalDate(year: historicalMonth.year, month: historicalMonth.month, day: min(elapsedDays, days))
                let historicalStart = try LocalDate(year: historicalMonth.year, month: historicalMonth.month, day: 1)
                let progressRange = try LedgerDateRange(start: historicalStart, end: progressEnd)
                let fullRange = try LedgerDateRange(start: historicalStart, end: try LocalDate(year: historicalMonth.year, month: historicalMonth.month, day: days))
                let progressSpend = try spending(categoryID: categoryID, in: progressRange, state: state)
                let fullSpend = try spending(categoryID: categoryID, in: fullRange, state: state)
                priorProgressSpends.append(progressSpend)
                if fullSpend.minorUnits > 0 {
                    historicalProgressFractions.append(Decimal(progressSpend.minorUnits) / Decimal(fullSpend.minorUnits))
                }
            }
        }

        return CategorySpendingInsight(
            currentSpend: currentSpend,
            anomaly: try AnomalyDetectionService.detect(currentProgressSpend: currentSpend, priorProgressSpends: priorProgressSpends),
            forecast: try ForecastService.forecast(
                currentSpend: currentSpend,
                elapsedDays: elapsedDays,
                daysInMonth: daysThisMonth,
                historicalProgressFractions: historicalProgressFractions
            )
        )
    }

    private static func spending(categoryID: UUID, in range: LedgerDateRange, state: LedgerState) throws -> Money {
        try CashFlowCalculator.expensesByCategory(in: range, state: state)[categoryID]
            ?? Money(minorUnits: 0, currencyCode: state.baseCurrencyCode)
    }

    private static func month(offset: Int, from month: MonthKey) -> MonthKey? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let shifted = calendar.date(byAdding: .month, value: offset, to: date)
        else { return nil }
        let components = calendar.dateComponents([.year, .month], from: shifted)
        guard let year = components.year, let value = components.month else { return nil }
        return MonthKey(year: year, month: value)
    }

}

public struct NetWorthGrowthSources: Sendable {
    public var netWorthChange: Money
    public var dailyCashFlowContribution: Money
    public var investmentReturn: Money
    public var liabilityChange: Money
    /// A visible reconciliation remainder. It prevents the UI from silently assigning unknown balance changes to saving or market performance.
    public var unclassifiedChange: Money
}

public enum NetWorthGrowthService {
    public static func explain(
        from start: NetWorthSnapshot,
        to end: NetWorthSnapshot,
        over range: LedgerDateRange,
        in state: LedgerState
    ) throws -> NetWorthGrowthSources {
        let currency = state.baseCurrencyCode
        let zero = try Money(minorUnits: 0, currencyCode: currency)
        guard start.netWorth.currencyCode == currency, end.netWorth.currencyCode == currency else { throw LedgerError.currencyMismatch }
        let transactionRange = try rangeAfterSnapshot(start.date, through: end.date, boundedBy: range)
        let summary = try transactionRange.map { try CashFlowCalculator.summary(in: $0, state: state) }
            ?? CashFlowSummary(ordinaryIncome: zero, livingExpenses: zero, investmentContributions: zero, realizedInvestmentGains: zero, dividendIncome: zero)
        let salesProceeds = try state.transactions
            .filter { transactionRange?.contains($0.draft.occurredOn) == true && $0.deletedAt == nil && $0.draft.kind == .investmentSell && $0.draft.amount.currencyCode == currency }
            .reduce(zero) { try $0.adding($1.draft.amount) }
        let startingInvestments = try start.stockValue.adding(start.cryptoValue)
        let endingInvestments = try end.stockValue.adding(end.cryptoValue)
        let investmentReturn = try endingInvestments
            .subtracting(startingInvestments)
            .subtracting(summary.investmentContributions)
            .adding(salesProceeds)
            .adding(summary.dividendIncome)
        let dailyCashFlow = try summary.ordinaryIncome.subtracting(summary.livingExpenses)
        let liabilityChange = try start.liabilityValue.subtracting(end.liabilityValue)
        let netWorthChange = try end.netWorth.subtracting(start.netWorth)
        // Charges and interest already affect daily cash flow, while principal payments and card payments are net-worth-neutral transfers.
        // Therefore liability movement is displayed as context rather than added again to the reconciled sources.
        let attributed = try dailyCashFlow.adding(investmentReturn)
        return NetWorthGrowthSources(
            netWorthChange: netWorthChange,
            dailyCashFlowContribution: dailyCashFlow,
            investmentReturn: investmentReturn,
            liabilityChange: liabilityChange,
            unclassifiedChange: try netWorthChange.subtracting(attributed)
        )
    }

    private static func rangeAfterSnapshot(_ snapshotDate: LocalDate, through end: LocalDate, boundedBy range: LedgerDateRange) throws -> LedgerDateRange? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let nextDate = calendar.date(byAdding: .day, value: 1, to: snapshotDate.date(in: calendar.timeZone)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: nextDate)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let dayAfterSnapshot = try LocalDate(year: year, month: month, day: day)
        let start = max(range.start, dayAfterSnapshot)
        guard start <= end, start <= range.end else { return nil }
        return try LedgerDateRange(start: start, end: min(end, range.end))
    }
}

public struct CashFlowTrendPoint: Identifiable, Sendable {
    public var id: String { date.iso8601 }
    public var date: LocalDate
    public var ordinaryIncome: Money
    public var livingExpenses: Money
    public var availableBalance: Money
}

public enum CashFlowTrendService {
    /// Uses daily buckets for short selections so a single month/week is not reduced to one point.
    public static func points(in range: LedgerDateRange, state: LedgerState) throws -> [CashFlowTrendPoint] {
        guard let elapsedDays = calendar.dateComponents([.day], from: range.start.date(in: utc), to: range.end.date(in: utc)).day else { throw LedgerError.invalidDate }
        let dayCount = elapsedDays + 1
        return dayCount <= 62 ? try daily(in: range, state: state) : try monthly(in: range, state: state)
    }

    public static func daily(in range: LedgerDateRange, state: LedgerState) throws -> [CashFlowTrendPoint] {
        var dates: [LocalDate] = []
        var date = range.start.date(in: utc)
        while date <= range.end.date(in: utc) {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { throw LedgerError.invalidDate }
            dates.append(try LocalDate(year: year, month: month, day: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { throw LedgerError.invalidDate }
            date = next
        }
        return try dates.map { date in
            let summary = try CashFlowCalculator.summary(in: LedgerDateRange(singleDay: date), state: state)
            return CashFlowTrendPoint(date: date, ordinaryIncome: summary.ordinaryIncome, livingExpenses: summary.livingExpenses, availableBalance: try summary.availableBalance())
        }
    }

    public static func monthly(in range: LedgerDateRange, state: LedgerState) throws -> [CashFlowTrendPoint] {
        var months: [MonthKey] = []
        var cursor = try LocalDate(year: range.start.year, month: range.start.month, day: 1)
        let endMonth = range.end.monthKey
        while cursor.monthKey <= endMonth {
            months.append(cursor.monthKey)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor.date(in: utc)),
                  let year = calendar.dateComponents([.year], from: next).year,
                  let month = calendar.dateComponents([.month], from: next).month
            else { throw LedgerError.invalidDate }
            cursor = try LocalDate(year: year, month: month, day: 1)
        }
        return try months.map { month in
            let monthStart = try LocalDate(year: month.year, month: month.month, day: 1)
            let monthEnd = try LocalDate(year: month.year, month: month.month, day: month.daysInMonth())
            let start = max(range.start, monthStart)
            let end = min(range.end, monthEnd)
            let summary = try CashFlowCalculator.summary(in: LedgerDateRange(start: start, end: end), state: state)
            return CashFlowTrendPoint(date: monthStart, ordinaryIncome: summary.ordinaryIncome, livingExpenses: summary.livingExpenses, availableBalance: try summary.availableBalance())
        }
    }

    private static let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = utc
        return value
    }
}

public enum CategoryHistoryService {
    public static func averageMonthlySpend(categoryID: UUID, before targetMonth: MonthKey, months: Int = 6, in state: LedgerState) throws -> Money? {
        guard months > 0 else { return nil }
        let zero = try Money(minorUnits: 0, currencyCode: state.baseCurrencyCode)
        var total = zero
        var count = 0
        for offset in 1 ... months {
            guard let historical = month(offset: -offset, from: targetMonth) else { continue }
            let range = try LedgerDateRange(
                start: LocalDate(year: historical.year, month: historical.month, day: 1),
                end: LocalDate(year: historical.year, month: historical.month, day: try historical.daysInMonth())
            )
            total = try total.adding(CashFlowCalculator.expensesByCategory(in: range, state: state)[categoryID] ?? zero)
            count += 1
        }
        return count == 0 ? nil : try Money(minorUnits: total.minorUnits / Int64(count), currencyCode: state.baseCurrencyCode)
    }

    private static func month(offset: Int, from month: MonthKey) -> MonthKey? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let shifted = calendar.date(byAdding: .month, value: offset, to: date)
        else { return nil }
        let components = calendar.dateComponents([.year, .month], from: shifted)
        guard let year = components.year, let value = components.month else { return nil }
        return MonthKey(year: year, month: value)
    }

}
