import Foundation

public struct LocalDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { throw LedgerError.invalidDate }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        guard components.isValidDate else { throw LedgerError.invalidDate }
        self.year = year
        self.month = month
        self.day = day
    }

    private init(validatedYear: Int, month: Int, day: Int) {
        year = validatedYear
        self.month = month
        self.day = day
    }

    public init(iso8601: String) throws {
        let parts = iso8601.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { throw LedgerError.invalidDate }
        try self.init(year: year, month: month, day: day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var monthKey: MonthKey { MonthKey(year: year, month: month) }

    public func date(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func today(timeZone: TimeZone = .current) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        guard let year = components.year, let month = components.month, let day = components.day else {
            return LocalDate(validatedYear: 1970, month: 1, day: 1)
        }
        return (try? LocalDate(year: year, month: month, day: day)) ?? LocalDate(validatedYear: 1970, month: 1, day: 1)
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: container.decode(Int.self, forKey: .year),
            month: container.decode(Int.self, forKey: .month),
            day: container.decode(Int.self, forKey: .day)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(year, forKey: .year)
        try container.encode(month, forKey: .month)
        try container.encode(day, forKey: .day)
    }
}

public struct MonthKey: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    public func daysInMonth() throws -> Int {
        guard (1 ... 12).contains(month) else { throw LedgerError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let firstDay = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: firstDay)
        else { throw LedgerError.invalidDate }
        return range.count
    }
}

public struct LedgerDateRange: Codable, Hashable, Sendable {
    public var start: LocalDate
    public var end: LocalDate

    public init(start: LocalDate, end: LocalDate) throws {
        guard start <= end else { throw LedgerError.invalidDate }
        self.start = start
        self.end = end
    }

    public init(singleDay date: LocalDate) {
        start = date
        end = date
    }

    public func contains(_ date: LocalDate) -> Bool { start <= date && date <= end }
}

public enum AccountType: String, Codable, CaseIterable, Sendable {
    case cash
    case bank
    case creditCard
    case stock
    case crypto
    case loan
    case otherAsset
    case otherLiability

    public var isInvestment: Bool { self == .stock || self == .crypto }
    public var isLiability: Bool { self == .creditCard || self == .loan || self == .otherLiability }
}

public struct CreditCardMetadata: Codable, Hashable, Sendable {
    public var statementDay: Int
    public var paymentDay: Int?

    public init(statementDay: Int, paymentDay: Int? = nil) {
        self.statementDay = statementDay
        self.paymentDay = paymentDay
    }
}

public struct LoanMetadata: Codable, Hashable, Sendable {
    public var lenderName: String
    public var annualInterestRate: Decimal?

    public init(lenderName: String, annualInterestRate: Decimal? = nil) {
        self.lenderName = lenderName
        self.annualInterestRate = annualInterestRate
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var type: AccountType
    public var currencyCode: String
    public var includeInNetWorth: Bool
    public var openingBalance: Money
    public var creditCard: CreditCardMetadata?
    public var loan: LoanMetadata?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        currencyCode: String = "TWD",
        includeInNetWorth: Bool = true,
        openingBalance: Money? = nil,
        creditCard: CreditCardMetadata? = nil,
        loan: LoanMetadata? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        let normalizedCurrency = currencyCode.uppercased()
        self.currencyCode = normalizedCurrency.count == 3 ? normalizedCurrency : "TWD"
        self.includeInNetWorth = includeInNetWorth
        self.openingBalance = openingBalance ?? .zero(currencyCode: self.currencyCode)
        self.creditCard = creditCard
        self.loan = loan
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum CategoryKind: String, Codable, Sendable {
    case income
    case expense
    case investmentIncome
}

public struct Category: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CategoryKind
    public var sortOrder: Int
    public var useCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), name: String, kind: CategoryKind, sortOrder: Int = 0,
        useCount: Int = 0, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sortOrder = sortOrder
        self.useCount = useCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case income
    case expense
    case transfer
    case creditCardCharge
    case creditCardPayment
    case loanPayment
    case investmentBuy
    case investmentSell
    case dividend
}

public struct TransactionDraft: Codable, Hashable, Sendable {
    public var kind: TransactionKind
    public var occurredOn: LocalDate
    public var accountID: UUID
    public var counterpartyAccountID: UUID?
    public var amount: Money
    public var categoryID: UUID?
    public var description: String
    public var assetID: UUID?
    public var quantity: Decimal?
    public var costBasis: Money?
    public var principal: Money?
    public var interest: Money?
    public var fee: Money?
    public var member: String?
    public var tags: [String]?
    // Receipt bytes travel with the complete backup and recovery checkpoints.
    public var receiptImages: [Data]?
    public var recurrenceID: UUID?
    public var occurrenceKey: String?

