import Foundation
import SwiftUI

func moneyInput(_ text: String, currencyCode: String) throws -> Money {
    guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        throw CalculatorError.invalidExpression
    }
    return try Money.from(decimal: decimal, currencyCode: currencyCode, fractionDigits: CurrencyScale.fractionDigits(for: currencyCode))
}

func localDate(_ date: Date) -> LocalDate {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day,
          let result = try? LocalDate(year: year, month: month, day: day)
    else { return .today() }
    return result
}

func localDateRange(start: Date, end: Date) -> LedgerDateRange {
    (try? LedgerDateRange(start: localDate(start), end: localDate(end))) ?? LedgerDateRange(singleDay: LocalDate.today())
}

struct AddInvestmentAssetView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var symbol = ""
    @State private var name = ""
    @State private var market: InvestmentMarket
    @State private var currencyCode: String

    init(account: Account) {
        self.account = account
        _market = State(initialValue: account.type == .crypto ? .crypto : .taiwan)
        _currencyCode = State(initialValue: account.type == .crypto ? "USD" : account.currencyCode)
    }

    var body: some View {
        Form {
            TextField("代號，例如 2330 / AAPL / BTC", text: $symbol)
                .textInputAutocapitalization(.characters)
            TextField("名稱", text: $name)
            if account.type == .stock {
                Picker("市場", selection: $market) {
                    Text("台股").tag(InvestmentMarket.taiwan)
                    Text("美股").tag(InvestmentMarket.unitedStates)
                }
            } else {
                LabeledContent("市場", value: "Crypto")
            }
            if account.type == .crypto {
                LabeledContent("報價幣別", value: "USD（Binance 公開 USDT 市場）")
            } else {
                TextField("報價幣別", text: $currencyCode)
                    .textInputAutocapitalization(.characters)
            }
        }
        .navigationTitle("新增資產")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    Task {
                        await model.addInvestmentAsset(
                            accountID: account.id,
                            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            market: market,
                            currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                }
                .disabled(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private enum InvestmentAction: String, CaseIterable, Identifiable {
    case buy = "買入"
    case sell = "賣出"
    case dividend = "股息"
    var id: Self { self }
}

struct InvestmentEntryView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var action: InvestmentAction = .buy
    @State private var assetID: UUID?
    @State private var cashAccountID: UUID?
    @State private var amount = ""
    @State private var quantity = ""
    @State private var selectedDate = Date()

    private var assets: [InvestmentAsset] {
        model.state.assets.filter { $0.accountID == account.id && $0.deletedAt == nil }
    }

    private var cashAccounts: [Account] {
        model.state.accounts.filter {
            $0.deletedAt == nil && !$0.type.isLiability && !$0.type.isInvestment && $0.currencyCode == model.state.baseCurrencyCode
        }
    }

    private var investmentIncomeCategory: Category? {
        model.state.categories.first { $0.deletedAt == nil && $0.kind == .investmentIncome }
    }

    var body: some View {
        Form {
            Picker("操作", selection: $action) {
                ForEach(InvestmentAction.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("資產", selection: $assetID) {
                Text("請選擇").tag(UUID?.none)
                ForEach(assets) { asset in Text(asset.symbol).tag(Optional(asset.id)) }
            }
            Picker(action == .buy ? "付款帳戶" : "收款帳戶", selection: $cashAccountID) {
                Text("請選擇").tag(UUID?.none)
                ForEach(cashAccounts) { cash in Text(cash.name).tag(Optional(cash.id)) }
            }
            TextField(action == .sell ? "賣出金額（\(model.state.baseCurrencyCode)）" : action == .dividend ? "股息金額（\(model.state.baseCurrencyCode)）" : "投入金額（\(model.state.baseCurrencyCode)）", text: $amount)
                .keyboardType(.decimalPad)
            if action != .dividend {
                TextField("數量", text: $quantity).keyboardType(.decimalPad)
            }
            if action == .sell { Text("成本會依目前平均成本自動計算。").font(.footnote).foregroundStyle(.secondary) }
            DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
        }
        .navigationTitle("投資交易")
        .onAppear {
            assetID = assets.first?.id
            cashAccountID = cashAccounts.first?.id
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { submit() }
                    .disabled(assetID == nil || cashAccountID == nil || amount.isEmpty || (action != .dividend && quantity.isEmpty))
            }
        }
    }

    private func submit() {
        guard let assetID, let cashAccountID else { return }
        do {
            let currency = model.state.baseCurrencyCode
            let transactionAmount = try moneyInput(amount, currencyCode: currency)
            let transactionDate = localDate(selectedDate)
            let assetQuantity = action == .dividend ? nil : Decimal(string: quantity, locale: Locale(identifier: "en_US_POSIX"))
            if action != .dividend {
                guard let assetQuantity, assetQuantity > 0 else { throw CalculatorError.invalidExpression }
            }
            let draft: TransactionDraft
            switch action {
            case .buy:
                draft = TransactionDraft(kind: .investmentBuy, occurredOn: transactionDate, accountID: cashAccountID, counterpartyAccountID: account.id, amount: transactionAmount, description: "投資買入", assetID: assetID, quantity: assetQuantity)
            case .sell:
                draft = TransactionDraft(kind: .investmentSell, occurredOn: transactionDate, accountID: account.id, counterpartyAccountID: cashAccountID, amount: transactionAmount, description: "投資賣出", assetID: assetID, quantity: assetQuantity)
            case .dividend:
                draft = TransactionDraft(kind: .dividend, occurredOn: transactionDate, accountID: cashAccountID, counterpartyAccountID: account.id, amount: transactionAmount, categoryID: investmentIncomeCategory?.id, description: "股息", assetID: assetID)
            }
            Task {
                await model.addTransaction(draft)
                dismiss()
            }
        } catch {
            model.errorMessage = "請確認投資交易的金額、數量與持倉。"
        }
    }
}

struct CreditCardPaymentView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let card: Account
    @State private var payerID: UUID?
    @State private var amount = ""
    @State private var selectedDate = Date()

    private var payers: [Account] {
        model.state.accounts.filter {
            $0.deletedAt == nil && !$0.type.isLiability && !$0.type.isInvestment && $0.currencyCode == card.currencyCode
        }
    }

    var body: some View {
        Form {
            Picker("付款帳戶", selection: $payerID) {
                Text("請選擇").tag(UUID?.none)
                ForEach(payers) { payer in Text(payer.name).tag(Optional(payer.id)) }
            }
            TextField("金額", text: $amount).keyboardType(.decimalPad)
            DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
        }
        .navigationTitle("繳信用卡")
        .onAppear { payerID = payers.first?.id }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { submit() }.disabled(payerID == nil || amount.isEmpty)
            }
        }
    }

    private func submit() {
        guard let payerID else { return }
        do {
            let draft = TransactionDraft(kind: .creditCardPayment, occurredOn: localDate(selectedDate), accountID: payerID, counterpartyAccountID: card.id, amount: try moneyInput(amount, currencyCode: card.currencyCode), description: "信用卡繳款")
            Task { await model.addTransaction(draft); dismiss() }
        } catch {
            model.errorMessage = "請輸入有效的繳款金額。"
        }
    }
}

