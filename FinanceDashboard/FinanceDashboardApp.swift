import Foundation
import LocalAuthentication
import SwiftUI

private actor StateMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@main
struct FinanceDashboardApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = FinanceDashboardModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.activate() }
                    } else {
                        model.lock()
                    }
                }
        }
    }
}

@MainActor
final class FinanceDashboardModel: ObservableObject {
    // Authentication remains implemented for later re-enablement; disabled for this preview build.
    private static let authenticationEnabled = false

    @Published private(set) var state = LedgerState()
    @Published private(set) var isUnlocked = false
    @Published private(set) var recoveryCheckpoints: [RecoveryCheckpoint] = []
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let repository: LedgerRepository
    private let mutationGate = StateMutationGate()
    private var hasLoaded = false
    private var activationInProgress = false

    var hideAmounts: Bool { state.settings.hideAmounts }

    private func commit(_ mutation: (inout LedgerState) throws -> Void) async throws {
        await mutationGate.enter()
        do {
            var candidate = state
            // Preserve the pre-mutation state so every user mutation has a local rollback point.
            _ = try await repository.createRecoveryCheckpoint(from: state)
            try mutation(&candidate)
            try await repository.save(candidate)
            state = candidate
            recoveryCheckpoints = (try? await repository.recoveryCheckpoints()) ?? []
            await mutationGate.leave()
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    private func replaceState(with candidate: LedgerState, preservingCurrentRecovery: Bool) async throws {
        await mutationGate.enter()
        do {
            if preservingCurrentRecovery {
                _ = try await repository.createRecoveryCheckpoint(from: state)
            }
            try await repository.save(candidate)
            state = candidate
            recoveryCheckpoints = (try? await repository.recoveryCheckpoints()) ?? []
            await mutationGate.leave()
        } catch {
            await mutationGate.leave()
            throw error
        }
    }

    private static func refreshCategoryUsage(in state: inout LedgerState) {
        let counts = state.transactions.reduce(into: [UUID: Int]()) { counts, transaction in
            guard transaction.deletedAt == nil, let categoryID = transaction.draft.categoryID else { return }
            counts[categoryID, default: 0] += 1
        }
        for index in state.categories.indices {
            state.categories[index].useCount = counts[state.categories[index].id, default: 0]
        }
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceDashboard", isDirectory: true)
        repository = LedgerRepository(fileURL: directory.appendingPathComponent("ledger-backup.json"))
    }

    func activate() async {
        guard !activationInProgress else { return }
        activationInProgress = true
        defer { activationInProgress = false }
        if Self.authenticationEnabled {
            await requireAuthentication()
        } else {
            isUnlocked = true
        }
        guard isUnlocked else { return }
        if hasLoaded {
            await reconcileUnlockedState()
        } else {
            hasLoaded = await loadUnlockedState()
        }
    }

    private func loadUnlockedState() async -> Bool {
        do {
            var candidate = try await repository.load()
            if candidate.accounts.isEmpty && candidate.categories.isEmpty { candidate = DefaultLedgerData.make() }
            let today = LocalDate.today()
            LedgerMutationService.purgeDeleted(in: &candidate)
            do {
                _ = try RecurringTransactionService.materializeDue(on: today, in: &candidate)
            } catch {
                errorMessage = "固定收扣款尚未入帳：\(error.localizedDescription)"
            }
            Self.refreshCategoryUsage(in: &candidate)
            try LedgerMutationService.validateIntegrity(candidate)
            try SnapshotService.upsert(for: today, in: &candidate)
            try await replaceState(with: candidate, preservingCurrentRecovery: false)
            await refreshQuotes()
            return true
        } catch {
            errorMessage = "無法載入本機資料：\(error.localizedDescription)"
            return false
        }
    }

    private func reconcileUnlockedState() async {
        do {
            let today = LocalDate.today()
            try await commit { candidate in
                LedgerMutationService.purgeDeleted(in: &candidate)
                _ = try RecurringTransactionService.materializeDue(on: today, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try LedgerMutationService.validateIntegrity(candidate)
                try SnapshotService.upsert(for: today, in: &candidate)
            }
            recoveryCheckpoints = (try? await repository.recoveryCheckpoints()) ?? []
            await refreshQuotes()
        } catch {
            errorMessage = "無法更新已解鎖的本機資料：\(error.localizedDescription)"
        }
    }

    func requireAuthentication() async {
        isUnlocked = false
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        do {
            isUnlocked = try await context.evaluatePolicy(policy, localizedReason: "解鎖個人財務控制台")
        } catch {
            errorMessage = "需要 Face ID 或裝置密碼才能開啟財務資料。"
        }
    }

    func lock() {
        isUnlocked = false
    }

    @discardableResult
    func addTransaction(_ draft: TransactionDraft) async -> Bool {
        do {
            var budgetNotice: String?
            try await commit { candidate in
                _ = try LedgerMutationService.add(draft, to: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                if let categoryID = draft.categoryID, let index = candidate.categories.firstIndex(where: { $0.id == categoryID }) {
                    let categorySpend = try CashFlowCalculator.expensesByCategory(for: draft.occurredOn.monthKey, in: candidate)
                    if [.expense, .creditCardCharge, .loanPayment].contains(draft.kind),
                       let budget = candidate.budgets.first(where: { $0.isAnnual != true && $0.categoryID == categoryID && $0.month == draft.occurredOn.monthKey && $0.deletedAt == nil }),
                   let spent = categorySpend[categoryID],
                   draft.kind != .loanPayment || draft.interest?.isPositive == true {
                        budgetNotice = try BudgetService.notice(categoryName: candidate.categories[index].name, spent: spent, limit: budget.limit)
                    }
                }
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
            noticeMessage = budgetNotice
            return true
        } catch {
            errorMessage = "無法儲存交易：\(error.localizedDescription)"
            return false
        }
    }

    func replaceTransaction(_ transactionID: UUID, with draft: TransactionDraft) async {
        do {
            try await commit { candidate in
                try LedgerMutationService.replace(transactionID, with: draft, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法修改交易：\(error.localizedDescription)"
        }
    }

    func softDeleteTransaction(_ transactionID: UUID) async {
        do {
            try await commit { candidate in
                try LedgerMutationService.softDelete(transactionID, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法移至垃圾桶：\(error.localizedDescription)"
        }
    }

    func restoreTransaction(_ transactionID: UUID) async {
        do {
            try await commit { candidate in
                try LedgerMutationService.restore(transactionID, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法還原交易：\(error.localizedDescription)"
        }
    }

    func addAccount(name: String, type: AccountType, currencyCode: String = "TWD", openingAmount: Decimal = 0, statementDay: Int = 1) async {
        do {
            let normalizedCurrency = currencyCode.uppercased()
            guard type.isInvestment || normalizedCurrency == state.baseCurrencyCode else {
                errorMessage = "目前尚未設定可信匯率；日常帳戶必須使用 \(state.baseCurrencyCode)，外幣請建立股票或 Crypto 投資帳戶。"
                return
            }
            let enteredOpening = try Money.from(decimal: openingAmount, currencyCode: currencyCode, fractionDigits: CurrencyScale.fractionDigits(for: currencyCode))
            let opening = type.isLiability ? try enteredOpening.negated() : enteredOpening
            let account = Account(
                name: name,
                type: type,
                currencyCode: currencyCode,
                openingBalance: opening,
                creditCard: type == .creditCard ? CreditCardMetadata(statementDay: statementDay) : nil,
                loan: type == .loan ? LoanMetadata(lenderName: name) : nil
            )
            try await commit { candidate in
                candidate.accounts.append(account)
                AuditService.append(to: &candidate, entityID: account.id, entityType: "Account", action: .create, after: account)
            }
        } catch {
            errorMessage = "請輸入有效的帳戶幣別與期初金額。"
        }
    }

    func addCategory(name: String, kind: CategoryKind) async {
        do {
            try await commit { candidate in
                let category = Category(name: name, kind: kind, sortOrder: candidate.categories.count)
                candidate.categories.append(category)
                AuditService.append(to: &candidate, entityID: category.id, entityType: "Category", action: .create, after: category)
            }
        } catch {
            errorMessage = "無法儲存分類：\(error.localizedDescription)"
        }
    }

    func renameCategory(_ categoryID: UUID, to name: String) async {
        do {
            try await commit { candidate in
                guard let index = candidate.categories.firstIndex(where: { $0.id == categoryID && $0.deletedAt == nil }) else { return }
                let before = candidate.categories[index]
                candidate.categories[index].name = name
                candidate.categories[index].updatedAt = Date()
                AuditService.append(to: &candidate, entityID: categoryID, entityType: "Category", action: .update, before: before, after: candidate.categories[index])
            }
        } catch {
            errorMessage = "無法修改分類：\(error.localizedDescription)"
        }
    }

    func setAccountIncludedInNetWorth(_ accountID: UUID, included: Bool) async {
        do {
            try await commit { candidate in
                guard let index = candidate.accounts.firstIndex(where: { $0.id == accountID && $0.deletedAt == nil }) else { return }
                let before = candidate.accounts[index]
                candidate.accounts[index].includeInNetWorth = included
                candidate.accounts[index].updatedAt = Date()
                AuditService.append(to: &candidate, entityID: accountID, entityType: "Account", action: .update, before: before, after: candidate.accounts[index])
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法更新淨資產設定：\(error.localizedDescription)"
        }
    }

    func softDeleteAccount(_ accountID: UUID) async {
        do {
            try await commit { candidate in
                guard let index = candidate.accounts.firstIndex(where: { $0.id == accountID && $0.deletedAt == nil }) else { return }
                guard !candidate.transactions.contains(where: { $0.deletedAt == nil && ($0.draft.accountID == accountID || $0.draft.counterpartyAccountID == accountID) }),
                      !candidate.assets.contains(where: { $0.deletedAt == nil && $0.accountID == accountID }) else {
                    throw LedgerError.incompatibleAccountType
                }
                let before = candidate.accounts[index]
                candidate.accounts[index].deletedAt = Date()
                candidate.accounts[index].updatedAt = Date()
                AuditService.append(to: &candidate, entityID: accountID, entityType: "Account", action: .softDelete, before: before, after: candidate.accounts[index])
            }
        } catch {
            errorMessage = "無法刪除帳戶：帳戶仍有交易或持倉；請先移除相關資料。"
        }
    }

    func setHideAmounts(_ hidden: Bool) async {
        do {
            try await commit { $0.settings.hideAmounts = hidden }
        } catch {
            errorMessage = "無法保存隱私設定：\(error.localizedDescription)"
        }
    }

    func softDeleteCategory(_ categoryID: UUID) async {
        do {
            try await commit { candidate in
                guard let index = candidate.categories.firstIndex(where: { $0.id == categoryID && $0.deletedAt == nil }) else { return }
                let before = candidate.categories[index]
                candidate.categories[index].deletedAt = Date()
                candidate.categories[index].updatedAt = Date()
                AuditService.append(to: &candidate, entityID: categoryID, entityType: "Category", action: .softDelete, before: before, after: candidate.categories[index])
            }
        } catch {
            errorMessage = "無法移除分類：\(error.localizedDescription)"
        }
    }

    func reorderCategories(_ orderedIDs: [UUID]) async {
        do {
            try await commit { candidate in
                for (offset, id) in orderedIDs.enumerated() {
                    guard let index = candidate.categories.firstIndex(where: { $0.id == id }) else { continue }
                    let before = candidate.categories[index]
                    candidate.categories[index].sortOrder = offset
                    candidate.categories[index].updatedAt = Date()
                    AuditService.append(to: &candidate, entityID: id, entityType: "Category", action: .update, before: before, after: candidate.categories[index])
                }
            }
        } catch {
            errorMessage = "無法調整分類順序：\(error.localizedDescription)"
        }
    }

    func setBudget(categoryID: UUID, limit: Money, month: MonthKey = LocalDate.today().monthKey, isAnnual: Bool = false) async {
        guard limit.isPositive,
              limit.currencyCode == state.baseCurrencyCode,
              state.categories.contains(where: { $0.id == categoryID && $0.kind == .expense && $0.deletedAt == nil })
        else {
            errorMessage = "預算必須為正數，且套用在目前有效的支出分類。"
            return
        }
        do {
            try await commit { candidate in
                if let index = candidate.budgets.firstIndex(where: { $0.categoryID == categoryID && ($0.isAnnual == true) == isAnnual && (isAnnual ? $0.month.year == month.year : $0.month == month) && $0.deletedAt == nil }) {
                    let before = candidate.budgets[index]
                    candidate.budgets[index].limit = limit
                    candidate.budgets[index].updatedAt = Date()
                    AuditService.append(to: &candidate, entityID: candidate.budgets[index].id, entityType: "Budget", action: .update, before: before, after: candidate.budgets[index])
                } else {
                    let budget = Budget(categoryID: categoryID, month: month, limit: limit, isAnnual: isAnnual)
                    candidate.budgets.append(budget)
                    AuditService.append(to: &candidate, entityID: budget.id, entityType: "Budget", action: .create, after: budget)
                }
            }
        } catch {
            errorMessage = "無法儲存預算：\(error.localizedDescription)"
        }
    }

    func addRecurring(dayOfMonth: Int, template: TransactionDraft) async {
        guard (1 ... 31).contains(dayOfMonth) else {
            errorMessage = "固定收扣款日期必須在每月 1 到 31 日。"
            return
        }
        do {
            try await commit { candidate in
                try LedgerService.validate(template, in: candidate)
                let recurring = RecurringTransaction(dayOfMonth: dayOfMonth, template: template)
                candidate.recurringTransactions.append(recurring)
                AuditService.append(to: &candidate, entityID: recurring.id, entityType: "RecurringTransaction", action: .create, after: recurring)
            }
        } catch {
            errorMessage = "無法建立固定收扣款：\(error.localizedDescription)"
        }
    }

    func deleteBudgets(_ ids: Set<UUID>) async {
        do {
            try await commit { candidate in
                for index in candidate.budgets.indices where ids.contains(candidate.budgets[index].id) && candidate.budgets[index].deletedAt == nil {
                    let before = candidate.budgets[index]
                    candidate.budgets[index].deletedAt = Date()
                    candidate.budgets[index].updatedAt = Date()
                    AuditService.append(to: &candidate, entityID: before.id, entityType: "Budget", action: .softDelete, before: before, after: candidate.budgets[index])
                }
            }
        } catch { errorMessage = "無法刪除預算：\(error.localizedDescription)" }
    }

    func markRecurringNotOccurred(recurrenceID: UUID, on date: LocalDate) async {
        do {
            try await commit { candidate in
                try RecurringTransactionService.markNotOccurred(recurrenceID: recurrenceID, on: date, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法標記固定收扣款未發生：\(error.localizedDescription)"
        }
    }

    func reverseRecurringOccurrence(recurrenceID: UUID, on date: LocalDate) async {
        do {
            try await commit { candidate in
                try RecurringTransactionService.reverseOccurrence(recurrenceID: recurrenceID, on: date, in: &candidate)
                Self.refreshCategoryUsage(in: &candidate)
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法撤銷固定收扣款：\(error.localizedDescription)"
        }
    }

    func addInvestmentAsset(accountID: UUID, symbol: String, name: String, market: InvestmentMarket, currencyCode: String) async {
        guard let account = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }), account.type.isInvestment else {
            errorMessage = "請先選擇股票或 Crypto 帳戶。"
            return
        }
        guard (account.type == .crypto && market == .crypto) || (account.type == .stock && market != .crypto) else {
            errorMessage = "資產市場與帳戶類型不相符。"
            return
        }
        guard (try? Money(minorUnits: 0, currencyCode: currencyCode)) != nil else {
            errorMessage = "報價幣別必須是三碼代號。"
            return
        }
        let asset = InvestmentAsset(accountID: accountID, symbol: symbol, name: name, market: market, currencyCode: currencyCode)
        do {
            try await commit { candidate in
                candidate.assets.append(asset)
                AuditService.append(to: &candidate, entityID: asset.id, entityType: "InvestmentAsset", action: .create, after: asset)
            }
        } catch {
            errorMessage = "無法儲存投資資產：\(error.localizedDescription)"
        }
    }

    func backupData() throws -> Data { try LedgerBackupCodec.export(state) }

    func restoreBackup(_ data: Data) async {
        do {
            var restored = try LedgerBackupCodec.restore(data)
            try LedgerMutationService.validateIntegrity(restored)
            Self.refreshCategoryUsage(in: &restored)
            try SnapshotService.upsert(for: .today(), in: &restored)
            try await replaceState(with: restored, preservingCurrentRecovery: true)
            noticeMessage = "完整資料已還原；還原前資料已儲存為本機復原點。"
        } catch {
            errorMessage = "無法還原備份：\(error.localizedDescription)"
        }
    }

    func restoreRecoveryCheckpoint(_ checkpoint: RecoveryCheckpoint) async {
        do {
            let data = try await repository.recoveryData(for: checkpoint)
            await restoreBackup(data)
        } catch {
            errorMessage = "無法讀取本機復原點：\(error.localizedDescription)"
        }
    }

    func csvData() -> Data { Data(LedgerBackupCodec.csvExport(transactions: state.transactions).utf8) }

    func refreshQuotes() async {
        let assets = state.assets.filter { $0.deletedAt == nil }
        let quotes = state.quotes
        let baseCurrency = state.baseCurrencyCode
        let exchange = FrankfurterExchangeRateProvider()
        var refreshed: [UUID: PriceQuote] = [:]
        for asset in assets {
            let provider: any QuoteProvider = asset.market == .crypto ? BinancePublicQuoteProvider() : YahooFinanceQuoteProvider()
            let existing = quotes.first(where: { $0.assetID == asset.id })
            let result = await QuoteRefreshService.refresh(asset: asset, provider: provider, existingQuote: existing)
            switch result {
            case var .updated(quote):
                if quote.currencyCode != baseCurrency,
                   let rate = try? await exchange.rate(from: quote.currencyCode, to: baseCurrency) {
                    quote.baseCurrencyPrice = quote.price * rate
                    quote.baseCurrencyCode = baseCurrency
                }
                refreshed[asset.id] = quote
            case let .retainedStale(quote?):
                refreshed[asset.id] = quote
            case .retainedStale(nil):
                break
            }
        }
        do {
            try await commit { candidate in
                for (assetID, quote) in refreshed where candidate.assets.contains(where: { $0.id == assetID && $0.deletedAt == nil }) {
                    if let index = candidate.quotes.firstIndex(where: { $0.assetID == assetID }) {
                        candidate.quotes[index] = quote
                    } else {
                        candidate.quotes.append(quote)
                    }
                }
                try SnapshotService.upsert(for: .today(), in: &candidate)
            }
        } catch {
            errorMessage = "無法更新行情快照；已保留既有資料。"
        }
    }

    var dashboard: DashboardValues {
        let today = LocalDate.today()
        let summary = (try? CashFlowCalculator.summary(for: today.monthKey, in: state)) ?? .zero(currency: state.baseCurrencyCode)
        let netWorth = (try? NetWorthCalculator.calculate(in: state)) ?? .zero(currency: state.baseCurrencyCode)
        let baseZero = Money.zero(currencyCode: state.baseCurrencyCode)
        let todayRange = LedgerDateRange(singleDay: today)
        let todayExpense = (try? CashFlowCalculator.summary(in: todayRange, state: state).livingExpenses) ?? baseZero
        let categorySpend = (try? CashFlowCalculator.expensesByCategory(for: today.monthKey, in: state)) ?? [:]
        let hasBudgetAlert = state.budgets.contains { budget in
            guard budget.deletedAt == nil, budget.isAnnual != true, budget.month == today.monthKey, let spent = categorySpend[budget.categoryID] else { return false }
            return (try? BudgetService.status(spent: spent, limit: budget.limit)) == .overLimit
        }
        let hasExpenseAnomaly = state.categories.contains { category in
            guard category.deletedAt == nil, category.kind == .expense,
                  let insight = try? SpendingInsightService.insight(categoryID: category.id, asOf: today, in: state)
            else { return false }
            return insight.anomaly.isAnomalous
        }
        return DashboardValues(
            netWorth: netWorth.netWorth,
            todayExpense: todayExpense,
            availableBalance: (try? summary.availableBalance()) ?? baseZero,
            hasAnomaly: hasExpenseAnomaly,
            hasBudgetAlert: hasBudgetAlert
        )
    }
}

struct DashboardValues {
    var netWorth: Money
    var todayExpense: Money
    var availableBalance: Money
    var hasAnomaly: Bool
    var hasBudgetAlert: Bool
}

extension CashFlowSummary {
    static func zero(currency: String) -> CashFlowSummary {
        let zero = Money.zero(currencyCode: currency)
        return CashFlowSummary(ordinaryIncome: zero, livingExpenses: zero, investmentContributions: zero, realizedInvestmentGains: zero, dividendIncome: zero)
    }
}

extension NetWorthResult {
    static func zero(currency: String) -> NetWorthResult {
        let zero = Money.zero(currencyCode: currency)
        return NetWorthResult(totalAssets: zero, totalLiabilities: zero, netWorth: zero, cashValue: zero, stockValue: zero, cryptoValue: zero, otherAssetValue: zero, liabilityValue: zero, warnings: [])
    }
}

enum DefaultLedgerData {
    static func make() -> LedgerState {
        let account = Account(name: "現金", type: .cash)
        let categories = [
            Category(name: "餐飲", kind: .expense), Category(name: "交通", kind: .expense),
            Category(name: "娛樂", kind: .expense), Category(name: "購物", kind: .expense),
            Category(name: "居住", kind: .expense), Category(name: "醫療", kind: .expense),
            Category(name: "訂閱", kind: .expense), Category(name: "薪資", kind: .income),
            Category(name: "投資收益", kind: .investmentIncome), Category(name: "其他", kind: .expense),
        ]
        return LedgerState(accounts: [account], categories: categories)
    }
}
