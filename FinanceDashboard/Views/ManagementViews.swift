import Foundation
import Charts
import SwiftUI

struct BudgetManagerView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var showsEditor = false
    @State private var selectedMonth = Date()
    @State private var isAnnual = false
    @State private var confirmsBudgetDeletion = false

    private var month: MonthKey { localDate(selectedMonth).monthKey }
    private var budgets: [Budget] {
        model.state.budgets.filter { $0.deletedAt == nil && ($0.isAnnual == true) == isAnnual && (isAnnual ? $0.month.year == month.year : $0.month == month) }
            .sorted { lhs, rhs in
                let left = model.state.categories.first(where: { $0.id == lhs.categoryID })?.name ?? ""
                let right = model.state.categories.first(where: { $0.id == rhs.categoryID })?.name ?? ""
                return left < right
            }
    }

    var body: some View {
        List {
            Picker("期間", selection: $isAnnual) {
                Text("月預算").tag(false)
                Text("年預算").tag(true)
            }.pickerStyle(.segmented)
            DatePicker("預算月份", selection: $selectedMonth, displayedComponents: .date)
            let categorySpend = spending
            if let overview = try? BudgetService.overview(budgets: budgets, spending: categorySpend, currency: model.state.baseCurrencyCode, remainingDays: remainingDays) {
                Section("預算總覽") {
                    LabeledContent("總預算") { MoneyText(money: overview.limit, hidden: model.hideAmounts) }
                    LabeledContent("預算分類支出") { MoneyText(money: overview.spent, hidden: model.hideAmounts) }
                    LabeledContent("剩餘") { MoneyText(money: overview.remaining, hidden: model.hideAmounts) }
                    if remainingDays > 0 {
                        LabeledContent("剩餘天數", value: "\(remainingDays)")
                        LabeledContent("每日可用預算") { MoneyText(money: overview.perDay, hidden: model.hideAmounts) }
                    }
                }
            }
            ForEach(budgets) { budget in
                let name = model.state.categories.first(where: { $0.id == budget.categoryID })?.name ?? "已刪除分類"
                let spent = categorySpend[budget.categoryID]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name)
                        Spacer()
                        MoneyText(money: budget.limit, hidden: model.hideAmounts)
                    }
                    if let remaining = try? budget.limit.subtracting(spent ?? .zero(currencyCode: budget.limit.currencyCode)) {
                        LabeledContent("剩餘預算") { MoneyText(money: remaining, hidden: model.hideAmounts) }
                        if !model.hideAmounts {
                            ProgressView(value: max(0, min(1, Double(remaining.minorUnits) / Double(budget.limit.minorUnits))))
                                .tint(remaining.minorUnits < 0 ? .red : .green)
                                .accessibilityLabel("預算剩餘比例")
                        }
                    }
                    if let spent, let status = try? BudgetService.status(spent: spent, limit: budget.limit) {
                        Text(budgetStatusText(status, spent: spent, limit: budget.limit))
                            .font(.caption)
                            .foregroundStyle(status == .overLimit ? .red : status == .underHalf ? .secondary : .orange)
                    } else {
                        Text("尚未使用").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if budgets.isEmpty { Text("本月尚未設定分類預算") }
        }
        .navigationTitle(isAnnual ? "年預算" : "月預算")
        .toolbar {
            Button("新增或更新", systemImage: "plus") { showsEditor = true }
            Button("刪除本期預算", systemImage: "trash", role: .destructive) { confirmsBudgetDeletion = true }.disabled(budgets.isEmpty)
        }
        .confirmationDialog("刪除目前選定期間的預算？", isPresented: $confirmsBudgetDeletion, titleVisibility: .visible) {
            Button("刪除預算", role: .destructive) { Task { await model.deleteBudgets(Set(budgets.map(\.id))) } }
        } message: { Text("保留帳本交易。可從設定的復原點還原。") }
        .sheet(isPresented: $showsEditor) { BudgetEditorView(month: month, isAnnual: isAnnual) }
    }

    private var spending: [UUID: Money] {
        guard isAnnual else { return (try? CashFlowCalculator.expensesByCategory(for: month, in: model.state)) ?? [:] }
        guard let start = try? LocalDate(year: month.year, month: 1, day: 1),
              let end = try? LocalDate(year: month.year, month: 12, day: 31),
              let range = try? LedgerDateRange(start: start, end: end) else { return [:] }
        return (try? CashFlowCalculator.expensesByCategory(in: range, state: model.state)) ?? [:]
    }

    private var remainingDays: Int {
        let calendar = Calendar(identifier: .gregorian)
        guard let interval = calendar.dateInterval(of: isAnnual ? .year : .month, for: selectedMonth) else { return 0 }
        let start = max(interval.start, calendar.startOfDay(for: Date()))
        return max(0, calendar.dateComponents([.day], from: start, to: interval.end).day ?? 0)
    }

    private func budgetStatusText(_ status: BudgetStatus, spent: Money, limit: Money) -> String {
        let percentage = limit.minorUnits == 0 ? 0 : (Decimal(spent.minorUnits) / Decimal(limit.minorUnits) * 100)
        let formatted = NSDecimalNumber(decimal: percentage).rounding(accordingToBehavior: nil).stringValue
        switch status {
        case .underHalf: return "已使用 \(formatted)%"
        case .warning50: return "已達 50%（目前 \(formatted)%）"
        case .warning80: return "已達 80%（目前 \(formatted)%）"
        case .atLimit: return "已達 100%"
        case .overLimit: return "已超標（\(formatted)%）"
        }
    }
}

