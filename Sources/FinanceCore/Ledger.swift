import Foundation

public enum LedgerService {
    public static func makeTransaction(from draft: TransactionDraft, in state: LedgerState, now: Date = Date()) throws -> LedgerTransaction {
        let normalized = try normalize(draft, in: state)
        try validateNormalized(normalized, in: state)
        return LedgerTransaction(draft: normalized, createdAt: now, updatedAt: now)
    }

    public static func validate(_ draft: TransactionDraft, in state: LedgerState) throws {
        let normalized = try normalize(draft, in: state)
        try validateNormalized(normalized, in: state)
    }

    public static func normalize(_ draft: TransactionDraft, in state: LedgerState) throws -> TransactionDraft {
        guard draft.kind == .investmentSell else { return draft }
        guard let assetID = draft.assetID, let quantity = draft.quantity, quantity > 0 else { throw LedgerError.invalidQuantity }
        let expectedCost = try InvestmentCalculator.costBasis(for: assetID, sellQuantity: quantity, in: state, through: draft.occurredOn)
        if let suppliedCost = draft.costBasis, suppliedCost != expectedCost { throw LedgerError.invalidCostBasis }
        var normalized = draft
        normalized.costBasis = expectedCost
        return normalized
    }

    private static func validateNormalized(_ draft: TransactionDraft, in state: LedgerState) throws {
        guard (draft.receiptImages?.count ?? 0) <= 3,
              draft.receiptImages?.allSatisfy({ $0.count <= 5_000_000 }) != false else { throw LedgerError.invalidAmount }
        let refund = (draft.kind == .expense || draft.kind == .creditCardCharge) && draft.amount.minorUnits != 0
        guard draft.amount.isPositive || refund else { throw LedgerError.invalidAmount }
        let account = try activeAccount(draft.accountID, in: state)
        let counterparty = try draft.counterpartyAccountID.map { try activeAccount($0, in: state) }

        func requireCategory(_ expected: CategoryKind) throws {
            guard let categoryID = draft.categoryID else { throw LedgerError.missingCategory }
            guard let category = state.categories.first(where: { $0.id == categoryID && $0.deletedAt == nil }), category.kind == expected else {
                throw LedgerError.invalidCategory
            }
        }
        func requireAsset(on investmentAccount: Account) throws {
            guard let assetID = draft.assetID,
                  state.assets.contains(where: { $0.id == assetID && $0.deletedAt == nil && $0.accountID == investmentAccount.id })
            else { throw LedgerError.missingAsset }
            guard let quantity = draft.quantity, quantity > 0 else { throw LedgerError.invalidQuantity }
        }
        func requireCounterparty() throws -> Account {
            guard let counterparty else { throw LedgerError.missingCounterparty }
            guard counterparty.currencyCode == account.currencyCode, account.currencyCode == draft.amount.currencyCode else {
                throw LedgerError.currencyMismatch
            }
            return counterparty
        }
        func requireBaseCurrency() throws {
            guard draft.amount.currencyCode == state.baseCurrencyCode else { throw LedgerError.currencyMismatch }
        }

        if draft.kind != .investmentSell {
            guard account.currencyCode == draft.amount.currencyCode else { throw LedgerError.currencyMismatch }
        }

        switch draft.kind {
        case .income:
            try requireBaseCurrency()
            try requireCategory(.income)
            guard !account.type.isLiability && !account.type.isInvestment else { throw LedgerError.incompatibleAccountType }
        case .expense:
            try requireBaseCurrency()
            try requireCategory(.expense)
            guard !account.type.isInvestment && !account.type.isLiability else { throw LedgerError.incompatibleAccountType }
        case .transfer:
            let destination = try requireCounterparty()
            guard destination.id != account.id else { throw LedgerError.sameTransferAccount }
            guard !account.type.isLiability, !destination.type.isLiability,
                  !account.type.isInvestment, !destination.type.isInvestment else { throw LedgerError.incompatibleAccountType }
            if let fee = draft.fee {
                guard fee.currencyCode == draft.amount.currencyCode, fee.minorUnits >= 0 else { throw LedgerError.invalidAmount }
            }
        case .creditCardCharge:
            try requireBaseCurrency()
            try requireCategory(.expense)
            guard account.type == .creditCard else { throw LedgerError.incompatibleAccountType }
        case .creditCardPayment:
            try requireBaseCurrency()
            let card = try requireCounterparty()
            guard !account.type.isLiability && !account.type.isInvestment && card.type == .creditCard else { throw LedgerError.incompatibleAccountType }
        case .loanPayment:
            try requireBaseCurrency()
            let loan = try requireCounterparty()
            guard !account.type.isLiability && !account.type.isInvestment && loan.type == .loan else { throw LedgerError.incompatibleAccountType }
            guard let principal = draft.principal, let interest = draft.interest,
                  principal.minorUnits >= 0, interest.minorUnits >= 0,
                  principal.currencyCode == draft.amount.currencyCode, interest.currencyCode == draft.amount.currencyCode else { throw LedgerError.invalidLoanSplit }
            guard try principal.adding(interest) == draft.amount else { throw LedgerError.invalidLoanSplit }
            if interest.isPositive { try requireCategory(.expense) }
        case .investmentBuy:
            guard let investmentAccount = counterparty else { throw LedgerError.missingCounterparty }
            guard !account.type.isLiability && !account.type.isInvestment && investmentAccount.type.isInvestment else { throw LedgerError.incompatibleAccountType }
            guard draft.amount.currencyCode == state.baseCurrencyCode else { throw LedgerError.currencyMismatch }
            try requireAsset(on: investmentAccount)
        case .investmentSell:
            guard let receivingAccount = counterparty else { throw LedgerError.missingCounterparty }
            guard account.type.isInvestment && !receivingAccount.type.isLiability && !receivingAccount.type.isInvestment else { throw LedgerError.incompatibleAccountType }
            guard draft.amount.currencyCode == state.baseCurrencyCode, receivingAccount.currencyCode == draft.amount.currencyCode else { throw LedgerError.currencyMismatch }
            try requireAsset(on: account)
            guard let costBasis = draft.costBasis, costBasis.isPositive, costBasis.currencyCode == draft.amount.currencyCode else {
                throw LedgerError.invalidAmount
            }
        case .dividend:
            try requireBaseCurrency()
            guard let investmentAccount = counterparty else { throw LedgerError.missingCounterparty }
            guard !account.type.isLiability && !account.type.isInvestment && investmentAccount.type.isInvestment else { throw LedgerError.incompatibleAccountType }
            if let assetID = draft.assetID {
                guard state.assets.contains(where: { $0.id == assetID && $0.deletedAt == nil && $0.accountID == investmentAccount.id }) else {
                    throw LedgerError.missingAsset
                }
            }
            if let categoryID = draft.categoryID {
                guard state.categories.contains(where: { $0.id == categoryID && $0.kind == .investmentIncome && $0.deletedAt == nil }) else {
                    throw LedgerError.invalidCategory
                }
            }
        }
    }

