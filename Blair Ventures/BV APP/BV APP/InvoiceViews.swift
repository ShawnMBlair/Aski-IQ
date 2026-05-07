// InvoiceViews.swift
// Aski IQ – Invoicing UI

import SwiftUI

// MARK: - Invoice List View

struct InvoiceListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText: String = ""
    @State private var selectedStatus: InvoiceStatus? = nil
    @State private var showCreate = false
    @State private var showAging  = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [Invoice] {
        store.invoices
            .filter { inv in
                let matchStatus = selectedStatus == nil || inv.status == selectedStatus
                let matchSearch = searchText.isEmpty ||
                    inv.invoiceNumber.localizedCaseInsensitiveContains(searchText) ||
                    inv.billToName.localizedCaseInsensitiveContains(searchText) ||
                    inv.poNumber.localizedCaseInsensitiveContains(searchText)
                return matchStatus && matchSearch
            }
            .sorted { $0.invoiceDate > $1.invoiceDate }
    }

    private var displayed: [Invoice] {
        Array(filtered.prefix(pagination.displayLimit))
    }

    var body: some View {
        NavigationStack {
            listContent
                .searchable(text: $searchText, prompt: "Invoice #, client, PO…")
                .onChange(of: searchText) { pagination.reset() }
                .refreshable { await store.refreshAll() }
                .navigationTitle("Invoices")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showAging = true } label: {
                            Image(systemName: "chart.bar.doc.horizontal")
                        }
                        Button { showCreate = true } label: { Image(systemName: "plus") }
                    }
                }
                .sheet(isPresented: $showCreate) {
                    InvoiceCreateEditView(invoice: nil)
                }
                .sheet(isPresented: $showAging) {
                    InvoiceAgingReportView().environmentObject(store)
                }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            InvoiceSummaryBar()
                .padding(.horizontal)
                .padding(.vertical, 10)
            statusFilterBar
            Divider()
            invoiceListOrEmpty
        }
    }

    private var statusFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isSelected: selectedStatus == nil) {
                    selectedStatus = nil
                    pagination.reset()
                }
                ForEach(InvoiceStatus.allCases, id: \.self) { status in
                    FilterChip(label: status.displayName,
                               isSelected: selectedStatus == status) {
                        selectedStatus = selectedStatus == status ? nil : status
                        pagination.reset()
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var invoiceListOrEmpty: some View {
        if filtered.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.4))
                Text(searchText.isEmpty ? "No Invoices" : "No Results")
                    .font(.headline)
                Text(searchText.isEmpty
                     ? "Tap + to create your first invoice."
                     : "Try adjusting your search or filter.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            List {
                ForEach(displayed) { inv in
                    NavigationLink {
                        InvoiceDetailView(invoice: inv)
                    } label: {
                        InvoiceRow(invoice: inv)
                    }
                }
                LoadMoreFooter(
                    showing: displayed.count,
                    total:   filtered.count,
                    onLoad:  { pagination.loadMore() }
                )
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Summary Bar

private struct InvoiceSummaryBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            SummaryCell(
                label: "Outstanding",
                value: store.totalOutstanding.currencyString,
                color: store.totalOutstanding > 0 ? .orange : .green
            )
            Divider().frame(height: 36)
            SummaryCell(
                label: "Overdue",
                value: "\(store.overdueInvoices.count)",
                color: store.overdueInvoices.isEmpty ? .secondary : .red
            )
            Divider().frame(height: 36)
            SummaryCell(
                label: "Open",
                value: "\(store.openInvoices.count)",
                color: .blue
            )
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct SummaryCell: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline).bold()
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Invoice Row

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(invoice.invoiceNumber)
                    .font(.subheadline).bold()
                    .fontDesign(.monospaced)
                Spacer()
                InvoiceStatusBadge(status: invoice.status)
            }
            if !invoice.billToName.isEmpty {
                Text(invoice.billToName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(invoice.invoiceDate.shortDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(invoice.total.currencyString)
                    .font(.subheadline)
                    .foregroundColor(invoice.status == .paid ? .green : .primary)
                if invoice.balanceDue > 0 && invoice.status != .paid {
                    Text("· \(invoice.balanceDue.currencyString) due")
                        .font(.caption)
                        .foregroundColor(invoice.isOverdue ? .red : .orange)
                }
            }
            if invoice.isOverdue {
                Label("\(invoice.daysPastDue) days overdue", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).bold()
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status Badge

struct InvoiceStatusBadge: View {
    let status: InvoiceStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(invoiceStatusColor(status).opacity(0.15))
            .foregroundColor(invoiceStatusColor(status))
            .cornerRadius(8)
    }
}

func invoiceStatusColor(_ status: InvoiceStatus) -> Color {
    switch status {
    case .draft:   return .secondary
    case .sent:    return .blue
    case .viewed:  return .purple
    case .partial: return .orange
    case .paid:    return .green
    case .overdue: return .red
    case .void:    return .gray
    }
}

// MARK: - Invoice Detail View

struct InvoiceDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let invoice: Invoice

    @State private var localInv: Invoice
    @State private var showEdit      = false
    @State private var showPaySheet  = false
    /// Stripe Checkout sheet — distinct from the manual `showPaySheet`
    /// (which is for in-person / manual payment recording). The two
    /// flows write to the same `payments` array but the path is
    /// different: Stripe writes server-side via webhook, manual
    /// writes client-side and pushes through SyncEngine.
    @State private var showStripeSheet = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF = false

    // Email composer state
    @State private var showEmailSheet:  Bool = false
    @State private var pendingPDFData:  Data? = nil
    @State private var pendingFilename: String = ""
    @State private var showDeleteAlert = false

    init(invoice: Invoice) {
        self.invoice = invoice
        _localInv = State(initialValue: invoice)
    }

    private var project: Project? {
        guard let pid = localInv.projectID else { return nil }
        return store.projects.first { $0.id == pid }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Header card
                invoiceHeaderCard

                // MARK: Bill To
                if !localInv.billToName.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localInv.billToName)
                                .font(.subheadline).bold()
                            if !localInv.billToAddress.isEmpty {
                                Text(localInv.billToAddress)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !localInv.poNumber.isEmpty {
                                Label("PO \(localInv.poNumber)", systemImage: "doc.text")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Bill To").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                // MARK: Line Items
                GroupBox {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Description")
                                .font(.caption).bold().foregroundColor(.secondary)
                            Spacer()
                            Text("Qty")
                                .font(.caption).bold().foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text("Amount")
                                .font(.caption).bold().foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.bottom, 6)

                        Divider()

                        ForEach(localInv.lineItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.description)
                                            .font(.subheadline)
                                        if !item.costCode.isEmpty {
                                            Text(item.costCode)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(decStr(item.quantity))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(item.subtotal.currencyString)
                                        .font(.subheadline)
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.vertical, 5)

                                if item.id != localInv.lineItems.last?.id {
                                    Divider()
                                }
                            }
                        }

                        Divider().padding(.top, 4)

                        // Totals
                        HStack {
                            Text("Subtotal")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(localInv.subtotal.currencyString)
                                .font(.subheadline)
                        }
                        .padding(.top, 6)

                        if localInv.taxAmount > 0 {
                            HStack {
                                Text("GST (\(NSDecimalNumber(decimal: localInv.taxRate * 100).intValue)%)")
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text(localInv.taxAmount.currencyString)
                                    .font(.subheadline)
                            }
                            .padding(.top, 3)
                        }

                        HStack {
                            Text("Total")
                                .font(.subheadline).bold()
                            Spacer()
                            Text(localInv.total.currencyString)
                                .font(.subheadline).bold()
                        }
                        .padding(.top, 4)

                        if localInv.totalPaid > 0 {
                            HStack {
                                Text("Paid")
                                    .font(.caption).foregroundColor(.green)
                                Spacer()
                                Text("- \(localInv.totalPaid.currencyString)")
                                    .font(.subheadline).foregroundColor(.green)
                            }
                            .padding(.top, 3)
                        }

                        HStack {
                            Text("Balance Due")
                                .font(.subheadline).bold()
                                .foregroundColor(localInv.balanceDue > 0 ? (localInv.isOverdue ? .red : .orange) : .green)
                            Spacer()
                            Text(localInv.balanceDue.currencyString)
                                .font(.title3).bold()
                                .foregroundColor(localInv.balanceDue > 0 ? (localInv.isOverdue ? .red : .orange) : .green)
                        }
                        .padding(.top, 6)
                    }
                } label: {
                    Text("Line Items").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 12)

                // MARK: Payments
                if !localInv.payments.isEmpty {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(localInv.payments) { pay in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pay.method.displayName)
                                            .font(.subheadline)
                                        if !pay.reference.isEmpty {
                                            Text(pay.reference)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .fontDesign(.monospaced)
                                        }
                                        Text(pay.receivedDate.shortDate)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(pay.amount.currencyString)
                                        .font(.subheadline).bold()
                                        .foregroundColor(.green)
                                }
                                .padding(.vertical, 5)

                                if pay.id != localInv.payments.last?.id {
                                    Divider()
                                }
                            }
                        }
                    } label: {
                        Text("Payments Received").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                // MARK: Notes
                if !localInv.notes.isEmpty {
                    GroupBox {
                        Text(localInv.notes)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Notes (visible on invoice)").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                if !localInv.internalNotes.isEmpty {
                    GroupBox {
                        Text(localInv.internalNotes)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Internal Notes", systemImage: "lock.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                // MARK: Action Buttons
                actionButtonStack
                    .padding()

            }
            .padding(.bottom, 32)
        }
        .navigationTitle(localInv.invoiceNumber)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isGeneratingPDF {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Menu {
                        Button {
                            exportPDF()
                        } label: { Label("Share PDF…", systemImage: "square.and.arrow.up") }
                        Button {
                            emailPDF()
                        } label: { Label("Email PDF to client…", systemImage: "envelope.fill") }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share or email this invoice")
                }

                if store.currentUserRole.canEstimate ||
                   store.currentUserRole == .officeAdmin ||
                   store.currentUserRole == .manager ||
                   store.currentUserRole == .executive {
                    Button { showEdit = true } label: { Text("Edit") }
                }
            }
        }
        .sheet(isPresented: $showEdit, onDismiss: refreshLocal) {
            InvoiceCreateEditView(invoice: localInv)
        }
        .sheet(isPresented: $showPaySheet, onDismiss: refreshLocal) {
            InvoicePaymentSheet(invoiceID: localInv.id)
        }
        .sheet(isPresented: $showStripeSheet, onDismiss: {
            // Pull fresh state in case the webhook already landed.
            // refreshLocal pulls from store; the actual update lives
            // server-side and arrives on the next SyncEngine pull.
            refreshLocal()
            Task { await store.refreshAll() }
        }) {
            StripeCheckoutSheet(invoice: localInv)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showEmailSheet) {
            if let pdf = pendingPDFData {
                EmailComposeSheet(
                    recipientSuggestions: invoiceClientEmails,
                    defaultSubject: "Invoice \(localInv.invoiceNumber)",
                    defaultBody: invoiceEmailBody,
                    pdfData: pdf,
                    pdfFilename: pendingFilename,
                    entityType: "invoice",
                    entityID: localInv.id,
                    clientID: localInv.clientID,
                    contactID: nil,
                    opportunityID: nil,
                    quoteID: nil,
                    projectID: localInv.projectID
                )
                .environmentObject(store)
            }
        }
        .alert("Delete Invoice", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                store.deleteInvoice(id: localInv.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear { refreshLocal() }
    }

    // MARK: Header Card

    private var invoiceHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localInv.invoiceNumber)
                        .font(.title2).bold()
                        .fontDesign(.monospaced)
                    if let proj = project {
                        Label(proj.name, systemImage: "folder.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                Spacer()
                InvoiceStatusBadge(status: localInv.status)
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invoice Date")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(localInv.invoiceDate.shortDate)
                        .font(.caption).bold()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Due Date")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(localInv.dueDate.shortDate)
                        .font(.caption).bold()
                        .foregroundColor(localInv.isOverdue ? .red : .primary)
                }
                if !localInv.terms.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Terms")
                            .font(.caption2).foregroundColor(.secondary)
                        Text(localInv.terms)
                            .font(.caption).bold()
                    }
                }
                Spacer()
            }

            if localInv.isOverdue {
                Label("\(localInv.daysPastDue) days past due", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).bold()
                    .foregroundColor(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // MARK: Action Buttons

    private var actionButtonStack: some View {
        VStack(spacing: 10) {

            // Mark as Sent
            if localInv.status == .draft {
                Button {
                    markAs(.sent)
                } label: {
                    Label("Mark as Sent", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }

            // Record Payment
            if localInv.status.isOpen {
                Button {
                    showPaySheet = true
                } label: {
                    Label("Record Payment", systemImage: "creditcard.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                // Pay with Stripe (online). Available alongside manual
                // payment recording — the customer pays themselves via
                // a Stripe-hosted Checkout page; webhook updates the
                // invoice on completion. Hidden when balance is zero
                // (e.g. invoice was zeroed out by a manual payment).
                if localInv.balanceDue > 0 {
                    Button {
                        showStripeSheet = true
                    } label: {
                        Label("Pay Online (Stripe)", systemImage: "lock.shield.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
            }

            // QuickBooks push (admin only, only when connection live).
            // Manual button rather than auto-sync so the operator
            // controls when accounting sees a new invoice (drafts,
            // edits-in-progress shouldn't push).
            if store.currentUserRole.isAdmin,
               QBOService.shared.status?.isConnected == true {
                QBOPushInvoiceButton(invoice: localInv)
            }

            // Mark Void
            if localInv.status != .void && localInv.status != .paid {
                if store.currentUserRole == .officeAdmin ||
                   store.currentUserRole == .manager ||
                   store.currentUserRole == .executive {
                    Button {
                        markAs(.void)
                    } label: {
                        Label("Mark as Void", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.gray)
                            .cornerRadius(10)
                    }
                }
            }

            // Delete
            if store.currentUserRole == .officeAdmin ||
               store.currentUserRole == .manager ||
               store.currentUserRole == .executive {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete Invoice", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
            }
        }
    }

    // MARK: Helpers

    private func markAs(_ status: InvoiceStatus) {
        var updated = localInv
        updated.status = status
        if status == .sent { updated.sentAt = Date() }
        store.updateInvoice(updated)
        refreshLocal()
    }

    private func refreshLocal() {
        if let fresh = store.invoices.first(where: { $0.id == invoice.id }) {
            localInv = fresh
        }
    }

    private func exportPDF() {
        isGeneratingPDF = true
        let copy = localInv
        Task.detached(priority: .userInitiated) {
            let pdfData = InvoicePDFRenderer(invoice: copy).render()
            let safe = copy.invoiceNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safe).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems      = [url]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }

    /// Render the invoice PDF and open the email composer with it attached.
    private func emailPDF() {
        isGeneratingPDF = true
        let copy = localInv
        Task.detached(priority: .userInitiated) {
            let pdf = InvoicePDFRenderer(invoice: copy).render()
            let safe = copy.invoiceNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let filename = "\(safe).pdf"
            await MainActor.run {
                pendingPDFData  = pdf
                pendingFilename = filename
                isGeneratingPDF = false
                showEmailSheet  = true
            }
        }
    }

    private var invoiceClientEmails: [String] {
        guard let cid = localInv.clientID else { return [] }
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

    private var invoiceEmailBody: String {
        let signer = store.currentUser?.fullName.isEmpty == false
            ? store.currentUser!.fullName
            : AppSettings.shared.companyName
        let amt = localInv.balanceDue.currencyString
        return """
        Hello,

        Please find invoice \(localInv.invoiceNumber) attached. Balance due: \(amt). Terms: \(localInv.terms.isEmpty ? "Net 30" : localInv.terms).

        Reply to this email if you have any questions about the charges or payment.

        Thanks,
        \(signer)
        """
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        // Show whole numbers without decimal
        if n.decimalValue == d && d == Decimal(Int(truncating: n)) {
            return "\(Int(truncating: n))"
        }
        return NSDecimalNumber(decimal: d).stringValue
    }
}

// MARK: - Invoice Create / Edit View

struct InvoiceCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let invoice: Invoice?

    @State private var invoiceNumber: String
    @State private var invoiceDate: Date
    @State private var dueDate: Date
    @State private var status: InvoiceStatus
    @State private var selectedProjectID: UUID?
    @State private var selectedClientID: UUID?
    @State private var billToName: String
    @State private var billToAddress: String
    @State private var poNumber: String
    @State private var terms: String
    @State private var taxRate: Decimal
    @State private var lineItems: [InvoiceLineItem]
    @State private var notes: String
    @State private var internalNotes: String

    @State private var showAddLine   = false
    @State private var editingLineIdx: Int? = nil

    // Phase-2 deferred audit fix: concurrent-edit detection on edits.
    @State private var editingBaselineUpdatedAt: Date = Date()
    @State private var conflictServerInvoice: Invoice? = nil
    @State private var showConflictAlert = false
    @State private var pendingLocalInvoice: Invoice? = nil

    init(invoice: Invoice?) {
        self.invoice = invoice
        let inv = invoice
        _invoiceNumber   = State(initialValue: inv?.invoiceNumber ?? "")
        _invoiceDate     = State(initialValue: inv?.invoiceDate ?? Date())
        _dueDate         = State(initialValue: inv?.dueDate ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())!)
        _status          = State(initialValue: inv?.status ?? .draft)
        _selectedProjectID = State(initialValue: inv?.projectID)
        _selectedClientID  = State(initialValue: inv?.clientID)
        _billToName      = State(initialValue: inv?.billToName ?? "")
        _billToAddress   = State(initialValue: inv?.billToAddress ?? "")
        _poNumber        = State(initialValue: inv?.poNumber ?? "")
        _terms           = State(initialValue: inv?.terms ?? "Net 30")
        _taxRate         = State(initialValue: inv?.taxRate ?? 0.05)
        _lineItems       = State(initialValue: inv?.lineItems ?? [])
        _notes           = State(initialValue: inv?.notes ?? "")
        _internalNotes   = State(initialValue: inv?.internalNotes ?? "")
        // Capture baseline timestamp for the conflict pre-check on
        // save. Edit path only uses this — new invoices skip the
        // check (no row to compare against).
        _editingBaselineUpdatedAt = State(initialValue: inv?.updatedAt ?? Date())
    }

    private var isNew: Bool { invoice == nil }

    /// Phase 9 (lock-on-terminal-state): once an invoice is paid or
    /// voided, its line items and totals are part of the financial
    /// record. Editing them post-terminal would shift AR balances,
    /// recognized revenue, and reconciliation reports without an
    /// audit trail. The lock is iOS-only — server still allows
    /// admin-driven corrections via direct SQL.
    /// Locked states: `.paid`, `.void`. Open states (`.draft`,
    /// `.sent`, `.viewed`, `.partial`, `.overdue`) remain editable.
    private var isLocked: Bool {
        guard let inv = invoice else { return false }
        return inv.status == .paid || inv.status == .void
    }

    private var lockedReason: String {
        switch invoice?.status {
        case .paid: return "Invoice paid"
        case .void: return "Invoice voided"
        default:    return "Invoice locked"
        }
    }

    // Computed totals for preview
    private var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.subtotal }
    }
    private var taxableSubtotal: Decimal {
        lineItems.filter { $0.taxable }.reduce(0) { $0 + $1.subtotal }
    }
    private var taxAmount: Decimal {
        (taxableSubtotal * taxRate).rounded(scale: 2)
    }
    private var total: Decimal { subtotal + taxAmount }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked {
                    Section {
                        lockedBanner
                    }
                    .listRowInsets(EdgeInsets())
                }
                headerSection
                projectClientSection
                billToSection
                lineItemsSection
                taxSection
                notesSection
            }
            .disabled(isLocked)
            .navigationTitle(isNew ? "New Invoice" : "Edit Invoice")
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
                        Button("Save") { save() }.bold()
                            .disabled(invoiceNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if isNew && invoiceNumber.isEmpty {
                    invoiceNumber = store.nextInvoiceNumber()
                }
            }
            .alert("Someone else updated this invoice",
                   isPresented: $showConflictAlert) {
                Button("Overwrite with my changes", role: .destructive) {
                    if let inv = pendingLocalInvoice {
                        store.updateInvoice(inv)
                        dismiss()
                    }
                }
                Button("Discard my changes", role: .cancel) {
                    Task { await store.refreshAll() }
                    dismiss()
                }
            } message: {
                if let server = conflictServerInvoice {
                    let by = server.lastModifiedBy.isEmpty ? "another user" : server.lastModifiedBy
                    let when = server.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    Text("\(by) updated this invoice on the server at \(when), after you opened it. Saving now would overwrite their changes.")
                } else {
                    Text("The server has newer changes than your local copy.")
                }
            }
            .sheet(isPresented: $showAddLine) {
                InvoiceLineItemEditSheet(item: nil) { lineItems.append($0) }
            }
            .sheet(item: Binding(
                get: { editingLineIdx.map { IdentifiableIndex(value: $0) } },
                set: { editingLineIdx = $0?.value }
            )) { wrap in
                InvoiceLineItemEditSheet(item: lineItems[wrap.value]) { lineItems[wrap.value] = $0 }
            }
        }
    }

    // MARK: Form Sections

    private var headerSection: some View {
        Section("Invoice Details") {
            HStack {
                Text("Invoice #")
                TextField("BV-INV-2026-0001", text: $invoiceNumber)
                    .multilineTextAlignment(.trailing)
                    .fontDesign(.monospaced)
            }
            DatePicker("Invoice Date", selection: $invoiceDate, displayedComponents: .date)
            DatePicker("Due Date",     selection: $dueDate,     displayedComponents: .date)
            Picker("Status", selection: $status) {
                ForEach(InvoiceStatus.allCases, id: \.self) { s in
                    Text(s.displayName).tag(s)
                }
            }
            HStack {
                Text("Terms")
                TextField("Net 30", text: $terms).multilineTextAlignment(.trailing)
            }
        }
    }

    private var projectClientSection: some View {
        Section("Project & Client") {
            Picker("Project", selection: $selectedProjectID) {
                Text("None").tag(UUID?.none)
                ForEach(store.projects.filter { $0.status == .active }) { proj in
                    Text(proj.name).tag(Optional(proj.id))
                }
            }
            .onChange(of: selectedProjectID) { newVal in
                guard let pid = newVal,
                      let proj = store.projects.first(where: { $0.id == pid }) else { return }
                // Auto-fill bill-to from client name match
                if let client = store.clients.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(proj.clientName) == .orderedSame
                }) {
                    if selectedClientID == nil { selectedClientID = client.id }
                    if billToName.isEmpty    { billToName    = client.name }
                    if billToAddress.isEmpty { billToAddress = client.fullBillingAddress }
                } else if billToName.isEmpty {
                    billToName = proj.clientName
                }
            }

            Picker("Client", selection: $selectedClientID) {
                Text("None").tag(UUID?.none)
                ForEach(store.clients) { client in
                    Text(client.name).tag(Optional(client.id))
                }
            }
            .onChange(of: selectedClientID) { newVal in
                guard let cid = newVal,
                      let client = store.clients.first(where: { $0.id == cid }) else { return }
                if billToName.isEmpty    { billToName    = client.name }
                if billToAddress.isEmpty { billToAddress = client.fullBillingAddress }
            }
        }
    }

    private var billToSection: some View {
        Section("Bill To") {
            TextField("Company / Person Name", text: $billToName)
            TextField("Address", text: $billToAddress, axis: .vertical).lineLimit(3)
            HStack {
                Text("PO #")
                TextField("Optional", text: $poNumber).multilineTextAlignment(.trailing)
            }
        }
    }

    private var lineItemsSection: some View {
        Section {
            ForEach(Array(lineItems.enumerated()), id: \.element.id) { idx, item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description).font(.subheadline)
                        Text("\(decStr(item.quantity)) × \(item.unitPrice.currencyString)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(item.subtotal.currencyString).font(.subheadline)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingLineIdx = idx }
            }
            .onDelete { lineItems.remove(atOffsets: $0) }

            Button { showAddLine = true } label: {
                Label("Add Line Item", systemImage: "plus.circle")
            }
        } header: {
            Text("Line Items")
        } footer: {
            lineItemsFooter
        }
    }

    @ViewBuilder
    private var lineItemsFooter: some View {
        if !lineItems.isEmpty {
            VStack(alignment: .trailing, spacing: 2) {
                HStack { Text("Subtotal"); Spacer(); Text(subtotal.currencyString) }
                HStack {
                    Text("GST (\(NSDecimalNumber(decimal: taxRate * 100).intValue)%)")
                    Spacer()
                    Text(taxAmount.currencyString)
                }
                HStack { Text("Total").bold(); Spacer(); Text(total.currencyString).bold() }
            }
            .font(.footnote)
            .padding(.top, 4)
        }
    }

    private var taxSection: some View {
        Section("Tax") {
            HStack {
                Text("Tax Rate")
                Spacer()
                TextField("0.05", value: $taxRate, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("%").foregroundColor(.secondary)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Visible on invoice (optional)", text: $notes, axis: .vertical).lineLimit(3)
            TextField("Internal notes (not printed)", text: $internalNotes, axis: .vertical).lineLimit(3)
        }
    }

    // MARK: - Locked banner

    @ViewBuilder
    private var lockedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — \(lockedReason.lowercased())")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text("This invoice is part of the financial record. Editing line items, totals, or tax would shift AR balances and revenue recognition without an audit trail.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }

    private func save() {
        // Phase 9 lock — defensive guard. Toolbar swaps Save for a
        // Locked label when isLocked, but if any code path slips
        // through we abort with a clear message.
        if isLocked {
            ToastService.shared.error("This invoice is \(lockedReason.lowercased()) and is locked.")
            return
        }
        // Week 4 audit closeout: validate the minimum required-field
        // set BEFORE we touch the store. Pre-fix users could mint a
        // draft invoice with no number, no client, no line items —
        // which then hit RLS WITH CHECK and silently failed to push.
        let trimmedNumber = invoiceNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmedNumber.isEmpty else {
            ToastService.shared.error("Invoice number is required.")
            return
        }
        guard selectedClientID != nil || !billToName.trimmingCharacters(in: .whitespaces).isEmpty else {
            ToastService.shared.error("Pick a client or enter a Bill To name.")
            return
        }
        guard !lineItems.isEmpty else {
            ToastService.shared.error("Add at least one line item.")
            return
        }
        // Defence-in-depth: line-item editor already disables Done
        // when either field is non-positive, but a malformed import
        // could land lineItems that fail this check. Surface the
        // first offender so the operator can fix it.
        if let bad = lineItems.first(where: { $0.quantity <= 0 || $0.unitPrice <= 0 }) {
            ToastService.shared.error("Line item \"\(bad.description)\" has zero quantity or price.")
            return
        }

        var inv = invoice ?? Invoice(invoiceNumber: invoiceNumber)
        inv.invoiceNumber   = trimmedNumber
        inv.invoiceDate     = invoiceDate
        inv.dueDate         = dueDate
        inv.status          = status
        inv.projectID       = selectedProjectID
        inv.clientID        = selectedClientID
        inv.billToName      = billToName
        inv.billToAddress   = billToAddress
        inv.poNumber        = poNumber
        inv.terms           = terms
        inv.taxRate         = taxRate
        inv.lineItems       = lineItems
        inv.notes           = notes
        inv.internalNotes   = internalNotes
        inv.updatedAt       = Date()

        // Phase-2 deferred audit fix: concurrent-edit pre-check on
        // edits only. New invoices can't conflict (no row to
        // compare against on the server).
        if isNew {
            store.addInvoice(inv)
            dismiss()
        } else {
            pendingLocalInvoice = inv
            Task { @MainActor in
                let result = await ConflictDetectionService.shared.checkInvoice(
                    id:                inv.id,
                    baselineUpdatedAt: editingBaselineUpdatedAt
                )
                switch result {
                case .clean, .checkFailed, .notFound:
                    store.updateInvoice(inv)
                    dismiss()
                case .conflict(let server):
                    conflictServerInvoice = server
                    showConflictAlert     = true
                }
            }
        }
    }

    private func decStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        if d == Decimal(Int(truncating: n)) { return "\(Int(truncating: n))" }
        return n.stringValue
    }
}

