// ChangeOrderViews.swift
// Aski IQ – Change Orders UI
// List → Detail → Create/Edit flow for change orders on active projects.

import SwiftUI

// MARK: - Global List (all projects)

struct ChangeOrderListView: View {
    @EnvironmentObject var store: AppStore

    /// When provided, filters to a single project.
    var projectID: UUID? = nil

    @State private var showCreate = false
    @State private var filterStatus: ChangeOrderStatus? = nil

    private var filtered: [ChangeOrder] {
        var list = projectID != nil
            ? store.changeOrders(for: projectID!)
            : store.changeOrders
        if let s = filterStatus { list = list.filter { $0.status == s } }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        COListBody(
            items: filtered,
            filterStatus: $filterStatus,
            projectID: projectID,
            showCreate: $showCreate
        )
        .navigationTitle(projectID != nil ? "Change Orders" : "All Change Orders")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.currentUserRole.canManageCOs {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            ChangeOrderCreateEditView(projectID: projectID ?? store.projects.first?.id ?? UUID())
        }
    }
}

// Extracted to keep body under 10 children
private struct COListBody: View {
    let items: [ChangeOrder]
    @Binding var filterStatus: ChangeOrderStatus?
    let projectID: UUID?
    @Binding var showCreate: Bool

    var body: some View {
        List {
            COFilterBar(filterStatus: $filterStatus)
            COSummaryRow(items: items)
            if items.isEmpty {
                COEmptyRow()
            } else {
                ForEach(items) { co in
                    NavigationLink(destination: ChangeOrderDetailView(changeOrder: co)) {
                        ChangeOrderRow(co: co, showProject: projectID == nil)
                    }
                }
            }
        }
    }
}

private struct COFilterBar: View {
    @Binding var filterStatus: ChangeOrderStatus?
    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: filterStatus == nil) {
                        filterStatus = nil
                    }
                    ForEach(ChangeOrderStatus.allCases, id: \.self) { s in
                        FilterChip(label: s.displayName, isSelected: filterStatus == s) {
                            filterStatus = filterStatus == s ? nil : s
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
            }
        }
    }
}

private struct COSummaryRow: View {
    let items: [ChangeOrder]
    var body: some View {
        let approved = items.filter { $0.status == .approved }
        let open     = items.filter { $0.status.isOpen }
        let total    = approved.reduce(Decimal(0)) { $0 + $1.effectiveCostImpact }
        Section {
            HStack(spacing: 0) {
                COStat(label: "Total COs",   value: "\(items.count)",        color: .primary)
                Divider().frame(height: 36)
                COStat(label: "Open",        value: "\(open.count)",         color: open.isEmpty ? .secondary : .orange)
                Divider().frame(height: 36)
                COStat(label: "Approved $",  value: total.currencyString,    color: total > 0 ? .green : .secondary)
            }
        }
    }
}

private struct COStat: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct COEmptyRow: View {
    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.largeTitle).foregroundColor(.secondary)
                Text("No change orders yet.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }
}

// MARK: - Row

