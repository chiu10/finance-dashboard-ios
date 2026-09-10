import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var selectedDate = Date()
    @State private var showsCalendar = true
    @State private var expandsDay = true

    var body: some View {
        let values = model.dashboard
        NavigationStack {
            List {
                Section("月曆") {
                    Picker("帳本檢視", selection: $showsCalendar) {
                        Text("月曆").tag(true)
                        Text("清單").tag(false)
                    }.pickerStyle(.segmented)
                    if showsCalendar {
                        CalendarGridView(selectedDate: $selectedDate, transactionDates: Set(model.state.transactions.filter { $0.deletedAt == nil }.map { $0.draft.occurredOn }))
                            .onChange(of: selectedDate) { _, _ in expandsDay = true }
                        DisclosureGroup("\(selectedDate.formatted(date: .abbreviated, time: .omitted)) 帳本", isExpanded: $expandsDay) {
                            let transactions = model.state.transactions.filter { $0.deletedAt == nil && $0.draft.occurredOn == localDate(selectedDate) }
                            ForEach(transactions) { transaction in
                                HStack {
                                    Text(transaction.draft.description.isEmpty ? transaction.draft.kind.localizedName : transaction.draft.description)
                                    Spacer()
                                    MoneyText(money: transaction.draft.amount, hidden: model.hideAmounts)
                                }
                            }
                            if transactions.isEmpty { Text("當日沒有交易") }
                            NavigationLink("查看及修改當日交易") { LedgerHistoryView(range: LedgerDateRange(singleDay: localDate(selectedDate)), title: "當日帳本") }
                        }
                    } else {
                        NavigationLink("全部交易與搜尋") { LedgerHistoryView() }
                    }
                }
                Section {
                    NavigationLink { NetWorthAnalysisView() } label: {
                        MetricCard(title: "淨資產", value: values.netWorth, hidden: model.hideAmounts, color: .primary)
                    }
                }
                Section {
                    NavigationLink {
                        CashFlowDetailView(title: "本日收支", range: LedgerDateRange(singleDay: .today()))
                    } label: {
                        MetricCard(title: "本日支出", value: values.todayExpense, hidden: model.hideAmounts, color: .orange)
                    }
                    NavigationLink {
                        CashFlowDetailView(title: "本月收支", range: currentMonthRange)
                    } label: {
                        MetricCard(title: "本月可用結餘", value: values.availableBalance, hidden: model.hideAmounts, color: values.availableBalance.minorUnits < 0 ? .red : .green)
                    }
                    NavigationLink { SpendingAlertDetailView() } label: {
                        Label(alertTitle(for: values), systemImage: values.hasAnomaly || values.hasBudgetAlert ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(values.hasAnomaly || values.hasBudgetAlert ? .orange : .green)
                    }
                }
            }
            .navigationTitle("首頁")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") } } }
        }
    }

    private func alertTitle(for values: DashboardValues) -> String {
        switch (values.hasAnomaly, values.hasBudgetAlert) {
        case (true, true): return "存在支出異常與預算超標"
        case (true, false): return "存在支出異常"
        case (false, true): return "存在預算超標"
        case (false, false): return "目前沒有支出異常"
        }
    }

    private var currentMonthRange: LedgerDateRange {
        let today = LocalDate.today()
        let firstDay = (try? LocalDate(year: today.year, month: today.month, day: 1)) ?? today
        return (try? LedgerDateRange(start: firstDay, end: today)) ?? LedgerDateRange(singleDay: today)
    }
}

private struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let transactionDates: Set<LocalDate>
    private let calendar = Calendar.current
    private var monthStart: Date { calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate }
    private var days: [Date?] {
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let weekday = calendar.component(.weekday, from: monthStart) - 1
        return Array(repeating: nil, count: weekday) + (1...count).compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("上一月") { selectedDate = calendar.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate }
                Spacer(); Text(monthStart.formatted(.dateTime.year().month(.wide))).font(.headline)
                Spacer(); Button("下一月") { selectedDate = calendar.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(calendar.shortWeekdaySymbols, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let local = localDate(date)
                        Button { selectedDate = date } label: {
                            VStack(spacing: 2) {
                                Text(calendar.component(.day, from: date).description)
                                    .frame(width: 30, height: 26)
                                    .background(calendar.isDate(date, inSameDayAs: selectedDate) ? Color.orange.opacity(0.2) : .clear, in: Circle())
                                Circle().fill(transactionDates.contains(local) ? Color.primary : .clear).frame(width: 4, height: 4)
                            }
                        }.buttonStyle(.plain)
                    } else { Color.clear.frame(height: 34) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CashFlowDetailView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    let title: String
    let range: LedgerDateRange

    var body: some View {
        let summary = (try? CashFlowCalculator.summary(in: range, state: model.state)) ?? .zero(currency: model.state.baseCurrencyCode)
        List {
            Section("拆解") {
                LabeledContent("一般收入") { MoneyText(money: summary.ordinaryIncome, hidden: model.hideAmounts) }
                LabeledContent("生活支出") { MoneyText(money: summary.livingExpenses, hidden: model.hideAmounts) }
                LabeledContent("投資投入") { MoneyText(money: summary.investmentContributions, hidden: model.hideAmounts) }
                LabeledContent("可用結餘") { MoneyText(money: (try? summary.availableBalance()) ?? .zero(currencyCode: model.state.baseCurrencyCode), hidden: model.hideAmounts) }
            }
            Section("投資收益（不計入可用結餘）") {
                LabeledContent("已實現收益") { MoneyText(money: summary.realizedInvestmentGains, hidden: model.hideAmounts) }
                LabeledContent("股息") { MoneyText(money: summary.dividendIncome, hidden: model.hideAmounts) }
            }
            NavigationLink("查看此期間交易") { LedgerHistoryView(range: range, title: title) }
        }
        .navigationTitle(title)
    }
}

private struct SpendingAlertDetailView: View {
    @EnvironmentObject private var model: FinanceDashboardModel

    var body: some View {
        let today = LocalDate.today()
        let spending = (try? CashFlowCalculator.expensesByCategory(for: today.monthKey, in: model.state)) ?? [:]
        let anomalies = model.state.categories.filter {
            $0.deletedAt == nil && $0.kind == .expense &&
                ((try? SpendingInsightService.insight(categoryID: $0.id, asOf: today, in: model.state).anomaly.isAnomalous) == true)
        }
        let exceeded = model.state.budgets.filter {
            $0.deletedAt == nil && $0.isAnnual != true && $0.month == today.monthKey &&
                ((try? BudgetService.status(spent: spending[$0.categoryID] ?? .zero(currencyCode: model.state.baseCurrencyCode), limit: $0.limit)) == .overLimit)
        }
        List {
            Section("支出異常") {
                ForEach(anomalies) { Text($0.name) }
                if anomalies.isEmpty { Text("目前沒有支出異常") }
            }
            Section("預算超標") {
                ForEach(exceeded) { budget in
                    Text(model.state.categories.first(where: { $0.id == budget.categoryID })?.name ?? "已刪除分類")
                }
                if exceeded.isEmpty { Text("目前沒有預算超標") }
            }
        }
        .navigationTitle("警告狀態")
    }
}

private struct MetricCard: View {
    let title: String
    let value: Money
    let hidden: Bool
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            MoneyText(money: value, hidden: hidden).font(.title2.bold()).foregroundStyle(color)
        }
        .padding(.vertical, 6)
    }
}