    public init(
        kind: TransactionKind,
        occurredOn: LocalDate,
        accountID: UUID,
        counterpartyAccountID: UUID? = nil,
        amount: Money,
        categoryID: UUID? = nil,
        description: String = "",
        assetID: UUID? = nil,
        quantity: Decimal? = nil,
        costBasis: Money? = nil,
        principal: Money? = nil,
        interest: Money? = nil,
        fee: Money? = nil,
        member: String? = nil,
        tags: [String]? = nil,
        receiptImages: [Data]? = nil,
        recurrenceID: UUID? = nil,
        occurrenceKey: String? = nil
    ) {
        self.kind = kind
        self.occurredOn = occurredOn
        self.accountID = accountID
        self.counterpartyAccountID = counterpartyAccountID
        self.amount = amount
        self.categoryID = categoryID
        self.description = description
        self.assetID = assetID
        self.quantity = quantity
        self.costBasis = costBasis
        self.principal = principal
        self.interest = interest
        self.fee = fee
        self.member = member
        self.tags = tags
        self.receiptImages = receiptImages
        self.recurrenceID = recurrenceID
        self.occurrenceKey = occurrenceKey
    }
}

public struct LedgerTransaction: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var draft: TransactionDraft
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), draft: TransactionDraft, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.draft = draft
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum InvestmentMarket: String, Codable, Sendable { case taiwan, unitedStates, crypto }

public struct InvestmentAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var symbol: String
    public var name: String
    public var market: InvestmentMarket
    public var currencyCode: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), accountID: UUID, symbol: String, name: String, market: InvestmentMarket,
        currencyCode: String = "TWD", createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.symbol = symbol.uppercased()
        self.name = name
        self.market = market
        self.currencyCode = currencyCode.uppercased()
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct PriceQuote: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var assetID: UUID
    /// A quote is an exact Decimal because assets such as crypto can trade below one cent.
    public var price: Decimal
    public var currencyCode: String
    public var timestamp: Date
    public var source: String
    public var isStale: Bool
    /// The quote converted to the ledger base currency when a trusted FX rate is available.
    public var baseCurrencyPrice: Decimal?
    public var baseCurrencyCode: String?

    public init(
        id: UUID = UUID(), assetID: UUID, price: Decimal, currencyCode: String,
        timestamp: Date = Date(), source: String, isStale: Bool = false,
        baseCurrencyPrice: Decimal? = nil, baseCurrencyCode: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.price = price
        let normalizedCurrency = currencyCode.uppercased()
        self.currencyCode = normalizedCurrency.count == 3 ? normalizedCurrency : "TWD"
        self.timestamp = timestamp
        self.source = source
        self.isStale = isStale
        self.baseCurrencyPrice = baseCurrencyPrice
        let normalizedBaseCurrency = baseCurrencyCode?.uppercased()
        self.baseCurrencyCode = normalizedBaseCurrency?.count == 3 ? normalizedBaseCurrency : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, price, currencyCode, timestamp, source, isStale, baseCurrencyPrice, baseCurrencyCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        source = try container.decode(String.self, forKey: .source)
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false

        let decodedCurrency = try container.decodeIfPresent(String.self, forKey: .currencyCode)?.uppercased()
        if let decodedPrice = try? container.decode(Decimal.self, forKey: .price) {
            price = decodedPrice
            if let decodedCurrency, decodedCurrency.count == 3 {
                currencyCode = decodedCurrency
            } else {
                currencyCode = "TWD"
            }
        } else {
            let legacyPrice = try container.decode(Money.self, forKey: .price)
            price = legacyPrice.decimalValue(fractionDigits: CurrencyScale.fractionDigits(for: legacyPrice.currencyCode))
            if let decodedCurrency, decodedCurrency.count == 3 {
                currencyCode = decodedCurrency
            } else {
                currencyCode = legacyPrice.currencyCode
            }
        }

        let decodedBaseCurrency = try container.decodeIfPresent(String.self, forKey: .baseCurrencyCode)?.uppercased()
        if let decodedBasePrice = try? container.decode(Decimal.self, forKey: .baseCurrencyPrice) {
            baseCurrencyPrice = decodedBasePrice
            baseCurrencyCode = decodedBaseCurrency?.count == 3 ? decodedBaseCurrency : nil
        } else if let legacyBasePrice = try? container.decode(Money.self, forKey: .baseCurrencyPrice) {
            baseCurrencyPrice = legacyBasePrice.decimalValue(fractionDigits: CurrencyScale.fractionDigits(for: legacyBasePrice.currencyCode))
            baseCurrencyCode = decodedBaseCurrency?.count == 3 ? decodedBaseCurrency : legacyBasePrice.currencyCode
        } else {
            baseCurrencyPrice = nil
            baseCurrencyCode = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(price, forKey: .price)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(source, forKey: .source)
        try container.encode(isStale, forKey: .isStale)
        try container.encodeIfPresent(baseCurrencyPrice, forKey: .baseCurrencyPrice)
        try container.encodeIfPresent(baseCurrencyCode, forKey: .baseCurrencyCode)
    }
}