struct ChangeOrderRow: View {
    @EnvironmentObject var store: AppStore
    let co: ChangeOrder
    var showProject: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                COStatusBadge(status: co.status)
                Spacer()
                Text(co.effectiveCostImpact.currencyString)
                    .font(.subheadline).bold()
                    .foregroundColor(co.effectiveCostImpact >= 0 ? .primary : .red)
            }
            Text(co.number).font(.caption2).foregroundColor(.secondary)
            Text(co.title).font(.subheadline).bold()
            if showProject, let proj = store.project(id: co.projectID) {
                Text(proj.name).font(.caption).foregroundColor(.secondary)
            }
            if co.scheduleImpactDays != 0 {
                Label("\(co.scheduleImpactDays > 0 ? "+" : "")\(co.scheduleImpactDays) days",
                      systemImage: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundColor(co.scheduleImpactDays > 0 ? .orange : .green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct ChangeOrderDetailView: View {
    @EnvironmentObject var store: AppStore
    @State private var co: ChangeOrder
    @State private var showEdit          = false
    @State private var showDeleteConfirm = false
    @State private var showShareSheet    = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF   = false

    // Email composer state
    @State private var showEmailSheet:  Bool = false
    @State private var pendingPDFData:  Data? = nil
    @State private var pendingFilename: String = ""
    @Environment(\.dismiss) var dismiss

    init(changeOrder: ChangeOrder) {
        _co = State(initialValue: changeOrder)
    }

    private var projectName: String? { store.project(id: co.projectID)?.name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CODetailHeader(co: co)
                CODetailFinancials(co: co)
                if !co.lineItems.isEmpty { CODetailLineItems(co: co) }
                CODetailInfo(co: co)
                CODetailDates(co: co)
                CODetailStatusActions(co: $co)
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(co.number)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if isGeneratingPDF {
                        ProgressView().tint(.blue)
                    } else {
                        Menu {
                            Button { exportPDF() } label: { Label("Share PDF…", systemImage: "square.and.arrow.up") }
                            Button { emailPDF() }  label: { Label("Email PDF to client…", systemImage: "envelope.fill") }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share or email this change order")
                    }
                    if store.currentUserRole.canManageCOs {
                        Menu {
                            Button { showEdit = true } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) { showDeleteConfirm = true } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: {
            if let updated = store.changeOrders.first(where: { $0.id == co.id }) { co = updated }
        }) {
            ChangeOrderCreateEditView(existing: co, projectID: co.projectID)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showEmailSheet) {
            if let pdf = pendingPDFData {
                EmailComposeSheet(
                    recipientSuggestions: coClientEmails,
                    defaultSubject: "Change Order \(co.number)",
                    defaultBody: coEmailBody,
                    pdfData: pdf,
                    pdfFilename: pendingFilename,
                    entityType: "change_order",
                    entityID: co.id,
                    clientID: store.project(id: co.projectID)?.clientID,
                    contactID: nil,
                    opportunityID: nil,
                    quoteID: nil,
                    projectID: co.projectID
                )
                .environmentObject(store)
            }
        }
        .confirmationDialog("Delete this change order?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteChangeOrder(co)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(store.$changeOrders) { all in
            if let updated = all.first(where: { $0.id == co.id }) { co = updated }
        }
    }

    // MARK: Email

    /// Render the change-order PDF and open the email composer with it attached.
    private func emailPDF() {
        isGeneratingPDF = true
        let capturedCO   = co
        let capturedProj = projectName
        let company      = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ" : AppSettings.shared.companyName
        Task.detached(priority: .userInitiated) {
            let pdf = ChangeOrderPDFRenderer(
                changeOrder: capturedCO,
                projectName: capturedProj,
                companyName: company
            ).render()
            let safe = capturedCO.number
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let filename = "ChangeOrder_\(safe).pdf"
            await MainActor.run {
                pendingPDFData  = pdf
                pendingFilename = filename
                isGeneratingPDF = false
                showEmailSheet  = true
            }
        }
    }

    private var coClientEmails: [String] {
        guard let cid = store.project(id: co.projectID)?.clientID else { return [] }
        var seen = Set<String>(); var out: [String] = []
        if let client = store.client(id: cid),
           let email  = client.contactEmail, !email.isEmpty,
           seen.insert(email.lowercased()).inserted {
            out.append(email)
        }
        for c in store.crmContacts where c.clientID == cid && !c.isDeleted {
            if !c.email.isEmpty, seen.insert(c.email.lowercased()).inserted {
                out.append(c.email)
            }
        }
        return out
    }

    private var coEmailBody: String {
        let proj = projectName ?? "the project"
        let signer = store.currentUser?.fullName.isEmpty == false
            ? store.currentUser!.fullName
            : AppSettings.shared.companyName
        let sign  = co.effectiveCostImpact >= 0 ? "+" : "−"
        let amt   = abs(co.effectiveCostImpact).currencyString
        return """
        Hello,

        Please find change order \(co.number) for \(proj) attached. Cost impact: \(sign)\(amt). Schedule impact: \(co.scheduleImpactDays) day\(co.scheduleImpactDays == 1 ? "" : "s").

        Reply once you've reviewed and signed off, or let me know if you'd like to discuss any of the line items.

        Thanks,
        \(signer)
        """
    }

    // MARK: PDF Export

    private func exportPDF() {
        isGeneratingPDF = true
        let capturedCO   = co
        let capturedProj = projectName
        let company      = AppSettings.shared.companyName.isEmpty
            ? "Aski IQ" : AppSettings.shared.companyName
        Task.detached(priority: .userInitiated) {
            let pdfData = ChangeOrderPDFRenderer(
                changeOrder: capturedCO,
                projectName: capturedProj,
                companyName: company
            ).render()
            let safe   = capturedCO.number.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let url    = FileManager.default.temporaryDirectory
                .appendingPathComponent("CO_\(safe).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems      = [url]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }
}

private struct CODetailHeader: View {
    let co: ChangeOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    COStatusBadge(status: co.status)
                    Text(co.title).font(.title3).bold()
                    Label(co.type.displayName, systemImage: co.type.icon)
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding().background(Color(.secondarySystemBackground))
        .cornerRadius(16).padding(.horizontal)
    }
}

private struct CODetailFinancials: View {
    let co: ChangeOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Financial Impact").font(.headline).padding(.horizontal)
            HStack(spacing: 0) {
                COFinStat(label: "Cost Impact",
                          value: co.effectiveCostImpact.currencyString,
                          color: co.effectiveCostImpact >= 0 ? .primary : .red)
                Divider().frame(height: 48)
                COFinStat(label: "Schedule",
                          value: co.scheduleImpactDays == 0 ? "None" : "\(co.scheduleImpactDays > 0 ? "+" : "")\(co.scheduleImpactDays)d",
                          color: co.scheduleImpactDays > 0 ? .orange : co.scheduleImpactDays < 0 ? .green : .secondary)
                if let clientRef = co.clientReferenceNumber, !clientRef.isEmpty {
                    Divider().frame(height: 48)
                    COFinStat(label: "Client Ref", value: clientRef, color: .secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct COFinStat: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct CODetailLineItems: View {
    let co: ChangeOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line Items").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(co.lineItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description).font(.subheadline)
                            Text("\(item.quantity.formatted()) \(item.unit) × \(item.unitPrice.currencyString)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(item.total.currencyString).font(.subheadline).bold()
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                    if item.id != co.lineItems.last?.id { Divider().padding(.leading) }
                }
                Divider()
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(co.lineItemTotal.currencyString).font(.headline)
                }
                .padding(.horizontal).padding(.vertical, 10)
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct CODetailInfo: View {
    let co: ChangeOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline).padding(.horizontal)
            VStack(alignment: .leading, spacing: 10) {
                if !co.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description").font(.caption).foregroundColor(.secondary)
                        Text(co.description).font(.subheadline)
                    }
                    Divider()
                }
                if let reason = co.reason, !reason.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reason / Justification").font(.caption).foregroundColor(.secondary)
                        Text(reason).font(.subheadline)
                    }
                    Divider()
                }
                if let notes = co.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Internal Notes").font(.caption).foregroundColor(.secondary)
                        Text(notes).font(.subheadline)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct CODetailDates: View {
    let co: ChangeOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                CODateRow(label: "Created",   date: co.createdAt)
                if let d = co.submittedDate  { Divider(); CODateRow(label: "Submitted",  date: d) }
                if let d = co.approvedDate   { Divider(); CODateRow(label: "Approved",   date: d) }
                if let d = co.rejectedDate   { Divider(); CODateRow(label: "Rejected",   date: d) }
                if let name = co.approvedByName, !name.isEmpty {
                    Divider()
                    HStack {
                        Text("Approved by").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text(name).font(.subheadline)
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12).padding(.horizontal)
        }
    }
}

private struct CODateRow: View {
    let label: String; let date: Date
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

private struct CODetailStatusActions: View {
    @EnvironmentObject var store: AppStore
    @Binding var co: ChangeOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.headline).padding(.horizontal)
            VStack(spacing: 8) {
                if co.status == .draft {
                    COActionButton(label: "Submit for Approval", color: .blue, icon: "paperplane.fill") {
                        var updated = co
                        updated.status = .submitted
                        updated.submittedDate = Date()
                        store.upsertChangeOrder(updated)
                    }
                }
                if co.status == .submitted || co.status == .underReview {
                    COActionButton(label: "Mark Approved", color: .green, icon: "checkmark.circle.fill") {
                        var updated = co
                        updated.status = .approved
                        updated.approvedDate = Date()
                        store.upsertChangeOrder(updated)
                    }
                    COActionButton(label: "Mark Rejected", color: .red, icon: "xmark.circle.fill") {
                        var updated = co
                        updated.status = .rejected
                        updated.rejectedDate = Date()
                        store.upsertChangeOrder(updated)
                    }
                }
                if co.status != .voided && co.status != .approved {
                    COActionButton(label: "Void", color: .secondary, icon: "slash.circle") {
                        var updated = co
                        updated.status = .voided
                        store.upsertChangeOrder(updated)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct COActionButton: View {
    let label: String; let color: Color; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline).bold()
                .frame(maxWidth: .infinity).padding()
                .background(color.opacity(0.12))
                .foregroundColor(color)
                .cornerRadius(12)
        }
    }
}

// MARK: - Create / Edit Sheet

struct ChangeOrderCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: ChangeOrder? = nil
    var projectID: UUID

    // Form state
    @State private var title: String = ""
    @State private var type: ChangeOrderType = .ownerInitiated
    @State private var description: String = ""
    @State private var reason: String = ""
    @State private var notes: String = ""
    @State private var costImpact: String = "0"
    @State private var scheduleImpactDays: String = "0"
    @State private var clientRef: String = ""
    @State private var approvedByName: String = ""
    @State private var lineItems: [ChangeOrderLineItem] = []
    @State private var showAddLineItem = false

    private var isEditing: Bool { existing != nil }

    /// Phase 9 (lock-on-terminal-state): once a change order is approved,
    /// rejected, or voided it is part of the contract record. Editing
    /// scope, cost, or schedule impact post-decision would silently
    /// shift the deal value the customer signed off on.
    /// Locked states: `.approved`, `.rejected`, `.voided`. Open states
    /// (`.draft`, `.submitted`, `.underReview`) remain editable.
    private var isLocked: Bool {
        guard let s = existing?.status else { return false }
        return !s.isOpen
    }

    private var lockedReason: String {
        switch existing?.status {
        case .approved: return "Change order approved"
        case .rejected: return "Change order rejected"
        case .voided:   return "Change order voided"
        default:        return "Change order locked"
        }
    }

    var body: some View {
        NavigationStack {
            COCreateForm(
                title: $title,
                type: $type,
                description: $description,
                reason: $reason,
                notes: $notes,
                costImpact: $costImpact,
                scheduleImpactDays: $scheduleImpactDays,
                clientRef: $clientRef,
                approvedByName: $approvedByName,
                lineItems: $lineItems,
                showAddLineItem: $showAddLineItem,
                isLocked: isLocked,
                lockedReason: lockedReason
            )
            .disabled(isLocked)
            .navigationTitle(isEditing ? "Edit Change Order" : "New Change Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLocked {
                        Label("Locked", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Save") { save() }
                            .bold()
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .onAppear { populateFromExisting() }
    }

    private func populateFromExisting() {
        guard let co = existing else { return }
        title               = co.title
        type                = co.type
        description         = co.description
        reason              = co.reason ?? ""
        notes               = co.notes ?? ""
        costImpact          = "\(co.costImpact)"
        scheduleImpactDays  = "\(co.scheduleImpactDays)"
        clientRef           = co.clientReferenceNumber ?? ""
        approvedByName      = co.approvedByName ?? ""
        lineItems           = co.lineItems
    }

    private func save() {
        // Phase 9 lock — defensive guard. Toolbar swaps Save for a
        // Locked label when isLocked, but if any code path slips
        // through we abort with a clear message.
        if isLocked {
            ToastService.shared.error("This change order is \(lockedReason.lowercased()) and is locked.")
            return
        }
        var co = existing ?? ChangeOrder(
            number: store.nextCONumber(for: projectID),
            title: title,
            projectID: projectID
        )
        co.title                 = title.trimmingCharacters(in: .whitespaces)
        co.type                  = type
        co.description           = description
        co.reason                = reason.isEmpty ? nil : reason
        co.notes                 = notes.isEmpty ? nil : notes
        co.costImpact            = Decimal(string: costImpact) ?? 0
        co.scheduleImpactDays    = Int(scheduleImpactDays) ?? 0
        co.clientReferenceNumber = clientRef.isEmpty ? nil : clientRef
        co.approvedByName        = approvedByName.isEmpty ? nil : approvedByName
        co.lineItems             = lineItems
        co.createdByID           = store.currentUser?.id
        store.upsertChangeOrder(co)
        dismiss()
    }
}

// Extracted to avoid TupleView explosion in the sheet body
private struct COCreateForm: View {
    @Binding var title: String
    @Binding var type: ChangeOrderType
    @Binding var description: String
    @Binding var reason: String
    @Binding var notes: String
    @Binding var costImpact: String
    @Binding var scheduleImpactDays: String
    @Binding var clientRef: String
    @Binding var approvedByName: String
    @Binding var lineItems: [ChangeOrderLineItem]
    @Binding var showAddLineItem: Bool

    /// Phase 9 lock — rendered as a banner section above all editable
    /// rows. The parent View also applies `.disabled(isLocked)` on
    /// the form so individual inputs become non-interactive.
    var isLocked: Bool = false
    var lockedReason: String = ""

    var body: some View {
        Form {
            if isLocked {
                Section {
                    COLockedBanner(reason: lockedReason)
                }
                .listRowInsets(EdgeInsets())
            }
            COFormIdentitySection(title: $title, type: $type, clientRef: $clientRef)
            COFormImpactSection(costImpact: $costImpact, scheduleImpactDays: $scheduleImpactDays)
            COFormLineItemsSection(lineItems: $lineItems, showAddLineItem: $showAddLineItem)
            COFormNarrativeSection(description: $description, reason: $reason, notes: $notes)
            COFormApprovalSection(approvedByName: $approvedByName)
        }
    }
}

private struct COLockedBanner: View {
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — \(reason.lowercased())")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text("This change order is part of the contract record. Editing scope, cost, or schedule impact would silently shift the deal value the customer signed off on.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }
}

private struct COFormIdentitySection: View {
    @Binding var title: String
    @Binding var type: ChangeOrderType
    @Binding var clientRef: String
    var body: some View {
        Section("Change Order") {
            TextField("Title", text: $title)
            Picker("Type", selection: $type) {
                ForEach(ChangeOrderType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.icon).tag(t)
                }
            }
            TextField("Client Reference # (optional)", text: $clientRef)
        }
    }
}

private struct COFormImpactSection: View {
    @Binding var costImpact: String
    @Binding var scheduleImpactDays: String
    var body: some View {
        Section("Impact") {
            HStack {
                Text("Cost Impact ($)")
                Spacer()
                TextField("0.00", text: $costImpact)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            HStack {
                Text("Schedule Impact (days)")
                Spacer()
                TextField("0", text: $scheduleImpactDays)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
        }
    }
}

private struct COFormLineItemsSection: View {
    @Binding var lineItems: [ChangeOrderLineItem]
    @Binding var showAddLineItem: Bool

    var body: some View {
        Section("Line Items (optional)") {
            ForEach(lineItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description).font(.subheadline)
                        Text("\(item.quantity.formatted()) \(item.unit) × \(item.unitPrice.currencyString)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(item.total.currencyString).font(.subheadline)
                }
            }
            .onDelete { indexSet in lineItems.remove(atOffsets: indexSet) }
            Button { showAddLineItem = true } label: {
                Label("Add Line Item", systemImage: "plus.circle")
            }
        }
        .sheet(isPresented: $showAddLineItem) {
            COLineItemSheet { lineItems.append($0) }
        }
    }
}

private struct COFormNarrativeSection: View {
    @Binding var description: String
    @Binding var reason: String
    @Binding var notes: String
    var body: some View {
        Section("Description") {
            TextField("Scope description…", text: $description, axis: .vertical)
                .lineLimit(3...8)
            TextField("Reason / justification…", text: $reason, axis: .vertical)
                .lineLimit(2...6)
            TextField("Internal notes…", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }
}

private struct COFormApprovalSection: View {
    @Binding var approvedByName: String
    var body: some View {
        Section("Approval") {
            TextField("Approved by (name, optional)", text: $approvedByName)
        }
    }
}

// MARK: - Line Item Add Sheet

private struct COLineItemSheet: View {
    @Environment(\.dismiss) var dismiss
    let onAdd: (ChangeOrderLineItem) -> Void

    @State private var desc: String = ""
    @State private var qty: String = "1"
    @State private var unit: String = "LS"
    @State private var unitPrice: String = "0"

    var body: some View {
        NavigationStack {
            Form {
                Section("Line Item") {
                    TextField("Description", text: $desc)
                    HStack {
                        Text("Qty"); Spacer()
                        TextField("1", text: $qty).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    HStack {
                        Text("Unit"); Spacer()
                        TextField("LS", text: $unit).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    HStack {
                        Text("Unit Price ($)"); Spacer()
                        TextField("0.00", text: $unitPrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 120)
                    }
                }
                let total = (Decimal(string: qty) ?? 1) * (Decimal(string: unitPrice) ?? 0)
                Section {
                    HStack {
                        Text("Total").bold()
                        Spacer()
                        Text(total.currencyString).bold()
                    }
                }
            }
            .navigationTitle("Add Line Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let item = ChangeOrderLineItem(
                            description: desc,
                            quantity: Decimal(string: qty) ?? 1,
                            unit: unit.isEmpty ? "LS" : unit,
                            unitPrice: Decimal(string: unitPrice) ?? 0
                        )
                        onAdd(item)
                        dismiss()
                    }
                    .bold().disabled(desc.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Status Badge

struct COStatusBadge: View {
    let status: ChangeOrderStatus

    private var color: Color {
        switch status {
        case .draft:       return .gray
        case .submitted:   return .blue
        case .underReview: return .orange
        case .approved:    return .green
        case .rejected:    return .red
        case .voided:      return .gray
        }
    }

    var body: some View {
        Label(status.displayName, systemImage: status.icon)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

// MARK: - UserRole Extension

private extension UserRole {
    var canManageCOs: Bool {
        // Owner is a peer of executive at the top of the hierarchy.
        [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
    }
}
