// ExpenseViews.swift
// Phase 9 / Expenses v1.1 — list + create/edit + detail views
//
// UX directive (user, 2026-05-11): "make it user friendly"
// - Minimum taps from open-app to expense-captured (Office Staff
//   bulk upload should be ≤3 taps per receipt)
// - Big touch targets, iPad-first layout
// - Defaults that work (auto vendor/date/amount where possible)
// - Friction only on irreversible actions (Approve / Reject /
//   Mark Paid / Delete)
// - Plain-language status copy
//
// Not yet in this file:
// - Approval queue UI → ExpenseApprovalQueueView (next commit)
// - PDF report renderer → ExpensePDFRenderer (next commit)
// - CSV export → blocked on Helen's accounting-software answer

import SwiftUI
import PhotosUI
import Combine

// MARK: - Expense List View

struct ExpenseListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false
    @State private var filterState: ExpenseApprovalState? = nil
    @State private var searchText = ""

    private var filtered: [Expense] {
        store.expenses
            .filter { !$0.isDeleted }
            .filter { e in
                if let s = filterState, e.approvalState != s { return false }
                if searchText.isEmpty { return true }
                let q = searchText.lowercased()
                return e.vendor.lowercased().contains(q)
                    || e.expenseNumber.lowercased().contains(q)
                    || e.memo.lowercased().contains(q)
            }
            .sorted { $0.expenseDate > $1.expenseDate }
    }

    private var totalAmount: Decimal {
        filtered.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar — total + count for current filter
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total")
                        .font(.caption).foregroundColor(.secondary)
                    Text(totalAmount.currencyString)
                        .font(.headline.weight(.semibold))
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filtered.count == 1 ? "Expense" : "Expenses")
                        .font(.caption).foregroundColor(.secondary)
                    Text("\(filtered.count)")
                        .font(.headline.weight(.semibold))
                }
                Spacer()
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All", value: nil)
                    filterChip("Pending", value: .pendingApproval)
                    filterChip("Approved", value: .approved)
                    filterChip("Paid", value: .paid)
                    filterChip("Rejected", value: .rejected)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))

            // List
            if filtered.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No expenses yet" : "No matches",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Tap the + button to add your first expense."
                        : "Try a different search.")
                )
            } else {
                List {
                    ForEach(filtered) { expense in
                        NavigationLink {
                            ExpenseDetailView(expenseID: expense.id)
                                .environmentObject(store)
                        } label: {
                            ExpenseRow(expense: expense)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText)
            }
        }
        .navigationTitle("Expenses")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: {
                    Label("New Expense", systemImage: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                ExpenseCreateEditView(expense: nil)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func filterChip(_ label: String, value: ExpenseApprovalState?) -> some View {
        let selected = filterState == value
        Button {
            filterState = value
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(selected ? .white : .primary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Expense Row

private struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: expense.category.icon)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.vendor.isEmpty ? "(no vendor)" : expense.vendor)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(expense.expenseDate.shortDate)
                    Text("·")
                    Text(expense.category.displayName)
                    if expense.isReimbursable {
                        Text("·")
                        Label("Reimbursable", systemImage: "person.fill.badge.plus")
                            .labelStyle(.iconOnly)
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(expense.amount.currencyString)
                    .font(.subheadline.weight(.semibold))
                ApprovalStateBadge(state: expense.approvalState)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ApprovalStateBadge: View {
    let state: ExpenseApprovalState

    private var color: Color {
        switch state {
        case .draft:            return .gray
        case .pendingApproval:  return .orange
        case .autoApproved:     return .green
        case .approved:         return .green
        case .rejected:         return .red
        case .paid:             return .blue
        }
    }

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - Create / Edit

struct ExpenseCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let originalExpense: Expense?

    @State private var vendor: String = ""
    @State private var expenseDate: Date = Date()
    @State private var amountText: String = ""
    @State private var memo: String = ""
    @State private var category: ExpenseCategory = .other
    @State private var paymentMethod: ExpensePaymentMethod = .companyCard
    @State private var destination: ExpenseDestination = .company
    @State private var projectID: UUID? = nil
    @State private var materialRequestID: UUID? = nil
    @State private var companyDestinationLabel: String = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var pendingAttachments: [ExpenseAttachment] = []
    @State private var saveError: String? = nil

    init(expense: Expense?) {
        self.originalExpense = expense
        if let e = expense {
            _vendor                   = State(initialValue: e.vendor)
            _expenseDate              = State(initialValue: e.expenseDate)
            _amountText               = State(initialValue: NSDecimalNumber(decimal: e.amount).stringValue)
            _memo                     = State(initialValue: e.memo)
            _category                 = State(initialValue: e.category)
            _paymentMethod            = State(initialValue: e.paymentMethod)
            _destination              = State(initialValue: e.destination)
            _projectID                = State(initialValue: e.projectID)
            _materialRequestID        = State(initialValue: e.materialRequestID)
            _companyDestinationLabel  = State(initialValue: e.companyDestinationLabel)
        }
    }

    private var parsedAmount: Decimal {
        Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canSave: Bool {
        guard !vendor.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard parsedAmount > 0 else { return false }
        switch destination {
        case .project:         return projectID != nil
        case .materialRequest: return materialRequestID != nil
        case .company:         return true
        }
    }

    var body: some View {
        Form {
            // Required: vendor + amount up front for fast capture.
            Section("Receipt") {
                TextField("Vendor *", text: $vendor)
                    .textInputAutocapitalization(.words)
                DatePicker("Date", selection: $expenseDate, displayedComponents: .date)
                HStack {
                    Text("Amount *")
                    Spacer()
                    Text("$").foregroundColor(.secondary)
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
                Picker("Category", selection: $category) {
                    ForEach(ExpenseCategory.allCases, id: \.self) { c in
                        Label(c.displayName, systemImage: c.icon).tag(c)
                    }
                }
                Picker("Paid By", selection: $paymentMethod) {
                    ForEach(ExpensePaymentMethod.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
            }

            // Cost destination — Single source of truth for where the
            // money lands (Company / Project / Material Request).
            Section {
                Picker("Charge to", selection: $destination) {
                    Text("Company").tag(ExpenseDestination.company)
                    Text("Project").tag(ExpenseDestination.project)
                    Text("Material Request").tag(ExpenseDestination.materialRequest)
                }
                .pickerStyle(.segmented)

                switch destination {
                case .company:
                    TextField("Bucket (e.g. Office, Insurance)", text: $companyDestinationLabel)
                case .project:
                    Picker("Project", selection: $projectID) {
                        Text("Choose a project…").tag(UUID?.none)
                        ForEach(store.projects.filter { !$0.isDeleted }) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                case .materialRequest:
                    Picker("Material Request", selection: $materialRequestID) {
                        Text("Choose an MR…").tag(UUID?.none)
                        ForEach(store.materialRequests.filter { !$0.isDeleted }) { mr in
                            Text(mr.requestNumber).tag(Optional(mr.id))
                        }
                    }
                }
            } header: {
                Text("Cost Destination")
            }

            // Attachments — primary receipt + optional supplementary.
            // Photo library only for v1 (camera add comes via the row's
            // Camera button which we can wire if requested; spec says
            // photo + PDF upload for v1.0).
            Section {
                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images
                ) {
                    Label(
                        pendingAttachments.isEmpty
                            ? "Add Receipt Photo"
                            : "Add Another",
                        systemImage: "camera.fill"
                    )
                }
                .onChange(of: selectedPhoto) { _, item in
                    Task { await loadPhoto(item) }
                }
                if !pendingAttachments.isEmpty {
                    ForEach(pendingAttachments) { att in
                        HStack {
                            Image(systemName: att.fileType.icon)
                                .foregroundColor(.accentColor)
                            Text(att.fileName).lineLimit(1)
                            Spacer()
                            Text(att.displaySize)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Attachments")
            } footer: {
                Text("Receipts are required for auto-approval under $250. Otherwise the expense flags as 'Missing Receipt' and goes to manager review.")
            }

            // Memo
            Section("Memo (optional)") {
                TextField("Notes for accounting / approver", text: $memo, axis: .vertical)
                    .lineLimit(3...6)
            }

            if let err = saveError {
                Section {
                    Text(err).foregroundColor(.red).font(.caption)
                }
            }
        }
        .navigationTitle(originalExpense == nil ? "New Expense" : "Edit Expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(originalExpense == nil ? "Save" : "Update") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let img = UIImage(data: data)
        let thumb = img?
            .preparingThumbnail(of: CGSize(width: 200, height: 200))?
            .jpegData(compressionQuality: 0.7)

        await MainActor.run {
            var att = ExpenseAttachment(expenseID: originalExpense?.id ?? UUID())
            att.companyID         = store.currentCompanyID
            att.fileName          = "receipt_\(Int(Date().timeIntervalSince1970)).jpg"
            att.fileType          = .image
            att.mimeType          = "image/jpeg"
            att.fileSizeBytes     = data.count
            att.fileData          = data
            att.thumbnailData     = thumb
            att.source            = .library
            att.isPrimaryReceipt  = pendingAttachments.isEmpty
            att.syncStatus        = .pending
            pendingAttachments.append(att)
            selectedPhoto = nil
        }
    }

    private func save() {
        guard canSave else {
            saveError = "Vendor + amount + destination are required."
            return
        }

        var expense = originalExpense ?? Expense()
        expense.companyID                = store.currentCompanyID
        expense.vendor                   = vendor.trimmingCharacters(in: .whitespaces)
        expense.expenseDate              = expenseDate
        expense.amount                   = parsedAmount
        expense.memo                     = memo.trimmingCharacters(in: .whitespaces)
        expense.category                 = category
        expense.paymentMethod            = paymentMethod
        expense.destination              = destination
        expense.projectID                = destination == .project ? projectID : nil
        expense.materialRequestID        = destination == .materialRequest ? materialRequestID : nil
        expense.companyDestinationLabel  = destination == .company ? companyDestinationLabel : ""
        expense.isReimbursable           = paymentMethod.requiresReimbursement
        expense.createdBy                = expense.createdBy ?? store.currentUser?.id
        expense.submittedBy              = store.currentUser?.id
        expense.expenseOwnerEmployeeID   = expense.expenseOwnerEmployeeID ?? store.currentUser?.id
        expense.submittedOnBehalfOf      = expense.createdBy != expense.expenseOwnerEmployeeID
        expense.updatedAt                = Date()
        expense.lastModifiedAt           = Date()
        expense.lastModifiedBy           = store.currentUser?.fullName ?? ""
        expense.syncStatus               = .pending

        // Auto-approve path: company-card under $250 with no flags.
        // Will be re-checked by ExpenseApprovalService once flags are
        // fully wired; for v1.1 the form handles the obvious case.
        if expense.qualifiesForAutoApproval(attachments: pendingAttachments + store.expenseAttachments) {
            expense.approvalState = .autoApproved
            expense.approvedAt    = Date()
        } else if expense.approvalState == .draft {
            expense.approvalState = .pendingApproval
        }

        // Assign expense_number — placeholder; proper monotonic
        // numbering comes via NumberGenerationService extension once
        // the EXP prefix is added (matches BV-EXP-2026-0001 pattern).
        if expense.expenseNumber.isEmpty {
            expense.expenseNumber = "BV-EXP-\(Calendar.current.component(.year, from: Date()))-\(String(format: "%04d", store.expenses.count + 1))"
        }

        // Bind every pending attachment to this expense
        let finalAttachments = pendingAttachments.map { a -> ExpenseAttachment in
            var copy = a
            copy.expenseID = expense.id
            copy.companyID = store.currentCompanyID
            return copy
        }

        store.upsertExpense(expense)
        for att in finalAttachments {
            store.upsertExpenseAttachment(att)
        }
        dismiss()
    }
}

// MARK: - Detail

struct ExpenseDetailView: View {
    @EnvironmentObject var store: AppStore
    let expenseID: UUID

    @State private var showEdit = false

    private var expense: Expense? {
        store.expenses.first(where: { $0.id == expenseID })
    }

    private var attachments: [ExpenseAttachment] {
        store.expenseAttachments.filter { $0.expenseID == expenseID && !$0.isDeleted }
    }

    var body: some View {
        if let expense {
            List {
                Section {
                    LabeledContent("Vendor", value: expense.vendor.isEmpty ? "—" : expense.vendor)
                    LabeledContent("Date", value: expense.expenseDate.shortDate)
                    LabeledContent("Amount", value: expense.amount.currencyString)
                    LabeledContent("Category", value: expense.category.displayName)
                    LabeledContent("Paid By", value: expense.paymentMethod.displayName)
                    LabeledContent("Status") { ApprovalStateBadge(state: expense.approvalState) }
                }

                Section("Destination") {
                    switch expense.destination {
                    case .company:
                        LabeledContent("Company expense", value: expense.companyDestinationLabel.isEmpty ? "—" : expense.companyDestinationLabel)
                    case .project:
                        let name = store.projects.first(where: { $0.id == expense.projectID })?.name ?? "Project"
                        LabeledContent("Project", value: name)
                    case .materialRequest:
                        let num = store.materialRequests.first(where: { $0.id == expense.materialRequestID })?.requestNumber ?? "—"
                        LabeledContent("Material Request", value: num)
                    }
                }

                if !attachments.isEmpty {
                    Section("Receipts (\(attachments.count))") {
                        ForEach(attachments) { att in
                            HStack {
                                Image(systemName: att.fileType.icon)
                                    .foregroundColor(.accentColor)
                                Text(att.fileName).lineLimit(1)
                                Spacer()
                                Text(att.displaySize)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if !expense.memo.isEmpty {
                    Section("Memo") {
                        Text(expense.memo)
                    }
                }

                Section("Identifiers") {
                    LabeledContent("Expense #", value: expense.expenseNumber)
                    LabeledContent("Created", value: expense.createdAt.shortDate)
                }
            }
            .navigationTitle(expense.vendor.isEmpty ? "Expense" : expense.vendor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showEdit = true }
                }
            }
            .sheet(isPresented: $showEdit) {
                NavigationStack {
                    ExpenseCreateEditView(expense: expense)
                        .environmentObject(store)
                }
            }
        } else {
            ContentUnavailableView(
                "Expense not found",
                systemImage: "exclamationmark.triangle",
                description: Text("This expense may have been deleted.")
            )
        }
    }
}

// MARK: - AppStore upsert helpers

extension AppStore {
    func upsertExpense(_ expense: Expense) {
        var e = expense
        if let i = expenses.firstIndex(where: { $0.id == e.id }) {
            expenses[i] = e
        } else {
            expenses.append(e)
        }
        Task { await SyncEngine.shared.pushPendingExpenses() }
        objectWillChange.send()
    }

    func upsertExpenseAttachment(_ attachment: ExpenseAttachment) {
        if let i = expenseAttachments.firstIndex(where: { $0.id == attachment.id }) {
            expenseAttachments[i] = attachment
        } else {
            expenseAttachments.append(attachment)
        }
        Task { await SyncEngine.shared.pushPendingExpenseAttachments() }
        objectWillChange.send()
    }
}