public struct Budget: Codable, Identifiable, Hashable, Sendable {
    /// Missing on older backups means a monthly budget.
    public var isAnnual: Bool?
    public var id: UUID
    public var categoryID: UUID
    public var month: MonthKey
    public var limit: Money
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), categoryID: UUID, month: MonthKey, limit: Money, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil, isAnnual: Bool? = nil) {
        self.isAnnual = isAnnual
        self.id = id
        self.categoryID = categoryID
        self.month = month
        self.limit = limit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct RecurringTransaction: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var dayOfMonth: Int
    public var template: TransactionDraft
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), dayOfMonth: Int, template: TransactionDraft, isActive: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.dayOfMonth = dayOfMonth
        self.template = template
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum RecurrenceStatus: String, Codable, Sendable { case created, skipped, reversed }

public struct RecurringOccurrence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var recurrenceID: UUID
    public var date: LocalDate
    public var transactionID: UUID?
    public var status: RecurrenceStatus
    public var createdAt: Date

    public init(id: UUID = UUID(), recurrenceID: UUID, date: LocalDate, transactionID: UUID?, status: RecurrenceStatus, createdAt: Date = Date()) {
        self.id = id
        self.recurrenceID = recurrenceID
        self.date = date
        self.transactionID = transactionID
        self.status = status
        self.createdAt = createdAt
    }
}

public struct NetWorthSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: LocalDate
    public var totalAssets: Money
    public var totalLiabilities: Money
    public var netWorth: Money
    public var cashValue: Money
    public var stockValue: Money
    public var cryptoValue: Money
    public var otherAssetValue: Money
    public var liabilityValue: Money
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), date: LocalDate, totalAssets: Money, totalLiabilities: Money, netWorth: Money,
        cashValue: Money, stockValue: Money, cryptoValue: Money, otherAssetValue: Money, liabilityValue: Money,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.totalAssets = totalAssets
        self.totalLiabilities = totalLiabilities
        self.netWorth = netWorth
        self.cashValue = cashValue
        self.stockValue = stockValue
        self.cryptoValue = cryptoValue
        self.otherAssetValue = otherAssetValue
        self.liabilityValue = liabilityValue
        self.updatedAt = updatedAt
    }
}

public enum AuditAction: String, Codable, Sendable { case create, update, softDelete, restore, migration }

public struct AuditLog: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var entityID: UUID
    public var entityType: String
    public var action: AuditAction
    public var timestamp: Date
    public var beforeSnapshot: String?
    public var afterSnapshot: String?

    public init(id: UUID = UUID(), entityID: UUID, entityType: String, action: AuditAction, timestamp: Date = Date(), beforeSnapshot: String? = nil, afterSnapshot: String? = nil) {
        self.id = id
        self.entityID = entityID
        self.entityType = entityType
        self.action = action
        self.timestamp = timestamp
        self.beforeSnapshot = beforeSnapshot
        self.afterSnapshot = afterSnapshot
    }
}

public struct MigrationWarning: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceVersion: Int
    public var message: String
    public var createdAt: Date

    public init(id: UUID = UUID(), sourceVersion: Int, message: String, createdAt: Date = Date()) {
        self.id = id
        self.sourceVersion = sourceVersion
        self.message = message
        self.createdAt = createdAt
    }
}

