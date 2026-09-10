import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var backupDocument = LedgerFileDocument(data: Data())
    @State private var csvDocument = LedgerFileDocument(data: Data())
    @State private var exportingBackup = false
    @State private var exportingCSV = false
    @State private var importing = false
    @State private var pendingRestoreData: Data?

    var body: some View {
        NavigationStack {
            Form {
                Section("隱私") {
                    Toggle("隱藏金額", isOn: Binding(
                        get: { model.state.settings.hideAmounts },
                        set: { hidden in Task { await model.setHideAmounts(hidden) } }
                    ))
                    Button("重新要求 Face ID") { Task { await model.requireAuthentication() } }
                }
                Section("資料") {
                    NavigationLink("交易紀錄") { LedgerHistoryView() }
                    NavigationLink("預算規劃（每月）") { BudgetManagerView() }
                    NavigationLink("固定收扣款") { RecurringManagerView() }
                    NavigationLink("管理分類") { CategoryManagerView() }
                    NavigationLink("成員與標籤") { MemberTagManagerView() }
                    NavigationLink("垃圾桶") { TrashView() }
                    NavigationLink("還原前復原點") { RecoveryCheckpointView() }
                    Button("匯出 CSV") {
                        csvDocument = LedgerFileDocument(data: model.csvData())
                        exportingCSV = true
                    }
                    Button("完整資料備份") {
                        do {
                            backupDocument = LedgerFileDocument(data: try model.backupData())
                            exportingBackup = true
                        } catch { model.errorMessage = "無法建立備份。" }
                    }
                    Button("完整資料還原") { importing = true }
                }
                Section("同步") {
                    Text("目前為離線優先。本機資料不會自動傳送；日後可接上使用者選定的同步提供者。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
        }
        .fileExporter(isPresented: $exportingBackup, document: backupDocument, contentType: .json, defaultFilename: "FinanceDashboard-backup") { result in
            if case .failure = result { model.errorMessage = "備份匯出失敗。" }
        }
        .fileExporter(isPresented: $exportingCSV, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: "FinanceDashboard-transactions") { result in
            if case .failure = result { model.errorMessage = "CSV 匯出失敗。" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            guard url.startAccessingSecurityScopedResource() else { model.errorMessage = "無法讀取選取的備份。"; return }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                pendingRestoreData = try Data(contentsOf: url)
            } catch { model.errorMessage = "無法讀取選取的備份。" }
        }
        .confirmationDialog("完整資料還原？", isPresented: Binding(get: { pendingRestoreData != nil }, set: { if !$0 { pendingRestoreData = nil } }), titleVisibility: .visible) {
            Button("建立復原點後還原", role: .destructive) {
                guard let data = pendingRestoreData else { return }
                pendingRestoreData = nil
                Task { await model.restoreBackup(data) }
            }
        } message: {
            Text("目前資料會先新增一個本機復原點，再覆寫為選取的完整備份。")
        }
    }
}

private struct MemberTagManagerView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    private var members: [String] {
        Set(model.state.transactions.compactMap { $0.deletedAt == nil ? $0.draft.member : nil }.filter { !$0.isEmpty }).sorted()
    }
    private var tags: [String] {
        Set(model.state.transactions.filter { $0.deletedAt == nil }.flatMap { $0.draft.tags ?? [] }.filter { !$0.isEmpty }).sorted()
    }
    var body: some View {
        List {
            Section("成員（由交易自動整理）") {
                if members.isEmpty { Text("尚無成員") } else { ForEach(members, id: \.self, content: Text.init) }
            }
            Section("標籤（由交易自動整理）") {
                if tags.isEmpty { Text("尚無標籤") } else { ForEach(tags, id: \.self, content: Text.init) }
            }
        }
        .navigationTitle("成員與標籤")
    }
}

private struct RecoveryCheckpointView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var selectedCheckpoint: RecoveryCheckpoint?

    var body: some View {
        List {
            Section {
                Text("每次資料變更與完整資料還原前，App 都會保留目前資料的本機復原點；選擇還原時會再建立一個新的復原點。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("復原點") {
                ForEach(model.recoveryCheckpoints) { checkpoint in
                    HStack {
                        Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Button("還原") { selectedCheckpoint = checkpoint }
                            .buttonStyle(.bordered)
                    }
                }
                if model.recoveryCheckpoints.isEmpty { Text("尚無本機復原點。") }
            }
        }
        .navigationTitle("復原點")
        .confirmationDialog("還原此復原點？", isPresented: Binding(get: { selectedCheckpoint != nil }, set: { if !$0 { selectedCheckpoint = nil } }), titleVisibility: .visible) {
            if let checkpoint = selectedCheckpoint {
                Button("還原", role: .destructive) {
                    Task { await model.restoreRecoveryCheckpoint(checkpoint) }
                }
            }
        } message: {
            Text("目前資料會先新增一個本機復原點，之後才進行還原。")
        }
    }
}

private struct CategoryManagerView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @State private var showsAdd = false

    private var categories: [Category] {
        model.state.categories.filter { $0.deletedAt == nil }.sorted {
            $0.useCount == $1.useCount ? $0.sortOrder < $1.sortOrder : $0.useCount > $1.useCount
        }
    }

    var body: some View {
        List {
            ForEach(categories) { category in
                NavigationLink { EditCategoryView(category: category) } label: {
                    HStack { Text(category.name); Spacer(); Text(category.kind.localizedName).foregroundStyle(.secondary) }
                }
            }
            .onDelete { offsets in
                for index in offsets { Task { await model.softDeleteCategory(categories[index].id) } }
            }
            .onMove { source, destination in
                var reordered = categories
                reordered.move(fromOffsets: source, toOffset: destination)
                Task { await model.reorderCategories(reordered.map(\.id)) }
            }
        }
        .navigationTitle("分類")
        .toolbar {
            EditButton()
            Button("新增", systemImage: "plus") { showsAdd = true }
        }
        .sheet(isPresented: $showsAdd) { AddCategoryView() }
    }
}

private struct AddCategoryView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: CategoryKind = .expense

    var body: some View {
        NavigationStack {
            Form {
                TextField("分類名稱", text: $name)
                Picker("類型", selection: $kind) {
                    Text("支出").tag(CategoryKind.expense)
                    Text("收入").tag(CategoryKind.income)
                    Text("投資收益").tag(CategoryKind.investmentIncome)
                }
            }
            .navigationTitle("新增分類")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task { await model.addCategory(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind); dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct EditCategoryView: View {
    @EnvironmentObject private var model: FinanceDashboardModel
    @Environment(\.dismiss) private var dismiss
    let category: Category
    @State private var name: String

    init(category: Category) {
        self.category = category
        _name = State(initialValue: category.name)
    }

    var body: some View {
        Form {
            TextField("分類名稱", text: $name)
            LabeledContent("類型", value: category.kind.localizedName)
        }
        .navigationTitle("修改分類")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") {
                    Task {
                        await model.renameCategory(category.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct LedgerFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