    private static func activeAccount(_ id: UUID, in state: LedgerState) throws -> Account {
        guard let account = state.accounts.first(where: { $0.id == id }) else { throw LedgerError.missingAccount }
        guard account.deletedAt == nil else { throw LedgerError.deletedAccount }
        return account
    }
}

public struct CashFlowSummary: Equatable, Sendable {
    public var ordinaryIncome: Money
    public var livingExpenses: Money
    public var investmentContributions: Money
    public var realizedInvestmentGains: Money
    public var dividendIncome: Money

    public func availableBalance() throws -> Money {
        try ordinaryIncome.subtracting(livingExpenses).subtracting(investmentContributions)
    }
}

public enum CashFlowCalculator {
    public static func summary(for month: MonthKey, in state: LedgerState) throws -> CashFlowSummary {
        try summary(in: range(for: month), state: state)
    }

    public static func summary(in range: LedgerDateRange, state: LedgerState) throws -> CashFlowSummary {
        let currency = state.baseCurrencyCode
        var summary = CashFlowSummary(
            ordinaryIncome: try Money(minorUnits: 0, currencyCode: currency),
            livingExpenses: try Money(minorUnits: 0, currencyCode: currency),
            investmentContributions: try Money(minorUnits: 0, currencyCode: currency),
            realizedInvestmentGains: try Money(minorUnits: 0, currencyCode: currency),
            dividendIncome: try Money(minorUnits: 0, currencyCode: currency)
        )

        for transaction in state.transactions where transaction.deletedAt == nil && range.contains(transaction.draft.occurredOn) {
            let draft = transaction.draft
            guard draft.amount.currencyCode == currency else { continue }
            switch draft.kind {
            case .income:
                summary.ordinaryIncome = try summary.ordinaryIncome.adding(draft.amount)
            case .expense, .creditCardCharge:
                summary.livingExpenses = try summary.livingExpenses.adding(draft.amount)
            case .loanPayment:
                if let interest = draft.interest { summary.livingExpenses = try summary.livingExpenses.adding(interest) }
            case .investmentBuy:
                summary.investmentContributions = try summary.investmentContributions.adding(draft.amount)
            case .investmentSell:
                if let costBasis = draft.costBasis {
                    summary.realizedInvestmentGains = try summary.realizedInvestmentGains.adding(try draft.amount.subtracting(costBasis))
                }
            case .dividend:
                summary.dividendIncome = try summary.dividendIncome.adding(draft.amount)
            case .transfer:
                if let fee = draft.fee { summary.livingExpenses = try summary.livingExpenses.adding(fee) }
            case .creditCardPayment:
                break
            }
        }
        return summary
    }