private struct BudgetEditorView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let month: MonthKey
    var isAnnual = false
    @State private var categoryID: UUID?
    @State private var amount = ""

    private var categories: [Category] {
        model.state.categories.filter { $0.deletedAt == nil && $0.kind == .expense }
            .sorted { $0.useCount == $1.useCount ? $0.sortOrder < $1.sortOrder : $0.useCount > $1.useCount }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("分類", selection: $categoryID) {
                    Text("請選擇").tag(UUID?.none)
                    ForEach(categories) { category in Text(category.name).tag(Optional(category.id)) }
                }
                TextField("\(isAnnual ? "全年" : "每月")金額（\(model.state.baseCurrencyCode)）", text: $amount).keyboardType(.decimalPad)
            }
            .navigationTitle(isAnnual ? "年預算" : "月預算")
            .onAppear { categoryID = categories.first?.id }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { submit() }.disabled(categoryID == nil || amount.isEmpty)
                }
            }
        }
    }

    private func submit() {
        guard let categoryID else { return }
        do {
            let limit = try moneyInput(amount, currencyCode: model.state.baseCurrencyCode)
            Task { await model.setBudget(categoryID: categoryID, limit: limit, month: month, isAnnual: isAnnual); dismiss() }
        } catch {
            model.errorMessage = "請輸入有效且大於零的預算金額。"
        }
    }
}

