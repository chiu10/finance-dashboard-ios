import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var showsAddAccount = false

    var body: some View {
        NavigationStack {
            List {
                let balances = (try? AccountBalanceCalculator.balances(in: model.state)) ?? [:]
                ForEach(AccountType.allCases, id: \.self) { type in
                    let accounts = model.state.accounts.filter { $0.deletedAt == nil && $0.type == type }
                    if !accounts.isEmpty {
                        Section(title(for: type)) {
                            ForEach(accounts) { account in
                                NavigationLink { AccountDetailView(account: account) } label: {
                                    HStack {
                                        Text(account.name)
                                        Spacer()
                                        if !account.type.isInvestment, let balance = balances[account.id] {
                                            MoneyText(money: balance, hidden: model.hideAmounts)
                                        }
                                        Text(account.currencyCode).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("帳戶")
            .toolbar { Button("新增", systemImage: "plus") { showsAddAccount = true } }
            .sheet(isPresented: $showsAddAccount) { AddAccountView() }
        }
    }

    private func title(for type: AccountType) -> String { type.localizedName }
}

private struct AddAccountView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var currencyCode = "TWD"
    @State private var openingAmount = "0"
    @State private var statementDay = 1

    var body: some View {
        NavigationStack {
            Form {
                TextField("帳戶名稱", text: $name)
                Picker("類型", selection: $type) {
                    ForEach(AccountType.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                TextField("幣別（例如 TWD / USD）", text: $currencyCode)
                    .textInputAutocapitalization(.characters)
                if !type.isInvestment {
                    Text("日常帳戶目前必須使用 \(model.state.baseCurrencyCode)；未設定匯率前不會接受外幣生活收支。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField(type.isLiability ? "目前負債（以正數輸入）" : "期初餘額", text: $openingAmount)
                    .keyboardType(.decimalPad)
                if type == .creditCard {
                    Stepper("結帳日：每月 \(statementDay) 日", value: $statementDay, in: 1 ... 31)
                }
            }
            .navigationTitle("新增帳戶")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        guard let opening = Decimal(string: openingAmount, locale: Locale(identifier: "en_US_POSIX")), opening >= 0 else { return }
                        Task {
                            await model.addAccount(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                type: type,
                                currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines),
                                openingAmount: opening,
                                statementDay: statementDay
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct AccountDetailView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var showsDeleteConfirmation = false

    private var currentAccount: Account {
        model.state.accounts.first(where: { $0.id == account.id }) ?? account
    }

    var body: some View {
        List {
            Section("帳戶") {
                NavigationLink("帳戶交易明細") {
                    LedgerHistoryView(title: currentAccount.name, accountID: currentAccount.id)
                }
                NavigationLink("逐月結轉報表") { AccountMonthlyStatementsView(account: currentAccount) }
                let balances = (try? AccountBalanceCalculator.balances(in: model.state)) ?? [:]
                Toggle("計入淨資產", isOn: Binding(
                    get: { currentAccount.includeInNetWorth },
                    set: { included in Task { await model.setAccountIncludedInNetWorth(currentAccount.id, included: included) } }
                ))
                LabeledContent("類型", value: currentAccount.type.localizedName)
                LabeledContent("幣別", value: currentAccount.currencyCode)
                if let balance = balances[currentAccount.id], !currentAccount.type.isInvestment {
                    let displayedBalance = currentAccount.type.isLiability && balance.minorUnits < 0 ? (try? balance.negated()) ?? balance : balance
                    LabeledContent(currentAccount.type.isLiability ? "目前負債" : "目前餘額") { MoneyText(money: displayedBalance, hidden: model.hideAmounts) }
                }
            }
            if let accountFlow = accountFlowSummary {
                Section("期間收支") {
                    LabeledContent("本月流入") { MoneyText(money: accountFlow.month.inflow, hidden: model.hideAmounts) }
                    LabeledContent("本月流出") { MoneyText(money: accountFlow.month.outflow, hidden: model.hideAmounts) }
                    LabeledContent("本月淨流量") { MoneyText(money: accountFlow.month.net, hidden: model.hideAmounts) }
                    LabeledContent("今年淨流量") { MoneyText(money: accountFlow.year.net, hidden: model.hideAmounts) }
                    NavigationLink("查看本月明細") { LedgerHistoryView(range: accountFlow.month.range, title: "本月帳戶明細", accountID: currentAccount.id) }
                    NavigationLink("查看今年明細") { LedgerHistoryView(range: accountFlow.year.range, title: "今年帳戶明細", accountID: currentAccount.id) }
                }
            }
            if currentAccount.type.isInvestment {
                Section(currentAccount.type == .stock ? "持倉" : "Crypto 資產") {
                    let assets = model.state.assets.filter { $0.accountID == currentAccount.id && $0.deletedAt == nil }
                    let positions = (try? InvestmentCalculator.positions(in: model.state)) ?? [:]
                    if assets.isEmpty { Text("尚未建立持倉") }
                    ForEach(assets) { asset in
                        let position = positions[asset.id]
                        let valuation = position.map { InvestmentCalculator.valuation(for: asset, position: $0, quotes: model.state.quotes) }
                        let quote = model.state.quotes.filter { $0.assetID == asset.id }.max { $0.timestamp < $1.timestamp }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(asset.symbol) · \(asset.name)")
                            if model.hideAmounts {
                                Text("已隱藏持倉金額與數量").font(.caption).foregroundStyle(.secondary)
                            } else {
                                if let position { Text("數量 \(NSDecimalNumber(decimal: position.quantity).stringValue)").font(.caption).foregroundStyle(.secondary) }
                                if let quote {
                                    Text("最新價格 \(NSDecimalNumber(decimal: quote.price).stringValue) \(quote.currencyCode)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let value = valuation?.marketValue {
                                    MoneyText(money: value).font(.subheadline)
                                } else {
                                    Text("價格尚未更新").font(.caption).foregroundStyle(.orange)
                                }
                                if let cost = position?.totalCost {
                                    Text("持有成本 \(MoneyTextFormatter.string(for: cost))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let averageCost = valuation?.averageCost {
                                    Text("平均成本 \(MoneyTextFormatter.string(for: averageCost))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let unrealized = valuation?.unrealizedPnL {
                                    Text("未實現損益 \(MoneyTextFormatter.string(for: unrealized))")
                                        .font(.caption).foregroundStyle(unrealized.minorUnits >= 0 ? .green : .red)
                                }
                                if let realized = position?.realizedPnL, !realized.isZero {
                                    Text("已實現損益 \(MoneyTextFormatter.string(for: realized))")
                                        .font(.caption).foregroundStyle(realized.minorUnits >= 0 ? .green : .red)
                                }
                                if let dividend = position?.dividendIncome, !dividend.isZero {
                                    Text("股息 \(MoneyTextFormatter.string(for: dividend))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let totalReturn = valuation?.totalReturn {
                                    Text("總報酬 \(MoneyTextFormatter.string(for: totalReturn))\(valuation?.returnPercentage.map { "（\(NSDecimalNumber(decimal: $0).rounding(accordingToBehavior: nil).stringValue)%）" } ?? "")")
                                        .font(.caption).foregroundStyle(totalReturn.minorUnits >= 0 ? .green : .red)
                                }
                            }
                            if let timestamp = valuation?.quoteTimestamp {
                                Text("價格時間 \(timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            }
                            if valuation?.isStale == true { Text("使用最後成功價格").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    NavigationLink("新增資產") { AddInvestmentAssetView(account: currentAccount) }
                    NavigationLink("買入、賣出或股息") { InvestmentEntryView(account: currentAccount) }
                }
            }
            if currentAccount.type == .creditCard, let metadata = currentAccount.creditCard {
                Section("信用卡") {
                    LabeledContent("結帳日", value: "每月 \(metadata.statementDay) 日")
                    if let total = try? CreditCardService.currentStatementTotal(for: currentAccount, asOf: .today(), in: model.state) {
                        LabeledContent("本期已刷") { MoneyText(money: total, hidden: model.hideAmounts) }
                    }
                    NavigationLink("繳信用卡") { CreditCardPaymentView(card: currentAccount) }
                }
                if let range = try? CreditCardService.currentStatementRange(for: currentAccount, asOf: .today()) {
                    let cardCharges = model.state.transactions.filter { $0.deletedAt == nil && $0.draft.kind == .creditCardCharge && $0.draft.accountID == currentAccount.id }
                    let currentCharges = cardCharges.filter { range.contains($0.draft.occurredOn) }.sorted { $0.draft.occurredOn > $1.draft.occurredOn }
                    let nextCharges = cardCharges.filter { $0.draft.occurredOn > range.end }.sorted { $0.draft.occurredOn < $1.draft.occurredOn }
                    Section("本期／下期交易") {
                        Text("本期：\(range.start.iso8601) 至 \(range.end.iso8601)")
                            .font(.caption).foregroundStyle(.secondary)
                        if currentCharges.isEmpty {
                            Text("本期尚無刷卡交易").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(currentCharges) { charge in
                                HStack {
                                    Text(charge.draft.description.isEmpty ? "刷卡交易" : charge.draft.description)
                                    Spacer()
                                    MoneyText(money: charge.draft.amount, hidden: model.hideAmounts)
                                }
                            }
                        }
                        if !nextCharges.isEmpty {
                            Text("下期").font(.caption).foregroundStyle(.secondary)
                            ForEach(nextCharges) { charge in
                                HStack {
                                    Text(charge.draft.description.isEmpty ? "刷卡交易" : charge.draft.description)
                                    Spacer()
                                    MoneyText(money: charge.draft.amount, hidden: model.hideAmounts)
                                }
                            }
                        }
                    }
                }
            }
            if currentAccount.type == .loan { NavigationLink("支付本金與利息") { LoanPaymentView(loan: currentAccount) } }
        }
        .navigationTitle(currentAccount.name)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("刪除帳戶", role: .destructive) { showsDeleteConfirmation = true }
            }
        }
        .confirmationDialog("將帳戶移至垃圾桶？", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("移至垃圾桶", role: .destructive) {
                Task { await model.softDeleteAccount(currentAccount.id); dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("有交易或持倉的帳戶無法刪除，以避免破壞歷史資料。")
        }
    }

    private var accountFlowSummary: (month: (range: LedgerDateRange, inflow: Money, outflow: Money, net: Money), year: (range: LedgerDateRange, inflow: Money, outflow: Money, net: Money))? {
        let today = LocalDate.today()
        guard
              let monthRange = try? LedgerDateRange(start: LocalDate(year: today.year, month: today.month, day: 1), end: today),
              let yearRange = try? LedgerDateRange(start: LocalDate(year: today.year, month: 1, day: 1), end: today),
              let month = flow(for: monthRange), let year = flow(for: yearRange) else { return nil }
        return ((monthRange, month.inflow, month.outflow, month.net), (yearRange, year.inflow, year.outflow, year.net))
    }

    private func flow(for range: LedgerDateRange) -> (inflow: Money, outflow: Money, net: Money)? {
        let transactions = model.state.transactions.filter { transaction in
            guard transaction.deletedAt == nil, range.contains(transaction.draft.occurredOn),
                  transaction.draft.accountID == currentAccount.id || transaction.draft.counterpartyAccountID == currentAccount.id else { return false }
            return transaction.draft.amount.currencyCode == currentAccount.currencyCode
        }
        guard var zero = try? Money(minorUnits: 0, currencyCode: currentAccount.currencyCode) else { return nil }
        var inflow = zero
        var outflow = zero
        for transaction in transactions {
            let draft = transaction.draft
            let isInflow: Bool
            switch draft.kind {
            case .income, .dividend: isInflow = draft.accountID == currentAccount.id
            case .investmentSell: isInflow = draft.counterpartyAccountID == currentAccount.id
            case .transfer, .creditCardPayment: isInflow = draft.counterpartyAccountID == currentAccount.id
            default: isInflow = false
            }
            let isOutflow = draft.accountID == currentAccount.id && [.expense, .creditCardCharge, .transfer, .creditCardPayment, .investmentBuy, .loanPayment].contains(draft.kind)
            if isInflow { inflow = (try? inflow.adding(draft.amount)) ?? inflow }
            if isOutflow { outflow = (try? outflow.adding(draft.amount)) ?? outflow }
        }
        zero = inflow
        let net = (try? inflow.subtracting(outflow)) ?? zero
        return (inflow, outflow, net)
    }
}

private struct AccountMonthlyStatementsView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    let account: Account
    private var months: [MonthKey] {
        let today = LocalDate.today(); let index = today.year * 12 + today.month - 1
        return (0..<12).reversed().map { raw in
            let value = index - raw; return MonthKey(year: value / 12, month: value % 12 + 1)
        }
    }
    var body: some View {
        List {
            ForEach(months, id: \.self) { month in
                if let row = statement(for: month) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(month.year) 年 \(month.month) 月").font(.headline)
                        LabeledContent("期初結餘") { MoneyText(money: row.opening, hidden: model.hideAmounts) }
                        LabeledContent("本月流入") { MoneyText(money: row.inflow, hidden: model.hideAmounts) }
                        LabeledContent("本月流出") { MoneyText(money: row.outflow, hidden: model.hideAmounts) }
                        LabeledContent("期末結餘") { MoneyText(money: row.closing, hidden: model.hideAmounts) }
                    }
                }
            }
        }
        .navigationTitle("逐月結轉")
    }
    private func statement(for month: MonthKey) -> (opening: Money, inflow: Money, outflow: Money, closing: Money)? {
        guard let last = try? month.daysInMonth(), let start = try? LocalDate(year: month.year, month: month.month, day: 1), let end = try? LocalDate(year: month.year, month: month.month, day: last), let range = try? LedgerDateRange(start: start, end: end), let zero = try? Money(minorUnits: 0, currencyCode: account.currencyCode) else { return nil }
        var opening = account.openingBalance, inflow = zero, outflow = zero
        for transaction in model.state.transactions where transaction.deletedAt == nil && transaction.draft.amount.currencyCode == account.currencyCode {
            let draft = transaction.draft
            let side = draft.accountID == account.id ? -1 : (draft.counterpartyAccountID == account.id ? 1 : 0)
            guard side != 0 else { continue }
            let signed = (draft.kind == .income || draft.kind == .dividend || draft.kind == .investmentSell) ? 1 : side
            if draft.occurredOn < range.start { opening = (try? opening.adding(signed > 0 ? draft.amount : draft.amount.negated())) ?? opening }
            else if range.contains(draft.occurredOn) {
                if signed > 0 { inflow = (try? inflow.adding(draft.amount)) ?? inflow } else { outflow = (try? outflow.adding(draft.amount)) ?? outflow }
            }
        }
        let closing = (try? opening.adding(inflow).subtracting(outflow)) ?? opening
        return (opening, inflow, outflow, closing)
    }
}
