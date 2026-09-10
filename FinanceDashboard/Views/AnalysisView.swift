import SwiftUI
import Charts

struct AnalysisView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var period: AnalysisPeriod = .month
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var breakdownByMember = false

    var body: some View {
        NavigationStack {
            List {
                Section("預算規劃") {
                    NavigationLink("每月分類預算") { BudgetManagerView() }
                }
                Picker("期間", selection: $period) {
                    ForEach(AnalysisPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                if period == .custom {
                    DatePicker("開始日期", selection: $customStart, displayedComponents: .date)
                    DatePicker("結束日期", selection: $customEnd, in: customStart..., displayedComponents: .date)
                }
                Section("支出去向") {
                    let spending = (try? CashFlowCalculator.expensesByCategory(in: selectedRange, state: model.state)) ?? [:]
                    let highestSpend = max(1, spending.values.map(\.minorUnits).max() ?? 1)
                    if !spending.isEmpty && !model.hideAmounts {
                        Chart(spending.sorted { $0.value.minorUnits > $1.value.minorUnits }, id: \.key) { item in
                            BarMark(
                                x: .value("分類", model.state.categories.first(where: { $0.id == item.key })?.name ?? "其他"),
                                y: .value("支出", Double(item.value.minorUnits))
                            )
                        }
                        .frame(height: 180)
                    }
                    ForEach(spending.sorted { $0.value.minorUnits > $1.value.minorUnits }, id: \.key) { categoryID, amount in
                        let name = model.state.categories.first(where: { $0.id == categoryID })?.name ?? "已刪除分類"
                        NavigationLink { CategoryDetailView(categoryID: categoryID, range: selectedRange) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    MoneyText(money: amount, hidden: model.hideAmounts)
                                }
                                ProgressView(value: Double(amount.minorUnits), total: Double(highestSpend))
                                    .tint(.accentColor)
                            }
                        }
                    }
                    if spending.isEmpty { Text("此期間尚無生活支出") }
                }
                Section("收支與淨資產") {
                    let summary = (try? CashFlowCalculator.summary(in: selectedRange, state: model.state)) ?? .zero(currency: model.state.baseCurrencyCode)
                    LabeledContent("收入") { MoneyText(money: summary.ordinaryIncome, hidden: model.hideAmounts) }
                    LabeledContent("生活支出") { MoneyText(money: summary.livingExpenses, hidden: model.hideAmounts) }
                    LabeledContent("投資投入") { MoneyText(money: summary.investmentContributions, hidden: model.hideAmounts) }
                    LabeledContent("結餘") { MoneyText(money: (try? summary.availableBalance()) ?? .zero(currencyCode: model.state.baseCurrencyCode), hidden: model.hideAmounts) }
                    LabeledContent("已實現投資收益") { MoneyText(money: summary.realizedInvestmentGains, hidden: model.hideAmounts) }
                    LabeledContent("股息（不計入可用結餘）") { MoneyText(money: summary.dividendIncome, hidden: model.hideAmounts) }
                    CashFlowTrendChart(points: (try? CashFlowTrendService.points(in: selectedRange, state: model.state)) ?? [], hidden: model.hideAmounts)
                    NavigationLink("淨資產歷史與組成") { NetWorthAnalysisView() }
                }
                Section("帳戶／成員支出") {
                    Picker("統計方式", selection: $breakdownByMember) {
                        Text("帳戶").tag(false)
                        Text("成員").tag(true)
                    }.pickerStyle(.segmented)
                    let breakdown = (try? CashFlowCalculator.spendingBreakdown(in: selectedRange, state: model.state, byMember: breakdownByMember)) ?? [:]
                    ForEach(breakdown.sorted { $0.value.minorUnits > $1.value.minorUnits }, id: \.key) { name, amount in
                        LabeledContent(name) { MoneyText(money: amount, hidden: model.hideAmounts) }
                    }
                    if breakdown.isEmpty { Text("此期間沒有支出") }
                }
            }
            .navigationTitle("分析")
        }
    }

    private var selectedRange: LedgerDateRange {
        (try? period.range(asOf: Date(), customStart: customStart, customEnd: max(customStart, customEnd)))
            ?? LedgerDateRange(singleDay: .today())
    }
}

private struct CashFlowTrendChart: View {
    let points: [CashFlowTrendPoint]
    let hidden: Bool