struct RecurringManagerView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var showsEditor = false

    private var recurring: [RecurringTransaction] {
        model.state.recurringTransactions.filter { $0.deletedAt == nil }.sorted { $0.dayOfMonth < $1.dayOfMonth }
    }

    private var occurrences: [RecurringOccurrence] {
        model.state.occurrences.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section("固定收扣款") {
                ForEach(recurring) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("每月 \(item.dayOfMonth) 日 · \(item.template.kind == .income ? "收入" : "支出")")
                        Text(item.template.description.isEmpty ? "未填寫備註" : item.template.description)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if recurring.isEmpty { Text("尚未建立固定收扣款") }
            }
            if !occurrences.isEmpty {
                Section("已建立紀錄") {
                    ForEach(occurrences) { occurrence in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(occurrence.date.iso8601)
                                Text(occurrence.status.localizedName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if occurrence.status == .created {
                                Button("撤銷", role: .destructive) {
                                    Task { await model.reverseRecurringOccurrence(recurrenceID: occurrence.recurrenceID, on: occurrence.date) }
                                }
                                .buttonStyle(.borderless)
                                Button("標記未發生", role: .destructive) {
                                    Task { await model.markRecurringNotOccurred(recurrenceID: occurrence.recurrenceID, on: occurrence.date) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("固定收扣款")
        .toolbar { Button("新增", systemImage: "plus") { showsEditor = true } }
        .sheet(isPresented: $showsEditor) { RecurringEditorView() }
    }
}

private enum RecurringKind: String, CaseIterable, Identifiable {
    case income = "收入"
    case expense = "支出"
    var id: Self { self }
    var transactionKind: TransactionKind { self == .income ? .income : .expense }
    var categoryKind: CategoryKind { self == .income ? .income : .expense }
}

private struct RecurringEditorView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RecurringKind = .expense
    @State private var dayOfMonth = 1
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var amount = ""
    @State private var note = ""

    private var accounts: [Account] {
        model.state.accounts.filter { $0.deletedAt == nil && !$0.type.isLiability && !$0.type.isInvestment }
    }

    private var categories: [Category] {
        model.state.categories.filter { $0.deletedAt == nil && $0.kind == kind.categoryKind }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("類型", selection: $kind) {
                    ForEach(RecurringKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, _ in categoryID = categories.first?.id }
                Stepper("每月 \(dayOfMonth) 日", value: $dayOfMonth, in: 1 ... 31)
                Picker("帳戶", selection: $accountID) {
                    Text("請選擇").tag(UUID?.none)
                    ForEach(accounts) { account in Text(account.name).tag(Optional(account.id)) }
                }
                Picker("分類", selection: $categoryID) {
                    Text("請選擇").tag(UUID?.none)
                    ForEach(categories) { category in Text(category.name).tag(Optional(category.id)) }
                }
                TextField("金額", text: $amount).keyboardType(.decimalPad)
                TextField("備註（選填）", text: $note)
            }
            .navigationTitle("固定收扣款")
            .onAppear {
                accountID = accounts.first?.id
                categoryID = categories.first?.id
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { submit() }
                        .disabled(accountID == nil || categoryID == nil || amount.isEmpty)
                }
            }
        }
    }

    private func submit() {
        guard let accountID, let categoryID,
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        do {
            let draft = TransactionDraft(
                kind: kind.transactionKind,
                occurredOn: .today(),
                accountID: accountID,
                amount: try moneyInput(amount, currencyCode: account.currencyCode),
                categoryID: categoryID,
                description: note
            )
            Task { await model.addRecurring(dayOfMonth: dayOfMonth, template: draft); dismiss() }
        } catch {
            model.errorMessage = "請輸入有效的固定金額。"
        }
    }
}

struct LedgerHistoryView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    var range: LedgerDateRange?
    var title = "交易紀錄"
    var accountID: UUID?
    @State private var searchText = ""

    init(range: LedgerDateRange? = nil, title: String = "交易紀錄", accountID: UUID? = nil) {
        self.range = range
        self.title = title
        self.accountID = accountID
    }

    private var transactions: [LedgerTransaction] {
        model.state.transactions.filter {
            $0.deletedAt == nil && (range?.contains($0.draft.occurredOn) ?? true)
                && (accountID == nil || $0.draft.accountID == accountID || $0.draft.counterpartyAccountID == accountID)
                && matchesSearch($0)
        }.sorted {
            $0.draft.occurredOn == $1.draft.occurredOn ? $0.createdAt > $1.createdAt : $0.draft.occurredOn > $1.draft.occurredOn
        }
    }

    var body: some View {
        List {
            ForEach(transactions) { transaction in
                NavigationLink { TransactionEditorView(transaction: transaction) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(transaction.draft.description.isEmpty ? transaction.draft.kind.localizedName : transaction.draft.description)
                            Text(transaction.draft.occurredOn.iso8601).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MoneyText(money: transaction.draft.amount, hidden: model.hideAmounts)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { transactions[$0].id }.forEach { id in
                    Task { await model.softDeleteTransaction(id) }
                }
            }
            if transactions.isEmpty { Text("尚無交易紀錄") }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "備註、分類、帳戶、成員或標籤")
    }

    private func matchesSearch(_ transaction: LedgerTransaction) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let draft = transaction.draft
        let category = model.state.categories.first { $0.id == draft.categoryID }?.name ?? ""
        let accounts = model.state.accounts.filter { $0.id == draft.accountID || $0.id == draft.counterpartyAccountID }.map(\.name)
        return ([draft.description, draft.member ?? "", category] + accounts + (draft.tags ?? [])).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private enum NetWorthPeriod: String, CaseIterable, Identifiable {
    case oneMonth, threeMonths, sixMonths, oneYear, all, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .oneMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1Y"
        case .all: return "ALL"
        case .custom: return "自訂"
        }
    }
}

struct NetWorthAnalysisView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var period: NetWorthPeriod = .oneMonth
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()

    private var range: LedgerDateRange {
        let calendar = Calendar.current
        let today = Date()
        let start: Date
        switch period {
        case .oneMonth: start = calendar.date(byAdding: .month, value: -1, to: today) ?? today
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: today) ?? today
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: today) ?? today
        case .oneYear: start = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        case .all:
            let first = model.state.snapshots.map(\.date).min() ?? .today()
            return (try? LedgerDateRange(start: first, end: .today())) ?? LedgerDateRange(singleDay: .today())
        case .custom: return localDateRange(start: customStart, end: customEnd)
        }
        return localDateRange(start: start, end: today)
    }

    private var snapshots: [NetWorthSnapshot] {
        model.state.snapshots.filter { range.contains($0.date) }.sorted { $0.date < $1.date }
    }

    private var netWorth: NetWorthResult {
        (try? NetWorthCalculator.calculate(in: model.state)) ?? .zero(currency: model.state.baseCurrencyCode)
    }

    var body: some View {
        List {
            Picker("期間", selection: $period) {
                ForEach(NetWorthPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if period == .custom {
                DatePicker("開始日期", selection: $customStart, displayedComponents: .date)
                DatePicker("結束日期", selection: $customEnd, in: customStart..., displayedComponents: .date)
            }
            Section("淨資產") {
                if model.hideAmounts {
                    Text("已隱藏淨資產趨勢。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if snapshots.count >= 2 {
                    Chart(snapshots) { snapshot in
                        LineMark(
                            x: .value("日期", snapshot.date.date()),
                            y: .value("淨資產", Double(snapshot.netWorth.minorUnits))
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .frame(height: 180)
                    if let latest = snapshots.last { LabeledContent("期末") { MoneyText(money: latest.netWorth, hidden: model.hideAmounts) } }
                } else {
                    Text("目前尚無足夠的每日快照可繪製趨勢。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("資產組成") {
                LabeledContent("現金／銀行") { MoneyText(money: netWorth.cashValue, hidden: model.hideAmounts) }
                LabeledContent("股票") { MoneyText(money: netWorth.stockValue, hidden: model.hideAmounts) }
                LabeledContent("Crypto") { MoneyText(money: netWorth.cryptoValue, hidden: model.hideAmounts) }
                LabeledContent("其他資產") { MoneyText(money: netWorth.otherAssetValue, hidden: model.hideAmounts) }
                LabeledContent("負債") { MoneyText(money: netWorth.liabilityValue, hidden: model.hideAmounts) }
            }
            if !netWorth.warnings.isEmpty {
                Section("價格與匯率限制") {
                    ForEach(netWorth.warnings, id: \.self) { warning in
                        Text(warning).font(.footnote).foregroundStyle(.orange)
                    }
                    Text("未取得可信價格或匯率時，該資產會被排除，不會以 0 或猜測匯率計入淨資產。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            growthSection
        }
        .navigationTitle("淨資產分析")
    }

    @ViewBuilder
    private var growthSection: some View {
        Section("淨資產成長來源") {
            if let first = snapshots.first, let last = snapshots.last, first.id != last.id,
               let source = try? NetWorthGrowthService.explain(from: first, to: last, over: range, in: model.state) {
                LabeledContent("淨資產變動") { MoneyText(money: source.netWorthChange, hidden: model.hideAmounts) }
                LabeledContent("日常現金流") { MoneyText(money: source.dailyCashFlowContribution, hidden: model.hideAmounts) }
                LabeledContent("投資損益／股息") { MoneyText(money: source.investmentReturn, hidden: model.hideAmounts) }
                LabeledContent("負債變動（背景）") { MoneyText(money: source.liabilityChange, hidden: model.hideAmounts) }
                Text("負債變動已反映在日常現金流或帳戶互轉中，不會再次重複加總。")
                    .font(.caption).foregroundStyle(.secondary)
                if !source.unclassifiedChange.isZero {
                    LabeledContent("待歸類調整") { MoneyText(money: source.unclassifiedChange, hidden: model.hideAmounts) }
                    Text("待歸類調整不會被誤標為儲蓄或投資報酬。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("需要至少兩個有效日快照才能拆解變動來源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TransactionEditorView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    @State private var amount: String
    @State private var note: String
    @State private var selectedDate: Date
    @State private var categoryID: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var member: String
    @State private var tags: String

    init(transaction: LedgerTransaction) {
        self.transaction = transaction
        _amount = State(initialValue: NSDecimalNumber(decimal: transaction.draft.amount.decimalValue(fractionDigits: CurrencyScale.fractionDigits(for: transaction.draft.amount.currencyCode))).stringValue)
        _note = State(initialValue: transaction.draft.description)
        _selectedDate = State(initialValue: transaction.draft.occurredOn.date())
        _categoryID = State(initialValue: transaction.draft.categoryID)
        _member = State(initialValue: transaction.draft.member ?? "")
        _tags = State(initialValue: (transaction.draft.tags ?? []).joined(separator: ", "))
    }

    private var editableCategoryKind: CategoryKind? {
        switch transaction.draft.kind {
        case .income: return .income
        case .expense, .creditCardCharge, .loanPayment: return .expense
        case .dividend: return .investmentIncome
        default: return nil
        }
    }

    private var categories: [Category] {
        guard let editableCategoryKind else { return [] }
        return model.state.categories.filter { $0.deletedAt == nil && $0.kind == editableCategoryKind }
    }

    var body: some View {
        Form {
            LabeledContent("類型", value: transaction.draft.kind.localizedName)
            if transaction.draft.kind == .loanPayment {
                LabeledContent("總額", value: amount)
                Text("貸款付款請保留原本金／利息拆分。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("金額", text: $amount).keyboardType(.decimalPad)
            }
            if editableCategoryKind != nil {
                Picker("分類", selection: $categoryID) {
                    Text("請選擇").tag(UUID?.none)
                    ForEach(categories) { category in Text(category.name).tag(Optional(category.id)) }
                }
            }
            DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
            TextField("備註", text: $note)
            TextField("成員", text: $member)
            TextField("標籤（以逗號分隔）", text: $tags)
            ForEach(Array((transaction.draft.receiptImages ?? []).enumerated()), id: \.offset) { _, data in
                if let receipt = UIImage(data: data) {
                    Image(uiImage: receipt).resizable().scaledToFit().accessibilityLabel("收據照片")
                }
            }
        }
        .navigationTitle("修改交易")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() } }
            ToolbarItem(placement: .bottomBar) { Button("移至垃圾桶", role: .destructive) { showsDeleteConfirmation = true } }
        }
        .confirmationDialog("移至垃圾桶？", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("移至垃圾桶", role: .destructive) {
                Task { await model.softDeleteTransaction(transaction.id); dismiss() }
            }
        }
    }

    private func save() {
        do {
            var draft = transaction.draft
            if transaction.draft.kind != .loanPayment {
                draft.amount = try moneyInput(amount, currencyCode: draft.amount.currencyCode)
            }
            draft.categoryID = categoryID
            draft.occurredOn = localDate(selectedDate)
            draft.description = note
            draft.member = member.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            Task { await model.replaceTransaction(transaction.id, with: draft); dismiss() }
        } catch {
            model.errorMessage = "請輸入有效的交易金額。"
        }
    }
}

struct TrashView: View {
    @EnvironmentObject private var model: FinanceDashboardModel

    private var transactions: [LedgerTransaction] {
        model.state.transactions.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            ForEach(transactions) { transaction in
                HStack {
                    VStack(alignment: .leading) {
                        Text(transaction.draft.description.isEmpty ? transaction.draft.kind.localizedName : transaction.draft.description)
                        Text("刪除於 \(transaction.deletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("還原") { Task { await model.restoreTransaction(transaction.id) } }
                        .buttonStyle(.bordered)
                }
            }
            if transactions.isEmpty { Text("垃圾桶是空的") }
        }
        .navigationTitle("垃圾桶")
        .safeAreaInset(edge: .bottom) {
            Text("交易會在刪除 30 天後於 App 啟動時清除；Audit Log 會保留。")
                .font(.footnote).foregroundStyle(.secondary).padding()
        }
    }
}
