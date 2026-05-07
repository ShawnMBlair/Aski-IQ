// ProcurementViews.swift
// Aski IQ – Materials & Purchase Orders UI

import SwiftUI

// MARK: - Phase 9 Locked Banner (shared by MR + PO create-edit views)

/// Read-only banner shown atop terminal-state procurement records.
/// Both MaterialRequest (delivered/cancelled) and PurchaseOrder
/// (received/closed/cancelled) lock for the same reason: their
/// line items have been booked downstream and editing here would
/// silently shift the procurement record.
struct ProcurementLockedBanner: View {
    let reason: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — \(reason.lowercased())")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Procurement Hub

struct ProcurementHubView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("Requests").tag(0)
                    Text("POs").tag(1)
                    Text("Suppliers").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                switch selectedTab {
                case 1:  POListContent()
                case 2:  SupplierListContent()
                default: MRListContent()
                }
            }
            .navigationTitle("Procurement")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    navigationAddButton
                }
            }
        }
    }

    @ViewBuilder
    private var navigationAddButton: some View {
        switch selectedTab {
        case 1:
            Button { } label: { Image(systemName: "plus") }
                .background(
                    NavigationLink(destination: POCreateEditView(po: nil)) { EmptyView() }
                        .opacity(0)
                )
        case 2:
            Button { } label: { Image(systemName: "plus") }
                .background(
                    NavigationLink(destination: SupplierCreateEditView(supplier: nil)) { EmptyView() }
                        .opacity(0)
                )
        default:
            Button { } label: { Image(systemName: "plus") }
                .background(
                    NavigationLink(destination: MRCreateEditView(request: nil, preselectedProjectID: nil)) { EmptyView() }
                        .opacity(0)
                )
        }
    }
}

// MARK: - Material Request List