    var body: some View {
        if hidden {
            Text("已隱藏趨勢金額").font(.footnote).foregroundStyle(.secondary)
        } else if points.count >= 2 {
            Chart(points) { point in
                LineMark(
                    x: .value("日期", point.date.iso8601),
                    y: .value("金額", Double(point.ordinaryIncome.minorUnits)),
                    series: .value("項目", "收入")
                )
                .foregroundStyle(.green)
                LineMark(
                    x: .value("日期", point.date.iso8601),
                    y: .value("金額", Double(point.livingExpenses.minorUnits)),
                    series: .value("項目", "支出")
                )
                .foregroundStyle(.orange)
                LineMark(
                    x: .value("日期", point.date.iso8601),
                    y: .value("金額", Double(point.availableBalance.minorUnits)),
                    series: .value("項目", "結餘")
                )
                .foregroundStyle(.blue)
            }
            .frame(height: 180)
        } else {
            Text("至少需要兩個日期區間的資料才會顯示收支趨勢。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private extension AnalysisPeriod {
    var title: String {
        switch self {
        case .week: return "本週"
        case .month: return "本月"
        case .lastMonth: return "上月"
        case .threeMonths: return "3 個月"
        case .sixMonths: return "6 個月"
        case .year: return "今年"
        case .oneYear: return "1 年"
        case .custom: return "自訂"
        }
    }
}

private struct CategoryDetailView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    let categoryID: UUID
    let range: LedgerDateRange

    private var currentSpend: Money {
        let spending = (try? CashFlowCalculator.expensesByCategory(in: range, state: model.state)) ?? [:]
        return spending[categoryID] ?? .zero(currencyCode: model.state.baseCurrencyCode)
    }

    private var previousRange: LedgerDateRange {
        let calendar = Calendar.current
        let startDate = range.start.date()
        let endDate = range.end.date()
        let days = (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: startDate) ?? startDate
        let previousStart = calendar.date(byAdding: .day, value: -days, to: startDate) ?? startDate
        return localDateRange(start: previousStart, end: previousEnd)
    }

    private var previousSpend: Money {
        let spending = (try? CashFlowCalculator.expensesByCategory(in: previousRange, state: model.state)) ?? [:]
        return spending[categoryID] ?? .zero(currencyCode: model.state.baseCurrencyCode)
    }

    private var sixMonthAverage: Money? {
        try? CategoryHistoryService.averageMonthlySpend(categoryID: categoryID, before: range.end.monthKey, in: model.state)
    }

    private var currentMonthInsight: CategorySpendingInsight? {
        let today = LocalDate.today()
        guard range.start.monthKey == today.monthKey, range.end == today else { return nil }
        return try? SpendingInsightService.insight(categoryID: categoryID, asOf: today, in: model.state)
    }

    var body: some View {
        List {
            Section("本期") {
                LabeledContent("本期支出") { MoneyText(money: currentSpend, hidden: model.hideAmounts) }
                LabeledContent("上期支出") { MoneyText(money: previousSpend, hidden: model.hideAmounts) }
                if previousSpend.minorUnits > 0 {
                    let change = Decimal(currentSpend.minorUnits - previousSpend.minorUnits) / Decimal(previousSpend.minorUnits) * 100
                    Text("與上期相比 \(NSDecimalNumber(decimal: change).rounding(accordingToBehavior: nil).stringValue)%")
                        .font(.caption).foregroundStyle(change >= 0 ? .orange : .green)
                }
                if let sixMonthAverage {
                    LabeledContent("近六個月平均") { MoneyText(money: sixMonthAverage, hidden: model.hideAmounts) }
                }
                if let insight = currentMonthInsight {
                    if let average = insight.anomaly.historicalAverage {
                        LabeledContent("近六個月同期平均") { MoneyText(money: average, hidden: model.hideAmounts) }
                    }
                    if let projected = insight.forecast.projectedMonthEnd {
                        LabeledContent("預估月底（\(insight.forecast.confidence.localizedName)）") { MoneyText(money: projected, hidden: model.hideAmounts) }
                    }
                    if insight.anomaly.isAnomalous { Text("本月目前進度高於近六個月同期平均 30%。").foregroundStyle(.orange) }
                }
            }
            Section("交易明細") {
                ForEach(model.state.transactions.filter { $0.deletedAt == nil && $0.draft.categoryID == categoryID && range.contains($0.draft.occurredOn) }) { transaction in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(transaction.draft.description.isEmpty ? transaction.draft.kind.localizedName : transaction.draft.description)
                            Text(transaction.draft.occurredOn.iso8601).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if transaction.draft.kind == .loanPayment, let interest = transaction.draft.interest {
                            VStack(alignment: .trailing) {
                                MoneyText(money: interest, hidden: model.hideAmounts)
                                Text("利息支出").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text("付款總額")
                                    MoneyText(money: transaction.draft.amount, hidden: model.hideAmounts)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            MoneyText(money: transaction.draft.amount, hidden: model.hideAmounts)
                        }
                    }
                }
            }
        }
        .navigationTitle("分類明細")
    }
}
