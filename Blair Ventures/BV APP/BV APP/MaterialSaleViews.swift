// MaterialSaleViews.swift
// AskiCommand — Material Sale UI
//
// Standalone commercial workflow: sell products/materials/rentals without a project.
// Every sale auto-links to a CRM opportunity on first save.

import SwiftUI

// MARK: - Material Sale List View

struct MaterialSaleListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate  = false
    @State private var searchText  = ""
    @State private var filterStatus: MaterialSaleStatus? = nil
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [MaterialSale] {
        store.materialSales
            .filter { !$0.isDeleted }
            .filter { filterStatus == nil || $0.status == filterStatus }
            .filter {
                searchText.isEmpty ||
                $0.saleNumber.localizedCaseInsensitiveContains(searchText) ||
                (store.client(id: $0.clientID)?.name ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Phase 7 first-launch sync gate. Material Sales reference
                // clients + opportunities + (optionally) quotes — all
                // server-resident.
                if !store.hasCompletedFirstSync {
                    FirstLaunchSyncGateBanner()
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                // Status filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: filterStatus == nil) {
                            filterStatus = nil
                        }
                        ForEach(MaterialSaleStatus.allCases, id: \.self) { s in
                            FilterChip(
                                label: s.displayName,
                                isSelected: filterStatus == s
                            ) { filterStatus = filterStatus == s ? nil : s }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                Divider()

                if filtered.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "shippingbox")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary)
                        Text("No material sales yet.")
                            .font(.headline)
                        Text("Tap + to create your first sale.")
                            .font(.subheadline).foregroundColor(.secondary)
                        Button("New Sale") {
                            // Phase 7 / Decision 1: route through
                            // CommercialIntakeView so Material Sales
                            // gain the same opportunity + client gate
                            // already applied to Estimates.
                            showCreate = true
                        }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(Array(filtered.prefix(pagination.displayLimit))) { sale in
                            NavigationLink(destination: MaterialSaleDetailView(sale: sale)) {
                                MaterialSaleListRow(sale: sale)
                            }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, filtered.count),
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)    { _ in pagination.reset() }
                    .onChange(of: filterStatus)  { _ in pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search sales or client")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Material Sales")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.hasCompletedFirstSync)
                }
            }
            // Phase 7 / Decision 1: route MaterialSale create through
            // CommercialIntakeView. This is the same hub the Estimate
            // create flow uses — it forces a work-type pick (which we
            // pre-fill to .materialSale here) and then a client
            // selection before opening MaterialSaleCreateEditView with
            // a populated CommercialContext. Pre-fix the `+` opened
            // the create form with no client / opportunity, letting
            // the user fill out an entire sale before discovering it
            // wouldn't push.
            .sheet(isPresented: $showCreate) {
                CommercialIntakeView(
                    prefillContext: CommercialContext(
                        workType: .materialSale,
                        source: .intake
                    )
                )
                .environmentObject(store)
            }
        }
    }
}

// MARK: - Material Sale List Row

struct MaterialSaleListRow: View {
    let sale: MaterialSale
    @EnvironmentObject var store: AppStore

    private var clientName: String {
        store.client(id: sale.clientID)?.name ?? "Unknown Client"
    }