struct MRListContent: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedStatus: MaterialRequestStatus? = nil
    @State private var showCreate = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [MaterialRequest] {
        store.materialRequests
            .filter { mr in
                let matchStatus = selectedStatus == nil || mr.status == selectedStatus
                let matchSearch = searchText.isEmpty ||
                    mr.requestNumber.localizedCaseInsensitiveContains(searchText) ||
                    mr.requestedByName.localizedCaseInsensitiveContains(searchText)
                return matchStatus && matchSearch
            }
            .sorted { $0.requestDate > $1.requestDate }
    }

    private var displayed: [MaterialRequest] {
        Array(filtered.prefix(pagination.displayLimit))
    }

    var body: some View {
        mrListBody
            .searchable(text: $searchText, prompt: "Request #, requested by…")
            .onChange(of: searchText) { pagination.reset() }
            .sheet(isPresented: $showCreate) {
                MRCreateEditView(request: nil, preselectedProjectID: nil)
            }
    }

    private var mrListBody: some View {
        VStack(spacing: 0) {
            // Pending approvals banner
            let pending = store.pendingMaterialApprovals.count
            if pending > 0 {
                Button { selectedStatus = .submitted } label: {
                    HStack {
                        Image(systemName: "tray.full.fill").foregroundColor(.orange)
                        Text("\(pending) material request\(pending == 1 ? "" : "s") awaiting approval")
                            .font(.subheadline).bold().foregroundColor(.orange)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.orange.opacity(0.6))
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                }
            }

            // Status filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: selectedStatus == nil) {
                        selectedStatus = nil; pagination.reset()
                    }
                    ForEach(MaterialRequestStatus.allCases, id: \.self) { s in
                        FilterChip(label: s.displayName, isSelected: selectedStatus == s) {
                            selectedStatus = selectedStatus == s ? nil : s
                            pagination.reset()
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }

            Divider()

            if filtered.isEmpty {
                Spacer()
                EmptyCard(message: searchText.isEmpty ? "No material requests yet." : "No results.")
                Spacer()
            } else {
                List {
                    ForEach(displayed) { mr in
                        NavigationLink { MRDetailView(request: mr) } label: { MRRow(request: mr) }
                    }
                    LoadMoreFooter(showing: displayed.count, total: filtered.count) { pagination.loadMore() }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct MRRow: View {
    let request: MaterialRequest
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        request.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name } ?? "No Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(request.requestNumber)
                    .font(.subheadline).bold().fontDesign(.monospaced)
                Spacer()
                MRStatusBadge(status: request.status)
            }
            Text(projectName)
                .font(.caption).foregroundColor(.blue)
            HStack {
                Label(request.requestedByName, systemImage: "person")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(request.requestDate.shortDate)
                    .font(.caption2).foregroundColor(.secondary)
                if let required = request.requiredByDate {
                    Text("· Req \(required.shortDate)")
                        .font(.caption2)
                        .foregroundColor(required < Date() && request.status.isOpen ? .red : .secondary)
                }
            }
            if !request.lineItems.isEmpty {
                Text("\(request.lineItems.count) item\(request.lineItems.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundColor(.secondary)
                    + Text(request.estimatedTotal > 0 ? " · \(request.estimatedTotal.currencyString)" : "")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MRStatusBadge: View {
    let status: MaterialRequestStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(mrStatusColor(status).opacity(0.15))
            .foregroundColor(mrStatusColor(status))
            .cornerRadius(8)
    }
}

func mrStatusColor(_ s: MaterialRequestStatus) -> Color {
    switch s {
    case .draft:     return .secondary
    case .submitted: return .orange
    case .approved:  return .blue
    case .ordered:   return .purple
    case .partial:   return .yellow
    case .delivered: return .green
    case .cancelled: return .gray
    }
}

// MARK: - MR Detail View

struct MRDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: MaterialRequest
    @State private var local: MaterialRequest
    @State private var showEdit = false
    @State private var showCreatePO = false
    @State private var showDeleteAlert = false

    init(request: MaterialRequest) {
        self.request = request
        _local = State(initialValue: request)
    }

    private var projectName: String {
        local.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name } ?? "No Project"
    }

    private var canApprove: Bool {
        [.projectManager, .officeAdmin, .manager, .executive].contains(store.currentUserRole)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(local.requestNumber)
                                .font(.title2).bold().fontDesign(.monospaced)
                            Label(projectName, systemImage: "folder.fill")
                                .font(.caption).foregroundColor(.blue)
                        }
                        Spacer()
                        MRStatusBadge(status: local.status)
                    }
                    Divider()
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Requested By").font(.caption2).foregroundColor(.secondary)
                            Text(local.requestedByName).font(.caption).bold()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Date").font(.caption2).foregroundColor(.secondary)
                            Text(local.requestDate.shortDate).font(.caption).bold()
                        }
                        if let req = local.requiredByDate {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Required By").font(.caption2).foregroundColor(.secondary)
                                Text(req.shortDate).font(.caption).bold()
                                    .foregroundColor(req < Date() && local.status.isOpen ? .red : .primary)
                            }
                        }
                        Spacer()
                    }
                    if !local.siteLocation.isEmpty {
                        Label(local.siteLocation, systemImage: "mappin.circle")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))

                // Line Items
                GroupBox {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Item").font(.caption).bold().foregroundColor(.secondary)
                            Spacer()
                            Text("Qty / Unit").font(.caption).bold().foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                            Text("Est. Cost").font(.caption).bold().foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .padding(.bottom, 6)
                        Divider()
                        ForEach(local.lineItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.description).font(.subheadline)
                                        if !item.costCode.isEmpty {
                                            Text(item.costCode).font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(decStr(item.quantity)) \(item.unit.displayName)")
                                        .font(.caption).foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text(item.totalCost > 0 ? item.totalCost.currencyString : "—")
                                        .font(.subheadline)
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.vertical, 5)
                                if item.id != local.lineItems.last?.id { Divider() }
                            }
                        }
                        if local.estimatedTotal > 0 {
                            Divider().padding(.top, 4)
                            HStack {
                                Text("Estimated Total").font(.subheadline).bold()
                                Spacer()
                                Text(local.estimatedTotal.currencyString).font(.subheadline).bold()
                            }
                            .padding(.top, 6)
                        }
                    }
                } label: {
                    Text("Materials Requested").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal).padding(.top, 12)

                // Notes
                if !local.notes.isEmpty {
                    GroupBox {
                        Text(local.notes).font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Notes").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Approval info
                if local.status == .approved || local.status == .ordered || local.status == .delivered {
                    GroupBox {
                        HStack {
                            Label(local.approvedByName, systemImage: "checkmark.seal.fill")
                                .font(.subheadline).foregroundColor(.green)
                            Spacer()
                            if let at = local.approvedAt {
                                Text(at.shortDate).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    } label: {
                        Text("Approved").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Linked PO
                if let poID = local.purchaseOrderID,
                   let po = store.purchaseOrders.first(where: { $0.id == poID }) {
                    GroupBox {
                        NavigationLink { PODetailView(po: po) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(po.poNumber).font(.subheadline).bold().fontDesign(.monospaced)
                                    Text(po.supplierName).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                POStatusBadge(status: po.status)
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                    } label: {
                        Text("Linked Purchase Order").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Actions
                VStack(spacing: 10) {
                    if local.status == .draft {
                        actionButton("Submit for Approval", icon: "paperplane.fill", color: .blue) {
                            transition(to: .submitted)
                        }
                    }
                    if local.status == .submitted && canApprove {
                        actionButton("Approve Request", icon: "checkmark.circle.fill", color: .green) {
                            store.approveMaterialRequest(local)
                            refreshLocal()
                        }
                    }
                    if local.status == .approved && canApprove && local.purchaseOrderID == nil {
                        actionButton("Create Purchase Order", icon: "doc.badge.plus", color: .purple) {
                            showCreatePO = true
                        }
                    }
                    if local.status == .ordered {
                        actionButton("Mark as Delivered", icon: "shippingbox.fill", color: .green) {
                            transition(to: .delivered)
                        }
                    }
                    if canApprove {
                        Button { showEdit = true } label: {
                            Label("Edit Request", systemImage: "pencil")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                    }
                    if store.currentUserRole == .officeAdmin || store.currentUserRole == .manager || store.currentUserRole == .executive {
                        Button(role: .destructive) { showDeleteAlert = true } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.red.opacity(0.1)).foregroundColor(.red)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(local.requestNumber)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit, onDismiss: refreshLocal) {
            MRCreateEditView(request: local, preselectedProjectID: local.projectID)
        }
        .sheet(isPresented: $showCreatePO, onDismiss: refreshLocal) {
            POCreateEditView(po: newPOFromRequest())
        }
        .alert("Delete Request", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { store.deleteMaterialRequest(id: local.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .onAppear { refreshLocal() }
    }

    private func actionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(color).foregroundColor(.white).cornerRadius(10)
        }
    }

    private func transition(to status: MaterialRequestStatus) {
        var updated = local
        updated.status = status
        updated.updatedAt = Date()
        store.updateMaterialRequest(updated)
        refreshLocal()
    }

    private func refreshLocal() {
        if let fresh = store.materialRequests.first(where: { $0.id == request.id }) { local = fresh }
    }

    private func newPOFromRequest() -> PurchaseOrder {
        var po = PurchaseOrder(poNumber: store.nextPONumber(), projectID: local.projectID)
        po.materialRequestID = local.id
        po.lineItems         = local.lineItems
        if let proj = local.projectID.flatMap({ pid in store.projects.first { $0.id == pid } }) {
            po.deliveryAddress = proj.siteAddress ?? ""
        }
        return po
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - MR Create/Edit View

struct MRCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: MaterialRequest?
    let preselectedProjectID: UUID?

    @State private var requestNumber: String
    @State private var selectedProjectID: UUID?
    @State private var requestedByName: String
    @State private var requestDate: Date
    @State private var hasRequiredBy: Bool
    @State private var requiredByDate: Date
    @State private var siteLocation: String
    @State private var lineItems: [MaterialLineItem]
    @State private var notes: String
    @State private var status: MaterialRequestStatus

    @State private var showAddLine   = false
    @State private var editingLineIdx: Int? = nil

    init(request: MaterialRequest?, preselectedProjectID: UUID?) {
        self.request              = request
        self.preselectedProjectID = preselectedProjectID
        _requestNumber    = State(initialValue: request?.requestNumber ?? "")
        _selectedProjectID = State(initialValue: request?.projectID ?? preselectedProjectID)
        _requestedByName  = State(initialValue: request?.requestedByName ?? "")
        _requestDate      = State(initialValue: request?.requestDate ?? Date())
        _hasRequiredBy    = State(initialValue: request?.requiredByDate != nil)
        _requiredByDate   = State(initialValue: request?.requiredByDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!)
        _siteLocation     = State(initialValue: request?.siteLocation ?? "")
        _lineItems        = State(initialValue: request?.lineItems ?? [])
        _notes            = State(initialValue: request?.notes ?? "")
        _status           = State(initialValue: request?.status ?? .draft)
    }

    private var isNew: Bool { request == nil }

    /// Phase 9 (lock-on-terminal-state): once a material request is
    /// delivered or cancelled, its line items are part of the
    /// procurement record. Editing them post-terminal would shift
    /// historical material costs that PMs and accounting have
    /// already booked.
    /// Locked states: `.delivered`, `.cancelled` (per `isOpen`).
    private var isLocked: Bool {
        guard let r = request else { return false }
        return !r.status.isOpen
    }

    private var lockedReason: String {
        switch request?.status {
        case .delivered: return "Materials delivered"
        case .cancelled: return "Request cancelled"
        default:         return "Request locked"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked {
                    Section {
                        ProcurementLockedBanner(
                            reason: lockedReason,
                            detail: "This request is part of the procurement record. Editing line items would shift historical material costs already booked against the project."
                        )
                    }
                    .listRowInsets(EdgeInsets())
                }
                mrDetailsSection
                mrLineItemsSection
                Section("Notes") {
                    TextField("Additional details or instructions", text: $notes, axis: .vertical).lineLimit(3)
                }
            }
            .disabled(isLocked)
            .navigationTitle(isNew ? "New Request" : "Edit Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLocked {
                        Label("Locked", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Save") { save() }.bold()
                            .disabled(requestNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if isNew && requestNumber.isEmpty {
                    requestNumber = store.nextMaterialRequestNumber()
                }
                if requestedByName.isEmpty {
                    requestedByName = store.currentUser?.fullName ?? ""
                }
            }
            .sheet(isPresented: $showAddLine) {
                MaterialLineItemEditSheet(item: nil) { lineItems.append($0) }
            }
            .sheet(item: Binding(
                get: { editingLineIdx.map { IdentifiableIdx(value: $0) } },
                set: { editingLineIdx = $0?.value }
            )) { wrap in
                MaterialLineItemEditSheet(item: lineItems[wrap.value]) { lineItems[wrap.value] = $0 }
            }
        }
    }

    private var mrDetailsSection: some View {
        Section("Request Details") {
            HStack {
                Text("Request #")
                TextField("MR-0001", text: $requestNumber)
                    .multilineTextAlignment(.trailing).fontDesign(.monospaced)
            }
            Picker("Project", selection: $selectedProjectID) {
                Text("None").tag(UUID?.none)
                ForEach(store.projects.filter { $0.status == .active }) { proj in
                    Text(proj.name).tag(Optional(proj.id))
                }
            }
            HStack {
                Text("Requested By")
                TextField("Name", text: $requestedByName).multilineTextAlignment(.trailing)
            }
            DatePicker("Request Date", selection: $requestDate, displayedComponents: .date)
            Toggle("Has Required-By Date", isOn: $hasRequiredBy)
            if hasRequiredBy {
                DatePicker("Required By", selection: $requiredByDate, displayedComponents: .date)
            }
            HStack {
                Text("Site Location")
                TextField("e.g. Level 2, North wing", text: $siteLocation).multilineTextAlignment(.trailing)
            }
            Picker("Status", selection: $status) {
                ForEach(MaterialRequestStatus.allCases, id: \.self) { s in
                    Text(s.displayName).tag(s)
                }
            }
        }
    }

    private var mrLineItemsSection: some View {
        Section {
            ForEach(Array(lineItems.enumerated()), id: \.element.id) { idx, item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description).font(.subheadline)
                        Text("\(decStr(item.quantity)) \(item.unit.displayName)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(item.totalCost > 0 ? item.totalCost.currencyString : "—")
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingLineIdx = idx }
            }
            .onDelete { lineItems.remove(atOffsets: $0) }
            Button { showAddLine = true } label: {
                Label("Add Item", systemImage: "plus.circle")
            }
        } header: {
            Text("Materials")
        } footer: {
            if !lineItems.isEmpty {
                let total = lineItems.reduce(Decimal(0)) { $0 + $1.totalCost }
                if total > 0 {
                    Text("Estimated total: \(total.currencyString)").font(.footnote)
                }
            }
        }
    }

    private func save() {
        // Phase 9 lock — defensive guard.
        if isLocked {
            ToastService.shared.error("This request is \(lockedReason.lowercased()) and is locked.")
            return
        }
        var mr = request ?? MaterialRequest(requestNumber: requestNumber)
        mr.requestNumber   = requestNumber.trimmingCharacters(in: .whitespaces)
        mr.projectID       = selectedProjectID
        mr.requestedByName = requestedByName
        mr.requestDate     = requestDate
        mr.requiredByDate  = hasRequiredBy ? requiredByDate : nil
        mr.siteLocation    = siteLocation
        mr.lineItems       = lineItems
        mr.notes           = notes
        mr.status          = status
        mr.updatedAt       = Date()
        isNew ? store.addMaterialRequest(mr) : store.updateMaterialRequest(mr)
        dismiss()
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - Material Line Item Edit Sheet

struct MaterialLineItemEditSheet: View {
    @Environment(\.dismiss) var dismiss
    let item: MaterialLineItem?
    let onSave: (MaterialLineItem) -> Void

    @State private var description: String
    @State private var quantity:    Decimal
    @State private var unit:        UnitOfMeasure
    @State private var unitCost:    Decimal
    @State private var costCode:    String
    @State private var notes:       String

    init(item: MaterialLineItem?, onSave: @escaping (MaterialLineItem) -> Void) {
        self.item   = item
        self.onSave = onSave
        _description = State(initialValue: item?.description ?? "")
        _quantity    = State(initialValue: item?.quantity   ?? 1)
        _unit        = State(initialValue: item?.unit       ?? .each)
        _unitCost    = State(initialValue: item?.unitCost   ?? 0)
        _costCode    = State(initialValue: item?.costCode   ?? "")
        _notes       = State(initialValue: item?.notes      ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2)
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("1", value: $quantity, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    Picker("Unit", selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { u in
                            Text(u.displayName).tag(u)
                        }
                    }
                    HStack {
                        Text("Unit Cost")
                        Spacer()
                        TextField("0.00", value: $unitCost, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                    }
                    HStack {
                        Text("Cost Code")
                        TextField("Optional", text: $costCode).multilineTextAlignment(.trailing)
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2)
                }
                if unitCost > 0 {
                    Section {
                        HStack {
                            Text("Estimated Total")
                            Spacer()
                            Text((quantity * unitCost).currencyString).bold()
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "Add Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        var updated = item ?? MaterialLineItem(description: description)
                        updated.description = description.trimmingCharacters(in: .whitespaces)
                        updated.quantity    = quantity
                        updated.unit        = unit
                        updated.unitCost    = unitCost
                        updated.costCode    = costCode
                        updated.notes       = notes
                        onSave(updated)
                        dismiss()
                    }
                    .bold()
                    .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - PO List

struct POListContent: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedStatus: POStatus? = nil
    @State private var showCreate = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [PurchaseOrder] {
        store.purchaseOrders
            .filter { po in
                let matchStatus = selectedStatus == nil || po.status == selectedStatus
                let matchSearch = searchText.isEmpty ||
                    po.poNumber.localizedCaseInsensitiveContains(searchText) ||
                    po.supplierName.localizedCaseInsensitiveContains(searchText)
                return matchStatus && matchSearch
            }
            .sorted { $0.issueDate > $1.issueDate }
    }

    private var displayed: [PurchaseOrder] { Array(filtered.prefix(pagination.displayLimit)) }

    var body: some View {
        poListBody
            .searchable(text: $searchText, prompt: "PO #, supplier…")
            .onChange(of: searchText) { pagination.reset() }
            .sheet(isPresented: $showCreate) { POCreateEditView(po: nil) }
    }

    private var poListBody: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: selectedStatus == nil) {
                        selectedStatus = nil; pagination.reset()
                    }
                    ForEach(POStatus.allCases, id: \.self) { s in
                        FilterChip(label: s.displayName, isSelected: selectedStatus == s) {
                            selectedStatus = selectedStatus == s ? nil : s; pagination.reset()
                        }
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            Divider()
            if filtered.isEmpty {
                Spacer()
                EmptyCard(message: searchText.isEmpty ? "No purchase orders yet." : "No results.")
                Spacer()
            } else {
                List {
                    ForEach(displayed) { po in
                        NavigationLink { PODetailView(po: po) } label: { PORow(po: po) }
                    }
                    LoadMoreFooter(showing: displayed.count, total: filtered.count) { pagination.loadMore() }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct PORow: View {
    let po: PurchaseOrder
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        po.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name } ?? "No Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(po.poNumber).font(.subheadline).bold().fontDesign(.monospaced)
                Spacer()
                POStatusBadge(status: po.status)
            }
            Text(po.supplierName.isEmpty ? "No Supplier" : po.supplierName)
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Text(projectName).font(.caption).foregroundColor(.blue)
                Spacer()
                Text(po.issueDate.shortDate).font(.caption2).foregroundColor(.secondary)
            }
            HStack {
                Text("\(po.lineItems.count) item\(po.lineItems.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(po.total.currencyString).font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

struct POStatusBadge: View {
    let status: POStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(poStatusColor(status).opacity(0.15))
            .foregroundColor(poStatusColor(status))
            .cornerRadius(8)
    }
}

func poStatusColor(_ s: POStatus) -> Color {
    switch s {
    case .draft:     return .secondary
    case .sent:      return .blue
    case .confirmed: return .purple
    case .partial:   return .orange
    case .received:  return .green
    case .closed:    return .green
    case .cancelled: return .gray
    }
}

// MARK: - PO Detail View

struct PODetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let po: PurchaseOrder
    @State private var local: PurchaseOrder
    @State private var showEdit = false
    @State private var showDeleteAlert = false

    init(po: PurchaseOrder) {
        self.po = po
        _local = State(initialValue: po)
    }

    private var projectName: String {
        local.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name } ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(local.poNumber).font(.title2).bold().fontDesign(.monospaced)
                            Label(local.supplierName.isEmpty ? "No Supplier" : local.supplierName,
                                  systemImage: "building.2")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        POStatusBadge(status: local.status)
                    }
                    Divider()
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Issued").font(.caption2).foregroundColor(.secondary)
                            Text(local.issueDate.shortDate).font(.caption).bold()
                        }
                        if let req = local.requiredDate {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Required By").font(.caption2).foregroundColor(.secondary)
                                Text(req.shortDate).font(.caption).bold()
                            }
                        }
                        if let rec = local.receivedDate {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Received").font(.caption2).foregroundColor(.secondary)
                                Text(rec.shortDate).font(.caption).bold().foregroundColor(.green)
                            }
                        }
                        Spacer()
                    }
                    Label(projectName, systemImage: "folder.fill").font(.caption).foregroundColor(.blue)
                }
                .padding().background(Color(.secondarySystemBackground))

                // Line Items + Totals
                GroupBox {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Item").font(.caption).bold().foregroundColor(.secondary)
                            Spacer()
                            Text("Qty").font(.caption).bold().foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
                            Text("Amount").font(.caption).bold().foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                        }.padding(.bottom, 6)
                        Divider()
                        ForEach(local.lineItems) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.description).font(.subheadline)
                                    Text("\(decStr(item.quantity)) \(item.unit.displayName) @ \(item.unitCost.currencyString)")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(decStr(item.quantity)).font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
                                Text(item.totalCost.currencyString).font(.subheadline).frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                            if item.id != local.lineItems.last?.id { Divider() }
                        }
                        Divider().padding(.top, 4)
                        HStack { Text("Subtotal").font(.caption).foregroundColor(.secondary); Spacer(); Text(local.subtotal.currencyString).font(.subheadline) }.padding(.top, 4)
                        HStack { Text("GST (\(NSDecimalNumber(decimal: local.taxRate * 100).intValue)%)").font(.caption).foregroundColor(.secondary); Spacer(); Text(local.taxAmount.currencyString).font(.subheadline) }.padding(.top, 3)
                        HStack { Text("Total").font(.subheadline).bold(); Spacer(); Text(local.total.currencyString).font(.subheadline).bold() }.padding(.top, 4)
                    }
                } label: {
                    Text("Line Items").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal).padding(.top, 12)

                // Notes
                if !local.notes.isEmpty {
                    GroupBox { Text(local.notes).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading) }
                    label: { Text("Notes").font(.caption).foregroundColor(.secondary) }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Actions
                VStack(spacing: 10) {
                    if local.status == .draft {
                        poActionButton("Mark as Sent", icon: "paperplane.fill", color: .blue) { transitionPO(to: .sent) }
                    }
                    if local.status == .sent {
                        poActionButton("Confirm Receipt Pending", icon: "checkmark.circle", color: .purple) { transitionPO(to: .confirmed) }
                    }
                    if local.status == .confirmed || local.status == .partial {
                        poActionButton("Mark as Received", icon: "shippingbox.fill", color: .green) {
                            var updated = local
                            updated.status       = .received
                            updated.receivedDate = Date()
                            updated.updatedAt    = Date()
                            store.updatePurchaseOrder(updated)
                            refreshLocal()
                        }
                    }
                    if store.currentUserRole == .projectManager || store.currentUserRole == .officeAdmin ||
                       store.currentUserRole == .manager || store.currentUserRole == .executive {
                        Button { showEdit = true } label: {
                            Label("Edit PO", systemImage: "pencil")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground)).cornerRadius(10)
                        }
                    }
                    if store.currentUserRole == .officeAdmin || store.currentUserRole == .manager || store.currentUserRole == .executive {
                        Button(role: .destructive) { showDeleteAlert = true } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.red.opacity(0.1)).foregroundColor(.red).cornerRadius(10)
                        }
                    }
                }
                .padding()
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(local.poNumber)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit, onDismiss: refreshLocal) {
            POCreateEditView(po: local)
        }
        .alert("Delete PO", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { store.deletePurchaseOrder(id: local.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .onAppear { refreshLocal() }
    }

    private func poActionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(color).foregroundColor(.white).cornerRadius(10)
        }
    }

    private func transitionPO(to status: POStatus) {
        var updated = local
        updated.status    = status
        updated.updatedAt = Date()
        store.updatePurchaseOrder(updated)
        refreshLocal()
    }

    private func refreshLocal() {
        if let fresh = store.purchaseOrders.first(where: { $0.id == po.id }) { local = fresh }
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - PO Create/Edit View

struct POCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let po: PurchaseOrder?

    @State private var poNumber:        String
    @State private var selectedProjectID: UUID?
    @State private var selectedSupplierID: UUID?
    @State private var supplierName:    String
    @State private var issueDate:       Date
    @State private var hasRequired:     Bool
    @State private var requiredDate:    Date
    @State private var deliveryAddress: String
    @State private var terms:           String
    @State private var taxRate:         Decimal
    @State private var lineItems:       [MaterialLineItem]
    @State private var notes:           String
    @State private var status:          POStatus

    @State private var showAddLine    = false
    @State private var editingLineIdx: Int? = nil

    init(po: PurchaseOrder?) {
        self.po = po
        _poNumber          = State(initialValue: po?.poNumber ?? "")
        _selectedProjectID  = State(initialValue: po?.projectID)
        _selectedSupplierID = State(initialValue: po?.supplierID)
        _supplierName       = State(initialValue: po?.supplierName ?? "")
        _issueDate          = State(initialValue: po?.issueDate ?? Date())
        _hasRequired        = State(initialValue: po?.requiredDate != nil)
        _requiredDate       = State(initialValue: po?.requiredDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!)
        _deliveryAddress    = State(initialValue: po?.deliveryAddress ?? "")
        _terms              = State(initialValue: po?.terms ?? "Net 30")
        _taxRate            = State(initialValue: po?.taxRate ?? 0.05)
        _lineItems          = State(initialValue: po?.lineItems ?? [])
        _notes              = State(initialValue: po?.notes ?? "")
        _status             = State(initialValue: po?.status ?? .draft)
    }

    private var isNew: Bool { po == nil }
    private var subtotal: Decimal { lineItems.reduce(0) { $0 + $1.totalCost } }
    private var taxAmount: Decimal { (subtotal * taxRate).rounded(scale: 2) }
    private var total: Decimal { subtotal + taxAmount }

    /// Phase 9 (lock-on-terminal-state): once a PO is received,
    /// closed, or cancelled, its line items, totals, and supplier
    /// commitments are part of the procurement record. Editing them
    /// post-terminal would shift booked AP balances and supplier
    /// performance metrics.
    /// Locked states: `.received`, `.closed`, `.cancelled` (per `isOpen`).
    private var isLocked: Bool {
        guard let p = po else { return false }
        return !p.status.isOpen
    }

    private var lockedReason: String {
        switch po?.status {
        case .received:  return "PO received"
        case .closed:    return "PO closed"
        case .cancelled: return "PO cancelled"
        default:         return "PO locked"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked {
                    Section {
                        ProcurementLockedBanner(
                            reason: lockedReason,
                            detail: "This PO is part of the procurement record. Editing line items or totals would shift booked AP balances and supplier performance metrics."
                        )
                    }
                    .listRowInsets(EdgeInsets())
                }
                poHeaderSection
                poLineItemsSection
                Section("Notes") {
                    TextField("Notes for supplier", text: $notes, axis: .vertical).lineLimit(3)
                }
                Section("Tax") {
                    HStack {
                        Text("Tax Rate")
                        Spacer()
                        TextField("0.05", value: $taxRate, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        Text("%").foregroundColor(.secondary)
                    }
                }
            }
            .disabled(isLocked)
            .navigationTitle(isNew ? "New Purchase Order" : "Edit PO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLocked {
                        Label("Locked", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button("Save") { save() }.bold()
                            .disabled(poNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if isNew && poNumber.isEmpty { poNumber = store.nextPONumber() }
            }
            .sheet(isPresented: $showAddLine) {
                MaterialLineItemEditSheet(item: nil) { lineItems.append($0) }
            }
            .sheet(item: Binding(
                get: { editingLineIdx.map { IdentifiableIdx(value: $0) } },
                set: { editingLineIdx = $0?.value }
            )) { wrap in
                MaterialLineItemEditSheet(item: lineItems[wrap.value]) { lineItems[wrap.value] = $0 }
            }
        }
    }

    private var poHeaderSection: some View {
        Section("PO Details") {
            HStack {
                Text("PO #")
                TextField("PO-0001", text: $poNumber).multilineTextAlignment(.trailing).fontDesign(.monospaced)
            }
            Picker("Project", selection: $selectedProjectID) {
                Text("None").tag(UUID?.none)
                ForEach(store.projects.filter { $0.status == .active }) { proj in
                    Text(proj.name).tag(Optional(proj.id))
                }
            }
            Picker("Supplier", selection: $selectedSupplierID) {
                Text("Enter Manually").tag(UUID?.none)
                ForEach(store.suppliers.sorted { $0.name < $1.name }) { sup in
                    Text(sup.name).tag(Optional(sup.id))
                }
            }
            .onChange(of: selectedSupplierID) { newVal in
                if let sid = newVal, let sup = store.suppliers.first(where: { $0.id == sid }) {
                    supplierName = sup.name
                }
            }
            if selectedSupplierID == nil {
                HStack {
                    Text("Supplier Name")
                    TextField("Enter supplier", text: $supplierName).multilineTextAlignment(.trailing)
                }
            }
            DatePicker("Issue Date", selection: $issueDate, displayedComponents: .date)
            Toggle("Has Required Date", isOn: $hasRequired)
            if hasRequired {
                DatePicker("Required By", selection: $requiredDate, displayedComponents: .date)
            }
            HStack {
                Text("Delivery Address")
                TextField("Site address", text: $deliveryAddress).multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Terms")
                TextField("Net 30", text: $terms).multilineTextAlignment(.trailing)
            }
            Picker("Status", selection: $status) {
                ForEach(POStatus.allCases, id: \.self) { s in Text(s.displayName).tag(s) }
            }
        }
    }

    private var poLineItemsSection: some View {
        Section {
            ForEach(Array(lineItems.enumerated()), id: \.element.id) { idx, item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description).font(.subheadline)
                        Text("\(decStr(item.quantity)) \(item.unit.displayName) @ \(item.unitCost.currencyString)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(item.totalCost.currencyString).font(.subheadline)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingLineIdx = idx }
            }
            .onDelete { lineItems.remove(atOffsets: $0) }
            Button { showAddLine = true } label: { Label("Add Item", systemImage: "plus.circle") }
        } header: {
            Text("Line Items")
        } footer: {
            if !lineItems.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack { Text("Subtotal"); Spacer(); Text(subtotal.currencyString) }
                    HStack { Text("GST (\(NSDecimalNumber(decimal: taxRate * 100).intValue)%)"); Spacer(); Text(taxAmount.currencyString) }
                    HStack { Text("Total").bold(); Spacer(); Text(total.currencyString).bold() }
                }.font(.footnote).padding(.top, 4)
            }
        }
    }

    private func save() {
        // Phase 9 lock — defensive guard.
        if isLocked {
            ToastService.shared.error("This PO is \(lockedReason.lowercased()) and is locked.")
            return
        }
        var item = po ?? PurchaseOrder(poNumber: poNumber)
        item.poNumber         = poNumber.trimmingCharacters(in: .whitespaces)
        item.projectID        = selectedProjectID
        item.supplierID       = selectedSupplierID
        item.supplierName     = selectedSupplierID != nil
            ? (store.suppliers.first { $0.id == selectedSupplierID }?.name ?? supplierName)
            : supplierName
        item.issueDate        = issueDate
        item.requiredDate     = hasRequired ? requiredDate : nil
        item.deliveryAddress  = deliveryAddress
        item.terms            = terms
        item.taxRate          = taxRate
        item.lineItems        = lineItems
        item.notes            = notes
        item.status           = status
        item.updatedAt        = Date()
        isNew ? store.addPurchaseOrder(item) : store.updatePurchaseOrder(item)
        dismiss()
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - Supplier List

struct SupplierListContent: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var showCreate = false
    @StateObject private var pagination = PaginationState(pageSize: 30)

    private var filtered: [Supplier] {
        store.suppliers
            .filter { sup in
                searchText.isEmpty ||
                sup.name.localizedCaseInsensitiveContains(searchText) ||
                sup.contactName.localizedCaseInsensitiveContains(searchText) ||
                sup.categories.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted { $0.isPreferred != $1.isPreferred ? $0.isPreferred : $0.name < $1.name }
    }

    private var displayed: [Supplier] { Array(filtered.prefix(pagination.displayLimit)) }

    var body: some View {
        supplierListBody
            .searchable(text: $searchText, prompt: "Supplier name, category…")
            .onChange(of: searchText) { pagination.reset() }
            .sheet(isPresented: $showCreate) { SupplierCreateEditView(supplier: nil) }
    }

    private var supplierListBody: some View {
        Group {
            if filtered.isEmpty {
                Spacer()
                EmptyCard(message: searchText.isEmpty ? "No suppliers yet." : "No results.")
                Spacer()
            } else {
                List {
                    ForEach(displayed) { sup in
                        NavigationLink { SupplierDetailView(supplier: sup) } label: { SupplierRow(supplier: sup) }
                    }
                    LoadMoreFooter(showing: displayed.count, total: filtered.count) { pagination.loadMore() }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct SupplierRow: View {
    let supplier: Supplier
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(supplier.name).font(.subheadline).bold()
                    if supplier.isPreferred {
                        Image(systemName: "star.fill").font(.caption2).foregroundColor(.yellow)
                    }
                }
                if !supplier.contactName.isEmpty {
                    Text(supplier.contactName).font(.caption).foregroundColor(.secondary)
                }
                if !supplier.categories.isEmpty {
                    Text(supplier.categories.joined(separator: " · "))
                        .font(.caption2).foregroundColor(.blue)
                }
            }
            Spacer()
            if !supplier.phone.isEmpty {
                Image(systemName: "phone").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SupplierDetailView: View {
    @EnvironmentObject var store: AppStore
    let supplier: Supplier
    @State private var local: Supplier
    @State private var showEdit = false

    init(supplier: Supplier) {
        self.supplier = supplier
        _local = State(initialValue: supplier)
    }

    var body: some View {
        List {
            Section("Contact") {
                if !local.contactName.isEmpty {
                    HStack { Text("Contact"); Spacer(); Text(local.contactName).foregroundColor(.secondary) }
                }
                if !local.phone.isEmpty {
                    HStack {
                        Text("Phone"); Spacer()
                        Link(local.phone, destination: URL(string: "tel:\(local.phone.filter { $0.isNumber })")!)
                            .foregroundColor(.blue)
                    }
                }
                if !local.email.isEmpty {
                    HStack {
                        Text("Email"); Spacer()
                        Link(local.email, destination: URL(string: "mailto:\(local.email)")!)
                            .foregroundColor(.blue)
                    }
                }
                if !local.address.isEmpty {
                    HStack { Text("Address"); Spacer(); Text(local.address).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
                }
            }
            if !local.accountNumber.isEmpty {
                Section("Account") {
                    HStack { Text("Account #"); Spacer(); Text(local.accountNumber).fontDesign(.monospaced).foregroundColor(.secondary) }
                }
            }
            if !local.categories.isEmpty {
                Section("Categories") {
                    ForEach(local.categories, id: \.self) { cat in
                        Label(cat, systemImage: "tag")
                    }
                }
            }
            if !local.notes.isEmpty {
                Section("Notes") { Text(local.notes) }
            }

            // POs for this supplier
            let supplierPOs = store.purchaseOrders.filter { $0.supplierID == local.id }
            if !supplierPOs.isEmpty {
                Section("Purchase Orders (\(supplierPOs.count))") {
                    ForEach(supplierPOs.prefix(5)) { po in
                        NavigationLink { PODetailView(po: po) } label: {
                            HStack {
                                Text(po.poNumber).fontDesign(.monospaced).font(.subheadline)
                                Spacer()
                                POStatusBadge(status: po.status)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(local.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.currentUserRole == .projectManager || store.currentUserRole == .officeAdmin ||
                   store.currentUserRole == .manager || store.currentUserRole == .executive {
                    Button("Edit") { showEdit = true }
                }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: {
            if let fresh = store.suppliers.first(where: { $0.id == supplier.id }) { local = fresh }
        }) {
            SupplierCreateEditView(supplier: local)
        }
    }
}

struct SupplierCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let supplier: Supplier?

    @State private var name:          String
    @State private var contactName:   String
    @State private var phone:         String
    @State private var email:         String
    @State private var address:       String
    @State private var accountNumber: String
    @State private var isPreferred:   Bool
    @State private var categories:    String   // comma-separated for simplicity
    @State private var notes:         String

    init(supplier: Supplier?) {
        self.supplier = supplier
        _name          = State(initialValue: supplier?.name          ?? "")
        _contactName   = State(initialValue: supplier?.contactName   ?? "")
        _phone         = State(initialValue: supplier?.phone         ?? "")
        _email         = State(initialValue: supplier?.email         ?? "")
        _address       = State(initialValue: supplier?.address       ?? "")
        _accountNumber = State(initialValue: supplier?.accountNumber ?? "")
        _isPreferred   = State(initialValue: supplier?.isPreferred   ?? false)
        _categories    = State(initialValue: supplier?.categories.joined(separator: ", ") ?? "")
        _notes         = State(initialValue: supplier?.notes         ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier") {
                    TextField("Company Name *", text: $name)
                    TextField("Contact Name", text: $contactName)
                    Toggle("Preferred Supplier", isOn: $isPreferred)
                }
                Section("Contact Details") {
                    HStack {
                        Image(systemName: "phone").foregroundColor(.secondary)
                        TextField("Phone", text: $phone).keyboardType(.phonePad)
                    }
                    HStack {
                        Image(systemName: "envelope").foregroundColor(.secondary)
                        TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    }
                    HStack {
                        Image(systemName: "mappin").foregroundColor(.secondary)
                        TextField("Address", text: $address, axis: .vertical).lineLimit(2)
                    }
                }
                Section {
                    HStack {
                        Text("Account #")
                        TextField("Optional", text: $accountNumber).multilineTextAlignment(.trailing)
                    }
                    TextField("Categories (comma separated)", text: $categories)
                } header: {
                    Text("Account")
                } footer: {
                    Text("e.g. Lumber, Concrete, Electrical")
                }
                Section("Notes") {
                    TextField("Internal notes", text: $notes, axis: .vertical).lineLimit(3)
                }
            }
            .navigationTitle(supplier == nil ? "New Supplier" : "Edit Supplier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var sup = supplier ?? Supplier(name: name)
        sup.name          = name.trimmingCharacters(in: .whitespaces)
        sup.contactName   = contactName
        sup.phone         = phone
        sup.email         = email
        sup.address       = address
        sup.accountNumber = accountNumber
        sup.isPreferred   = isPreferred
        sup.categories    = categories.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        sup.notes         = notes
        supplier == nil ? store.addSupplier(sup) : store.updateSupplier(sup)
        dismiss()
    }
}

// MARK: - Project Procurement Section

struct ProjectProcurementSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showCreateMR = false

    private var requests: [MaterialRequest] { store.materialRequests(for: project.id) }
    private var pos:      [PurchaseOrder]   { store.purchaseOrders(for: project.id)   }

    private var totalOrdered: Decimal { pos.reduce(0) { $0 + $1.total } }
    private var openPOs:      Int      { pos.filter { $0.status.isOpen }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Procurement", count: requests.count + pos.count)
                Spacer()
                Button { showCreateMR = true } label: {
                    Image(systemName: "plus.circle").foregroundColor(.blue)
                }
                .padding(.trailing)
            }

            if requests.isEmpty && pos.isEmpty {
                Text("No material requests or purchase orders.")
                    .font(.caption).foregroundColor(.secondary).padding()
            } else {
                // Summary chips
                HStack(spacing: 12) {
                    if !requests.isEmpty {
                        summaryChip(
                            label: "Requests",
                            value: "\(requests.count)",
                            color: requests.filter { $0.status.isOpen }.count > 0 ? .orange : .secondary
                        )
                    }
                    if !pos.isEmpty {
                        summaryChip(label: "Open POs", value: "\(openPOs)", color: openPOs > 0 ? .blue : .secondary)
                        summaryChip(label: "Ordered", value: totalOrdered.currencyString, color: .primary)
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)

                // Recent requests
                ForEach(requests.prefix(3)) { mr in
                    NavigationLink { MRDetailView(request: mr) } label: { MRRow(request: mr).padding(.horizontal) }
                    Divider().padding(.leading)
                }

                // Recent POs
                ForEach(pos.prefix(3)) { po in
                    NavigationLink { PODetailView(po: po) } label: { PORow(po: po).padding(.horizontal) }
                    Divider().padding(.leading)
                }

                if requests.count + pos.count > 6 {
                    NavigationLink { ProcurementHubView() } label: {
                        Text("View all procurement")
                            .font(.caption).foregroundColor(.blue)
                            .padding(.horizontal).padding(.vertical, 6)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateMR) {
            MRCreateEditView(request: nil, preselectedProjectID: project.id)
        }
    }

    private func summaryChip(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption).bold().foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
}

// MARK: - IdentifiableIdx (local helper to avoid collision with InvoiceViews)

private struct IdentifiableIdx: Identifiable {
    let id: Int
    let value: Int
    init(value: Int) { self.id = value; self.value = value }
}