// MARK: - Line Item Edit Sheet

struct InvoiceLineItemEditSheet: View {
    @Environment(\.dismiss) var dismiss
    let item: InvoiceLineItem?
    let onSave: (InvoiceLineItem) -> Void

    @State private var description: String
    @State private var quantity:  Decimal
    @State private var unitPrice: Decimal
    @State private var taxable:   Bool
    @State private var costCode:  String

    init(item: InvoiceLineItem?, onSave: @escaping (InvoiceLineItem) -> Void) {
        self.item   = item
        self.onSave = onSave
        _description = State(initialValue: item?.description ?? "")
        _quantity    = State(initialValue: item?.quantity   ?? 1)
        _unitPrice   = State(initialValue: item?.unitPrice  ?? 0)
        _taxable     = State(initialValue: item?.taxable    ?? true)
        _costCode    = State(initialValue: item?.costCode   ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Line Item") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2)
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("1", value: $quantity, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Unit Price")
                        Spacer()
                        TextField("0.00", value: $unitPrice, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Cost Code")
                        TextField("Optional", text: $costCode)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Taxable (GST)", isOn: $taxable)
                }

                Section {
                    HStack {
                        Text("Subtotal")
                        Spacer()
                        Text((quantity * unitPrice).currencyString)
                            .bold()
                    }
                }
            }
            .navigationTitle(item == nil ? "Add Line Item" : "Edit Line Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        var updated = item ?? InvoiceLineItem(description: description)
                        updated.description = description.trimmingCharacters(in: .whitespaces)
                        updated.quantity    = quantity
                        updated.unitPrice   = unitPrice
                        updated.taxable     = taxable
                        updated.costCode    = costCode
                        onSave(updated)
                        dismiss()
                    }
                    .bold()
                    // Week 4 audit closeout: validate line item math
                    // before save. Pre-fix you could create a row with
                    // qty = 0 OR unit price = 0 and end up with a $0
                    // line on the invoice. Now Done is greyed out
                    // until both fields are positive (the description
                    // check stays as the third leg of the validation).
                    .disabled(
                        description.trimmingCharacters(in: .whitespaces).isEmpty
                        || quantity  <= 0
                        || unitPrice <= 0
                    )
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Payment Sheet

struct InvoicePaymentSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let invoiceID: UUID

    @State private var amount: Decimal = 0
    @State private var method: PaymentMethod = .eft
    @State private var receivedDate = Date()
    @State private var reference = ""
    @State private var notes     = ""

    private var invoice: Invoice? {
        store.invoices.first { $0.id == invoiceID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let inv = invoice {
                    Section("Invoice") {
                        HStack {
                            Text(inv.invoiceNumber)
                                .fontDesign(.monospaced).font(.subheadline)
                            Spacer()
                            Text("Due: \(inv.balanceDue.currencyString)")
                                .foregroundColor(.orange).font(.subheadline).bold()
                        }
                    }
                }

                Section("Payment Details") {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0.00", value: $amount, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    DatePicker("Date Received", selection: $receivedDate, displayedComponents: .date)
                    HStack {
                        Text("Reference")
                        TextField("Cheque #, Txn ID…", text: $reference)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Notes (optional)", text: $notes)
                }
            }
            .navigationTitle("Record Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let payment = InvoicePayment(
                            amount: amount,
                            method: method,
                            receivedDate: receivedDate,
                            reference: reference,
                            notes: notes
                        )
                        store.recordPayment(payment, on: invoiceID)
                        dismiss()
                    }
                    .bold()
                    .disabled(amount <= 0)
                }
            }
            .onAppear {
                // Pre-fill with balance due
                if let inv = invoice { amount = inv.balanceDue }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Project Invoice Section

struct ProjectInvoiceSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    private var invoices: [Invoice] {
        store.invoices(for: project.id)
    }

    private var totalBilled: Decimal {
        invoices.reduce(0) { $0 + $1.total }
    }

    private var totalPaid: Decimal {
        invoices.reduce(0) { $0 + $1.totalPaid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Invoices", count: invoices.count)
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.blue)
                }
                .padding(.trailing)
            }

            if invoices.isEmpty {
                Text("No invoices for this project.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                // Summary row
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Billed").font(.caption2).foregroundColor(.secondary)
                        Text(totalBilled.currencyString).font(.caption).bold()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Collected").font(.caption2).foregroundColor(.secondary)
                        Text(totalPaid.currencyString).font(.caption).bold().foregroundColor(.green)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Outstanding").font(.caption2).foregroundColor(.secondary)
                        Text((totalBilled - totalPaid).currencyString)
                            .font(.caption).bold()
                            .foregroundColor((totalBilled - totalPaid) > 0 ? .orange : .secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.bottom, 6)

                ForEach(invoices.prefix(5)) { inv in
                    NavigationLink {
                        InvoiceDetailView(invoice: inv)
                    } label: {
                        InvoiceRow(invoice: inv)
                            .padding(.horizontal)
                    }
                    Divider().padding(.leading)
                }

                if invoices.count > 5 {
                    NavigationLink {
                        InvoiceListView()
                    } label: {
                        Text("View all \(invoices.count) invoices")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            InvoiceCreateEditView(
                invoice: {
                    var inv = Invoice(invoiceNumber: store.nextInvoiceNumber(), projectID: project.id)
                    // Match client by name
                    if let client = store.clients.first(where: {
                        $0.name.localizedCaseInsensitiveCompare(project.clientName) == .orderedSame
                    }) {
                        inv.clientID      = client.id
                        inv.billToName    = client.name
                        inv.billToAddress = client.fullBillingAddress
                    } else {
                        inv.billToName = project.clientName
                    }
                    return inv
                }()
            )
        }
    }
}

// MARK: - Identifiable Index helper (for sheet binding on array index)

private struct IdentifiableIndex: Identifiable {
    let id: Int
    let value: Int
    init(value: Int) { self.id = value; self.value = value }
}

// MARK: - Invoice Aging Report

struct InvoiceAgingReportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// Grouping mode for the body of the report. Buckets shows the standard
    /// bucket-first drill-down; clients shows aging totals per client so admins
    /// can quickly see who owes what across all overdue periods.
    private enum Grouping: String, CaseIterable, Identifiable {
        case buckets = "By Aging"
        case clients = "By Client"
        var id: String { rawValue }
    }
    @State private var grouping: Grouping = .buckets

    /// Per-client aggregate of all open invoices, sorted by total owed desc.
    private struct ClientAging: Identifiable {
        let id: UUID
        let name: String
        let invoices: [Invoice]
        var total: Decimal { invoices.reduce(0) { $0 + $1.balanceDue } }
        var oldestDaysOverdue: Int {
            invoices.compactMap { inv -> Int? in
                guard inv.isOverdue else { return nil }
                return Calendar.current.dateComponents([.day], from: inv.dueDate, to: Date()).day
            }.max() ?? 0
        }
        var hasOverdue: Bool { invoices.contains(where: { $0.isOverdue }) }
    }

    private var clientAging: [ClientAging] {
        let open = store.invoices.filter {
            $0.status != .paid && $0.status != .void && $0.balanceDue > 0
        }
        let grouped = Dictionary(grouping: open, by: { $0.clientID ?? UUID() })
        return grouped.compactMap { (cid, invs) -> ClientAging? in
            guard let id = invs.first?.clientID else { return nil }
            let name = store.client(id: id)?.name ?? invs.first?.billToName ?? "Unknown client"
            return ClientAging(id: id, name: name, invoices: invs)
        }
        .sorted { $0.total > $1.total }
    }

    private struct AgingBucket: Identifiable {
        let id: String
        let label: String
        let color: Color
        let invoices: [Invoice]
        var total: Decimal { invoices.reduce(0) { $0 + $1.balanceDue } }
    }

    private var buckets: [AgingBucket] {
        let open = store.invoices.filter {
            $0.status != .paid && $0.status != .void && $0.balanceDue > 0
        }
        let now = Date()
        func daysOverdue(_ inv: Invoice) -> Int {
            max(0, Calendar.current.dateComponents([.day], from: inv.dueDate, to: now).day ?? 0)
        }
        return [
            AgingBucket(id: "current", label: "Current",
                        color: .blue,
                        invoices: open.filter { !$0.isOverdue }),
            AgingBucket(id: "1-30",   label: "1–30 Days",
                        color: .orange,
                        invoices: open.filter { $0.isOverdue && daysOverdue($0) <= 30 }),
            AgingBucket(id: "31-60",  label: "31–60 Days",
                        color: .orange,
                        invoices: open.filter { let d = daysOverdue($0); return d > 30 && d <= 60 }),
            AgingBucket(id: "61-90",  label: "61–90 Days",
                        color: .red,
                        invoices: open.filter { let d = daysOverdue($0); return d > 60 && d <= 90 }),
            AgingBucket(id: "90+",    label: "90+ Days",
                        color: .red,
                        invoices: open.filter { daysOverdue($0) > 90 }),
        ]
    }

    private var grandTotal: Decimal { buckets.reduce(0) { $0 + $1.total } }

    var body: some View {
        NavigationStack {
            List {
                // Grand total header
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total Outstanding")
                                .font(.subheadline).foregroundColor(.secondary)
                            Text(grandTotal.currencyString)
                                .font(.title2.weight(.bold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Open Invoices")
                                .font(.subheadline).foregroundColor(.secondary)
                            Text("\(buckets.flatMap(\.invoices).count)")
                                .font(.title2.weight(.bold))
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Aging bar chart
                Section {
                    AgingBarChart(buckets: buckets.map { ($0.label, $0.total, $0.color) },
                                  grandTotal: grandTotal)
                    .frame(height: 120)
                    .padding(.vertical, 8)
                } header: {
                    Text("Aging Distribution")
                }

                // Grouping toggle
                Section {
                    Picker("Group by", selection: $grouping) {
                        ForEach(Grouping.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if grouping == .buckets {
                    // Bucket drill-downs
                    ForEach(buckets) { bucket in
                        if !bucket.invoices.isEmpty {
                            Section {
                                ForEach(bucket.invoices) { inv in
                                    NavigationLink(destination: InvoiceDetailView(invoice: inv).environmentObject(store)) {
                                        AgingInvoiceRow(invoice: inv)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(bucket.label)
                                    Spacer()
                                    Text(bucket.total.currencyString)
                                        .foregroundColor(bucket.color)
                                        .fontWeight(.semibold)
                                    Text("(\(bucket.invoices.count))")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    // Per-client aging — total owed + count + oldest overdue,
                    // tap-to-expand into per-invoice list.
                    Section {
                        ForEach(clientAging) { client in
                            DisclosureGroup {
                                ForEach(client.invoices.sorted { $0.dueDate < $1.dueDate }) { inv in
                                    NavigationLink(destination: InvoiceDetailView(invoice: inv).environmentObject(store)) {
                                        AgingInvoiceRow(invoice: inv)
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.name).font(.subheadline).bold()
                                        Text("\(client.invoices.count) open invoice\(client.invoices.count == 1 ? "" : "s")")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(client.total.currencyString)
                                            .font(.subheadline).bold()
                                            .foregroundColor(client.hasOverdue ? .red : .primary)
                                        if client.hasOverdue {
                                            Text("Oldest \(client.oldestDaysOverdue)d overdue")
                                                .font(.caption2).foregroundColor(.red)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Outstanding by Client")
                    } footer: {
                        if clientAging.isEmpty {
                            Text("No outstanding balances.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Aging Report")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Aging Bar Chart

private struct AgingBarChart: View {
    let buckets: [(label: String, value: Decimal, color: Color)]
    let grandTotal: Decimal

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(buckets.indices, id: \.self) { i in
                let b = buckets[i]
                let fraction = grandTotal > 0
                    ? CGFloat(NSDecimalNumber(decimal: b.value / grandTotal).doubleValue)
                    : 0
                VStack(spacing: 4) {
                    if b.value > 0 {
                        Text(b.value.currencyString)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(b.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(b.value > 0 ? b.color.opacity(0.85) : Color(.systemFill))
                        .frame(height: max(4, 80 * fraction))
                    Text(b.label)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Aging Invoice Row

private struct AgingInvoiceRow: View {
    let invoice: Invoice

    private var daysOverdue: Int {
        guard invoice.isOverdue else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: invoice.dueDate, to: Date()).day ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.invoiceNumber)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.monospaced)
                Spacer()
                Text(invoice.balanceDue.currencyString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(invoice.isOverdue ? .red : .primary)
            }
            HStack {
                Text(invoice.billToName.isEmpty ? "—" : invoice.billToName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if invoice.isOverdue {
                    Text("\(daysOverdue)d overdue")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.red)
                } else {
                    Text("Due \(invoice.dueDate.shortDate)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

