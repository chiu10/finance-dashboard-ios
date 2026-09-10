import Foundation
import XCTest
@testable import FinanceCore

private func twd(_ amount: Int64) -> Money { .twd(amount) }

private struct FailingQuoteProvider: QuoteProvider {
    let identifier = "failing-test-provider"
    func latestQuote(for asset: InvestmentAsset) async throws -> PriceQuote { throw QuoteProviderError.unavailable }
}

private struct TestExpectationFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class FinanceCoreTests: XCTestCase {
    func testLocalDateRejectsInvalidInput() throws {
        for value in ["2026-02-30", "2026-13-01", "2026-00-10", "2026-01-00", "2025-02-29", "2026--09-05", "2026-09-05-extra"] {
            XCTAssertThrowsError(try LocalDate(iso8601: value), value)
        }
        let invalid = Data("{\"year\":2026,\"month\":2,\"day\":30}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalDate.self, from: invalid))
        let valid = try LocalDate(iso8601: "2024-02-29")
        XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: JSONEncoder().encode(valid)), valid)
    }

    func testAnalysisPeriods() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 2
        let today = try LocalDate(iso8601: "2026-09-05").date(in: .gmt)
        let expected: [(AnalysisPeriod, String, String)] = [
            (.week, "2026-08-31", "2026-09-05"),
            (.month, "2026-09-01", "2026-09-05"),
            (.lastMonth, "2026-08-01", "2026-08-31"),
            (.threeMonths, "2026-06-05", "2026-09-05"),
            (.sixMonths, "2026-03-05", "2026-09-05"),
            (.year, "2026-01-01", "2026-09-05"),
            (.oneYear, "2025-09-05", "2026-09-05"),
            (.custom, "2026-09-05", "2026-09-05")
        ]
        for (period, start, end) in expected {
            let range = try period.range(asOf: today, calendar: calendar, customStart: today, customEnd: today)
            try expect(range.start.iso8601 == start)
            try expect(range.end.iso8601 == end)
        }
        let march = try LocalDate(iso8601: "2024-03-31").date(in: .gmt)
        let leapFebruary = try AnalysisPeriod.lastMonth.range(asOf: march, calendar: calendar, customStart: march, customEnd: march)
        try expect(leapFebruary.end.iso8601 == "2024-02-29")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = .gmt
        let month = try AnalysisPeriod.month.range(asOf: today, calendar: buddhist, customStart: today, customEnd: today)
        try expect(month.start.iso8601 == "2026-09-01")
    }

    func testCashFlowTrendUsesDailyBucketsForShortRanges() throws {
        let start = try LocalDate(iso8601: "2026-09-01")
        let end = try LocalDate(iso8601: "2026-09-05")
        let bank = Account(name: "合成銀行", type: .bank)
        let income = incomeCategory()
        let expense = expenseCategory()
        var state = LedgerState(accounts: [bank], categories: [income, expense])
        try LedgerMutationService.add(TransactionDraft(kind: .income, occurredOn: start, accountID: bank.id, amount: twd(1_001), categoryID: income.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: start, accountID: bank.id, amount: twd(1), categoryID: expense.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: try LocalDate(iso8601: "2026-09-03"), accountID: bank.id, amount: twd(2), categoryID: expense.id), to: &state)
        let points = try CashFlowTrendService.points(in: LedgerDateRange(start: start, end: end), state: state)
        XCTAssertEqual(points.map(\.date.iso8601), ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"])
        XCTAssertEqual(points[0].ordinaryIncome, twd(1_001))
        XCTAssertEqual(points[0].livingExpenses, twd(1))
        XCTAssertEqual(points[2].livingExpenses, twd(2))
        let longRange = try LedgerDateRange(start: start, end: try LocalDate(iso8601: "2026-11-30"))
        let longPoints = try CashFlowTrendService.points(in: longRange, state: state)
        XCTAssertEqual(longPoints.map(\.date.iso8601), ["2026-09-01", "2026-10-01", "2026-11-01"])
        XCTAssertEqual(longPoints[1].ordinaryIncome, twd(0))
        XCTAssertEqual(longPoints[1].livingExpenses, twd(0))
    }

    private func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: UInt = #line) throws {
        if try !condition() {
            recordExpectationFailure("Expectation failed.", file: file, line: line)
        }
    }

    private func require<T>(_ value: @autoclosure () throws -> T?, file: String = #fileID, line: UInt = #line) throws -> T {
        guard let value = try value() else {
            throw TestExpectationFailure(message: "Expected a required value at \(file):\(line).")
        }
        return value
    }

    private func failTest(_ message: String, file: String = #fileID, line: UInt = #line) {
        recordExpectationFailure(message, file: file, line: line)
    }

    private func recordExpectationFailure(_ message: String, file: String, line: UInt) {
        let location = XCTSourceCodeLocation(filePath: file, lineNumber: Int(line))
        let context = XCTSourceCodeContext(location: location)
        record(XCTIssue(type: .assertionFailure, compactDescription: message, detailedDescription: nil, sourceCodeContext: context, associatedError: nil, attachments: []))
    }

    private func expenseCategory() -> FinanceCore.Category { FinanceCore.Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "餐飲", kind: .expense) }
    private func incomeCategory() -> FinanceCore.Category { FinanceCore.Category(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "薪資", kind: .income) }

    func testOrdinaryCashFlow() throws {
        let bank = Account(name: "銀行", type: .bank)
        let income = incomeCategory()
        let expense = expenseCategory()
        var state = LedgerState(accounts: [bank], categories: [income, expense])
        try LedgerMutationService.add(TransactionDraft(kind: .income, occurredOn: try LocalDate(iso8601: "2026-09-01"), accountID: bank.id, amount: twd(50_000), categoryID: income.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: try LocalDate(iso8601: "2026-09-02"), accountID: bank.id, amount: twd(20_000), categoryID: expense.id), to: &state)
        let summary = try CashFlowCalculator.summary(for: MonthKey(year: 2026, month: 9), in: state)
        try expect(summary.ordinaryIncome == twd(50_000))
        try expect(summary.livingExpenses == twd(20_000))
        try expect(try summary.availableBalance() == twd(30_000))
    }

    func testExpenseRefundReducesSpendAndBudgetUsage() throws {
        let bank = Account(name: "銀行", type: .bank)
        let category = Category(name: "餐飲", kind: .expense)
        var state = LedgerState(accounts: [bank], categories: [category], budgets: [Budget(categoryID: category.id, month: MonthKey(year: 2026, month: 9), limit: twd(1_000))])
        let date = try LocalDate(iso8601: "2026-09-06")
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: date, accountID: bank.id, amount: twd(500), categoryID: category.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: date, accountID: bank.id, amount: twd(-200), categoryID: category.id), to: &state)
        let spend = try CashFlowCalculator.expensesByCategory(for: date.monthKey, in: state)[category.id]
        try expect(spend == twd(300))
        try expect(try BudgetService.status(spent: spend!, limit: twd(1_000)) == .underHalf)
    }

    func testInvestmentBuy() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let income = incomeCategory()
        let expense = expenseCategory()
        let asset = InvestmentAsset(accountID: broker.id, symbol: "TEST", name: "Synthetic Stock", market: .taiwan)
        var state = LedgerState(accounts: [bank, broker], categories: [income, expense], assets: [asset], quotes: [PriceQuote(assetID: asset.id, price: Decimal(20_000), currencyCode: "TWD", source: "test")])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .income, occurredOn: date, accountID: bank.id, amount: twd(50_000), categoryID: income.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: date, accountID: bank.id, amount: twd(20_000), categoryID: expense.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(20_000), assetID: asset.id, quantity: 1), to: &state)
        let cashFlow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        let netWorth = try NetWorthCalculator.calculate(in: state)
        try expect(cashFlow.livingExpenses == twd(20_000))
        try expect(cashFlow.investmentContributions == twd(20_000))
        try expect(try cashFlow.availableBalance() == twd(10_000))
        try expect(netWorth.netWorth == twd(30_000))
    }

    func testFirstQuoteFailureUsesRecordedCost() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(20_000))
        let broker = Account(name: "券商", type: .stock)
        let asset = InvestmentAsset(accountID: broker.id, symbol: "NOQUOTE", name: "No Quote Yet", market: .taiwan)
        var state = LedgerState(accounts: [bank, broker], assets: [asset])
        let date = try LocalDate(iso8601: "2026-09-01")

        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(20_000), assetID: asset.id, quantity: 1), to: &state)

        let netWorth = try NetWorthCalculator.calculate(in: state)
        try expect(netWorth.netWorth == twd(20_000))
        try expect(netWorth.stockValue == twd(20_000))
        try expect(netWorth.warnings.contains { $0.contains("暫以已記錄成本") })
    }

    func testTransfer() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(5_000))
        let cash = Account(name: "現金", type: .cash)
        var state = LedgerState(accounts: [bank, cash])
        try LedgerMutationService.add(TransactionDraft(kind: .transfer, occurredOn: try LocalDate(iso8601: "2026-09-01"), accountID: bank.id, counterpartyAccountID: cash.id, amount: twd(5_000)), to: &state)
        let balances = try AccountBalanceCalculator.balances(in: state)
        let flow = try CashFlowCalculator.summary(for: MonthKey(year: 2026, month: 9), in: state)
        let netWorth = try NetWorthCalculator.calculate(in: state)
        try expect(balances[bank.id] == twd(0))
        try expect(balances[cash.id] == twd(5_000))
        try expect(netWorth.totalAssets == twd(5_000))
        try expect(flow.ordinaryIncome == twd(0))
        try expect(flow.livingExpenses == twd(0))
    }

    func testVideoMetadataAndAnnualBudgetBackupRoundTrip() throws {
        let account = Account(name: "測試帳戶", type: .bank)
        let category = Category(name: "餐飲", kind: .expense)
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(accounts: [account], categories: [category])
        let draft = TransactionDraft(kind: .expense, occurredOn: date, accountID: account.id, amount: twd(100), categoryID: category.id, member: "自己", tags: ["午餐"], receiptImages: [Data([1, 2, 3])])
        try LedgerMutationService.add(draft, to: &state)
        state.budgets = [Budget(categoryID: category.id, month: date.monthKey, limit: twd(12000), isAnnual: true)]
        let restored = try LedgerBackupCodec.restore(LedgerBackupCodec.export(state))
        XCTAssertEqual(restored.transactions.first?.draft, draft)
        XCTAssertEqual(restored.budgets.first?.isAnnual, true)
        let overview = try BudgetService.overview(budgets: restored.budgets, spending: [category.id: twd(2000)], currency: "TWD", remainingDays: 10)
        XCTAssertEqual(overview.remaining, twd(10000))
        XCTAssertEqual(overview.perDay, twd(1000))
        let breakdown = try CashFlowCalculator.spendingBreakdown(in: LedgerDateRange(singleDay: date), state: restored, byMember: true)
        XCTAssertEqual(breakdown["自己"], twd(100))
    }

    func testLegacyBudgetAndTransactionDecodeWithoutVideoFields() throws {
        let account = Account(name: "測試帳戶", type: .bank)
        let category = Category(name: "餐飲", kind: .expense)
        let date = try LocalDate(iso8601: "2026-09-01")
        let state = LedgerState(schemaVersion: 3, accounts: [account], categories: [category], transactions: [LedgerTransaction(draft: TransactionDraft(kind: .expense, occurredOn: date, accountID: account.id, amount: twd(100), categoryID: category.id))], budgets: [Budget(categoryID: category.id, month: date.monthKey, limit: twd(1000))])
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: LedgerBackupCodec.export(state)) as? [String: Any])
        payload["schemaVersion"] = 3
        let restored = try LedgerBackupCodec.restore(JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(restored.transactions.first?.draft.member)
        XCTAssertNil(restored.transactions.first?.draft.receiptImages)
        XCTAssertNil(restored.budgets.first?.isAnnual)
        XCTAssertEqual(restored.schemaVersion, 4)
    }

    func testTransferFeeIsChargedToSourceAndCashFlow() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(1_100))
        let cash = Account(name: "現金", type: .cash)
        var state = LedgerState(accounts: [bank, cash])
        try LedgerMutationService.add(TransactionDraft(kind: .transfer, occurredOn: try LocalDate(iso8601: "2026-09-01"), accountID: bank.id, counterpartyAccountID: cash.id, amount: twd(1_000), fee: twd(100)), to: &state)
        let balances = try AccountBalanceCalculator.balances(in: state)
        let flow = try CashFlowCalculator.summary(for: MonthKey(year: 2026, month: 9), in: state)
        try expect(balances[bank.id] == twd(0))
        try expect(balances[cash.id] == twd(1_000))
        try expect(flow.livingExpenses == twd(100))
    }

    func testDuplicateAccountIDsAreRejected() throws {
        let sharedID = UUID()
        let first = Account(id: sharedID, name: "銀行 A", type: .bank)
        let second = Account(id: sharedID, name: "銀行 B", type: .bank)
        let state = LedgerState(accounts: [first, second])

        do {
            _ = try AccountBalanceCalculator.balances(in: state)
            failTest("Duplicate account IDs should be rejected")
        } catch let error as LedgerError {
            try expect(error == .duplicateEntityID)
        }
        do {
            try LedgerMutationService.validateIntegrity(state)
            failTest("A duplicate account ID must not pass restore validation")
        } catch let error as LedgerError {
            try expect(error == .duplicateEntityID)
        }
    }

    func testOpeningBalanceCurrencyMismatchIsRejected() throws {
        let account = Account(name: "台幣帳戶", type: .bank, currencyCode: "TWD", openingBalance: .usdCents(100))

        do {
            try LedgerMutationService.validateIntegrity(LedgerState(accounts: [account]))
            failTest("An account opening balance must use the account currency")
        } catch let error as LedgerError {
            try expect(error == .currencyMismatch)
        }
    }

    func testUnconvertedDailyCashFlowIsRejected() throws {
        let usdBank = Account(name: "USD Bank", type: .bank, currencyCode: "USD")
        let salary = incomeCategory()
        let state = LedgerState(accounts: [usdBank], categories: [salary])
        do {
            try LedgerService.validate(TransactionDraft(kind: .income, occurredOn: try LocalDate(iso8601: "2026-09-01"), accountID: usdBank.id, amount: .usdCents(100), categoryID: salary.id), in: state)
            failTest("Unconverted daily cash flow should have been rejected")
        } catch let error as LedgerError {
            try expect(error == .currencyMismatch)
        }
    }

    func testCreditCard() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(2_000))
        let card = Account(name: "信用卡", type: .creditCard, creditCard: CreditCardMetadata(statementDay: 15))
        let category = expenseCategory()
        var state = LedgerState(accounts: [bank, card], categories: [category])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .creditCardCharge, occurredOn: date, accountID: card.id, amount: twd(1_000), categoryID: category.id), to: &state)
        let chargedBalances = try AccountBalanceCalculator.balances(in: state)
        let chargedFlow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        try expect(chargedBalances[card.id] == twd(-1_000))
        try expect(chargedFlow.livingExpenses == twd(1_000))
        try expect(try CreditCardService.currentStatementTotal(for: card, asOf: date, in: state) == twd(1_000))
        try LedgerMutationService.add(TransactionDraft(kind: .creditCardPayment, occurredOn: date, accountID: bank.id, counterpartyAccountID: card.id, amount: twd(1_000)), to: &state)
        let balances = try AccountBalanceCalculator.balances(in: state)
        let flow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        try expect(balances[card.id] == twd(0))
        try expect(flow.livingExpenses == twd(1_000))
        do {
            _ = try LedgerMutationService.add(TransactionDraft(kind: .creditCardPayment, occurredOn: date, accountID: bank.id, counterpartyAccountID: card.id, amount: twd(1)), to: &state)
            failTest("Overpaying a liability should have been rejected")
        } catch let error as LedgerError {
            try expect(error == .invalidLiabilityBalance)
        }
    }

    func testLoanPayment() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(20_000))
        let loan = Account(name: "房貸", type: .loan, openingBalance: twd(-100_000), loan: LoanMetadata(lenderName: "Test Bank"))
        let category = expenseCategory()
        var state = LedgerState(accounts: [bank, loan], categories: [category])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .loanPayment, occurredOn: date, accountID: bank.id, counterpartyAccountID: loan.id, amount: twd(10_000), categoryID: category.id, principal: twd(8_000), interest: twd(2_000)), to: &state)
        let balances = try AccountBalanceCalculator.balances(in: state)
        let flow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        try expect(balances[loan.id] == twd(-92_000))
        try expect(flow.livingExpenses == twd(2_000))
        let categories = try CashFlowCalculator.expensesByCategory(for: date.monthKey, in: state)
        try expect(categories[category.id] == twd(2_000))
        try expect(try BudgetService.notice(categoryName: category.name, spent: categories[category.id] ?? twd(0), limit: twd(2_500)) != nil)
    }

    func testCreditCardStatementRange() throws {
        let card = Account(name: "信用卡", type: .creditCard, creditCard: CreditCardMetadata(statementDay: 15))
        let asOf = try LocalDate(iso8601: "2026-09-20")
        let range = try CreditCardService.currentStatementRange(for: card, asOf: asOf)
        try expect(range.start == (try LocalDate(iso8601: "2026-09-15")))
        try expect(range.end == asOf)
    }

    func testInvestmentSale() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "美股券商", type: .stock, currencyCode: "USD")
        let asset = InvestmentAsset(accountID: broker.id, symbol: "SELL", name: "Synthetic", market: .unitedStates, currencyCode: "USD")
        var state = LedgerState(accounts: [bank, broker], assets: [asset])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(100_000), assetID: asset.id, quantity: 1), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(130_000), assetID: asset.id, quantity: 1, costBasis: twd(100_000)), to: &state)
        let flow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        let balances = try AccountBalanceCalculator.balances(in: state)
        try expect(flow.ordinaryIncome == twd(0))
        try expect(flow.realizedInvestmentGains == twd(30_000))
        try expect(balances[bank.id] == twd(30_000))
    }

    func testPartialInvestmentSale() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let asset = InvestmentAsset(accountID: broker.id, symbol: "PART", name: "Partial Sale", market: .taiwan)
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(accounts: [bank, broker], assets: [asset])

        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(100), assetID: asset.id, quantity: 3), to: &state, now: Date(timeIntervalSince1970: 1))
        let firstSale = try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(60), assetID: asset.id, quantity: 1), to: &state, now: Date(timeIntervalSince1970: 2))
        try expect(firstSale.draft.costBasis == twd(33))
        let partialPosition = try require(InvestmentCalculator.positions(in: state)[asset.id])
        try expect(partialPosition.quantity == 2)
        try expect(partialPosition.totalCost == twd(67))

        let finalSale = try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(80), assetID: asset.id, quantity: 2), to: &state, now: Date(timeIntervalSince1970: 3))
        try expect(finalSale.draft.costBasis == twd(67))
    }

    func testUnrealizedGain() throws {
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(100_000))
        let broker = Account(name: "券商", type: .stock)
        let asset = InvestmentAsset(accountID: broker.id, symbol: "GAIN", name: "Synthetic", market: .taiwan)
        var state = LedgerState(accounts: [bank, broker], assets: [asset], quotes: [PriceQuote(assetID: asset.id, price: Decimal(130_000), currencyCode: "TWD", source: "test")])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(100_000), assetID: asset.id, quantity: 1), to: &state)
        let netWorth = try NetWorthCalculator.calculate(in: state)
        let flow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        try expect(netWorth.netWorth == twd(130_000))
        try expect(try flow.availableBalance() == twd(-100_000))
        try expect(flow.ordinaryIncome == twd(0))
    }

    func testInvestmentIntegrity() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let asset = InvestmentAsset(accountID: broker.id, symbol: "SAFE", name: "Synthetic", market: .taiwan)
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(accounts: [bank, broker], assets: [asset])
        let buy = try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(100), assetID: asset.id, quantity: 1), to: &state)
        do {
            _ = try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(200), assetID: asset.id, quantity: 2, costBasis: twd(100)), to: &state)
            failTest("Oversell should have been rejected")
        } catch let error as LedgerError {
            try expect(error == .invalidQuantity)
        }
        try expect(state.transactions.count == 1)
        do {
            _ = try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(130), assetID: asset.id, quantity: 1, costBasis: twd(99)), to: &state)
            failTest("An inconsistent cost basis should have been rejected")
        } catch let error as LedgerError {
            try expect(error == .invalidCostBasis)
        }
        let sale = try LedgerMutationService.add(TransactionDraft(kind: .investmentSell, occurredOn: date, accountID: broker.id, counterpartyAccountID: bank.id, amount: twd(130), assetID: asset.id, quantity: 1), to: &state)
        try expect(sale.draft.costBasis == twd(100))
        do {
            try LedgerMutationService.softDelete(buy.id, in: &state)
            failTest("Deleting the supporting buy should have been rejected")
        } catch let error as LedgerError {
            try expect(error == .invalidQuantity)
        }
        try expect(state.transactions.filter { $0.deletedAt == nil }.count == 2)
    }

    func testDividend() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let category = FinanceCore.Category(name: "投資收益", kind: .investmentIncome)
        var state = LedgerState(accounts: [bank, broker], categories: [category])
        let date = try LocalDate(iso8601: "2026-09-01")
        try LedgerMutationService.add(TransactionDraft(kind: .dividend, occurredOn: date, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(5_000), categoryID: category.id), to: &state)
        let flow = try CashFlowCalculator.summary(for: date.monthKey, in: state)
        let netWorth = try NetWorthCalculator.calculate(in: state)
        try expect(flow.dividendIncome == twd(5_000))
        try expect(try flow.availableBalance() == twd(0))
        try expect(netWorth.netWorth == twd(5_000))
    }

    func testDividendRejectsOrphanedAssetReference() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let otherBroker = Account(name: "另一券商", type: .stock)
        let asset = InvestmentAsset(accountID: otherBroker.id, symbol: "OTHER", name: "Synthetic", market: .taiwan)
        let state = LedgerState(accounts: [bank, broker, otherBroker], assets: [asset])
        let draft = TransactionDraft(kind: .dividend, occurredOn: try LocalDate(iso8601: "2026-09-01"), accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(1), assetID: asset.id)
        XCTAssertThrowsError(try LedgerService.validate(draft, in: state)) { error in
            XCTAssertEqual(error as? LedgerError, .missingAsset)
        }
    }

    func testNetWorthGrowth() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let income = incomeCategory()
        let expense = expenseCategory()
        let asset = InvestmentAsset(accountID: broker.id, symbol: "GROW", name: "Synthetic", market: .taiwan)
        let startDate = try LocalDate(iso8601: "2026-09-01")
        let endDate = try LocalDate(iso8601: "2026-09-02")
        var state = LedgerState(accounts: [bank, broker], categories: [income, expense], assets: [asset])
        try LedgerMutationService.add(TransactionDraft(kind: .income, occurredOn: endDate, accountID: bank.id, amount: twd(50), categoryID: income.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: endDate, accountID: bank.id, amount: twd(20), categoryID: expense.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: endDate, accountID: bank.id, counterpartyAccountID: broker.id, amount: twd(20), assetID: asset.id, quantity: 1), to: &state)
        let start = NetWorthSnapshot(date: startDate, totalAssets: twd(0), totalLiabilities: twd(0), netWorth: twd(0), cashValue: twd(0), stockValue: twd(0), cryptoValue: twd(0), otherAssetValue: twd(0), liabilityValue: twd(0))
        let end = NetWorthSnapshot(date: endDate, totalAssets: twd(35), totalLiabilities: twd(0), netWorth: twd(35), cashValue: twd(10), stockValue: twd(25), cryptoValue: twd(0), otherAssetValue: twd(0), liabilityValue: twd(0))
        let sources = try NetWorthGrowthService.explain(from: start, to: end, over: LedgerDateRange(start: startDate, end: endDate), in: state)
        try expect(sources.dailyCashFlowContribution == twd(30))
        try expect(sources.investmentReturn == twd(5))
        try expect(sources.unclassifiedChange == twd(0))
    }

    func testBudgetStates() throws {
        try expect(try BudgetService.notice(categoryName: "餐飲", spent: twd(4_999), limit: twd(10_000)) == nil)
        try expect(try BudgetService.notice(categoryName: "餐飲", spent: twd(8_200), limit: twd(10_000)) == "新增本筆後，餐飲 預算已使用 82%。")
        try expect(try BudgetService.notice(categoryName: "餐飲", spent: twd(10_300), limit: twd(10_000)) == "新增本筆後，餐飲 預算已使用 103%，已超標。")
        try expect(try BudgetService.status(spent: twd(5_000), limit: twd(10_000)) == .warning50)
        try expect(try BudgetService.status(spent: twd(8_000), limit: twd(10_000)) == .warning80)
        try expect(try BudgetService.status(spent: twd(10_000), limit: twd(10_000)) == .atLimit)
        try expect(try BudgetService.status(spent: twd(11_000), limit: twd(10_000)) == .overLimit)
    }

    func testInvalidBudgetIsRejected() throws {
        let bank = Account(name: "銀行", type: .bank)
        let category = expenseCategory()
        let state = LedgerState(accounts: [bank], categories: [category], budgets: [Budget(categoryID: category.id, month: MonthKey(year: 2026, month: 9), limit: twd(0))])

        do {
            try LedgerMutationService.validateIntegrity(state)
            failTest("A zero budget must not be persisted")
        } catch let error as LedgerError {
            try expect(error == .invalidAmount)
        }
    }

    func testHistoricalDeletedCategoryRemainsValid() throws {
        let bank = Account(name: "銀行", type: .bank)
        var category = expenseCategory()
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(accounts: [bank], categories: [category])
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: date, accountID: bank.id, amount: twd(100), categoryID: category.id), to: &state)
        category.deletedAt = Date(timeIntervalSince1970: 1)
        state.categories = [category]

        try LedgerMutationService.validateIntegrity(state)
    }

    func testPurgeKeepsReferencedCategoryAndAuditHistory() throws {
        let bank = Account(name: "銀行", type: .bank)
        var category = expenseCategory()
        let transactionDate = try LocalDate(iso8601: "2026-01-01")
        let deletionDate = Date(timeIntervalSince1970: 1)
        let purgeDate = Date(timeIntervalSince1970: 60 * 60 * 24 * 31)
        var state = LedgerState(accounts: [bank], categories: [category])
        let active = try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: transactionDate, accountID: bank.id, amount: twd(100), categoryID: category.id), to: &state)
        let deleted = try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: transactionDate, accountID: bank.id, amount: twd(50), categoryID: category.id), to: &state)
        try LedgerMutationService.softDelete(deleted.id, in: &state, now: deletionDate)
        category.deletedAt = deletionDate
        state.categories = [category]

        LedgerMutationService.purgeDeleted(in: &state, now: purgeDate)

        try expect(state.transactions.map(\.id) == [active.id])
        try expect(state.transactions.first?.draft.amount == twd(100))
        try expect(state.categories.map(\.id) == [category.id])
        try expect(state.auditLogs.map(\.action) == [.create, .create, .softDelete])
        try LedgerMutationService.validateIntegrity(state)
    }

    func testPurgeUsesStrictThirtyDayBoundary() throws {
        let bank = Account(name: "銀行", type: .bank)
        let category = expenseCategory()
        let date = try LocalDate(iso8601: "2026-01-01")
        let deletedAt = Date(timeIntervalSince1970: 100)
        var state = LedgerState(accounts: [bank], categories: [category])
        let transaction = try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: date, accountID: bank.id, amount: twd(1), categoryID: category.id), to: &state)
        try LedgerMutationService.softDelete(transaction.id, in: &state, now: deletedAt)

        LedgerMutationService.purgeDeleted(in: &state, now: deletedAt.addingTimeInterval(30 * 24 * 60 * 60))
        XCTAssertEqual(state.transactions.count, 1)
        LedgerMutationService.purgeDeleted(in: &state, now: deletedAt.addingTimeInterval(31 * 24 * 60 * 60))
        XCTAssertTrue(state.transactions.isEmpty)
    }

    func testOrphanedInvestmentTransactionIsRejected() throws {
        let bank = Account(name: "銀行", type: .bank)
        let broker = Account(name: "券商", type: .stock)
        let draft = TransactionDraft(
            kind: .investmentBuy,
            occurredOn: try LocalDate(iso8601: "2026-09-01"),
            accountID: bank.id,
            counterpartyAccountID: broker.id,
            amount: twd(100),
            assetID: UUID(),
            quantity: 1
        )
        let state = LedgerState(accounts: [bank, broker], transactions: [LedgerTransaction(draft: draft)])

        do {
            try LedgerMutationService.validateIntegrity(state)
            failTest("An imported investment transaction must reference an existing asset")
        } catch let error as LedgerError {
            try expect(error == .missingAsset)
        }
    }

    func testAnomaly() throws {
        let result = try AnomalyDetectionService.detect(currentProgressSpend: twd(13_001), priorProgressSpends: Array(repeating: twd(10_000), count: 6))
        try expect(result.isAnomalous)
        try expect(result.historicalAverage == twd(10_000))
    }

    func testSameProgressInsight() throws {
        let bank = Account(name: "銀行", type: .bank)
        let category = expenseCategory()
        let currentDate = try LocalDate(iso8601: "2026-09-10")
        var state = LedgerState(accounts: [bank], categories: [category])
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: currentDate, accountID: bank.id, amount: twd(13_001), categoryID: category.id), to: &state)
        for month in 3 ... 8 {
            try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: try LocalDate(year: 2026, month: month, day: 10), accountID: bank.id, amount: twd(10_000), categoryID: category.id), to: &state)
        }
        let insight = try SpendingInsightService.insight(categoryID: category.id, asOf: currentDate, in: state)
        try expect(insight.anomaly.isAnomalous)
        try expect(insight.anomaly.historicalAverage == twd(10_000))
        try expect(insight.forecast.confidence == .high)
    }

    func testCategoryHistoryAverage() throws {
        let bank = Account(name: "銀行", type: .bank)
        let category = expenseCategory()
        var state = LedgerState(accounts: [bank], categories: [category])
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: try LocalDate(iso8601: "2026-01-10"), accountID: bank.id, amount: twd(100), categoryID: category.id), to: &state)
        try LedgerMutationService.add(TransactionDraft(kind: .expense, occurredOn: try LocalDate(iso8601: "2026-02-10"), accountID: bank.id, amount: twd(300), categoryID: category.id), to: &state)

        let average = try CategoryHistoryService.averageMonthlySpend(categoryID: category.id, before: MonthKey(year: 2026, month: 3), months: 2, in: state)
        try expect(average == twd(200))
    }

    func testForecastZeroProgressHistory() throws {
        let forecast = try ForecastService.forecast(
            currentSpend: twd(1_000),
            elapsedDays: 10,
            daysInMonth: 30,
            historicalProgressFractions: [0, Decimal(3) / 10, Decimal(3) / 10]
        )
        try expect(forecast.projectedMonthEnd == twd(5_000))
        try expect(forecast.confidence == .medium)
    }

    func testQuoteFailureRetainsPrice() async throws {
        let account = Account(name: "Crypto", type: .crypto)
        let asset = InvestmentAsset(accountID: account.id, symbol: "BTC", name: "Bitcoin", market: .crypto, currencyCode: "USD")
        let quote = PriceQuote(assetID: asset.id, price: Decimal(100), currencyCode: "USD", source: "test")
        let result = await QuoteRefreshService.refresh(asset: asset, provider: FailingQuoteProvider(), existingQuote: quote)
        try expect(result == .retainedStale(PriceQuote(id: quote.id, assetID: asset.id, price: Decimal(100), currencyCode: "USD", timestamp: quote.timestamp, source: "test", isStale: true)))
        if case let .retainedStale(retained?) = result {
            try expect(retained.price == Decimal(100))
            try expect(retained.isStale)
        } else {
            failTest("Expected retained stale quote")
        }
    }

    func testCryptoQuotePrecision() throws {
        let bank = Account(name: "USD Bank", type: .bank, currencyCode: "USD")
        let wallet = Account(name: "Crypto", type: .crypto, currencyCode: "USD")
        let asset = InvestmentAsset(accountID: wallet.id, symbol: "MICRO", name: "Micro Coin", market: .crypto, currencyCode: "USD")
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(baseCurrencyCode: "USD", accounts: [bank, wallet], assets: [asset], quotes: [PriceQuote(assetID: asset.id, price: Decimal(1234) / 100_000_000, currencyCode: "USD", source: "test")])
        try LedgerMutationService.add(TransactionDraft(kind: .investmentBuy, occurredOn: date, accountID: bank.id, counterpartyAccountID: wallet.id, amount: .usdCents(1_000), assetID: asset.id, quantity: Decimal(1_000_000)), to: &state)
        let position = try require(InvestmentCalculator.positions(in: state)[asset.id])
        let valuation = InvestmentCalculator.valuation(for: asset, position: position, quotes: state.quotes)
        try expect(valuation.marketValue == .usdCents(1_234))
    }

    func testRecurringIdempotency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceDashboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger-backup.json"))
        let bank = Account(name: "銀行", type: .bank)
        let salary = incomeCategory()
        let date = try LocalDate(iso8601: "2026-09-05")
        let template = TransactionDraft(kind: .income, occurredOn: date, accountID: bank.id, amount: twd(50_000), categoryID: salary.id)
        let recurring = RecurringTransaction(dayOfMonth: 5, template: template)
        var state = LedgerState(accounts: [bank], categories: [salary], recurringTransactions: [recurring])
        try expect(try RecurringTransactionService.materializeDue(on: date, in: &state).count == 1)
        try expect(try RecurringTransactionService.materializeDue(on: date, in: &state).isEmpty)
        try expect(state.transactions.count == 1)
        try expect(state.occurrences.count == 1)
        try await repository.save(state)
        var reloaded = try await repository.load()
        try expect(try RecurringTransactionService.materializeDue(on: date, in: &reloaded).isEmpty)
        try expect(reloaded.transactions.count == 1)
        try RecurringTransactionService.reverseOccurrence(recurrenceID: recurring.id, on: date, in: &reloaded)
        try expect(reloaded.occurrences.first?.status == .reversed)
        try expect(reloaded.transactions.first?.deletedAt != nil)
        try expect(reloaded.auditLogs.map(\.action) == [.create, .softDelete])
    }

    func testRecurringCatchUp() throws {
        let bank = Account(name: "銀行", type: .bank)
        let salary = incomeCategory()
        let template = TransactionDraft(kind: .income, occurredOn: try LocalDate(iso8601: "2026-09-05"), accountID: bank.id, amount: twd(50_000), categoryID: salary.id)
        let recurring = RecurringTransaction(dayOfMonth: 5, template: template)
        var state = LedgerState(accounts: [bank], categories: [salary], recurringTransactions: [recurring])
        try expect(try RecurringTransactionService.materializeDue(on: try LocalDate(iso8601: "2026-09-06"), in: &state).count == 1)
        let scheduledDate = try LocalDate(iso8601: "2026-09-05")
        try expect(state.transactions.first?.draft.occurredOn == scheduledDate)
    }

    func testRecurringCatchUpMaterializesMissedMonths() throws {
        let bank = Account(name: "銀行", type: .bank)
        let salary = incomeCategory()
        let templateDate = try LocalDate(iso8601: "2026-08-05")
        let template = TransactionDraft(kind: .income, occurredOn: templateDate, accountID: bank.id, amount: twd(50_000), categoryID: salary.id)
        let recurring = RecurringTransaction(dayOfMonth: 5, template: template, createdAt: templateDate.date(in: .gmt))
        var state = LedgerState(accounts: [bank], categories: [salary], recurringTransactions: [recurring])
        let generated = try RecurringTransactionService.materializeDue(on: try LocalDate(iso8601: "2026-09-06"), in: &state)
        XCTAssertEqual(generated.map { $0.draft.occurredOn.iso8601 }, ["2026-08-05", "2026-09-05"])
    }

    func testCalculator() throws {
        var calculator = AmountCalculator()
        for character in "120" { calculator.input(character) }
        try calculator.apply(.add)
        for character in "35" { calculator.input(character) }
        try calculator.apply(.add)
        for character in "80" { calculator.input(character) }
        try expect(try calculator.equals() == Decimal(235))
        calculator.clear()
        for character in "480" { calculator.input(character) }
        try calculator.apply(.multiply)
        calculator.input("3")
        try expect(try calculator.equals() == Decimal(1440))
    }

    func testPersistenceLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceDashboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger-backup.json"))
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(1_234))
        let category = incomeCategory()
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(schemaVersion: 0, accounts: [bank], categories: [category])
        let transaction = try LedgerMutationService.add(TransactionDraft(kind: .income, occurredOn: date, accountID: bank.id, amount: twd(10), categoryID: category.id), to: &state)
        try LedgerMutationService.softDelete(transaction.id, in: &state)
        try expect(state.transactions.first?.deletedAt != nil)
        try expect(state.auditLogs.count == 2)
        try SnapshotService.upsert(for: date, in: &state)
        try SnapshotService.upsert(for: date, in: &state)
        try expect(state.snapshots.count == 1)
        let migrated = try LedgerMigration.migrate(state, from: 0)
        try expect(migrated.transactions.count == 1)
        try expect(migrated.migrationWarnings.count == 1)
        let netWorthBeforeReload = try NetWorthCalculator.calculate(in: migrated).netWorth
        try await repository.save(migrated)
        let restored = try await repository.load()
        try expect(restored.accounts.count == 1)
        try expect(restored.accounts.first?.openingBalance == twd(1_234))
        try expect(restored.transactions.count == 1)
        try expect(restored.transactions.first?.draft.amount == twd(10))
        try expect(restored.transactions.first?.deletedAt != nil)
        try expect(restored.auditLogs.count == 2)
        try expect(try NetWorthCalculator.calculate(in: restored).netWorth == netWorthBeforeReload)
    }

    func testLegacyMigrationDefaults() throws {
        let bank = Account(name: "銀行", type: .bank)
        let original = LedgerState(schemaVersion: 1, accounts: [bank])
        let exported = try LedgerBackupCodec.export(original)
        var root = try require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        root["schemaVersion"] = 1
        var stateJSON = try require(root["state"] as? [String: Any])
        stateJSON.removeValue(forKey: "settings")
        root["state"] = stateJSON
        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let migrated = try LedgerBackupCodec.restore(legacyData)
        try expect(migrated.accounts.count == 1)
        try expect(!migrated.settings.hideAmounts)
        try expect(migrated.schemaVersion == LedgerState.currentSchemaVersion)
        try expect(!migrated.migrationWarnings.isEmpty)
    }

    func testPartialLegacySettingsMigration() throws {
        let bank = Account(name: "銀行", type: .bank)
        let original = LedgerState(
            schemaVersion: 2,
            accounts: [bank],
            settings: LedgerSettings(hideAmounts: true, syncProviderIdentifier: "offline-only")
        )
        var root = try require(JSONSerialization.jsonObject(with: LedgerBackupCodec.export(original)) as? [String: Any])
        root["schemaVersion"] = 2
        var stateJSON = try require(root["state"] as? [String: Any])
        var settingsJSON = try require(stateJSON["settings"] as? [String: Any])
        settingsJSON.removeValue(forKey: "syncProviderIdentifier")
        stateJSON["settings"] = settingsJSON
        root["state"] = stateJSON

        let migrated = try LedgerBackupCodec.restore(JSONSerialization.data(withJSONObject: root))
        try expect(migrated.accounts.map(\.id) == [bank.id])
        try expect(migrated.settings.hideAmounts)
        try expect(migrated.settings.syncProviderIdentifier == "offline-only")
        try expect(!migrated.migrationWarnings.isEmpty)
    }

    func testLegacyQuoteMigration() throws {
        let account = Account(name: "券商", type: .stock)
        let asset = InvestmentAsset(accountID: account.id, symbol: "MIGRATE", name: "Legacy Quote", market: .taiwan)
        let quote = PriceQuote(assetID: asset.id, price: Decimal(12345) / 100, currencyCode: "USD", source: "legacy")
        let state = LedgerState(schemaVersion: 2, accounts: [account], assets: [asset], quotes: [quote])
        var root = try require(JSONSerialization.jsonObject(with: LedgerBackupCodec.export(state)) as? [String: Any])
        root["schemaVersion"] = 2
        var stateJSON = try require(root["state"] as? [String: Any])
        var quotes = try require(stateJSON["quotes"] as? [[String: Any]])
        quotes[0]["price"] = ["minorUnits": 12_345, "currencyCode": "USD"]
        quotes[0].removeValue(forKey: "currencyCode")
        stateJSON["quotes"] = quotes
        root["state"] = stateJSON
        let migrated = try LedgerBackupCodec.restore(JSONSerialization.data(withJSONObject: root))
        try expect(migrated.quotes.first?.price == Decimal(12345) / 100)
        try expect(migrated.quotes.first?.currencyCode == "USD")
        try expect(!migrated.migrationWarnings.isEmpty)
    }

    func testRecoveryCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceDashboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger-backup.json"))
        let bank = Account(name: "銀行", type: .bank, openingBalance: twd(42))
        let state = LedgerState(accounts: [bank])
        let checkpoint = try await repository.createRecoveryCheckpoint(from: state)
        let checkpoints = try await repository.recoveryCheckpoints()
        try expect(checkpoints.contains(where: { $0.id == checkpoint.id }))
        let restored = try LedgerBackupCodec.restore(try await repository.recoveryData(for: checkpoint))
        try expect(restored.accounts.count == 1)
        try expect(restored.accounts.first?.openingBalance == twd(42))
    }

    func testRecoveryCheckpointsPreserveMultipleStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceDashboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger-backup.json"))
        let first = LedgerState(accounts: [Account(name: "第一版", type: .cash, openingBalance: twd(1))])
        let second = LedgerState(accounts: [Account(name: "第二版", type: .cash, openingBalance: twd(2))])
        let firstCheckpoint = try await repository.createRecoveryCheckpoint(from: first, now: Date(timeIntervalSince1970: 10))
        let secondCheckpoint = try await repository.createRecoveryCheckpoint(from: second, now: Date(timeIntervalSince1970: 20))
        let checkpoints = try await repository.recoveryCheckpoints()
        XCTAssertEqual(checkpoints.map(\.id), [secondCheckpoint.id, firstCheckpoint.id])
        let restoredFirst = try LedgerBackupCodec.restore(try await repository.recoveryData(for: firstCheckpoint))
        let restoredSecond = try LedgerBackupCodec.restore(try await repository.recoveryData(for: secondCheckpoint))
        XCTAssertEqual(restoredFirst.accounts.first?.openingBalance, twd(1))
        XCTAssertEqual(restoredSecond.accounts.first?.openingBalance, twd(2))
    }

    func testFullBackupRoundTripRetainsAllCollections() throws {
        let account = Account(name: "銀行", type: .bank)
        let investmentAccount = Account(name: "券商", type: .stock)
        let category = expenseCategory()
        let date = try LocalDate(iso8601: "2026-09-01")
        let asset = InvestmentAsset(accountID: investmentAccount.id, symbol: "TEST", name: "測試資產", market: .taiwan)
        let draft = TransactionDraft(kind: .expense, occurredOn: date, accountID: account.id, amount: twd(10), categoryID: category.id)
        var transaction = LedgerTransaction(draft: draft)
        transaction.deletedAt = Date(timeIntervalSince1970: 123)
        let recurring = RecurringTransaction(dayOfMonth: 5, template: draft)
        let occurrence = RecurringOccurrence(recurrenceID: recurring.id, date: date, transactionID: transaction.id, status: .created)
        let snapshot = NetWorthSnapshot(date: date, totalAssets: twd(1), totalLiabilities: twd(0), netWorth: twd(1), cashValue: twd(1), stockValue: twd(0), cryptoValue: twd(0), otherAssetValue: twd(0), liabilityValue: twd(0))
        let audit = AuditLog(entityID: transaction.id, entityType: "LedgerTransaction", action: .create)
        let state = LedgerState(
            accounts: [account, investmentAccount], categories: [category], transactions: [transaction],
            assets: [asset], quotes: [PriceQuote(assetID: asset.id, price: 1, currencyCode: "TWD", source: "test")],
            budgets: [Budget(categoryID: category.id, month: date.monthKey, limit: twd(100))],
            recurringTransactions: [recurring], occurrences: [occurrence], snapshots: [snapshot], auditLogs: [audit],
            settings: LedgerSettings(hideAmounts: true, syncProviderIdentifier: "offline-only")
        )
        let restored = try LedgerBackupCodec.restore(try LedgerBackupCodec.export(state))
        XCTAssertEqual(restored.accounts.count, 2)
        XCTAssertEqual(restored.categories.count, 1)
        XCTAssertEqual(restored.transactions.count, 1)
        XCTAssertEqual(restored.transactions.first?.deletedAt, transaction.deletedAt)
        XCTAssertEqual(restored.assets.count, 1)
        XCTAssertEqual(restored.quotes.count, 1)
        XCTAssertEqual(restored.budgets.count, 1)
        XCTAssertEqual(restored.recurringTransactions.count, 1)
        XCTAssertEqual(restored.occurrences.count, 1)
        XCTAssertEqual(restored.snapshots.count, 1)
        XCTAssertEqual(restored.auditLogs.count, 1)
        XCTAssertTrue(restored.settings.hideAmounts)
    }

    func testBackupRejectsMalformedData() {
        let malformed = Data("not-a-finance-backup".utf8)
        XCTAssertThrowsError(try LedgerBackupCodec.restore(malformed))
    }

    func testBackupRejectsFutureSchema() throws {
        let state = LedgerState(accounts: [Account(name: "銀行", type: .bank)])
        var root = try require(JSONSerialization.jsonObject(with: LedgerBackupCodec.export(state)) as? [String: Any])
        root["schemaVersion"] = LedgerState.currentSchemaVersion + 1
        XCTAssertThrowsError(try LedgerBackupCodec.restore(JSONSerialization.data(withJSONObject: root)))
    }

    func testCSVExportEscapesNotesAndOmitsDeletedTransactions() throws {
        let account = Account(name: "銀行", type: .bank)
        let category = expenseCategory()
        let date = try LocalDate(iso8601: "2026-09-01")
        var state = LedgerState(accounts: [account], categories: [category])
        let active = try LedgerMutationService.add(
            TransactionDraft(kind: .expense, occurredOn: date, accountID: account.id, amount: twd(10), categoryID: category.id, description: "午餐, \"燒肉\""),
            to: &state
        )
        var deleted = active
        deleted.id = UUID()
        deleted.deletedAt = Date()
        let csv = LedgerBackupCodec.csvExport(transactions: [active, deleted])
        XCTAssertTrue(csv.contains("\"午餐, \"\"燒肉\"\"\""))
        XCTAssertEqual(csv.components(separatedBy: "\n").count, 2)
    }
}
