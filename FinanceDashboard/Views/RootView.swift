import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: FinanceDashboardModel

    var body: some View {
        Group {
            if model.isUnlocked {
                MainTabView()
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "財務資料已鎖定",
                        systemImage: "lock.fill",
                        description: Text(model.errorMessage ?? "使用 Face ID 或裝置密碼解鎖。")
                    )
                    Button("解鎖") { Task { await model.activate() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("財務控制台", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("提示", isPresented: Binding(get: { model.noticeMessage != nil }, set: { if !$0 { model.noticeMessage = nil } })) {
            Button("好", role: .cancel) { model.noticeMessage = nil }
        } message: {
            Text(model.noticeMessage ?? "")
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: FinanceDashboardModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("首頁", systemImage: "rectangle.grid.2x2") }
            AccountsView()
                .tabItem { Label("帳戶", systemImage: "wallet.bifold") }
            LedgerEntryView()
                .tabItem { Label("記帳", systemImage: "plus.circle.fill") }
            NavigationStack { BudgetManagerView() }
                .tabItem { Label("預算", systemImage: budgetIcon) }
            AnalysisView()
                .tabItem { Label("分析", systemImage: "chart.bar") }
        }
        .tint(.orange)
    }

    private var budgetIcon: String {
        let month = LocalDate.today().monthKey
        let budgets = model.state.budgets.filter { $0.deletedAt == nil && $0.isAnnual != true && $0.month == month }
        guard !budgets.isEmpty else { return "battery.100" }
        let spending = (try? CashFlowCalculator.expensesByCategory(for: month, in: model.state)) ?? [:]
        let remaining = budgets.map { budget -> Double in
            let spent = spending[budget.categoryID]?.minorUnits ?? 0
            return max(0, min(1, Double(budget.limit.minorUnits - spent) / Double(budget.limit.minorUnits)))
        }.min() ?? 1
        switch remaining {
        case ..<0.25: return "battery.25"
        case ..<0.5: return "battery.50"
        case ..<0.75: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct MoneyText: View {
    let money: Money
    var hidden: Bool = false

    var body: some View {
        if hidden {
            Text("••••••••")
        } else {
            Text(formatted)
                .monospacedDigit()
        }
    }

    private var formatted: String {
        MoneyTextFormatter.string(for: money)
    }
}

enum MoneyTextFormatter {
    static func string(for money: Money) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = money.currencyCode
        formatter.maximumFractionDigits = CurrencyScale.fractionDigits(for: money.currencyCode)
        return formatter.string(from: NSDecimalNumber(decimal: money.decimalValue(fractionDigits: CurrencyScale.fractionDigits(for: money.currencyCode)))) ?? "—"
    }
}

extension AccountType {
    var localizedName: String {
        switch self {
        case .cash: return "現金"
        case .bank: return "銀行"
        case .creditCard: return "信用卡"
        case .stock: return "股票"
        case .crypto: return "Crypto"
        case .loan: return "貸款"
        case .otherAsset: return "其他資產"
        case .otherLiability: return "其他負債"
        }
    }
}

extension CategoryKind {
    var localizedName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        case .investmentIncome: return "投資收益"
        }
    }
}

extension TransactionKind {
    var localizedName: String {
        switch self {
        case .income: return "收入"
        case .expense: return "支出"
        case .transfer: return "轉帳"
        case .creditCardCharge: return "信用卡刷卡"
        case .creditCardPayment: return "信用卡繳款"
        case .loanPayment: return "貸款付款"
        case .investmentBuy: return "投資買入"
        case .investmentSell: return "投資賣出"
        case .dividend: return "股息"
        }
    }
}

extension RecurrenceStatus {
    var localizedName: String {
        switch self {
        case .created: return "已建立"
        case .skipped: return "未發生"
        case .reversed: return "已撤銷"
        }
    }
}

extension ForecastConfidence {
    var localizedName: String {
        switch self {
        case .high: return "高信心"
        case .medium: return "中信心"
        case .low: return "低信心"
        case .unavailable: return "資料不足"
        }
    }
}