struct LoanPaymentView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let loan: Account
    @State private var payerID: UUID?
    @State private var categoryID: UUID?
    @State private var principal = ""
    @State private var interest = ""
    @State private var selectedDate = Date()

    private var payers: [Account] {
        model.state.accounts.filter {
            $0.deletedAt == nil && !$0.type.isLiability && !$0.type.isInvestment && $0.currencyCode == loan.currencyCode
        }
    }

    private var expenseCategories: [Category] {
        model.state.categories.filter { $0.deletedAt == nil && $0.kind == .expense }
    }

    var body: some View {
        Form {
            Picker("付款帳戶", selection: $payerID) {
                Text("請選擇").tag(UUID?.none)
                ForEach(payers) { payer in Text(payer.name).tag(Optional(payer.id)) }
            }
            TextField("本金", text: $principal).keyboardType(.decimalPad)
            TextField("利息", text: $interest).keyboardType(.decimalPad)
            Picker("利息分類", selection: $categoryID) {
                Text("請選擇").tag(UUID?.none)
                ForEach(expenseCategories) { category in Text(category.name).tag(Optional(category.id)) }
            }
            DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
        }
        .navigationTitle("支付本息")
        .onAppear {
            payerID = payers.first?.id
            categoryID = expenseCategories.first?.id
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { submit() }.disabled(payerID == nil || principal.isEmpty || interest.isEmpty)
            }
        }
    }

    private func submit() {
        guard let payerID else { return }
        do {
            let principalMoney = try moneyInput(principal, currencyCode: loan.currencyCode)
            let interestMoney = try moneyInput(interest, currencyCode: loan.currencyCode)
            let total = try principalMoney.adding(interestMoney)
            let draft = TransactionDraft(kind: .loanPayment, occurredOn: localDate(selectedDate), accountID: payerID, counterpartyAccountID: loan.id, amount: total, categoryID: categoryID, description: "貸款本息", principal: principalMoney, interest: interestMoney)
            Task { await model.addTransaction(draft); dismiss() }
        } catch {
            model.errorMessage = "請輸入有效的本金與利息。"
        }
    }
}