    var statusColor: Color {
        switch sale.status {
        case .draft:     return .secondary
        case .quoted:    return .blue
        case .ordered:   return .orange
        case .invoiced:  return .purple
        case .paid:      return .green
        case .cancelled: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sale.saleNumber.isEmpty ? "Draft" : sale.saleNumber)
                    .font(.caption).bold()
                    .foregroundColor(.purple)
                    .fontDesign(.monospaced)
                Spacer()
                // Status badge
                Text(sale.status.displayName)
                    .font(.caption2).bold()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(6)
            }
            HStack(spacing: 6) {
                Image(systemName: sale.saleType.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(sale.saleType.displayName)
                    .font(.caption).foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary).font(.caption)
                Text(clientName)
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 14) {
                Label("\(sale.lineItems.count) item\(sale.lineItems.count == 1 ? "" : "s")", systemImage: "list.bullet")
                    .font(.caption).foregroundColor(.secondary)
                Label(sale.grandTotal.currencyString, systemImage: "dollarsign.circle")
                    .font(.caption).bold()
                if sale.opportunityID != nil {
                    Label("CRM", systemImage: "link")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .foregroundColor(.purple)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Material Sale Detail View

struct MaterialSaleDetailView: View {
    let sale: MaterialSale
    @EnvironmentObject var store: AppStore
    @State private var localSale: MaterialSale
    @State private var showEdit   = false
    @State private var showDelete = false

    // PDF generation + share flow plumbing.
    @State private var isGeneratingPDF: Bool = false
    @State private var shareItems:      [Any] = []
    @State private var showShareSheet:  Bool = false
    @State private var pdfErrorMessage: String? = nil
    @State private var showPDFError:    Bool = false

    // Review-before-send sheet (Path-A clone of QuoteSendReviewSheet).
    // Tapping "Send for Customer Acceptance" opens this; tapping its
    // Send button THEN runs the email pipeline directly via
    // EmailService.sendPDF — no separate EmailComposeSheet.
    // Status flips ONLY on email-success.
    @State private var showReviewSheet: Bool = false

    // Acceptance status pill + revoke flow.
    @State private var acceptanceStatus: MaterialSaleAcceptanceService.AcceptanceStatus? = nil
    @State private var isLoadingAcceptanceStatus: Bool = false
    @State private var showRevokeConfirm: Bool = false

    init(sale: MaterialSale) {
        self.sale = sale
        self._localSale = State(initialValue: sale)
    }

    private var client: Client? { store.client(id: localSale.clientID) }
    private var contact: CRMContact? {
        guard let cid = localSale.contactID else { return nil }
        return store.crmContacts.first { $0.id == cid }
    }
    private var linkedOpp: CRMOpportunity? {
        guard let oppID = localSale.opportunityID else { return nil }
        return store.crmOpportunities.first { $0.id == oppID && !$0.isDeleted }
    }
    private var linkedQuote: Quote? {
        guard let qid = localSale.quoteID else { return nil }
        return store.quotes.first { $0.id == qid }
    }

    var statusColor: Color {
        switch localSale.status {
        case .draft:     return .secondary
        case .quoted:    return .blue
        case .ordered:   return .orange
        case .invoiced:  return .purple
        case .paid:      return .green
        case .cancelled: return .gray
        }
    }

    // body is split into focused helpers because the SwiftUI type-checker
    // hits "expression too complex" once you stack 4+ sheets, 2 alerts,
    // a toolbar, and a scroll view on a single chain. Each helper is
    // independently type-checkable, which keeps build times sane and
    // makes future edits localized.
    var body: some View {
        let title = localSale.saleNumber.isEmpty ? "Material Sale" : localSale.saleNumber
        return mainContent
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: { topToolbar })
            .sheet(isPresented: $showEdit) { editSheet() }
            .sheet(isPresented: $showReviewSheet) { reviewSheetContent() }
            .sheet(isPresented: $showShareSheet) { shareSheet() }
            .alert("Couldn't generate PDF",
                   isPresented: $showPDFError,
                   actions: { Button("OK", role: .cancel) {} },
                   message: { Text(pdfErrorMessage ?? "Try again or contact support.") })
            .alert("Revoke acceptance link?",
                   isPresented: $showRevokeConfirm,
                   actions: revokeAlertActions,
                   message: { Text("The customer's link will stop working immediately. Mint a new link by re-sending the sale.") })
            .alert("Delete Sale?",
                   isPresented: $showDelete,
                   actions: { deleteAlertActions() },
                   message: { Text("This action cannot be undone.") })
            .task(id: localSale.id) {
                await reloadAcceptanceStatus()
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                if !localSale.lineItems.isEmpty { lineItemsCard }
                totalsCard
                crmCard
                if let q = linkedQuote { linkedQuoteCard(q) }
                actionsCard
                Spacer(minLength: 40)
            }
            .padding(.top)
        }
    }

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button("Edit") { showEdit = true }
                Divider()
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func editSheet() -> some View {
        MaterialSaleCreateEditView(existing: localSale)
            .onDisappear {
                if let updated = store.materialSales.first(where: { $0.id == localSale.id }) {
                    localSale = updated
                }
            }
    }

    /// Review-before-send sheet. Mirrors QuoteSendReviewSheet —
    /// collects recipients + acceptance toggle, runs `runReviewedSend`
    /// when the user taps Send. Status advance happens in
    /// `handleReviewedSendSuccess` only on confirmed email-success.
    @ViewBuilder
    private func reviewSheetContent() -> some View {
        MaterialSaleSendReviewSheet(
            sale: localSale,
            performSend: { recipients, includeLink in
                await runReviewedSend(
                    recipients: recipients,
                    includeAcceptanceLink: includeLink
                )
            },
            onSendSucceeded: {
                handleReviewedSendSuccess()
            }
        )
        .environmentObject(store)
    }

    @ViewBuilder
    private func shareSheet() -> some View {
        ShareSheet(items: shareItems)
    }

    @ViewBuilder
    private func deleteAlertActions() -> some View {
        Button("Delete", role: .destructive) { store.deleteMaterialSale(localSale) }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func revokeAlertActions() -> some View {
        Button("Revoke", role: .destructive) {
            Task { await revokeAcceptanceLink() }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Sub-views

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(localSale.saleType.displayName, systemImage: localSale.saleType.icon)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(localSale.status.displayName)
                    .font(.caption).bold()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(6)
            }
            if let client { Text(client.name).font(.headline) }
            if let contact {
                Label(contact.fullName, systemImage: "person.fill")
                    .font(.caption).foregroundColor(.blue)
            }
            if let addr = localSale.deliveryAddress, !addr.isEmpty {
                Label(addr, systemImage: "shippingbox")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let date = localSale.requestedDeliveryDate {
                Label("Deliver by \(date.shortDate)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundColor(date < Date() ? .red : .secondary)
            }
            if let notes = localSale.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var lineItemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Line Items", count: localSale.lineItems.count)
            VStack(spacing: 0) {
                ForEach(localSale.lineItems) { item in
                    MaterialSaleLineItemRow(item: item)
                    if item.id != localSale.lineItems.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var totalsCard: some View {
        VStack(spacing: 0) {
            totalRow("Subtotal", value: localSale.subtotal)
            if localSale.taxRate > 0 {
                totalRow("Tax (\(localSale.taxRate)%)", value: localSale.taxAmount)
            }
            Divider()
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(localSale.grandTotal.currencyString).font(.headline)
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func totalRow(_ label: String, value: Decimal) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value.currencyString)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var crmCard: some View {
        Group {
            if let opp = linkedOpp {
                NavigationLink(destination: CRMOpportunityDetailView(opportunity: opp)) {
                    HStack(spacing: 12) {
                        Image(systemName: "link.circle.fill")
                            .font(.title2).foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CRM Opportunity")
                                .font(.caption).foregroundColor(.secondary)
                            Text(opp.title)
                                .font(.subheadline).bold().lineLimit(1)
                            Label(opp.stage.rawValue, systemImage: opp.stage.icon)
                                .font(.caption).foregroundColor(opp.stage.color)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.purple.opacity(0.06))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Not linked to CRM")
                        .font(.subheadline).bold()
                    Spacer()
                    Button {
                        var mutable = localSale
                        store.ensureMaterialSaleCRMLink(for: &mutable)
                        store.upsertMaterialSale(mutable)
                        localSale = mutable
                    } label: {
                        Text("Link Now")
                            .font(.caption).bold()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    private func linkedQuoteCard(_ quote: Quote) -> some View {
        NavigationLink(destination: QuoteDetailView(quote: quote)) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext.fill")
                    .font(.title2).foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quote").font(.caption).foregroundColor(.secondary)
                    Text(quote.jobNumber).font(.subheadline).bold()
                    Text(quote.grandTotal.currencyString)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                QuoteStatusBadge(status: quote.status)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var actionsCard: some View {
        VStack(spacing: 10) {
            // ── Acceptance Status Pill ────────────────────────────
            // Surfaces the current magic-link state to the rep:
            // "Awaiting acceptance · expires in 30d", "Accepted by …",
            // "Revoked", or "Expired". Only shows when at least one
            // token has been minted (otherwise nothing to display).
            if let status = acceptanceStatus, status.hasToken {
                acceptancePill(status)
            }

            // ── Send / Share Document ─────────────────────────────
            // Available from .draft through .invoiced — same lifecycle
            // window where re-sending the document to the client makes
            // sense. Hidden once the sale is paid or cancelled.
            if localSale.status == .draft
                || localSale.status == .quoted
                || localSale.status == .ordered
                || localSale.status == .invoiced {

                // Primary action: open Review sheet. The Review sheet
                // collects recipients + acceptance-link toggle and
                // calls our send pipeline only when the user taps
                // Send. Status flips ONLY on email-success — see
                // EmailComposeSheet.send() material_sale branch.
                Button {
                    showReviewSheet = true
                } label: {
                    if isGeneratingPDF {
                        HStack {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Generating PDF…")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.blue)
                        .foregroundColor(.white).cornerRadius(12)
                    } else {
                        Label(localSale.status == .draft
                              ? "Send for Customer Acceptance"
                              : "Re-send to Customer",
                              systemImage: "paperplane.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                }
                .disabled(isGeneratingPDF)

                // Secondary action: render + share via system sheet
                // (AirDrop, Files, third-party email, etc.). Useful
                // when the rep wants to send from their own client
                // app instead of through send-email Edge Function.
                Button {
                    generateAndShare()
                } label: {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color(.tertiarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                }
                .disabled(isGeneratingPDF)
            }

            // ── Status advance actions (kept after the send actions) ─
            // Note: "Mark as Quoted" is only useful when the user
            // wants to advance status WITHOUT actually emailing
            // (e.g. delivered-in-person quote). Email-success advances
            // automatically via emailSucceeded() so this button is a
            // manual fallback.
            if localSale.status == .draft {
                Button {
                    var updated = localSale
                    updated.status = .quoted
                    store.upsertMaterialSale(updated)
                    localSale = updated
                } label: {
                    Label("Mark as Quoted (no email)", systemImage: "doc.richtext")
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color(.tertiarySystemBackground))
                        .foregroundColor(.secondary).cornerRadius(10)
                }
            }
            if localSale.status == .quoted || localSale.status == .ordered {
                Button {
                    var updated = localSale
                    updated.status = .invoiced
                    store.upsertMaterialSale(updated)
                    localSale = updated
                } label: {
                    Label("Mark as Invoiced", systemImage: "doc.plaintext.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.purple)
                        .foregroundColor(.white).cornerRadius(12)
                }
            }
            if localSale.status == .invoiced {
                Button {
                    var updated = localSale
                    updated.status = .paid
                    store.upsertMaterialSale(updated)
                    localSale = updated
                    // Log payment to CRM
                    store.logCRMActivity(
                        type: .paymentReceived,
                        title: "Payment received — \(localSale.saleNumber)",
                        notes: "Sale paid in full. Total: \(localSale.grandTotal.currencyString).",
                        clientID: localSale.clientID,
                        contactID: localSale.contactID,
                        opportunityID: localSale.opportunityID,
                        quoteID: nil,
                        projectID: nil
                    )
                } label: {
                    Label("Mark as Paid", systemImage: "checkmark.seal.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.green)
                        .foregroundColor(.white).cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Send / PDF helpers

    /// Pre-fill recipient list from the sale's client + primary contact.
    private var clientContactEmails: [String] {
        var seen = Set<String>()
        var out: [String] = []
        // Linked contact email first (if set).
        if let c = contact, !c.email.isEmpty {
            let key = c.email.lowercased()
            if seen.insert(key).inserted { out.append(c.email) }
        }
        // Then any email on the client record.
        if let cl = client, let cEmail = cl.contactEmail, !cEmail.isEmpty {
            let key = cEmail.lowercased()
            if seen.insert(key).inserted { out.append(cEmail) }
        }
        return out
    }

    private var resolvedDeliveryAddress: String {
        // Prefer the explicit deliveryAddress on the sale; fall back to
        // the linked site's formatted address; final fallback is the
        // client's billing address so the doc isn't blank.
        if let addr = localSale.deliveryAddress, !addr.isEmpty { return addr }
        if let sid = localSale.siteID,
           let site = client?.sites.first(where: { $0.id == sid }) {
            let fa = site.formattedAddress
            return fa.isEmpty ? site.address : fa
        }
        return client?.fullBillingAddress ?? ""
    }

    private var emailDefaultBody: String {
        let clientLine = client?.name ?? "there"
        let totalLine  = localSale.grandTotal.currencyString
        let docLabel   = localSale.saleType == .rental
            ? "rental agreement"
            : (localSale.saleType == .directInvoice ? "invoice" : "quote")
        return """
        Hi \(clientLine),

        Please find attached your \(docLabel) for \(localSale.saleNumber). Total: \(totalLine).

        Let us know if you have any questions or would like to proceed.

        Thanks,
        \(AppSettings.shared.companyName)
        """
    }

    private func sanitizedFilenameStem() -> String {
        let raw = localSale.saleNumber.isEmpty
            ? "MaterialSale"
            : localSale.saleNumber
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let docLabel: String
        switch localSale.saleType {
        case .rental:        docLabel = "Rental"
        case .directInvoice: docLabel = "Invoice"
        default:             docLabel = "Quote"
        }
        return "\(docLabel)_\(cleaned)"
    }

    /// Acceptance status pill — clone of the QuoteDetailView pattern.
    /// Tinted by state: green for accepted, orange for pending,
    /// red for revoked, secondary for expired.
    @ViewBuilder
    private func acceptancePill(_ status: MaterialSaleAcceptanceService.AcceptanceStatus)
    -> some View
    {
        let (icon, color, includeRevokeButton): (String, Color, Bool) = {
            if status.acceptedAt != nil {
                return ("checkmark.seal.fill", .green, false)
            }
            if status.revokedAt != nil {
                return ("xmark.octagon.fill", .red, false)
            }
            if let exp = status.expiresAt, exp < Date() {
                return ("clock.badge.exclamationmark.fill", .secondary, false)
            }
            // Pending — admin can revoke.
            return ("paperplane.circle.fill", .orange, store.currentUserRole.isAdmin)
        }()

        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Customer Acceptance")
                    .font(.caption).foregroundColor(.secondary)
                Text(status.displaySummary)
                    .font(.subheadline)
            }
            Spacer()
            if includeRevokeButton {
                Button(role: .destructive) {
                    showRevokeConfirm = true
                } label: {
                    Text("Revoke")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }

    /// Sale type label used in subject/body copy.
    private var saleTypeLabel: String {
        switch localSale.saleType {
        case .rental:        return "Rental Agreement"
        case .directInvoice: return "Invoice"
        default:             return "Quote"
        }
    }

    /// Called by MaterialSaleSendReviewSheet's `performSend` closure
    /// after the user reviews recipients + acceptance toggle and taps
    /// Send. Mints a token (when toggle on), renders PDF, ships
    /// through EmailService.sendPDF, returns the result.
    ///
    /// IMPORTANT: status flip (.draft → .quoted) happens ONLY in
    /// `onSendSucceeded` after this returns .success — never inside
    /// the rendering or token-mint phase. Mirrors the Quote pattern.
    @MainActor
    private func runReviewedSend(
        recipients: [String],
        includeAcceptanceLink: Bool
    ) async -> Result<Void, EmailService.EmailError> {
        // 1) Mint acceptance token if requested. Failures are
        //    non-fatal — we just send without the link.
        var acceptanceURL: URL? = nil
        if includeAcceptanceLink {
            do {
                let mint = try await MaterialSaleAcceptanceService.shared
                    .mintToken(saleID: localSale.id)
                acceptanceURL = mint.url
            } catch {
                print("⚠️ MaterialSaleSend: token mint failed (\(error.localizedDescription)) — sending without link")
            }
        }

        // 2) Render PDF off-main with a snapshot of current state.
        let saleCopy   = localSale
        let nameCopy   = client?.name ?? "Client"
        let addrCopy   = resolvedDeliveryAddress
        let termsCopy  = store.materialSaleTerms(for: saleCopy.id)
        let filename   = sanitizedFilenameStem() + ".pdf"
        let pdf: Data = await Task.detached(priority: .userInitiated) {
            MaterialSalePDFRenderer(
                sale:            saleCopy,
                clientName:      nameCopy,
                deliveryAddress: addrCopy,
                saleTerms:       termsCopy
            ).render()
        }.value

        // 3) Build email body. When an acceptance URL was minted,
        //    prepend a one-tap acceptance line so the customer sees
        //    it prominently.
        let bodyText: String = {
            var body = emailDefaultBody
            if let url = acceptanceURL {
                body = """
                Click here to review and accept this \(saleTypeLabel.lowercased()) digitally:
                \(url.absoluteString)

                """ + body
            }
            return body
        }()

        let bodyHTML = EmailHTMLTemplate.wrap(
            plainText:   bodyText,
            companyName: AppSettings.shared.companyName,
            subject:     "\(saleCopy.saleNumber) — \(nameCopy)",
            footerNote:  acceptanceURL == nil
                ? nil
                : "Reply to this email if you have any questions before accepting."
        )

        let companyEmail = AppSettings.shared.companyEmail.trimmingCharacters(in: .whitespaces)

        // 4) Ship through EmailService (Resend Edge Function under
        //    the hood). On .success, the Review sheet calls
        //    onSendSucceeded which advances status + logs activity.
        return await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     "\(saleCopy.saleNumber) — \(nameCopy)",
            bodyText:    bodyText,
            bodyHTML:    bodyHTML,
            replyTo:     companyEmail.isEmpty ? nil : companyEmail,
            pdfData:     pdf,
            pdfFilename: filename,
            entityType:  "material_sale",
            entityID:    saleCopy.id
        )
    }

    /// Called by the Review sheet's onSendSucceeded after the email
    /// has confirmed delivery. Advances status .draft → .quoted (via
    /// the existing EmailComposeSheet contract path — but here we
    /// hit it directly since this flow doesn't go through that sheet).
    @MainActor
    private func handleReviewedSendSuccess() {
        // Idempotent — only flip from .draft. Re-sends from .quoted /
        // .ordered / .invoiced don't demote.
        if localSale.status == .draft {
            var updated = localSale
            updated.status = .quoted
            store.upsertMaterialSale(updated)
            localSale = updated
        }
        // CRM activity log — match EmailComposeSheet's format so the
        // timeline is consistent across send paths.
        store.logCRMActivity(
            type:          .emailSent,
            title:         "\(localSale.saleNumber) — \(client?.name ?? "Material Sale")",
            notes:         "Sent for customer acceptance.",
            clientID:      localSale.clientID,
            contactID:     localSale.contactID,
            opportunityID: localSale.opportunityID,
            quoteID:       nil,
            projectID:     localSale.projectID
        )
        // Pull fresh acceptance status so the pill on screen updates
        // immediately to "Awaiting acceptance · expires …".
        Task { await reloadAcceptanceStatus() }
    }

    /// Pulls the latest acceptance-token metadata from the server.
    /// Called on view appear, after a successful send, and after a
    /// revoke. Sets `acceptanceStatus` for the pill rendering.
    @MainActor
    private func reloadAcceptanceStatus() async {
        isLoadingAcceptanceStatus = true
        defer { isLoadingAcceptanceStatus = false }
        do {
            acceptanceStatus = try await MaterialSaleAcceptanceService.shared
                .fetchStatus(saleID: localSale.id)
        } catch {
            // Non-fatal. Pill just won't render.
            print("⚠️ MaterialSaleDetail: fetchStatus failed: \(error)")
        }
    }

    /// Revoke the live acceptance token. Admin-only — UI gates the
    /// button and the RPC re-checks server-side.
    @MainActor
    private func revokeAcceptanceLink() async {
        do {
            try await MaterialSaleAcceptanceService.shared.revoke(saleID: localSale.id)
            await reloadAcceptanceStatus()
            ToastService.shared.warning("Acceptance link revoked.")
        } catch {
            ToastService.shared.error("Couldn't revoke: \(error.localizedDescription)")
        }
    }

    /// Render PDF then open the system share sheet. Used when the
    /// rep wants to attach to their own email client / AirDrop /
    /// save to Files. Does NOT change sale status.
    private func generateAndShare() {
        isGeneratingPDF = true
        let saleCopy = localSale
        let nameCopy = client?.name ?? "Client"
        let addrCopy = resolvedDeliveryAddress
        let termsCopy = store.materialSaleTerms(for: saleCopy.id)
        Task.detached(priority: .userInitiated) {
            let pdf = MaterialSalePDFRenderer(
                sale:            saleCopy,
                clientName:      nameCopy,
                deliveryAddress: addrCopy,
                saleTerms:       termsCopy
            ).render()
            let fileName: String = await MainActor.run {
                self.sanitizedFilenameStem() + ".pdf"
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try? pdf.write(to: tempURL)
            await MainActor.run {
                self.shareItems      = [tempURL]
                self.isGeneratingPDF = false
                self.showShareSheet  = true
            }
        }
    }

    // Note: status advance (.draft → .quoted) and CRM emailSent
    // activity are handled directly by EmailComposeSheet.send() when
    // entityType == "material_sale". The detail view just refreshes
    // localSale on the email sheet's onDisappear so the buttons
    // re-render with the new status.
}

// MARK: - Material Sale Line Item Row

private struct MaterialSaleLineItemRow: View {
    let item: MaterialSaleLineItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description).font(.subheadline).bold()
                Text("\(qtyStr(item.quantity)) \(item.unit)  ×  \(item.unitPrice.currencyString)")
                    .font(.caption).foregroundColor(.secondary)
                if !item.notes.isEmpty {
                    Text(item.notes).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(item.lineTotal.currencyString).font(.subheadline).bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func qtyStr(_ val: Decimal) -> String {
        let d = Double(truncating: NSDecimalNumber(decimal: val))
        return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(format: "%.2g", d)
    }
}

// MARK: - Material Sale Create / Edit View

struct MaterialSaleCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: MaterialSale?         = nil
    var preselectedSaleType: SaleType   = .materialSale
    var context: CommercialContext?     = nil   // from CommercialIntakeView

    @State private var selectedClientID:  UUID?     = nil
    @State private var selectedContactID: UUID?     = nil
    @State private var selectedSiteID:    UUID?     = nil
    @State private var saleType:          SaleType  = .materialSale
    @State private var deliveryAddress    = ""
    @State private var hasDeliveryDate    = false
    @State private var deliveryDate       = Date()
    @State private var taxRateString      = String(AppSettings.shared.taxRate)
    @State private var notes              = ""
    @State private var lineItems:         [MaterialSaleLineItem] = []

    @State private var showClientPicker   = false
    @State private var showContactPicker  = false
    @State private var showSitePicker     = false
    @State private var showAddLineItem    = false
    /// Bug fix: Material Sale line items had no library connection.
    /// `MaterialSaleLineItem` already had a `productServiceID` back-link
    /// field but the form never opened the product picker — users had
    /// to retype description/qty/price every time. This flag drives
    /// the new "Pick from Products & Services" sheet.
    @State private var showProductPicker  = false
    @State private var showValidation     = false
    @State private var validationMessage  = ""

    // Terms & Conditions support — stable sale ID for the form
    // session so terms attached during the form land on the eventual
    // saved sale's FK. Mirrors the pattern in EstimateCreateView
    // and QuoteCreateView.
    @State private var editingSaleID: UUID = UUID()
    @State private var defaultsAttemptedThisSession: Bool = false
    private enum ActiveTermsSheet: String, Identifiable {
        case picker, custom, preview
        var id: String { rawValue }
    }
    @State private var activeTermsSheet: ActiveTermsSheet? = nil

    private var isEditing: Bool { existing != nil }

    /// Phase 9 (lock-on-terminal-state): once a material sale is paid
    /// or cancelled, its line items and totals are part of the
    /// financial record. Editing them would shift AR balances and
    /// recognized revenue without an audit trail.
    /// Locked states: `.paid`, `.cancelled`. Active states (`.draft`,
    /// `.quoted`, `.ordered`, `.invoiced`) remain editable via the
    /// `isActive` property on MaterialSaleStatus.
    private var isLocked: Bool {
        guard let s = existing?.status else { return false }
        return !s.isActive
    }

    private var lockedReason: String {
        switch existing?.status {
        case .paid:      return "Sale paid"
        case .cancelled: return "Sale cancelled"
        default:         return "Sale locked"
        }
    }

    /// Drives the terms section's read-only state. Paid / cancelled
    /// sales freeze attached terms (mirrors the lock pattern).
    private var termsReadOnly: Bool {
        guard let s = existing?.status else { return false }
        return s.termsAreReadOnly
    }

    private var selectedClient: Client? {
        guard let id = selectedClientID else { return nil }
        return store.client(id: id)
    }
    private var selectedContact: CRMContact? {
        guard let id = selectedContactID else { return nil }
        return store.crmContacts.first { $0.id == id }
    }
    private var subtotal: Decimal { lineItems.reduce(0) { $0 + $1.lineTotal } }
    private var taxRate:  Decimal { Decimal(string: taxRateString) ?? 0 }
    private var grandTotal: Decimal { subtotal + subtotal * taxRate / 100 }

    /// Phase 1 Step 5 — CRM linkage hint shown beneath the Site/Delivery
    /// section. Adapts to three states:
    ///   1. Editing an existing sale already linked to an opportunity
    ///      → green checkmark + opportunity title.
    ///   2. Editing an existing sale without a linkage (legacy row)
    ///      → orange notice; an opp will be auto-created on next save.
    ///   3. Creating a new sale → blue informational hint that an
    ///      opportunity will be created the moment Save is tapped.
    @ViewBuilder
    private var crmLinkageHintSection: some View {
        Section("CRM Opportunity") {
            if let saleID = existing?.id,
               let liveSale = store.materialSales.first(where: { $0.id == saleID }),
               let oppID = liveSale.opportunityID,
               let opp = store.crmOpportunities.first(where: { $0.id == oppID && !$0.isDeleted }) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(opp.title.isEmpty ? "Linked opportunity" : opp.title)
                            .font(.subheadline)
                        Text("Stage: \(opp.stage.rawValue)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                }
            } else if existing != nil {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not linked to a CRM opportunity")
                            .font(.subheadline)
                        Text("An opportunity will be created when you save this sale.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.orange)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-link to CRM")
                            .font(.subheadline)
                        Text("Saving this sale creates a linked opportunity in CRM with the client and contact you selected above.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked {
                    Section {
                        materialSaleLockedBanner
                    }
                    .listRowInsets(EdgeInsets())
                }
                // Context bar — shown when launched from CommercialIntakeView
                if let ctx = context {
                    Section {
                        CommercialContextBar(context: ctx)
                    }
                    .listRowInsets(EdgeInsets())
                }
                // Sale type
                Section("Sale Type *") {
                    Picker("Type", selection: $saleType) {
                        ForEach(SaleType.allCases, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Client
                Section {
                    Button { showClientPicker = true } label: {
                        HStack {
                            Image(systemName: selectedClient != nil ? "building.2.fill" : "building.2")
                                .foregroundColor(selectedClient != nil ? .blue : .secondary)
                            Text(selectedClient?.name ?? "Select Client")
                                .foregroundColor(selectedClient != nil ? .primary : .secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                } header: { Text("Client *") }

                // Contact & Site (requires client)
                if let clientID = selectedClientID {
                    Section("Contact") {
                        Button { showContactPicker = true } label: {
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundColor(selectedContact != nil ? .blue : .secondary)
                                Text(selectedContact?.fullName ?? "Select Contact (optional)")
                                    .foregroundColor(selectedContact != nil ? .primary : .secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Section("Site / Delivery") {
                        Button {
                            showSitePicker = true
                        } label: {
                            let site = selectedClient?.sites.first(where: { $0.id == selectedSiteID })
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(site != nil ? .orange : .secondary)
                                Text(site?.name ?? "Select Site (optional)")
                                    .foregroundColor(site != nil ? .primary : .secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        TextField("Delivery Address (if different)", text: $deliveryAddress)
                    }

                    // Phase 1 Step 5 — CRM linkage transparency.
                    //
                    // Material sales auto-link to a CRM opportunity at save
                    // time via `ensureMaterialSaleCRMLink`. Pre-fix, this
                    // happened invisibly and the user had no idea their
                    // sale was being mirrored into the pipeline. The hint
                    // makes the linkage visible AND explains why a manual
                    // picker isn't shown (the auto-link is the desired
                    // path; manual override would let the rep create
                    // unlinked sales — exactly the gap Phase 1 closed).
                    crmLinkageHintSection
                    let _ = clientID // suppress unused warning
                }

                // Delivery date
                Section("Delivery Date") {
                    Toggle("Set Requested Date", isOn: $hasDeliveryDate)
                    if hasDeliveryDate {
                        DatePicker("Date", selection: $deliveryDate, displayedComponents: .date)
                    }
                }

                // Line items
                Section {
                    ForEach($lineItems) { $item in
                        MaterialSaleLineItemEditRow(item: $item,
                            onDelete: { lineItems.removeAll { $0.id == item.id } }
                        )
                    }
                    // Primary path — pull from the Products & Services
                    // library so description/unit/price come prefilled
                    // and the productServiceID back-link is recorded.
                    Button {
                        showProductPicker = true
                    } label: {
                        Label("Pick from Products & Services", systemImage: "shippingbox.fill")
                            .foregroundColor(.blue)
                    }
                    // Escape hatch — freeform line item for one-off
                    // entries the user doesn't want to add to the
                    // library (custom freight charges, etc.).
                    Button {
                        lineItems.append(MaterialSaleLineItem())
                    } label: {
                        Label("Add Custom Line", systemImage: "plus.circle")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Line Items")
                        Spacer()
                        Text(subtotal.currencyString).foregroundColor(.secondary)
                    }
                } footer: {
                    if lineItems.isEmpty {
                        Text("Add items from your Products & Services library, or use Custom Line for one-offs. Build the library in Settings → Products & Services.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Tax & totals
                Section("Pricing") {
                    HStack {
                        Text("Tax Rate")
                        Spacer()
                        TextField("0", text: $taxRateString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Grand Total").bold()
                        Spacer()
                        Text(grandTotal.currencyString).bold()
                    }
                }

                // Terms & Conditions — Path-A clone of QuoteTermsSection.
                // Section delegates sheet presentation back to this
                // parent via the on*Present closures so we own a single
                // enum-driven sheet (activeTermsSheet) and avoid the
                // nested-sheet binding flap.
                MaterialSaleTermsSection(
                    saleID:           editingSaleID,
                    readOnly:         termsReadOnly,
                    onPresentPicker:  { activeTermsSheet = .picker },
                    onPresentCustom:  { activeTermsSheet = .custom },
                    onPresentPreview: { activeTermsSheet = .preview }
                )
                .environmentObject(store)

                // Notes
                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            .disabled(isLocked)
            .navigationTitle(isEditing ? "Edit Sale" : "New Sale")
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
                    }
                }
            }
            .alert("Missing Info", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationMessage) }
            .sheet(isPresented: $showClientPicker) {
                ClientPickerSheet(selectedClientID: $selectedClientID)
            }
            .sheet(isPresented: $showContactPicker) {
                if let clientID = selectedClientID {
                    ClientContactPickerSheet(
                        clientID: clientID,
                        siteID: selectedSiteID,
                        selectedContactID: $selectedContactID
                    )
                    .environmentObject(store)
                }
            }
            // Products & Services picker — same sheet QuoteCreateView
            // and EstimateCreateView use. Returns a CostCodeItem that
            // we map onto MaterialSaleLineItem so the back-link
            // (productServiceID), description, unit, qty, and unitPrice
            // all carry through. Client-aware: the picker applies any
            // client-specific pricing override automatically.
            .sheet(isPresented: $showProductPicker) {
                ProductServicePickerSheet(clientID: selectedClientID) { costCodeItem in
                    let mapped = MaterialSaleLineItem(
                        id:               UUID(),
                        description:      costCodeItem.description,
                        quantity:         costCodeItem.estimatedQuantity,
                        unit:             costCodeItem.unit,
                        unitPrice:        costCodeItem.unitRate,
                        notes:            "",
                        productServiceID: costCodeItem.productServiceID
                    )
                    lineItems.append(mapped)
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showSitePicker) {
                if let clientID = selectedClientID {
                    SitePickerSheet(clientID: clientID, selectedSiteID: $selectedSiteID)
                        .environmentObject(store)
                }
            }
            // Terms & Conditions sheet router — single enum drives all
            // three terms-related sheets. NEVER triggers workflow status
            // changes on the parent sale.
            .sheet(item: $activeTermsSheet) { kind in
                switch kind {
                case .picker:
                    MaterialSaleTermsPickerSheet(saleID: editingSaleID)
                        .environmentObject(store)
                case .custom:
                    MaterialSaleCustomTermSheet(saleID: editingSaleID)
                        .environmentObject(store)
                case .preview:
                    MaterialSaleTermsPreviewSheet(saleID: editingSaleID)
                        .environmentObject(store)
                }
            }
            .onAppear {
                populate()
                applyDefaultTermsIfNeeded()
            }
            .task {
                // Pull current templates + already-attached terms so
                // the section is populated. NEVER triggers status changes.
                await SyncEngine.shared.pullTermsTemplates()
                await SyncEngine.shared.pullMaterialSaleTerms()
            }
        }
    }

    private func populate() {
        saleType = preselectedSaleType
        // Apply CommercialContext (lowest priority — existing overrides)
        if let ctx = context {
            if selectedClientID  == nil { selectedClientID  = ctx.clientID }
            if selectedContactID == nil { selectedContactID = ctx.contactID }
            if selectedSiteID    == nil { selectedSiteID    = ctx.siteID }
            if let wt = ctx.workType    { saleType          = wt }
        }
        guard let e = existing else { return }
        // Align the form's stable terms-FK with the existing sale.
        editingSaleID     = e.id
        selectedClientID  = e.clientID
        selectedContactID = e.contactID
        selectedSiteID    = e.siteID
        saleType          = e.saleType
        deliveryAddress   = e.deliveryAddress ?? ""
        hasDeliveryDate   = e.requestedDeliveryDate != nil
        deliveryDate      = e.requestedDeliveryDate ?? Date()
        taxRateString     = "\(e.taxRate)"
        notes             = e.notes ?? ""
        lineItems         = e.lineItems
    }

    /// One-shot default-templates attachment. Mirrors
    /// QuoteCreateView / EstimateCreateView. NEVER triggers a status
    /// change on the parent sale — only `terms_default_applied` is
    /// touched at finalize-save time.
    private func applyDefaultTermsIfNeeded() {
        guard !defaultsAttemptedThisSession else { return }
        defaultsAttemptedThisSession = true

        guard !termsReadOnly else { return }

        let needsApply: Bool
        if let s = existing {
            needsApply = !s.termsDefaultApplied
        } else {
            needsApply = true
        }
        guard needsApply else { return }

        let existingTemplateIDs = Set(
            store.materialSaleTerms(for: editingSaleID).compactMap { $0.templateID }
        )
        let defaults = store.activeTermsTemplates
            .filter { $0.isDefault && !existingTemplateIDs.contains($0.id) }
        for d in defaults {
            store.attachTermsTemplateToMaterialSale(d, saleID: editingSaleID)
        }
    }

    // MARK: - Locked banner

    @ViewBuilder
    private var materialSaleLockedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — \(lockedReason.lowercased())")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text("This sale is part of the financial record. Editing line items or totals would shift AR balances and recognized revenue without an audit trail.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }

    private func save() {
        // Phase 9 lock — defensive guard.
        if isLocked {
            validationMessage = "This sale is \(lockedReason.lowercased()) and is locked."
            showValidation = true
            return
        }
        guard let clientID = selectedClientID else {
            validationMessage = "Please select a client."
            showValidation = true
            return
        }

        var sale = existing ?? MaterialSale(clientID: clientID)
        // Align sale.id with the form's stable editingSaleID so any
        // material_sale_terms attached during this session land on the
        // right FK. No-op for existing sales (populate() already
        // synced editingSaleID = e.id).
        let isNewSale = (existing == nil)
        if isNewSale { sale.id = editingSaleID }
        if sale.saleNumber.isEmpty {
            sale.saleNumber = store.nextSaleNumber()
        }
        sale.saleType              = saleType
        sale.clientID              = clientID
        sale.contactID             = selectedContactID
        sale.siteID                = selectedSiteID
        sale.deliveryAddress       = deliveryAddress.isEmpty ? nil : deliveryAddress
        sale.requestedDeliveryDate = hasDeliveryDate ? deliveryDate : nil
        sale.taxRate               = Decimal(string: taxRateString) ?? 0
        sale.notes                 = notes.isEmpty ? nil : notes
        sale.lineItems             = lineItems
        sale.lastModifiedBy        = store.currentUser?.fullName ?? ""
        sale.lastModifiedAt        = Date()
        sale.syncStatus            = .pending
        // Defaults have had their one chance to attach during the form
        // session. Mark the ledger so a later sync that brings in a new
        // is_default template doesn't retroactively attach.
        sale.termsDefaultApplied   = true

        // Phase 6 audit fix: thread soft-link FKs from the
        // CommercialContext into the new sale so a sale that
        // originates from an existing quote / project / CRM
        // opportunity stays linked. Pre-fix these landed on the
        // bridge's CRM-link helper but never on the sale itself,
        // so the back-link from sale → quote was lost.
        // Existing-record edits don't overwrite (these stay nil
        // unless the context explicitly populated them).
        if let ctx = context {
            if sale.projectID     == nil, let pid = ctx.projectID     { sale.projectID     = pid }
            if sale.quoteID       == nil, let qid = ctx.quoteID       { sale.quoteID       = qid }
            if sale.opportunityID == nil, let oid = ctx.opportunityID { sale.opportunityID = oid }
            if sale.contactID     == nil, let cid = ctx.contactID     { sale.contactID     = cid }
            if sale.siteID        == nil, let sid = ctx.siteID        { sale.siteID        = sid }
        }

        store.upsertMaterialSale(sale)

        // Auto-copy signed PDF from the linked quote (if any) onto
        // the new material sale so its documents grid inherits the
        // proof of acceptance. No-ops when no signed PDF exists yet
        // (e.g. sale created from a quote that was never accepted
        // via magic link).
        if let qid = sale.quoteID {
            SignedQuotePDFGenerator.shared.copyExistingSignedPDF(
                fromQuoteID: qid,
                to:          .materialSale(sale.id),
                store:       store
            )
        }

        // Auto-create CRM opportunity from context if we have one and no opportunity yet
        if var ctx = context, ctx.opportunityID == nil {
            ctx.clientID = clientID
            if ctx.workType == nil { ctx.workType = saleType }
            store.createOpportunityFromContext(&ctx)
        }

        dismiss()
    }
}

// MARK: - Material Sale Line Item Edit Row

private struct MaterialSaleLineItemEditRow: View {
    @Binding var item: MaterialSaleLineItem
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Description", text: $item.description)
                    .font(.subheadline)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Qty").font(.caption).foregroundColor(.secondary)
                    TextField("1", value: $item.quantity, format: .number)
                        .keyboardType(.decimalPad)
                        .frame(width: 50)
                        .font(.caption)
                }
                HStack(spacing: 4) {
                    Text("Unit").font(.caption).foregroundColor(.secondary)
                    TextField("ea", text: $item.unit)
                        .frame(width: 40)
                        .font(.caption)
                }
                HStack(spacing: 4) {
                    Text("Price").font(.caption).foregroundColor(.secondary)
                    TextField("0.00", value: $item.unitPrice, format: .currency(code: "CAD"))
                        .keyboardType(.decimalPad)
                        .frame(width: 80)
                        .font(.caption)
                }
                Spacer()
                Text(item.lineTotal.currencyString)
                    .font(.caption).bold()
            }
        }
        .padding(.vertical, 4)
    }
}