public struct RecoveryCheckpoint: Identifiable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date

    public init(id: String, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct LedgerSettings: Codable, Hashable, Sendable {
    public var hideAmounts: Bool
    public var syncProviderIdentifier: String

    public init(hideAmounts: Bool = false, syncProviderIdentifier: String = "offline-only") {
        self.hideAmounts = hideAmounts
        self.syncProviderIdentifier = syncProviderIdentifier
    }

    private enum CodingKeys: String, CodingKey { case hideAmounts, syncProviderIdentifier }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideAmounts = try container.decodeIfPresent(Bool.self, forKey: .hideAmounts) ?? false
        let identifier = try container.decodeIfPresent(String.self, forKey: .syncProviderIdentifier) ?? "offline-only"
        syncProviderIdentifier = identifier.isEmpty ? "offline-only" : identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hideAmounts, forKey: .hideAmounts)
        try container.encode(syncProviderIdentifier, forKey: .syncProviderIdentifier)
    }
}

public struct LedgerState: Codable, Sendable {
    public static let currentSchemaVersion = 4
    public var schemaVersion: Int
    public var baseCurrencyCode: String
    public var accounts: [Account]
    public var categories: [Category]
    public var transactions: [LedgerTransaction]
    public var assets: [InvestmentAsset]
    public var quotes: [PriceQuote]
    public var budgets: [Budget]
    public var recurringTransactions: [RecurringTransaction]
    public var occurrences: [RecurringOccurrence]
    public var snapshots: [NetWorthSnapshot]
    public var auditLogs: [AuditLog]
    public var migrationWarnings: [MigrationWarning]
    public var settings: LedgerSettings

    public init(
        schemaVersion: Int = LedgerState.currentSchemaVersion,
        baseCurrencyCode: String = "TWD",
        accounts: [Account] = [], categories: [Category] = [], transactions: [LedgerTransaction] = [],
        assets: [InvestmentAsset] = [], quotes: [PriceQuote] = [], budgets: [Budget] = [],
        recurringTransactions: [RecurringTransaction] = [], occurrences: [RecurringOccurrence] = [],
        snapshots: [NetWorthSnapshot] = [], auditLogs: [AuditLog] = [], migrationWarnings: [MigrationWarning] = [],
        settings: LedgerSettings = LedgerSettings()
    ) {
        self.schemaVersion = schemaVersion
        let normalizedCurrency = baseCurrencyCode.uppercased()
        self.baseCurrencyCode = normalizedCurrency.count == 3 ? normalizedCurrency : "TWD"
        self.accounts = accounts
        self.categories = categories
        self.transactions = transactions
        self.assets = assets
        self.quotes = quotes
        self.budgets = budgets
        self.recurringTransactions = recurringTransactions
        self.occurrences = occurrences
        self.snapshots = snapshots
        self.auditLogs = auditLogs
        self.migrationWarnings = migrationWarnings
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseCurrencyCode, accounts, categories, transactions, assets, quotes, budgets
        case recurringTransactions, occurrences, snapshots, auditLogs, migrationWarnings, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let decodedCurrency = (try container.decodeIfPresent(String.self, forKey: .baseCurrencyCode) ?? "TWD").uppercased()
        baseCurrencyCode = decodedCurrency.count == 3 ? decodedCurrency : "TWD"
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        categories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? []
        transactions = try container.decodeIfPresent([LedgerTransaction].self, forKey: .transactions) ?? []
        assets = try container.decodeIfPresent([InvestmentAsset].self, forKey: .assets) ?? []
        quotes = try container.decodeIfPresent([PriceQuote].self, forKey: .quotes) ?? []
        budgets = try container.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
        recurringTransactions = try container.decodeIfPresent([RecurringTransaction].self, forKey: .recurringTransactions) ?? []
        occurrences = try container.decodeIfPresent([RecurringOccurrence].self, forKey: .occurrences) ?? []
        snapshots = try container.decodeIfPresent([NetWorthSnapshot].self, forKey: .snapshots) ?? []
        auditLogs = try container.decodeIfPresent([AuditLog].self, forKey: .auditLogs) ?? []
        migrationWarnings = try container.decodeIfPresent([MigrationWarning].self, forKey: .migrationWarnings) ?? []
        settings = try container.decodeIfPresent(LedgerSettings.self, forKey: .settings) ?? LedgerSettings()
    }
}

public enum LedgerError: Error, Equatable, Sendable {
    case invalidDate
    case missingAccount
    case missingTransaction
    case deletedAccount
    case incompatibleAccountType
    case missingCounterparty
    case sameTransferAccount
    case invalidAmount
    case missingCategory
    case invalidCategory
    case missingAsset
    case invalidQuantity
    case invalidCostBasis
    case invalidLoanSplit
    case invalidLiabilityBalance
    case invalidRecurringDay
    case duplicateOccurrence
    case missingOccurrence
    case currencyMismatch
    case unsupportedSchema
    case invalidRecoveryCheckpoint
    case invalidQuote
    case duplicateEntityID
}
