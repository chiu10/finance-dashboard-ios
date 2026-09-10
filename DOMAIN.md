# FinanceDashboard domain model

## Glossary

- **Daily cash flow** — salary and actual living income or spending. It excludes transfers, investment principal, loan principal, and unrealized gains.
- **Available balance** — ordinary income minus living spending minus cash invested during the current month. Dividends and realized investment gains remain separately visible and do not increase this number.
- **Account** — a named container for cash, bank funds, liabilities, or an investment venue. `includeInNetWorth` controls whether it contributes to net worth.
- **Transaction** — an immutable financial event. Corrections create audit history; deletion is soft for 30 days.
- **Investment contribution** — cash exchanged for an investment position. It reduces available balance but is not daily spending.
- **Position** — the quantity and cost basis of one asset in a stock or crypto account.
- **Occurrence** — one idempotent materialization of a recurring transaction for one recurrence and date.

## Actors and goals

- A **person** records daily activity, reviews assets and liabilities, restores data, and controls privacy with local biometric authentication.
- The app provides a correct local ledger first; a future sync provider can copy the same durable ledger to the user's account.

## Boundaries and ownership

- `FinanceCore` owns ledger rules and never depends on SwiftUI, Face ID, a database, or an external price API.
- SwiftUI owns display and user input only.
- Local persistence owns serialization, migrations, audit retention, backup, and soft-delete maintenance.
- Quote providers own public market requests. Failure preserves the last valid quote and marks it stale; no provider may replace an unknown price with zero.

## Entities, values, states, and events

- `Money` is an integer amount in a declared smallest currency unit. Display input uses `Decimal`, then converts exactly; financial calculations never use `Double`. Market quotes retain an exact `Decimal` price so sub-cent crypto prices are not truncated before valuation.
- A liability account stores its derived balance as a negative signed amount internally, while its UI presents the debt as a positive amount. This keeps account deltas and net-worth subtraction unambiguous.
- `AccountType` is one of cash, bank, credit card, stock, crypto, loan, other asset, or other liability.
- `TransactionKind` expresses income, expense, transfer, credit-card charge/payment, loan payment, investment buy/sell, or dividend.
- `Budget` applies to one expense category for one calendar month.
- `RecurringTransaction` creates one `RecurringOccurrence` per scheduled date, never more.
- `NetWorthSnapshot` has at most one effective value per calendar day; later same-day updates replace it.

## Invariants

1. Monetary amounts are positive integer minor units, except derived signed account balances.
2. A transfer has two distinct accounts and changes neither daily income nor daily spending.
3. A credit-card charge adds daily spending and increases a liability; its later payment only transfers cash to reduce that liability.
4. A loan payment reduces liability by principal and adds daily spending only for interest.
5. An investment purchase reduces funding cash and increases investment contribution, but not living spending. A sale returns proceeds, derives its cost basis from the current average cost, and records only its realized gain as investment return.
6. Unrealized investment gains affect net worth only. Dividends affect investment return and receiving cash but not available balance.
7. A missing or failed quote retains the last successful price and timestamp. If no successful quote exists yet, net worth uses the recorded base-currency cost temporarily and labels that fallback instead of treating the asset as zero.
8. Deleted records keep audit history and `deletedAt` for 30 days before permanent maintenance removes the record.
9. No mutation may silently discard a record, historical value, migration warning, or audit entry.
10. A restored ledger with duplicate account UUIDs is rejected before it can overwrite local data.
11. A restored active transaction is revalidated in chronological order before it can overwrite local data; a historical soft-deleted category remains valid for its old records.
12. A partial investment sale uses rounded average cost at the currency's smallest unit, leaving the residual cost in the final remaining position.
13. Each account's opening balance must use that account's declared currency before the ledger is persisted or restored.

## Scenarios and edge cases

- Invalid type, date, non-finite quantity, zero/negative amount, or incompatible account type is rejected before persistence.
- A same-day recurring sync is idempotent even after application restart because occurrence keys are stored; opening after its scheduled day catches up once using the scheduled date. A day such as the 31st runs on that month's last valid calendar day.
- A category with sparse history uses a lower-confidence linear forecast rather than pretending the six-month curve is certain.
- Currency conversion is deliberately not guessed. A missing conversion must be surfaced as a warning instead of silently summing incompatible currencies.
- Daily income, spending, card, loan, dividend, and investment-cash transactions must use the ledger base currency until a trusted FX provider is configured; investment venues may still use their own quote currency.

## Decisions

- **D1 — Core ledger is pure Swift.** This makes Case A–L testable without iOS services or personal data.
- **D2 — Money uses integer minor units.** This is exact, portable, and simpler to audit than binary floating point.
- **D3 — iOS persistence is file-backed and versioned initially.** It is offline-first, backup-friendly, and has a clear migration envelope. A sync provider remains a boundary rather than being embedded in views.
- **D4 — Existing HTML baseline remains untouched.** It is preserved as repository history while the new product is a native iPhone target.
- **D5 — Schema version 3 adds backupable privacy/sync settings and exact Decimal quote migration.** Older backups retain every decoded record, including legacy Money quotes, and receive a migration warning rather than being overwritten or guessed.
- **D6 — Net-worth growth uses the change after the starting daily snapshot.** Liability movement is shown as context but is not added a second time when the same charge or interest is already in daily cash flow; any remainder remains visibly unclassified.

## Open questions

- Which base currency and FX provider should be used for mixed TWD/USD portfolios? Until chosen, the app must report excluded incompatible valuations.
- Which authenticated cloud account/backend should implement the sync protocol? No provider credentials or private APIs are required for the local-first build.