    public static func expensesByCategory(for month: MonthKey, in state: LedgerState) throws -> [UUID: Money] {
        try expensesByCategory(in: range(for: month), state: state)
    }

    public static func expensesByCategory(in range: LedgerDateRange, state: LedgerState) throws -> [UUID: Money] {
        var totals: [UUID: Money] = [:]
        for transaction in state.transactions where transaction.deletedAt == nil && range.contains(transaction.draft.occurredOn) {
            let draft = transaction.draft
            guard draft.amount.currencyCode == state.baseCurrencyCode,
                  [.expense, .creditCardCharge, .loanPayment].contains(draft.kind),
                  let categoryID = draft.categoryID else { continue }
            let expense = draft.kind == .loanPayment ? draft.interest : draft.amount
            guard let expense, expense.minorUnits != 0 else { continue }
            totals[categoryID] = try (totals[categoryID] ?? Money(minorUnits: 0, currencyCode: draft.amount.currencyCode)).adding(expense)
        }
        return totals
    }

    private static func range(for month: MonthKey) throws -> LedgerDateRange {
        let firstDay = try LocalDate(year: month.year, month: month.month, day: 1)
        let lastDay = try month.daysInMonth()
        return try LedgerDateRange(
            start: firstDay,
            end: LocalDate(year: month.year, month: month.month, day: lastDay)
        )
    }
}

public enum AccountBalanceCalculator {
    public static func balances(in state: LedgerState) throws -> [UUID: Money] {
        var result: [UUID: Money] = [:]
        for account in state.accounts where account.deletedAt == nil {
            guard result[account.id] == nil else { throw LedgerError.duplicateEntityID }
            result[account.id] = account.openingBalance
        }
        func apply(_ accountID: UUID, _ delta: Money) throws {
            guard let current = result[accountID] else { throw LedgerError.missingAccount }
            result[accountID] = try current.adding(delta)
        }
        for transaction in state.transactions where transaction.deletedAt == nil {
            let draft = transaction.draft
            switch draft.kind {
            case .income:
                try apply(draft.accountID, draft.amount)
            case .expense, .creditCardCharge:
                try apply(draft.accountID, draft.amount.negated())
            case .transfer, .creditCardPayment:
                guard let destination = draft.counterpartyAccountID else { throw LedgerError.missingCounterparty }
                let sourceDebit = try draft.amount.adding(draft.fee ?? .zero(currencyCode: draft.amount.currencyCode))
                try apply(draft.accountID, sourceDebit.negated())
                try apply(destination, draft.amount)
            case .loanPayment:
                guard let loan = draft.counterpartyAccountID, let principal = draft.principal else { throw LedgerError.invalidLoanSplit }
                try apply(draft.accountID, draft.amount.negated())
                try apply(loan, principal)
            case .investmentBuy:
                try apply(draft.accountID, draft.amount.negated())
            case .investmentSell:
                guard let receiving = draft.counterpartyAccountID else { throw LedgerError.missingCounterparty }
                try apply(receiving, draft.amount)
            case .dividend:
                try apply(draft.accountID, draft.amount)
            }
        }
        return result
    }
}

public enum CreditCardService {
    public static func currentStatementRange(for account: Account, asOf date: LocalDate) throws -> LedgerDateRange {
        guard account.type == .creditCard, let metadata = account.creditCard else { throw LedgerError.incompatibleAccountType }
        guard (1 ... 31).contains(metadata.statementDay) else { throw LedgerError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let current = date.date(in: calendar.timeZone)
        let startMonth: Date
        if date.day >= metadata.statementDay {
            startMonth = current
        } else if let previous = calendar.date(byAdding: .month, value: -1, to: current) {
            startMonth = previous
        } else {
            throw LedgerError.invalidDate
        }
        let monthParts = calendar.dateComponents([.year, .month], from: startMonth)
        guard let year = monthParts.year, let month = monthParts.month else { throw LedgerError.invalidDate }
        let lastDay = try MonthKey(year: year, month: month).daysInMonth()
        let start = try LocalDate(year: year, month: month, day: min(metadata.statementDay, lastDay))
        return try LedgerDateRange(start: start, end: date)
    }

    public static func currentStatementTotal(for account: Account, asOf date: LocalDate, in state: LedgerState) throws -> Money {
        let range = try currentStatementRange(for: account, asOf: date)
        return try state.transactions.filter {
            $0.deletedAt == nil && $0.draft.kind == .creditCardCharge && $0.draft.accountID == account.id && range.contains($0.draft.occurredOn)
        }.reduce(Money.zero(currencyCode: account.currencyCode)) { try $0.adding($1.draft.amount) }
    }
}
