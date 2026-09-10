import Foundation
import SwiftUI
import PhotosUI
import UIKit

private enum EntryMode: String, CaseIterable, Identifiable {
    case income = "收入"
    case expense = "支出"
    case transfer = "轉帳"
    var id: Self { self }
    var transactionKind: TransactionKind {
        switch self {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return .transfer
        }
    }
}

struct LedgerEntryView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var mode: EntryMode = .expense
    @State private var calculator = AmountCalculator()
    @State private var accountID: UUID?
    @State private var counterpartyID: UUID?
    @State private var categoryID: UUID?
    @State private var note = ""
    @State private var fee = ""
    @State private var member = "自己"
    @State private var tags = ""
    @State private var receiptSelection: [PhotosPickerItem] = []
    @State private var receipts: [Data] = []
    @State private var loadingReceipts = false
    @State private var isSaving = false
    @State private var showsCamera = false
    @State private var selectedDate = Date()

    private var activeAccounts: [Account] { model.state.accounts.filter { $0.deletedAt == nil } }
    private var transferAccounts: [Account] { activeAccounts.filter { !$0.type.isLiability && !$0.type.isInvestment } }
    private var entryAccounts: [Account] {
        switch mode {
        case .income: return activeAccounts.filter { !$0.type.isLiability && !$0.type.isInvestment }
        case .expense: return activeAccounts.filter { !$0.type.isInvestment && $0.type != .loan && $0.type != .otherLiability }
        case .transfer: return transferAccounts
        }
    }
    private var categories: [Category] {
        let kind: CategoryKind = mode == .income ? .income : .expense
        return model.state.categories.filter { $0.deletedAt == nil && $0.kind == kind }.sorted {
            $0.useCount == $1.useCount ? $0.sortOrder < $1.sortOrder : $0.useCount > $1.useCount
        }
    }
    private var selectedAccount: Account? {
        accountID.flatMap { selectedID in entryAccounts.first(where: { $0.id == selectedID }) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("類型", selection: $mode) {
                    ForEach(EntryMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in
                    categoryID = categories.first?.id
                    counterpartyID = nil
                    guard let accountID, entryAccounts.contains(where: { $0.id == accountID }) else {
                        self.accountID = entryAccounts.first?.id
                        return
                    }
                }

                Section("金額") {
                    Text(calculator.display).font(.largeTitle.monospacedDigit()).frame(maxWidth: .infinity, alignment: .trailing)
                    CalculatorKeypad(calculator: $calculator)
                }

                Section("交易資料") {
                    Picker("使用帳戶", selection: $accountID) {
                        Text("請選擇").tag(UUID?.none)
                        ForEach(entryAccounts) { account in Text(account.name).tag(Optional(account.id)) }
                    }
                    if mode == .expense,
                       let account = selectedAccount,
                       account.type == .creditCard,
                       let total = try? CreditCardService.currentStatementTotal(for: account, asOf: .today(), in: model.state) {
                        LabeledContent("目前本期已刷") { MoneyText(money: total, hidden: model.hideAmounts) }
                    }
                    if mode == .transfer {
                        Picker("轉入帳戶", selection: $counterpartyID) {
                            Text("請選擇").tag(UUID?.none)
                            ForEach(transferAccounts.filter { account in accountID.map { selectedID in selectedID != account.id } ?? true }) { account in Text(account.name).tag(Optional(account.id)) }
                        }
                        TextField("手續費（選填）", text: $fee).keyboardType(.decimalPad)
                    } else {
                        Picker("分類", selection: $categoryID) {
                            Text("請選擇").tag(UUID?.none)
                            ForEach(categories) { category in Text(category.name).tag(Optional(category.id)) }
                        }
                    }
                    DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                    TextField("備註（選填）", text: $note)
                    TextField("成員", text: $member)
                    TextField("標籤（以逗號分隔）", text: $tags)
                    PhotosPicker(selection: $receiptSelection, maxSelectionCount: 3, matching: .images) {
                        Label(loadingReceipts ? "載入收據中…" : "收據照片（\(receipts.count)/3）", systemImage: "photo")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showsCamera = true } label: { Label("拍攝收據", systemImage: "camera") }
                            .disabled(receipts.count >= 3 || loadingReceipts)
                    }
                    Text("照片隨完整備份保存；每張最多 5 MB。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button("完成") { submit() }
                    .frame(maxWidth: .infinity)
                    .disabled(isSaving || loadingReceipts || accountID == nil || (mode == .transfer && counterpartyID == nil) || (mode != .transfer && categoryID == nil))
            }
            .navigationTitle("記帳")
            .onAppear { selectDefaultsIfNeeded() }
            .task(id: receiptSelection) {
                loadingReceipts = true
                defer { loadingReceipts = false }
                do {
                    var loaded: [Data] = []
                    for selection in receiptSelection {
                        guard let data = try await selection.loadTransferable(type: Data.self), data.count <= 5_000_000 else {
                            throw LedgerError.invalidAmount
                        }
                        loaded.append(data)
                    }
                    try Task.checkCancellation()
                    receipts = loaded
                } catch is CancellationError {
                } catch { receipts = []; model.errorMessage = "收據照片無法載入，請選擇每張不超過 5 MB 的圖片。" }
            }
            .sheet(isPresented: $showsCamera) {
                CameraCaptureView { image in
                    if receipts.count < 3, let data = image.jpegData(compressionQuality: 0.82), data.count <= 5_000_000 {
                        receipts.append(data)
                    } else {
                        model.errorMessage = "照片最多 3 張，且每張不可超過 5 MB。"
                    }
                }
            }
        }
    }

    private func selectDefaultsIfNeeded() {
        if accountID == nil { accountID = entryAccounts.first?.id }
        if categoryID == nil { categoryID = categories.first?.id }
    }

    private func submit() {
        guard !isSaving else { return }
        guard let accountID, let account = entryAccounts.first(where: { $0.id == accountID }) else { return }
        do {
            let amount = try Money.from(
                decimal: calculator.value(),
                currencyCode: account.currencyCode,
                fractionDigits: CurrencyScale.fractionDigits(for: account.currencyCode)
            )
            guard amount.isPositive || (mode == .expense && amount.minorUnits != 0) else { throw LedgerError.invalidAmount }
            let transferFee: Money? = mode == .transfer && !fee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try moneyInput(fee, currencyCode: account.currencyCode)
                : nil
            if let transferFee, transferFee.minorUnits < 0 { throw LedgerError.invalidAmount }
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day], from: selectedDate)
            guard let year = components.year, let month = components.month, let day = components.day else { return }
            let date = try LocalDate(year: year, month: month, day: day)
            let transactionKind: TransactionKind = mode == .expense && account.type == .creditCard ? .creditCardCharge : mode.transactionKind
            let draft = TransactionDraft(
                kind: transactionKind,
                occurredOn: date,
                accountID: accountID,
                counterpartyAccountID: mode == .transfer ? counterpartyID : nil,
                amount: amount,
                categoryID: mode == .transfer ? nil : categoryID,
                description: note,
                fee: transferFee,
                member: member.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: tags.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                receiptImages: receipts
            )
            isSaving = true
            Task {
                defer { isSaving = false }
                guard await model.addTransaction(draft) else { return }
                calculator.clear()
                note = ""
                fee = ""
                receipts = []
                receiptSelection = []
                tags = ""
            }
        } catch {
            model.errorMessage = "收入、轉帳金額必須大於零；支出可輸入負數表示退款。"
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

private struct CalculatorKeypad: View {
    @Binding var calculator: AmountCalculator
    private let keys = ["7", "8", "9", "÷", "4", "5", "6", "×", "1", "2", "3", "−", "00", "0", "000", "+", ".", "⌫", "C", "="]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(keys, id: \.self) { key in
                Button(key) { tap(key) }
                    .buttonStyle(.bordered)
                    .font(.title3)
            }
        }
    }

    private func tap(_ key: String) {
        do {
            if key.allSatisfy(\.isNumber) {
                for digit in key { calculator.input(digit) }
            } else {
                switch key {
                case ".": calculator.decimalPoint()
            case "⌫": calculator.deleteLast()
            case "C": calculator.clear()
            case "=": _ = try calculator.equals()
            default:
                if let operation = ["+": CalculatorOperation.add, "−": .subtract, "×": .multiply, "÷": .divide][key] {
                    try calculator.apply(operation)
                }
                }
            }
        } catch {
            calculator.clear()
        }
    }
}
