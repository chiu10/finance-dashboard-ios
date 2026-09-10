import Foundation

public struct VersionedLedgerBackup: Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var state: LedgerState

    public init(state: LedgerState, exportedAt: Date = Date()) {
        self.schemaVersion = LedgerState.currentSchemaVersion
        self.exportedAt = exportedAt
        self.state = state
    }
}

public enum LedgerBackupCodec {
    public static func export(_ state: LedgerState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(VersionedLedgerBackup(state: state))
    }

    public static func restore(_ data: Data) throws -> LedgerState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(VersionedLedgerBackup.self, from: data)
        return try LedgerMigration.migrate(backup.state, from: backup.schemaVersion)
    }

    public static func csvExport(transactions: [LedgerTransaction]) -> String {
        let header = "id,date,type,amountMinor,currency,description,member,tags,receiptCount"
        let rows = transactions.filter { $0.deletedAt == nil }.map { transaction in
            let draft = transaction.draft
            return [
                transaction.id.uuidString,
                draft.occurredOn.iso8601,
                draft.kind.rawValue,
                String(draft.amount.minorUnits),
                draft.amount.currencyCode,
                csvEscape(draft.description),
                csvEscape(draft.member ?? ""),
                csvEscape((draft.tags ?? []).joined(separator: ", ")),
                String(draft.receiptImages?.count ?? 0),
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public enum LedgerMigration {
    public static func migrate(_ state: LedgerState, from schemaVersion: Int) throws -> LedgerState {
        guard schemaVersion <= LedgerState.currentSchemaVersion else { throw LedgerError.unsupportedSchema }
        var migrated = state
        if schemaVersion < LedgerState.currentSchemaVersion {
            migrated.migrationWarnings.append(MigrationWarning(sourceVersion: schemaVersion, message: "Migrated ledger without discarding records."))
        }
        migrated.schemaVersion = LedgerState.currentSchemaVersion
        return migrated
    }
}

public actor LedgerRepository {
    private let fileURL: URL

    private var recoveryDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("restore-checkpoints", isDirectory: true)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LedgerState() }
        return try LedgerBackupCodec.restore(Data(contentsOf: fileURL))
    }

    public func save(_ state: LedgerState) throws {
        try LedgerMutationService.validateIntegrity(state)
        let data = try LedgerBackupCodec.export(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeProtected(data, to: fileURL)
    }

    public func createRecoveryCheckpoint(from state: LedgerState, now: Date = Date()) throws -> RecoveryCheckpoint {
        try LedgerMutationService.validateIntegrity(state)
        let checkpoint = RecoveryCheckpoint(id: "pre-restore-\(UUID().uuidString)", createdAt: now)
        let url = try recoveryURL(for: checkpoint)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try writeProtected(LedgerBackupCodec.export(state), to: url)
        return checkpoint
    }

    public func recoveryCheckpoints() throws -> [RecoveryCheckpoint] {
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                guard id.hasPrefix("pre-restore-") else { return nil }
                let values = try? url.resourceValues(forKeys: [.creationDateKey])
                return RecoveryCheckpoint(id: id, createdAt: values?.creationDate ?? .distantPast)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func recoveryData(for checkpoint: RecoveryCheckpoint) throws -> Data {
        try Data(contentsOf: recoveryURL(for: checkpoint))
    }

    private func recoveryURL(for checkpoint: RecoveryCheckpoint) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard checkpoint.id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw LedgerError.invalidRecoveryCheckpoint }
        return recoveryDirectory.appendingPathComponent(checkpoint.id).appendingPathExtension("json")
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}

public enum AuditService {
    public static func append<T: Encodable>(
        to state: inout LedgerState,
        entityID: UUID,
        entityType: String,
        action: AuditAction,
        before: T? = nil,
        after: T? = nil,
        at timestamp: Date = Date()
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func snapshot(_ value: T?) -> String? {
            guard let value, let data = try? encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        state.auditLogs.append(AuditLog(
            entityID: entityID,
            entityType: entityType,
            action: action,
            timestamp: timestamp,
            beforeSnapshot: snapshot(before),
            afterSnapshot: snapshot(after)
        ))
    }
}

public enum LedgerMutationService {
    @discardableResult
    public static func add(_ draft: TransactionDraft, to state: inout LedgerState, now: Date = Date()) throws -> LedgerTransaction {
        if let recurrenceID = draft.recurrenceID,
           let occurrenceKey = draft.occurrenceKey,
           state.transactions.contains(where: { $0.deletedAt == nil && $0.draft.recurrenceID == recurrenceID && $0.draft.occurrenceKey == occurrenceKey }) {
            throw LedgerError.duplicateOccurrence
        }
        let transaction = try LedgerService.makeTransaction(from: draft, in: state, now: now)
        var candidate = state
        candidate.transactions.append(transaction)
        try validateIntegrity(candidate)
        AuditService.append(to: &candidate, entityID: transaction.id, entityType: "LedgerTransaction", action: .create, after: transaction, at: now)
        state = candidate
        return transaction
    }

    public static func replace(_ transactionID: UUID, with draft: TransactionDraft, in state: inout LedgerState, now: Date = Date()) throws {
        guard let index = state.transactions.firstIndex(where: { $0.id == transactionID && $0.deletedAt == nil }) else { throw LedgerError.missingTransaction }
        let before = state.transactions[index]
        var candidate = state
        candidate.transactions.remove(at: index)
        var replacement = try LedgerService.makeTransaction(from: draft, in: candidate, now: now)
        replacement.id = before.id
        replacement.createdAt = before.createdAt
        replacement.updatedAt = now
        candidate.transactions.insert(replacement, at: index)
        try validateIntegrity(candidate)
        AuditService.append(to: &candidate, entityID: transactionID, entityType: "LedgerTransaction", action: .update, before: before, after: replacement, at: now)
        state = candidate
    }

    public static func softDelete(_ transactionID: UUID, in state: inout LedgerState, now: Date = Date()) throws {
        guard let index = state.transactions.firstIndex(where: { $0.id == transactionID && $0.deletedAt == nil }) else { throw LedgerError.missingTransaction }
        let before = state.transactions[index]
        var candidate = state
        candidate.transactions[index].deletedAt = now
        candidate.transactions[index].updatedAt = now
        try validateIntegrity(candidate)
        AuditService.append(to: &candidate, entityID: transactionID, entityType: "LedgerTransaction", action: .softDelete, before: before, after: candidate.transactions[index], at: now)
        state = candidate
    }

    public static func restore(_ transactionID: UUID, in state: inout LedgerState, now: Date = Date()) throws {
        guard let index = state.transactions.firstIndex(where: { $0.id == transactionID && $0.deletedAt != nil }) else { throw LedgerError.missingTransaction }
        let before = state.transactions[index]
        var candidate = state
        candidate.transactions[index].deletedAt = nil
        candidate.transactions[index].updatedAt = now
        try validateIntegrity(candidate)
        AuditService.append(to: &candidate, entityID: transactionID, entityType: "LedgerTransaction", action: .restore, before: before, after: candidate.transactions[index], at: now)
        state = candidate
    }

    public static func purgeDeleted(olderThan days: Int = 30, in state: inout LedgerState, now: Date = Date()) {
        guard days >= 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        // Entity tombstones stay because transaction history and audit records may still reference them.
        state.transactions.removeAll { $0.deletedAt.map { $0 < cutoff } ?? false }
    }

    public static func validateIntegrity(_ state: LedgerState) throws {
        guard Set(state.accounts.map(\.id)).count == state.accounts.count else { throw LedgerError.duplicateEntityID }
        for account in state.accounts {
            guard account.openingBalance.currencyCode == account.currencyCode else { throw LedgerError.currencyMismatch }
        }
        var historicalState = state
        historicalState.transactions = []
        for index in historicalState.categories.indices {
            // Historical records retain their category after the user soft-deletes it.
            historicalState.categories[index].deletedAt = nil
        }
        let activeTransactions = state.transactions
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.draft.occurredOn != rhs.draft.occurredOn { return lhs.draft.occurredOn < rhs.draft.occurredOn }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        for transaction in activeTransactions {
            try LedgerService.validate(transaction.draft, in: historicalState)
            historicalState.transactions.append(transaction)
        }
        for budget in state.budgets where budget.deletedAt == nil {
            guard budget.limit.isPositive, budget.limit.currencyCode == state.baseCurrencyCode else { throw LedgerError.invalidAmount }
        }
        _ = try InvestmentCalculator.positions(in: state)
        for quote in state.quotes {
            guard quote.price > 0, quote.currencyCode.count == 3 else { throw LedgerError.invalidQuote }
            if let basePrice = quote.baseCurrencyPrice {
                guard basePrice > 0, quote.baseCurrencyCode?.count == 3 else { throw LedgerError.invalidQuote }
            }
        }
        let balances = try AccountBalanceCalculator.balances(in: state)
        for account in state.accounts where account.deletedAt == nil && account.type.isLiability {
            guard let balance = balances[account.id], balance.minorUnits <= 0 else { throw LedgerError.invalidLiabilityBalance }
        }
    }
}

public enum RecurringTransactionService {
    @discardableResult
    public static func materializeDue(on date: LocalDate, in state: inout LedgerState, now: Date = Date()) throws -> [LedgerTransaction] {
        var candidate = state
        var generated: [LedgerTransaction] = []
        let active = candidate.recurringTransactions.filter { $0.deletedAt == nil && $0.isActive }
        for recurring in active {
            guard (1 ... 31).contains(recurring.dayOfMonth) else { throw LedgerError.invalidRecurringDay }
            let lastOccurrence = candidate.occurrences
                .filter { $0.recurrenceID == recurring.id }
                .map(\.date)
                .max()
            let createdParts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: recurring.createdAt)
            let createdMonth = MonthKey(year: createdParts.year ?? date.year, month: createdParts.month ?? date.month)
            let templateMonth = recurring.template.occurredOn.monthKey
            let firstEligibleMonth = max(createdMonth, templateMonth)
            let firstMonth = max(lastOccurrence.flatMap { nextMonth(after: $0.monthKey) } ?? firstEligibleMonth, firstEligibleMonth)
            var month = firstMonth
            while month <= date.monthKey {
                let scheduledDay = min(recurring.dayOfMonth, try month.daysInMonth())
                let scheduledDate = try LocalDate(year: month.year, month: month.month, day: scheduledDay)
                if scheduledDate <= date,
                   !candidate.occurrences.contains(where: { $0.recurrenceID == recurring.id && $0.date == scheduledDate }) {
                    var draft = recurring.template
                    draft.occurredOn = scheduledDate
                    draft.recurrenceID = recurring.id
                    draft.occurrenceKey = "\(recurring.id.uuidString)-\(scheduledDate.iso8601)"
                    let transaction = try LedgerMutationService.add(draft, to: &candidate, now: now)
                    candidate.occurrences.append(RecurringOccurrence(recurrenceID: recurring.id, date: scheduledDate, transactionID: transaction.id, status: .created, createdAt: now))
                    generated.append(transaction)
                }
                guard let next = nextMonth(after: month) else { break }
                month = next
            }
        }
        state = candidate
        return generated
    }

    private static func nextMonth(after month: MonthKey) -> MonthKey? {
        if month.month == 12 { return MonthKey(year: month.year + 1, month: 1) }
        return MonthKey(year: month.year, month: month.month + 1)
    }

    public static func markNotOccurred(recurrenceID: UUID, on date: LocalDate, in state: inout LedgerState, now: Date = Date()) throws {
        try updateOccurrence(recurrenceID: recurrenceID, on: date, status: .skipped, in: &state, now: now)
    }

    public static func reverseOccurrence(recurrenceID: UUID, on date: LocalDate, in state: inout LedgerState, now: Date = Date()) throws {
        try updateOccurrence(recurrenceID: recurrenceID, on: date, status: .reversed, in: &state, now: now)
    }

    private static func updateOccurrence(recurrenceID: UUID, on date: LocalDate, status: RecurrenceStatus, in state: inout LedgerState, now: Date) throws {
        var candidate = state
        guard let index = candidate.occurrences.firstIndex(where: { $0.recurrenceID == recurrenceID && $0.date == date }) else { throw LedgerError.missingOccurrence }
        if let transactionID = candidate.occurrences[index].transactionID,
           candidate.transactions.contains(where: { $0.id == transactionID && $0.deletedAt == nil }) {
            try LedgerMutationService.softDelete(transactionID, in: &candidate, now: now)
        }
        candidate.occurrences[index].status = status
        state = candidate
    }
}

public enum SnapshotService {
    public static func upsert(for date: LocalDate, in state: inout LedgerState, now: Date = Date()) throws {
        let netWorth = try NetWorthCalculator.calculate(in: state)
        let snapshot = NetWorthSnapshot(
            id: state.snapshots.first(where: { $0.date == date })?.id ?? UUID(),
            date: date,
            totalAssets: netWorth.totalAssets,
            totalLiabilities: netWorth.totalLiabilities,
            netWorth: netWorth.netWorth,
            cashValue: netWorth.cashValue,
            stockValue: netWorth.stockValue,
            cryptoValue: netWorth.cryptoValue,
            otherAssetValue: netWorth.otherAssetValue,
            liabilityValue: netWorth.liabilityValue,
            updatedAt: now
        )
        if let index = state.snapshots.firstIndex(where: { $0.date == date }) {
            state.snapshots[index] = snapshot
        } else {
            state.snapshots.append(snapshot)
        }
    }
}
