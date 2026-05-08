// ProcurementViews.swift
// Aski IQ – Materials & Purchase Orders UI

import SwiftUI
import PhotosUI
import VisionKit

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

/// Procurement Hub — pipeline-status dashboard.
///
/// REPLACES the old 3-tab segmented control (Requests/POs/Suppliers) which
/// surfaced the data model rather than the workflow. The new layout mirrors
/// the operator's mental flow: Request → Approve → Buy → Receive → Close.
///
/// Each section card shows count + a one-line summary; tap navigates into a
/// filtered list view. The legacy POs / Suppliers screens stay reachable via
/// the toolbar's Browse menu — they're useful for day-to-day catalog work,
/// just not the primary entry point anymore.
struct ProcurementHubView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    myQueueCard
                    pipelineSection
                    quickActionsSection
                }
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Procurement")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        NavigationLink {
                            MRCreateEditView(request: nil, preselectedProjectID: nil)
                        } label: { Label("New Request", systemImage: "plus.square") }
                        Divider()
                        NavigationLink {
                            ProcurementBrowseView()
                        } label: { Label("Browse All", systemImage: "list.bullet.rectangle") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    // MARK: - My Queue

    /// Items the *current* user can act on right now. Drives the
    /// at-a-glance "what's waiting on me" experience that lets a user
    /// open the app and find their work without scrolling.
    @ViewBuilder
    private var myQueueCard: some View {
        let queue = store.myProcurementQueue
        if !queue.isEmpty {
            NavigationLink {
                ProcurementSectionListView(title: "My Queue", requests: queue)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.blue)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(queue.count) waiting on you")
                            .font(.headline)
                        Text("Tap to review what you can approve, send, or receive.")
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PIPELINE")
                .font(.caption).bold().foregroundColor(.secondary)
                .padding(.horizontal)
            VStack(spacing: 0) {
                pipelineRow(
                    title:   "Draft",
                    detail:  "Started but not submitted",
                    icon:    "pencil.line",
                    color:   .gray,
                    requests: store.draftMaterialRequests
                )
                Divider().padding(.leading, 60)
                pipelineRow(
                    title:   "Pending Approval",
                    detail:  "Waiting on manager / PM",
                    icon:    "clock.badge.exclamationmark",
                    color:   .orange,
                    requests: store.pendingMaterialApprovals
                )
                Divider().padding(.leading, 60)
                pipelineRow(
                    title:   "Approved to Order",
                    detail:  "Ready to send to supplier",
                    icon:    "checkmark.seal.fill",
                    color:   .green,
                    requests: store.approvedToOrderRequests
                )
                Divider().padding(.leading, 60)
                pipelineRow(
                    title:   "Ordered",
                    detail:  "Sent to supplier, awaiting delivery",
                    icon:    "paperplane.fill",
                    color:   .blue,
                    requests: store.orderedMaterialRequests
                )
                Divider().padding(.leading, 60)
                pipelineRow(
                    title:   "Partially Received",
                    detail:  "Some items in, more to come",
                    icon:    "shippingbox.and.arrow.backward.fill",
                    color:   .purple,
                    requests: store.partiallyReceivedRequests
                )
                Divider().padding(.leading, 60)
                pipelineRow(
                    title:   "Received",
                    detail:  "Materials in, awaiting close",
                    icon:    "shippingbox.fill",
                    color:   .green,
                    requests: store.deliveredMaterialRequests
                )
                // Rejected — terminal state. Only shown when there are
                // rejected requests so the pipeline doesn't show a "0"
                // bucket as a permanent reminder of failure.
                if !store.rejectedMaterialRequests.isEmpty {
                    Divider().padding(.leading, 60)
                    pipelineRow(
                        title:   "Rejected",
                        detail:  "Approver declined; requester can resubmit a new MR",
                        icon:    "hand.thumbsdown.fill",
                        color:   .red,
                        requests: store.rejectedMaterialRequests
                    )
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func pipelineRow(title: String,
                             detail: String,
                             icon: String,
                             color: Color,
                             requests: [MaterialRequest]) -> some View {
        NavigationLink {
            ProcurementSectionListView(title: title, requests: requests)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).bold()
                    Text(detail).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if requests.isEmpty {
                    Text("0")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(requests.count)")
                        .font(.subheadline).bold()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .foregroundColor(color)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.footnote).foregroundColor(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(requests.isEmpty)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK ACTIONS")
                .font(.caption).bold().foregroundColor(.secondary)
                .padding(.horizontal)
            VStack(spacing: 0) {
                NavigationLink {
                    MRCreateEditView(request: nil, preselectedProjectID: nil)
                } label: {
                    quickActionRow("New Material Request",
                                   icon: "plus.circle.fill",
                                   color: .blue)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 60)
                NavigationLink {
                    ProcurementBrowseView()
                } label: {
                    quickActionRow("Browse Suppliers, POs, All Requests",
                                   icon: "list.bullet.rectangle",
                                   color: .gray)
                }
                .buttonStyle(.plain)
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func quickActionRow(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(title).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote).foregroundColor(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }
}

// MARK: - Procurement Section List
// Reusable filtered list shown when a Hub pipeline section is tapped.

struct ProcurementSectionListView: View {
    @EnvironmentObject var store: AppStore
    let title: String
    let requests: [MaterialRequest]

    var body: some View {
        Group {
            if requests.isEmpty {
                ContentUnavailableView(
                    "No requests in this stage",
                    systemImage: "tray",
                    description: Text("Items in this status will appear here.")
                )
            } else {
                List {
                    ForEach(requests.sorted { $0.requestDate > $1.requestDate }) { mr in
                        NavigationLink { MRDetailView(request: mr) } label: { MRRow(request: mr) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Procurement Browse View
// Legacy 3-tab segmented control kept available for catalog browsing
// (full request list, all POs, all suppliers). Reachable via the Hub's
// toolbar Browse menu — no longer the default entry point.

struct ProcurementBrowseView: View {
    @State private var selectedTab = 0

    var body: some View {
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
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                browseAddButton
            }
        }
    }

    @ViewBuilder
    private var browseAddButton: some View {
        switch selectedTab {
        case 1:
            NavigationLink { POCreateEditView(po: nil) } label: { Image(systemName: "plus") }
        case 2:
            NavigationLink { SupplierCreateEditView(supplier: nil) } label: { Image(systemName: "plus") }
        default:
            NavigationLink { MRCreateEditView(request: nil, preselectedProjectID: nil) } label: { Image(systemName: "plus") }
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
    case .rejected:  return .red
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
    @State private var showReceiveSheet = false
    @State private var showDuplicateAlert = false
    @State private var duplicateMatches: [MaterialRequest] = []
    @State private var rejectReasonSheetMode: RejectionMode? = nil
    @State private var rejectReasonText: String = ""

    /// Differentiates the two reason-capture flows on the same sheet —
    /// outright rejection (terminal) vs. send-back-for-changes (returns
    /// to draft). The sheet's title + button copy adapt accordingly.
    enum RejectionMode: Identifiable {
        case reject
        case requestChanges
        var id: String {
            switch self {
            case .reject:         return "reject"
            case .requestChanges: return "requestChanges"
            }
        }
    }

    init(request: MaterialRequest) {
        self.request = request
        _local = State(initialValue: request)
    }

    private var projectName: String {
        local.projectID.flatMap { pid in store.projects.first { $0.id == pid }?.name } ?? "No Project"
    }

    /// True when the current user can approve THIS specific request — both
    /// (a) their role has approval rights, and (b) the request total is
    /// within their per-role approval limit. Lookup goes through
    /// AppStore.canApproveMaterialRequest(amount:) which reads the workflow
    /// settings hydrated from Supabase, not a hardcoded role list.
    private var canApprove: Bool {
        store.canApproveMaterialRequest(amount: local.estimatedTotal)
    }

    /// Routing copy for the Submit button — tells the user which role will
    /// actually see the approval queue, sourced from workflow_settings rather
    /// than a hardcoded chain.
    private var nextApproverRoleName: String? {
        store.minimumApprovingRole(for: local.estimatedTotal)?.displayName
    }

    /// True when the current user can delete this request. Mirrors the
    /// existing footer button check but pulls role permissions from the
    /// workflow settings table so admins can rebalance later without code
    /// changes. Falls back to the legacy hardcoded gate when the workflow
    /// settings table hasn't been populated yet (deny-all setting → false).
    private var canDelete: Bool {
        // Delete is intentionally not exposed as a workflow_settings field
        // because deletion is an admin action, not part of the MR pipeline.
        // Keep the hardcoded role list for now.
        [.officeAdmin, .manager, .executive].contains(store.currentUserRole)
    }

    /// Editing is gated by role only (not by amount). A project manager
    /// editing a $50k request shouldn't be blocked just because they can't
    /// approve that amount — they need to be able to fix typos / line items
    /// before sending it up the chain.
    private var canEditByRole: Bool {
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
                            // Email subtitle when on file — tappable so the
                            // PM can ping the requester directly without
                            // copy-pasting into Mail.
                            if let email = local.requestedByEmail, !email.isEmpty {
                                Link(email, destination: URL(string: "mailto:\(email)") ?? URL(string: "https://example.com")!)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
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
                                        // Show received progress only after the receive
                                        // workflow has been started — keeps the row uncluttered
                                        // for draft/approved requests.
                                        if item.quantityReceived > 0 {
                                            Label(
                                                "Received \(decStr(item.quantityReceived)) of \(decStr(item.quantity))",
                                                systemImage: item.isFullyReceived ? "checkmark.circle.fill" : "shippingbox"
                                            )
                                            .font(.caption2)
                                            .foregroundColor(item.isFullyReceived ? .green : .orange)
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(local.approvedByName, systemImage: "checkmark.seal.fill")
                                    .font(.subheadline).foregroundColor(.green)
                                Spacer()
                                if let at = local.approvedAt {
                                    Text(at.shortDate).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            if !local.approvalNote.isEmpty {
                                Text(local.approvalNote)
                                    .font(.caption).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Approval PDF generated by MaterialRequestPDFGenerator. Tap
                            // opens the file via QuickLook through DocumentDetailView,
                            // same as any other ProjectDocument.
                            if let storedFileName = local.pdfStoragePath {
                                let url = FileManager.default
                                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                                    .appendingPathComponent(storedFileName)
                                if FileManager.default.fileExists(atPath: url.path) {
                                    Link(destination: url) {
                                        Label("View Approval PDF", systemImage: "doc.fill")
                                            .font(.caption).bold()
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("Approved").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Reference document scanned at create time (supplier
                // receipt / quote / hand-written list). Tap "View" to open
                // the PDF via a signed URL in QuickLook.
                if let scanPath = local.receiptScanPath, !scanPath.isEmpty {
                    GroupBox {
                        ReceiptScanRow(storagePath: scanPath)
                    } label: {
                        Text("Reference Document").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // Delivery photo — fetched on demand via signed URL since
                // the storage path is server-side. Embedded as a tappable
                // AsyncImage that opens the full-resolution image in a sheet.
                if let storagePath = local.deliveryPhotoURL, !storagePath.isEmpty {
                    GroupBox {
                        DeliveryPhotoThumbnail(storagePath: storagePath)
                    } label: {
                        Text("Delivery Proof").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }

                // History — server-authoritative audit trail written by the
                // log_material_request_status_change DB trigger. Read-only on
                // the client; visible to anyone who can view the request.
                let history = store.auditEvents(for: local.id)
                if !history.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(history) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: historyIcon(for: event))
                                        .font(.caption)
                                        .foregroundColor(historyColor(for: event))
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(event.displayTitle(in: store))
                                            .font(.caption).bold()
                                        Text(event.performedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                                if event.id != history.last?.id { Divider() }
                            }
                        }
                    } label: {
                        Text("History").font(.caption).foregroundColor(.secondary)
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
                    if local.status == .draft && store.canCreateMaterialRequest {
                        // Self-approve shortcut for trusted roles within their
                        // approval limit — skips the submit-then-approve dance
                        // for routine purchases by managers / executives.
                        if store.canSelfApproveMaterialRequest(amount: local.estimatedTotal) {
                            actionButton("Submit & Approve", icon: "checkmark.seal.fill", color: .green) {
                                store.approveMaterialRequest(local)
                                refreshLocal()
                            }
                        } else {
                            actionButton("Submit for Approval", icon: "paperplane.fill", color: .blue) {
                                attemptSubmit()
                            }
                            if let role = nextApproverRoleName {
                                Text("Will route to \(role) for approval.")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    if local.status == .submitted && canApprove {
                        actionButton("Approve Request", icon: "checkmark.circle.fill", color: .green) {
                            store.approveMaterialRequest(local)
                            refreshLocal()
                        }
                        // Three-button approval surface per the procurement
                        // plan: Approve / Reject / Request Changes. The two
                        // negative actions both capture a reason via the same
                        // sheet — differentiated by RejectionMode.
                        actionButton("Request Changes", icon: "arrow.uturn.backward.circle.fill", color: .orange) {
                            rejectReasonText = ""
                            rejectReasonSheetMode = .requestChanges
                        }
                        actionButton("Reject Request", icon: "xmark.circle.fill", color: .red) {
                            rejectReasonText = ""
                            rejectReasonSheetMode = .reject
                        }
                    }
                    // When the current user is in the .submitted queue but can't
                    // approve this amount, surface why so they don't think the
                    // app is broken — the request is just above their tier.
                    if local.status == .submitted
                        && !canApprove
                        && store.currentUserWorkflowSetting.canApproveMaterialRequest {
                        Text("Above your approval limit (\(store.currentUserWorkflowSetting.approvalLimitAmount.currencyString)).")
                            .font(.caption).foregroundColor(.orange)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.orange.opacity(0.08)).cornerRadius(8)
                    }
                    if local.status == .approved && store.canSendToSupplier {
                        // No supplier yet — give the user a clear next step
                        // ("set a supplier so a PO can be drafted") rather
                        // than a wall of disabled buttons.
                        if local.supplierID == nil {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.orange)
                                Text("Pick a supplier on this request to auto-draft a Purchase Order, or create one manually below.")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(8)
                        }
                        // Email-to-supplier — only shown when a supplier with an
                        // email is set on the MR. The generator regenerates the
                        // PDF if the original was deleted from the doc grid.
                        if local.supplierID != nil {
                            actionButton("Email Approval to Supplier", icon: "envelope.fill", color: .blue) {
                                Task {
                                    #if canImport(UIKit)
                                    let ok = await MaterialRequestPDFGenerator.shared
                                        .emailApprovalPDF(for: local, store: store)
                                    if ok {
                                        await MainActor.run {
                                            ToastService.shared.success("Sent — request marked as ordered.")
                                            refreshLocal()
                                        }
                                    }
                                    #endif
                                }
                            }
                        }
                        // The Create PO button is now only useful when no
                        // PO got auto-drafted (supplier-less requests, or
                        // legacy MRs approved before this automation
                        // shipped). When auto-draft fired, the existing
                        // "Linked PO" GroupBox above takes over.
                        if local.purchaseOrderID == nil {
                            actionButton("Create Purchase Order", icon: "doc.badge.plus", color: .purple) {
                                showCreatePO = true
                            }
                        }
                    }
                    if (local.status == .ordered || local.status == .partial) && store.canReceiveMaterials {
                        actionButton("Receive Items", icon: "shippingbox.fill", color: .green) {
                            showReceiveSheet = true
                        }
                    }
                    if canEditByRole {
                        Button { showEdit = true } label: {
                            Label("Edit Request", systemImage: "pencil")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                    }
                    if canDelete {
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
        .sheet(isPresented: $showReceiveSheet, onDismiss: refreshLocal) {
            MRReceiveSheet(request: local) { quantities, photoPath in
                store.receiveMaterialRequest(
                    local,
                    receivedQuantities: quantities,
                    deliveryPhotoURL:   photoPath
                )
                refreshLocal()
            }
        }
        .sheet(item: $rejectReasonSheetMode, onDismiss: { refreshLocal() }) { mode in
            rejectReasonSheet(mode: mode)
        }
        .alert("Delete Request", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { store.deleteMaterialRequest(id: local.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .alert(
            "Possible duplicate request",
            isPresented: $showDuplicateAlert,
            presenting: duplicateMatches
        ) { matches in
            // Warn-don't-block: the user can still submit, they just have
            // to acknowledge the existing open requests first.
            Button("Submit Anyway") { submitDespiteDuplicates() }
            Button("Cancel", role: .cancel) {}
        } message: { matches in
            // Show up to 3 matches — keep the message readable on small
            // screens. Beyond 3 we just say "and N more."
            let preview = matches.prefix(3)
                .map { "• \($0.requestNumber) (\($0.status.displayName))" }
                .joined(separator: "\n")
            let trailer = matches.count > 3
                ? "\n…and \(matches.count - 3) more."
                : ""
            return Text(
                "There \(matches.count == 1 ? "is" : "are") \(matches.count) open request\(matches.count == 1 ? "" : "s") on this destination with overlapping items:\n\n\(preview)\(trailer)\n\nReview them first to avoid double-ordering."
            )
        }
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

    /// Submit-for-approval entry point. Runs a duplicate-request check
    /// against open requests on the same destination first; if matches are
    /// found, raises a confirmation alert so the submitter can decide
    /// whether to proceed (warn-don't-block per the spec — duplicate
    /// requests are sometimes legitimate, e.g. follow-up after a partial
    /// delivery short).
    private func attemptSubmit() {
        let matches = store.similarOpenRequests(to: local)
        if matches.isEmpty {
            store.submitMaterialRequest(local)
            refreshLocal()
        } else {
            duplicateMatches = matches
            showDuplicateAlert = true
        }
    }

    /// User confirmed they understand the duplicates and want to submit
    /// anyway. Called from the Submit-Anyway alert button.
    private func submitDespiteDuplicates() {
        store.submitMaterialRequest(local)
        refreshLocal()
        duplicateMatches = []
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

    private func historyIcon(for event: MaterialRequestAudit) -> String {
        switch event.newStatus {
        case "submitted": return "paperplane.fill"
        case "approved":  return "checkmark.seal.fill"
        case "ordered":   return "cart.fill"
        case "partial":   return "shippingbox.and.arrow.backward.fill"
        case "delivered": return "shippingbox.fill"
        case "cancelled": return "xmark.circle.fill"
        case "rejected":  return "hand.thumbsdown.fill"
        // status_changed back to draft — no `newStatus == "draft"` rows
        // in normal flow, but Request Changes produces exactly this.
        case "draft":     return "arrow.uturn.backward.circle.fill"
        default:          return event.action == "created" ? "plus.circle.fill" : "circle.fill"
        }
    }

    private func historyColor(for event: MaterialRequestAudit) -> Color {
        switch event.newStatus {
        case "approved", "delivered": return .green
        case "submitted":             return .blue
        case "ordered", "partial":    return .purple
        case "cancelled", "rejected": return .red
        case "draft":                 return .orange   // sent back for changes
        default:                       return .gray
        }
    }

    /// Reason-capture sheet shared by Reject and Request Changes. Both
    /// flows need a free-text justification visible in the audit log;
    /// only the title / button copy / destination action differ.
    @ViewBuilder
    private func rejectReasonSheet(mode: RejectionMode) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        mode == .reject
                            ? "Why is this being rejected?"
                            : "What needs to change?",
                        text: $rejectReasonText,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                } footer: {
                    Text(mode == .reject
                        ? "Stored on the request. Visible in the audit history."
                        : "The requester will see this when they reopen the request to edit.")
                        .font(.caption2)
                }
            }
            .navigationTitle(mode == .reject ? "Reject Request" : "Request Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { rejectReasonSheetMode = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(mode == .reject ? "Reject" : "Send Back") {
                        let trimmed = rejectReasonText.trimmingCharacters(in: .whitespaces)
                        // Both paths require a non-empty reason — without one
                        // the audit row is useless and the requester can't
                        // act on it.
                        guard !trimmed.isEmpty else { return }
                        switch mode {
                        case .reject:
                            store.rejectMaterialRequest(local, reason: trimmed)
                        case .requestChanges:
                            store.requestChangesOnMaterialRequest(local, notes: trimmed)
                        }
                        rejectReasonSheetMode = nil
                    }
                    .bold()
                    .disabled(rejectReasonText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - MR Create/Edit View

struct MRCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: MaterialRequest?
    let preselectedProjectID: UUID?

    @State private var requestNumber: String
    @State private var destinationType: MaterialRequestDestinationType
    @State private var selectedProjectID: UUID?
    @State private var selectedMaterialSaleID: UUID?
    @State private var selectedSupplierID: UUID?
    @State private var selectedRequestedByID: UUID?
    @State private var requestedByName: String
    @State private var requestedByEmail: String
    @State private var requestDate: Date
    @State private var hasRequiredBy: Bool
    @State private var requiredByDate: Date
    @State private var siteLocation: String
    @State private var lineItems: [MaterialLineItem]
    @State private var notes: String
    @State private var status: MaterialRequestStatus

    @State private var showAddLine   = false
    @State private var editingLineIdx: Int? = nil
    @State private var showDocumentScanner = false
    @State private var receiptScanPath: String?
    @State private var isUploadingReceipt = false
    /// Pre-generated row ID for new requests so storage uploads (receipt
    /// scan) land at the same path the saved row will reference. Without
    /// this, save() would mint a fresh UUID and the scan would orphan.
    @State private var pendingRequestID: UUID

    init(request: MaterialRequest?, preselectedProjectID: UUID?) {
        self.request              = request
        self.preselectedProjectID = preselectedProjectID
        _requestNumber          = State(initialValue: request?.requestNumber ?? "")
        // If a project is preselected, default destination to .project so the
        // picker UI matches what the user came from.
        let initialDestination: MaterialRequestDestinationType = {
            if let r = request { return r.destinationType }
            return preselectedProjectID != nil ? .project : .internalUse
        }()
        _destinationType        = State(initialValue: initialDestination)
        _selectedProjectID      = State(initialValue: request?.projectID ?? preselectedProjectID)
        _selectedMaterialSaleID = State(initialValue: request?.materialSaleID)
        _selectedSupplierID     = State(initialValue: request?.supplierID)
        _selectedRequestedByID  = State(initialValue: request?.requestedByID)
        _requestedByName        = State(initialValue: request?.requestedByName ?? "")
        _requestedByEmail       = State(initialValue: request?.requestedByEmail ?? "")
        _receiptScanPath        = State(initialValue: request?.receiptScanPath)
        _pendingRequestID       = State(initialValue: request?.id ?? UUID())
        _requestDate            = State(initialValue: request?.requestDate ?? Date())
        _hasRequiredBy          = State(initialValue: request?.requiredByDate != nil)
        _requiredByDate         = State(initialValue: request?.requiredByDate ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!)
        _siteLocation           = State(initialValue: request?.siteLocation ?? "")
        _lineItems              = State(initialValue: request?.lineItems ?? [])
        _notes                  = State(initialValue: request?.notes ?? "")
        _status                 = State(initialValue: request?.status ?? .draft)
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
                if isNew { quickActionsSection }
                if !validationIssues.isEmpty { validationBanner }
                mrDetailsSection
                mrLineItemsSection
                receiptScanSection
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
                            .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                if isNew && requestNumber.isEmpty {
                    requestNumber = store.nextMaterialRequestNumber()
                }
                // Default Requested By to the current employee (if their auth
                // user has a matching employee record), falling back to their
                // display name. Office staff with no employee record still get
                // a sensible name pre-filled.
                if selectedRequestedByID == nil && requestedByName.isEmpty {
                    if let me = currentUserEmployee {
                        selectedRequestedByID = me.id
                        requestedByName       = me.fullName
                        if requestedByEmail.isEmpty,
                           let myEmail = me.email, !myEmail.isEmpty {
                            requestedByEmail = myEmail
                        }
                    } else {
                        requestedByName = store.currentUser?.fullName ?? ""
                    }
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
            .sheet(isPresented: $showDocumentScanner) {
                // System document scanner — handles edge detection,
                // multi-page capture, and Save / Cancel via the wrapper.
                DocumentScannerView { scan in
                    guard let scan = scan else { return }
                    Task { await uploadScannedReceipt(scan) }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// Receipt / reference document section — VisionKit document scanner
    /// for supplier receipts, quotes, hand-written lists, etc. Saves a
    /// multi-page PDF to Supabase Storage on the request row. Optional —
    /// not in the validation gate.
    private var receiptScanSection: some View {
        Section {
            if isUploadingReceipt {
                HStack {
                    ProgressView()
                    Text("Uploading…").font(.caption).foregroundColor(.secondary)
                }
            } else if let path = receiptScanPath, !path.isEmpty {
                HStack {
                    Label("Receipt attached", systemImage: "doc.text.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("Replace") { showDocumentScanner = true }
                        .font(.caption)
                }
                Button(role: .destructive) {
                    receiptScanPath = nil
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Button {
                    showDocumentScanner = true
                } label: {
                    Label("Scan Receipt or Quote", systemImage: "doc.viewfinder")
                        .foregroundColor(.blue)
                }
            }
        } header: {
            Text("Reference Document")
        } footer: {
            Text("Scan a supplier receipt, quote, or hand-written list. Auto-detects edges and supports multi-page capture.")
                .font(.caption2)
        }
    }

    private func uploadScannedReceipt(_ scan: VNDocumentCameraScan) async {
        isUploadingReceipt = true
        defer { isUploadingReceipt = false }
        do {
            let path = try await ReceiptScanService.shared.upload(
                scan: scan,
                requestID: pendingRequestID,   // stable across scan + save
                companyID: request?.companyID ?? store.currentCompanyID
            )
            receiptScanPath = path
            ToastService.shared.success("Receipt scan attached.")
        } catch {
            ToastService.shared.error(error.localizedDescription)
        }
    }

    /// Active employees (sorted by name) — populates the Requested By picker.
    private var activeEmployees: [Employee] {
        store.employees
            .filter { $0.isActive && !$0.isDeleted }
            .sorted { $0.fullName < $1.fullName }
    }

    // MARK: Validation
    // Per-rule helpers feed both the inline banner and the Save-button gate.
    // Keeping them as separate computed booleans (rather than one big array
    // diff) means the UI can highlight specific fields, and adding a new
    // rule doesn't require touching the Save logic.

    private var hasRequestNumber: Bool {
        !requestNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasDestinationTarget: Bool {
        switch destinationType {
        case .project:      return selectedProjectID != nil
        case .materialSale: return selectedMaterialSaleID != nil
        case .internalUse:  return true
        }
    }

    private var hasRequestedBy: Bool {
        selectedRequestedByID != nil
            || !requestedByName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var hasLineItems: Bool { !lineItems.isEmpty }

    /// Ordered list of human-readable validation issues. Drives both the
    /// inline banner ("Pick a project") and the disabled-state explanation
    /// near the Save button. Empty array = ready to save.
    private var validationIssues: [String] {
        var issues: [String] = []
        if !hasRequestNumber {
            issues.append("Request number is required.")
        }
        if !hasDestinationTarget {
            issues.append(destinationType == .project
                ? "Pick a project for this request."
                : "Pick a material sale for this request.")
        }
        if !hasRequestedBy {
            issues.append("Requested By is required — select an employee or type a name.")
        }
        if !hasLineItems {
            issues.append("Add at least one item.")
        }
        return issues
    }

    private var canSave: Bool { validationIssues.isEmpty && !isLocked }

    // MARK: Quick-action helpers — Repeat / Import

    /// User's most recent non-draft, non-cancelled request. Drives the
    /// Repeat Last Request button. Filters to the current user so the
    /// button doesn't replay someone else's request by accident.
    private var lastRequestForCurrentUser: MaterialRequest? {
        guard let uid = store.currentUser?.id else { return nil }
        return store.materialRequests
            .filter { mr in
                guard !mr.isDeleted else { return false }
                guard mr.requestedByID == uid else { return false }
                guard mr.status != .draft && mr.status != .cancelled else { return false }
                return !mr.lineItems.isEmpty
            }
            .sorted { $0.requestDate > $1.requestDate }
            .first
    }

    /// Approved estimate on the selected project, if any. Drives the
    /// Import from Estimate button — only meaningful when destination
    /// is a project and that project has an estimate to source from.
    private var importableEstimate: Estimate? {
        guard destinationType == .project,
              let projectID = selectedProjectID else { return nil }
        return store.estimates
            .filter { $0.projectID == projectID && !$0.lineItems.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    /// Pre-populate quantities + line items from the user's last request.
    /// Skips fields that are already filled to avoid clobbering work in
    /// progress (e.g. a partially-typed item description).
    private func repeatLastRequest() {
        guard let last = lastRequestForCurrentUser else { return }
        if !hasLineItems {
            // Reset the IDs so SwiftUI sees them as new rows and the items
            // are independent from the source request after edits.
            lineItems = last.lineItems.map { item in
                var copy = item
                copy.id               = UUID()
                copy.quantityReceived = 0   // start fresh
                return copy
            }
        }
        if siteLocation.isEmpty       { siteLocation       = last.siteLocation }
        if selectedSupplierID == nil  { selectedSupplierID = last.supplierID  }
        if destinationType == .internalUse && last.destinationType != .internalUse {
            destinationType = last.destinationType
        }
        if selectedProjectID == nil      { selectedProjectID      = last.projectID }
        if selectedMaterialSaleID == nil { selectedMaterialSaleID = last.materialSaleID }
    }

    /// Convert an estimate's CostCodeItems into MaterialLineItems and
    /// append. Maps unit string → UnitOfMeasure enum with a fallback to
    /// `.each` for unrecognized units (legacy estimates may have free-text
    /// units that don't map cleanly).
    private func importFromEstimate(_ estimate: Estimate) {
        let imported = estimate.lineItems.map { ci -> MaterialLineItem in
            MaterialLineItem(
                description: ci.description,
                quantity:    ci.estimatedQuantity,
                quantityReceived: 0,
                unit:        UnitOfMeasure(rawValue: ci.unit) ?? .each,
                unitCost:    ci.unitRate,
                costCode:    ci.code,
                notes:       ""
            )
        }
        lineItems.append(contentsOf: imported)
    }

    /// The Employee record (if any) for the currently signed-in user.
    /// `store.currentUser` is itself an Employee — used to default Requested
    /// By so field workers don't have to scroll the picker.
    private var currentUserEmployee: Employee? { store.currentUser }

    private var openMaterialSales: [MaterialSale] {
        store.materialSales
            .filter { !$0.isDeleted }
            .sorted { $0.saleNumber > $1.saleNumber }
    }

    /// Quick-actions section — visible only on new requests. Surfaces the
    /// two repeatable-create paths (Repeat Last Request / Import from
    /// Estimate) at the top so the field user sees them before scrolling
    /// through fields they may not need to fill manually.
    @ViewBuilder
    private var quickActionsSection: some View {
        if lastRequestForCurrentUser != nil || importableEstimate != nil {
            Section {
                if let last = lastRequestForCurrentUser {
                    Button {
                        repeatLastRequest()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Repeat Last Request").font(.subheadline).bold()
                                Text("\(last.requestNumber) · \(last.lineItems.count) item\(last.lineItems.count == 1 ? "" : "s")")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }
                if let est = importableEstimate {
                    Button {
                        importFromEstimate(est)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Import from Estimate").font(.subheadline).bold()
                                Text("\(est.lineItems.count) line item\(est.lineItems.count == 1 ? "" : "s") from this project's estimate")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "square.and.arrow.down.fill")
                                .foregroundColor(.purple)
                        }
                    }
                }
            } header: {
                Text("Quick Start")
            } footer: {
                Text("Pre-fills line items and supplier from a previous request or this project's estimate.")
                    .font(.caption2)
            }
        }
    }

    /// Inline validation banner — shows the list of remaining issues so
    /// the user can fix them before scrolling. Updates live as fields
    /// change. Hidden when `validationIssues` is empty.
    private var validationBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Before saving:", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).bold()
                    .foregroundColor(.orange)
                ForEach(validationIssues, id: \.self) { issue in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•").foregroundColor(.orange)
                        Text(issue).font(.caption).foregroundColor(.primary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.orange.opacity(0.08))
    }

    private var mrDetailsSection: some View {
        Section {
            HStack {
                Text("Request #")
                Text("*").foregroundColor(.red)
                TextField("MR-0001", text: $requestNumber)
                    .multilineTextAlignment(.trailing).fontDesign(.monospaced)
            }

            // Destination — drives which downstream picker is shown. Editing
            // it clears the other two so we never persist a stale combination
            // that would fail the server-side single-destination check.
            HStack {
                Text("Destination")
                Text("*").foregroundColor(.red)
                Spacer()
                Picker("", selection: $destinationType) {
                    ForEach(MaterialRequestDestinationType.allCases, id: \.self) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .labelsHidden()
            }
            .onChange(of: destinationType) { newVal in
                switch newVal {
                case .project:      selectedMaterialSaleID = nil
                case .materialSale: selectedProjectID      = nil
                case .internalUse:
                    selectedProjectID      = nil
                    selectedMaterialSaleID = nil
                }
            }

            if destinationType == .project {
                HStack {
                    Text("Project")
                    Text("*").foregroundColor(.red)
                    Spacer()
                    Picker("", selection: $selectedProjectID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(store.projects.filter { $0.status == .active }) { proj in
                            Text(proj.name).tag(Optional(proj.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if destinationType == .materialSale {
                HStack {
                    Text("Material Sale")
                    Text("*").foregroundColor(.red)
                    Spacer()
                    Picker("", selection: $selectedMaterialSaleID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(openMaterialSales) { sale in
                            Text(sale.saleNumber).tag(Optional(sale.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            // Requested By — picker over employees, with a free-text fallback
            // so MRs entered on behalf of unlisted personnel still record a
            // name. The "(Other)" tag means selectedRequestedByID is nil and
            // requestedByName is whatever the user typed.
            HStack {
                Text("Requested By")
                Text("*").foregroundColor(.red)
                Spacer()
                Picker("", selection: $selectedRequestedByID) {
                    Text("Other (type name)").tag(UUID?.none)
                    ForEach(activeEmployees) { emp in
                        Text(emp.fullName).tag(Optional(emp.id))
                    }
                }
                .labelsHidden()
            }
            .onChange(of: selectedRequestedByID) { newVal in
                if let eid = newVal,
                   let emp = store.employees.first(where: { $0.id == eid }) {
                    requestedByName = emp.fullName
                    // Auto-pull email from the employee record so users
                    // don't re-type it. They can still override the field
                    // below if the employee has multiple addresses.
                    if let empEmail = emp.email, !empEmail.isEmpty {
                        requestedByEmail = empEmail
                    }
                }
            }
            if selectedRequestedByID == nil {
                HStack {
                    Text("Name")
                    TextField("Enter name", text: $requestedByName)
                        .multilineTextAlignment(.trailing)
                }
            }
            // Email — visible whether picker or "Other" is selected. Pre-fills
            // from the employee record but stays editable: a worker might want
            // CCs to a personal address, or office staff might want notices
            // sent to a shared inbox instead.
            HStack {
                Text("Email")
                TextField("name@company.com", text: $requestedByEmail)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
            }

            // Supplier — optional. When set, downstream PDF/email flows can
            // address the supplier directly instead of routing through a PO.
            Picker("Supplier", selection: $selectedSupplierID) {
                Text("None").tag(UUID?.none)
                ForEach(store.suppliers.sorted { $0.name < $1.name }) { sup in
                    Text(sup.name).tag(Optional(sup.id))
                }
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
        } header: {
            HStack(spacing: 4) {
                Text("Request Details")
                Text("* required").font(.caption2).foregroundColor(.secondary)
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
            HStack(spacing: 4) {
                Text("Materials")
                Text("*").foregroundColor(.red)
            }
        } footer: {
            if lineItems.isEmpty {
                Text("Add at least one item to submit this request.")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
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

        // Mirror the server-side single-destination check: refuse to save an
        // MR whose destinationType is .project / .materialSale without the
        // matching ID set. Saving it would either fail the DB constraint at
        // sync time (silent data loss) or persist an inconsistent local row.
        switch destinationType {
        case .project where selectedProjectID == nil:
            ToastService.shared.error("Pick a project for this request, or change destination.")
            return
        case .materialSale where selectedMaterialSaleID == nil:
            ToastService.shared.error("Pick a material sale for this request, or change destination.")
            return
        default: break
        }

        var mr = request ?? MaterialRequest(requestNumber: requestNumber)
        // Pin the row ID to the value used by any in-flight uploads
        // (receipt scans). For edits this is a no-op (matches request.id);
        // for new rows it overrides the freshly-minted UUID from the
        // initializer so storage paths and the saved row stay in sync.
        mr.id               = pendingRequestID
        mr.requestNumber    = requestNumber.trimmingCharacters(in: .whitespaces)
        mr.destinationType  = destinationType
        mr.projectID        = destinationType == .project      ? selectedProjectID      : nil
        mr.materialSaleID   = destinationType == .materialSale ? selectedMaterialSaleID : nil
        mr.supplierID       = selectedSupplierID
        mr.requestedByID    = selectedRequestedByID
        mr.requestedByName  = requestedByName.trimmingCharacters(in: .whitespaces)
        let trimmedEmail    = requestedByEmail.trimmingCharacters(in: .whitespaces)
        mr.requestedByEmail = trimmedEmail.isEmpty ? nil : trimmedEmail
        mr.requestDate      = requestDate
        mr.requiredByDate   = hasRequiredBy ? requiredByDate : nil
        mr.siteLocation     = siteLocation
        mr.lineItems        = lineItems
        mr.notes            = notes
        mr.status           = status
        mr.receiptScanPath  = receiptScanPath
        mr.updatedAt        = Date()
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

// MARK: - MR Receive Sheet

/// Per-line-item receiving UI. Receiver enters how much actually showed up
/// for each line; status rolls up automatically (partial vs delivered) in
/// AppStore.receiveMaterialRequest. Pre-fills with the previously-received
/// quantity so partial deliveries stack across multiple receive events.
///
/// PHOTO REQUIREMENT
///   Final .delivered status is BLOCKED without at least one delivery
///   photo (packing slip / materials on site). Partial receives are
///   allowed without a photo so a receiver on a tarmac with bad cellular
///   isn't stuck with their qty entries unsaved.
struct MRReceiveSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let request: MaterialRequest
    let onConfirm: ([UUID: Decimal], String?) -> Void

    @State private var quantities: [UUID: Decimal]

    // Photo state — selected by PhotosPicker, decoded into UIImage for the
    // thumbnail, uploaded on Confirm. existingPhotoPath holds the URL
    // already saved on the MR from a prior partial receive — so a receiver
    // who's added the photo earlier doesn't have to re-upload to finalize.
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var photoImage: UIImage? = nil
    @State private var existingPhotoPath: String?
    @State private var isUploading = false

    init(request: MaterialRequest,
         onConfirm: @escaping ([UUID: Decimal], String?) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        // Seed with prior received qty so the receiver only edits the delta.
        var seed: [UUID: Decimal] = [:]
        for item in request.lineItems { seed[item.id] = item.quantityReceived }
        _quantities = State(initialValue: seed)
        _existingPhotoPath = State(initialValue: request.deliveryPhotoURL)
    }

    private var allFullyReceived: Bool {
        request.lineItems.allSatisfy { (quantities[$0.id] ?? 0) >= $0.quantity }
    }

    private var anyShort: Bool {
        request.lineItems.contains { (quantities[$0.id] ?? 0) < $0.quantity }
    }

    private var hasPhoto: Bool {
        photoImage != nil || (existingPhotoPath?.isEmpty == false)
    }

    /// Confirm is blocked when saving would result in .delivered status
    /// without a photo. Partial receives are always allowed.
    private var confirmDisabled: Bool {
        if isUploading { return true }
        if allFullyReceived && !hasPhoto { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(request.lineItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.description).font(.subheadline).bold()
                            HStack {
                                Text("Requested: \(decStr(item.quantity)) \(item.unit.displayName)")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text("Received")
                                    .font(.caption).foregroundColor(.secondary)
                                TextField("0", value: Binding(
                                    get: { quantities[item.id] ?? 0 },
                                    set: { quantities[item.id] = max(0, $0) }
                                ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                                    .background(Color(.tertiarySystemBackground))
                                    .cornerRadius(6)
                                Text(item.unit.displayName)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if let q = quantities[item.id], q > item.quantity {
                                Label("Over by \(decStr(q - item.quantity))", systemImage: "exclamationmark.triangle")
                                    .font(.caption2).foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Mark received quantities")
                } footer: {
                    if allFullyReceived {
                        Label("Will mark request as Fully Received", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                    } else if anyShort {
                        Label("Will mark request as Partial Receipt", systemImage: "shippingbox.and.arrow.backward")
                            .font(.caption).foregroundColor(.orange)
                    }
                }

                // Photo proof — required to flip to .delivered. PhotosPicker
                // covers both the camera roll and (on iOS 17+) live capture
                // via the system picker. No custom camera UI needed.
                Section {
                    PhotosPicker(
                        selection: $photoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            hasPhoto ? "Replace Photo" : "Attach Delivery Photo",
                            systemImage: "camera.fill"
                        )
                        .foregroundColor(.blue)
                    }
                    .onChange(of: photoItem) { item in
                        Task {
                            guard let data = try? await item?.loadTransferable(type: Data.self),
                                  let img = UIImage(data: data) else { return }
                            photoImage = img
                        }
                    }
                    if let img = photoImage {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 220)
                            .cornerRadius(10)
                    } else if existingPhotoPath != nil {
                        Label("Photo already on file from earlier delivery", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundColor(.green)
                    }
                } header: {
                    Text("Delivery Photo")
                } footer: {
                    if allFullyReceived && !hasPhoto {
                        Label("Photo required to mark as Fully Received.", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundColor(.red)
                    } else {
                        Text("Packing slip or photo of delivered material. Required for final delivery sign-off.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Receive — \(request.requestNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isUploading)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isUploading {
                        ProgressView()
                    } else {
                        Button("Confirm") { Task { await confirm() } }
                            .bold()
                            .disabled(confirmDisabled)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Mark All Fully Received") {
                        for item in request.lineItems {
                            quantities[item.id] = item.quantity
                        }
                    }
                    Spacer()
                    Button("Done") {}
                }
            }
        }
    }

    /// Upload the new photo (if any) before calling onConfirm. Skips upload
    /// when only the existing-on-file photo is present — saves bandwidth on
    /// no-op partial-to-partial saves.
    private func confirm() async {
        var pathToSave: String? = existingPhotoPath
        if let newImage = photoImage {
            isUploading = true
            defer { isUploading = false }
            do {
                pathToSave = try await DeliveryPhotoService.shared.upload(
                    image:     newImage,
                    requestID: request.id,
                    companyID: request.companyID ?? store.currentCompanyID
                )
            } catch {
                ToastService.shared.error(error.localizedDescription)
                return
            }
        }
        onConfirm(quantities, pathToSave)
        dismiss()
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - Delivery Photo Thumbnail

/// Renders a delivery-proof photo from its Supabase Storage path. Resolves
/// to a signed URL on appear (1h TTL — long enough to view, short enough
/// that a leaked URL isn't durably useful). Tap to open in a sheet.
struct DeliveryPhotoThumbnail: View {
    let storagePath: String
    @State private var resolvedURL: URL? = nil
    @State private var showFullScreen = false

    var body: some View {
        Group {
            if let url = resolvedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    case .success(let image):
                        image
                            .resizable().scaledToFit()
                            .frame(maxHeight: 220)
                            .cornerRadius(8)
                            .onTapGesture { showFullScreen = true }
                    case .failure:
                        Label("Couldn't load photo", systemImage: "photo.badge.exclamationmark")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .task { await resolve() }
            }
        }
        .sheet(isPresented: $showFullScreen) {
            if let url = resolvedURL {
                NavigationStack {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showFullScreen = false }
                        }
                    }
                }
            }
        }
    }

    private func resolve() async {
        resolvedURL = await DeliveryPhotoService.shared.signedURL(for: storagePath)
    }
}

// MARK: - Receipt Scan Row

/// Displays a receipt-scan PDF attached to a Material Request. Resolves
/// the storage path to a signed URL on appear; tap to open the PDF in
/// the system viewer (QuickLook via Safari View if iOS handles it).
struct ReceiptScanRow: View {
    let storagePath: String
    @State private var resolvedURL: URL? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scanned receipt").font(.subheadline).bold()
                if resolvedURL == nil {
                    Text("Resolving…").font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("PDF · multi-page supported")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let url = resolvedURL {
                Link("View", destination: url)
                    .font(.caption).bold()
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
        .task { await resolve() }
    }

    private func resolve() async {
        resolvedURL = await ReceiptScanService.shared.signedURL(for: storagePath)
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
    @State private var isSendingToSupplier = false

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
                        // First-class send: renders the PO PDF, registers
                        // it on the project's doc grid, emails the supplier
                        // (with company email CC'd), then flips status to
                        // .sent on dispatch success. Falls back to a toast
                        // when no supplier email is on file rather than
                        // silently flipping status.
                        if isSendingToSupplier {
                            HStack {
                                ProgressView()
                                Text("Sending…").font(.caption).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                        } else {
                            poActionButton("Send to Supplier", icon: "envelope.fill", color: .blue) {
                                Task { await sendPOToSupplier() }
                            }
                            // Cheap escape hatch: if the user wants to flip
                            // status without emailing (e.g. they faxed it,
                            // or already sent out-of-band), keep the
                            // legacy manual transition under a quieter
                            // outline button.
                            Button("Mark as sent without emailing") {
                                store.markPurchaseOrderSent(local)
                                refreshLocal()
                            }
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.top, 2)
                        }
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

    /// Render PO PDF + email it to the supplier. Status flips to .sent
    /// only on dispatch success — failures keep the PO in .draft so the
    /// user can retry after fixing the email or supplier record.
    private func sendPOToSupplier() async {
        isSendingToSupplier = true
        defer { isSendingToSupplier = false }
        #if canImport(UIKit)
        let ok = await PurchaseOrderPDFGenerator.shared.emailToSupplier(po: local, store: store)
        if ok {
            store.markPurchaseOrderSent(local)
            ToastService.shared.success("Sent to \(local.supplierName).")
            refreshLocal()
        }
        #endif
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
