// EstimateViews.swift
// AskiCommand – Estimating Module
// REWRITTEN for new Estimate model — clientID, jobNumber, full status flow

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Estimate List View

struct EstimateListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false
    @State private var searchText = ""
    @State private var filterStatus: EstimateStatus? = nil
    @State private var pendingMyReviewOnly: Bool = false
    @StateObject private var pagination = PaginationState(pageSize: 20)

    /// All estimates assigned to the current user as reviewer, currently
    /// awaiting their action. Stamped at submitForReview time as a name
    /// (we don't store reviewer UUID on estimates yet) so we match by
    /// fullName. The count drives the badge on the "Pending My Review" chip.
    ///
    /// 2026-05 fix: normalize whitespace + case so "Shawn  Blair"
    /// (double-space stored) matches "Shawn Blair" (single-space from
    /// Employee.fullName). Pre-fix, mid-space variation made every
    /// match miss and the chip count stayed at 0 even when items existed.
    private var pendingForMe: [Estimate] {
        guard let me = store.currentUser?.fullName, !me.isEmpty else { return [] }
        let myNormalized = normalizeReviewerName(me)
        return store.estimates.filter { e in
            e.status == .internalReview
            && normalizeReviewerName(e.internalReviewBy ?? "") == myNormalized
        }
    }

    /// Whitespace-collapsed, case-folded comparison.
    private func normalizeReviewerName(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private var filtered: [Estimate] {
        let base: [Estimate]
        if pendingMyReviewOnly {
            base = pendingForMe
        } else {
            base = store.estimates.filter { filterStatus == nil || $0.status == filterStatus }
        }
        return base
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.jobNumber.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Phase 7 first-launch sync gate. Estimates reference
                // clients + opportunities — both server-resident. Block
                // create until first pull arrives.
                if !store.hasCompletedFirstSync {
                    FirstLaunchSyncGateBanner()
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                // Status Filter Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Pending My Review — surfaces the review queue
                        // for whoever's signed in. Mutually exclusive with
                        // status filters; turning it on clears them, and
                        // tapping a status chip clears this. Hidden when
                        // there's nothing pending so it doesn't add noise
                        // to estimators who never receive review requests.
                        if !pendingForMe.isEmpty {
                            Button {
                                pendingMyReviewOnly.toggle()
                                if pendingMyReviewOnly { filterStatus = nil }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.badge.clock.fill")
                                    Text("Pending My Review")
                                    Text("\(pendingForMe.count)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(
                                                pendingMyReviewOnly
                                                    ? Color.white.opacity(0.25)
                                                    : Color.purple.opacity(0.20)
                                            )
                                        )
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    pendingMyReviewOnly
                                        ? Color.purple
                                        : Color.purple.opacity(0.10)
                                )
                                .foregroundColor(pendingMyReviewOnly ? .white : .purple)
                                .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                        }

                        FilterChip(label: "All", isSelected: filterStatus == nil && !pendingMyReviewOnly) {
                            filterStatus = nil
                            pendingMyReviewOnly = false
                        }
                        ForEach(EstimateStatus.allCases, id: \.self) { status in
                            FilterChip(
                                label: status.displayName,
                                isSelected: filterStatus == status && !pendingMyReviewOnly
                            ) {
                                pendingMyReviewOnly = false
                                filterStatus = filterStatus == status ? nil : status
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                Divider()

                if filtered.isEmpty {
                    if pendingMyReviewOnly {
                        // Distinct empty state — they cleared their queue,
                        // not "no estimates exist."
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.green)
                            Text("Your review queue is clear.")
                                .font(.headline)
                            Text("Nothing assigned to you for review right now.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("Show all estimates") { pendingMyReviewOnly = false }
                                .buttonStyle(.bordered)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 52))
                                .foregroundColor(.secondary)
                            Text("No estimates yet.")
                                .font(.headline)
                            Text("Tap + to start your first estimate.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button("New Estimate") { showCreate = true }
                                .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                    }
                } else {
                    List {
                        ForEach(Array(filtered.prefix(pagination.displayLimit))) { estimate in
                            NavigationLink {
                                EstimateDetailView(estimate: estimate)
                            } label: {
                                EstimateListRow(estimate: estimate)
                            }
                        }
                        LoadMoreFooter(
                            showing: min(pagination.displayLimit, filtered.count),
                            total:   filtered.count,
                            onLoad:  { pagination.loadMore() }
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: searchText)         { _ in pagination.reset() }
                    .onChange(of: filterStatus)       { _ in pagination.reset() }
                    .onChange(of: pendingMyReviewOnly){ _ in pagination.reset() }
                }
            }
            .searchable(text: $searchText, prompt: "Search estimates or job numbers")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Estimates")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.hasCompletedFirstSync)
                }
            }
            // Slice 6: route the "+" through CommercialIntakeView so
            // every new estimate captures work-type + client up front
            // and the auto-link trigger (Slice 2) has the context it
            // needs to roll up to a CRM opportunity.
            //
            // The intake's onDismiss closes the sheet whether the
            // user finished or cancelled — same UX as opening the
            // create view directly.
            .sheet(isPresented: $showCreate) {
                CommercialIntakeView()
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Estimate List Row

struct EstimateListRow: View {
    let estimate: Estimate
    @EnvironmentObject var store: AppStore

    private var client: Client? {
        store.client(id: estimate.clientID)
    }

    private var siteName: String? {
        guard let siteID = estimate.siteID else { return nil }
        return client?.sites.first(where: { $0.id == siteID })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(estimate.jobNumber)
                    .font(.caption).bold()
                    .foregroundColor(.purple)
                    .fontDesign(.monospaced)
                Spacer()
                EstimateStatusBadge(status: estimate.status)
            }
            Text(estimate.name).font(.headline)

            // Client + Site on one line
            HStack(spacing: 4) {
                Text(client?.name ?? "Unknown Client")
                    .font(.subheadline).foregroundColor(.secondary)
                if let site = siteName {
                    Text("·").foregroundColor(.secondary).font(.subheadline)
                    Label(site, systemImage: "mappin")
                        .font(.subheadline).foregroundColor(.orange).lineLimit(1)
                }
            }

            HStack(spacing: 14) {
                Label(estimate.pricingType.displayName, systemImage: "tag")
                    .font(.caption).foregroundColor(.secondary)
                Label(estimate.totalEstimated.currencyString, systemImage: "dollarsign.circle")
                    .font(.caption).foregroundColor(.secondary)
                if let due = estimate.bidDueDate {
                    Label("Due \(due.shortDate)", systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(due < Date() ? .red : .secondary)
                }
                // CRM link badge
                if estimate.opportunityID != nil {
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

// MARK: - Estimate Status Badge

struct EstimateStatusBadge: View {
    let status: EstimateStatus

    var statusColor: Color {
        switch status {
        case .rfqReceived:    return .blue
        case .estimating:     return .orange
        case .internalReview: return .purple
        case .submitted:      return .teal
        case .awarded:        return .green
        // Phase 3 audit fix added the .converted case to EstimateStatus;
        // adding it here closes the exhaustive-switch warning.
        case .converted:      return .indigo
        case .lost:           return .red
        case .cancelled:      return .gray
        }
    }

    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundColor(statusColor)
            .cornerRadius(6)
    }
}

// MARK: - Estimate Detail View

struct EstimateDetailView: View {
    let estimate: Estimate
    @EnvironmentObject var store: AppStore
    @State private var localEstimate: Estimate
    @State private var showEdit = false
    @State private var showAddLine = false
    @State private var showMarkLost = false
    @State private var showCreateQuote = false
    @State private var lossReason: LossReason = .price
    @State private var competitorName = ""
    @State private var winLossNotes = ""
    @State private var showShareSheet   = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF  = false

    @State private var showRevisionHistory: Bool = false

    // Workflow refinement (2026-05): reviewer picker + auto-quote creation +
    // pre-approval validation. See approveAndSendToClient() for the full
    // path. The legacy approveAndSubmit() is retained as a fallback the UI
    // no longer surfaces (called only by code paths that bypass the picker).
    @State private var showReviewerPicker:    Bool   = false
    @State private var pickedReviewerID:      UUID?  = nil
    @State private var showApprovalValidationAlert: Bool = false
    @State private var approvalValidationMsg: String = ""

    init(estimate: Estimate) {
        self.estimate = estimate
        self._localEstimate = State(initialValue: estimate)
    }

    private var client: Client? {
        store.client(id: localEstimate.clientID)
    }

    private var clientName: String {
        client?.name ?? "Unknown Client"
    }

    private var estimateSite: ClientSite? {
        guard let siteID = localEstimate.siteID else { return nil }
        return client?.sites.first(where: { $0.id == siteID })
    }

    private var primaryContact: CRMContact? {
        guard let cid = localEstimate.primaryContactID else { return nil }
        return store.crmContacts.first(where: { $0.id == cid })
    }

    /// Line items may only be added / deleted while the estimate is still in draft stages.
    private var canEditLineItems: Bool {
        localEstimate.status == .estimating || localEstimate.status == .internalReview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(localEstimate.jobNumber)
                            .font(.subheadline).bold()
                            .foregroundColor(.purple)
                            .fontDesign(.monospaced)
                        Spacer()
                        EstimateStatusBadge(status: localEstimate.status)
                    }
                    Text(clientName)
                        .font(.subheadline).foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        Label(localEstimate.opportunityType.displayName, systemImage: localEstimate.opportunityType.icon)
                            .font(.caption).foregroundColor(.secondary)
                        Label(localEstimate.pricingType.displayName, systemImage: "tag")
                            .font(.caption).foregroundColor(.secondary)
                        Label("Rev \(localEstimate.revisionNumber)", systemImage: "number")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let due = localEstimate.bidDueDate {
                        Label("Bid due: \(due.shortDate)", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                            .foregroundColor(due < Date() ? .red : .orange)
                    }

                    // Site + Contact strip
                    if estimateSite != nil || primaryContact != nil {
                        Divider()
                        HStack(spacing: 16) {
                            if let site = estimateSite {
                                Label(site.name, systemImage: "mappin.circle.fill")
                                    .font(.caption).foregroundColor(.orange).lineLimit(1)
                            }
                            if let contact = primaryContact {
                                Label(contact.fullName, systemImage: "person.fill")
                                    .font(.caption).foregroundColor(.blue).lineLimit(1)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // CRM Link Card
                EstimateCRMLinkCard(estimate: $localEstimate)
                    .padding(.horizontal)

                // KPI Row
                HStack(spacing: 12) {
                    MiniKPICard(
                        value: localEstimate.subtotal.currencyString,
                        label: "Subtotal",
                        icon: "sum"
                    )
                    MiniKPICard(
                        value: localEstimate.totalEstimated.currencyString,
                        label: "Total",
                        icon: "dollarsign.circle"
                    )
                    MiniKPICard(
                        value: "\(localEstimate.lineItems.count)",
                        label: "Items",
                        icon: "list.bullet"
                    )
                    MiniKPICard(
                        value: "\(store.estimateDocs(for: localEstimate.id).count)",
                        label: "Docs",
                        icon: "doc.fill",
                        color: .indigo
                    )
                }
                .padding(.horizontal)

                // ── Line Items ────────────────────────────────────────────────────
                lineItemsSection

                // ── Pricing Breakdown ─────────────────────────────────────────────
                if !localEstimate.lineItems.isEmpty {
                    estimatePricingBreakdown
                }

                // Documents
                EstimateDocumentsSection(estimateID: localEstimate.id)

                // Reviewer banner — surfaces the assignee so anyone opening
                // the estimate sees who owns the next action. Only shown
                // while in `.internalReview`; once approved, the audit
                // trail (Section: Internal Review Details) shows the
                // history.
                if localEstimate.status == .internalReview,
                   let reviewer = localEstimate.internalReviewBy,
                   !reviewer.isEmpty {
                    let isMe = (reviewer == store.currentUser?.fullName)
                    HStack(spacing: 10) {
                        Image(systemName: isMe ? "person.crop.circle.badge.exclamationmark.fill"
                                               : "person.badge.clock.fill")
                            .foregroundColor(isMe ? .orange : .purple)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isMe ? "Pending your review" : "Pending review")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(isMe ? .orange : .purple)
                            Text(isMe ? "Tap “Approve & Send to Client” when ready."
                                      : "Reviewer: \(reviewer)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background((isMe ? Color.orange : Color.purple).opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke((isMe ? Color.orange : Color.purple).opacity(0.30), lineWidth: 1)
                    )
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Action Buttons
                VStack(spacing: 10) {

                    // Internal Review — opens reviewer picker. Reviewer is
                    // notified locally + stamped on internal_review_by.
                    if localEstimate.status == .estimating {
                        Button { showReviewerPicker = true } label: {
                            Label("Submit for Internal Review", systemImage: "person.badge.clock")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }

                    // Approve & Send to Client — validates, auto-creates a
                    // Quote pre-populated from the estimate, and opens the
                    // Quote sheet so the user can polish and send. The
                    // estimate moves to .submitted because it has now been
                    // submitted to the client (via the quote).
                    if localEstimate.status == .internalReview {
                        Button { approveAndSendToClient() } label: {
                            Label("Approve & Send to Client", systemImage: "checkmark.seal.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.teal)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }

                    // Submitted — quote exists, awaiting client. No manual
                    // award button: estimate auto-flips to .awarded when
                    // the linked quote becomes .accepted (via
                    // resolveOpportunityOutcome). "Mark as Lost" remains
                    // for the rare case where the deal collapses before
                    // the quote is sent.
                    if localEstimate.status == .submitted {
                        Button { showMarkLost = true } label: {
                            Label("Mark as Lost", systemImage: "xmark.circle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.red.opacity(0.12))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }
                    }

                    // Note: legacy "Create Quote" button on .awarded
                    // intentionally removed. The quote is now auto-created
                    // on the .internalReview → .submitted transition. The
                    // showCreateQuote state and the QuoteCreateView sheet
                    // remain in the file as a code-callable fallback for
                    // edge cases (e.g., legacy awarded estimates with no
                    // linked quote — see SQL audit).
                }
                .padding(.horizontal)

                // Win/Loss info
                if localEstimate.status == .lost {
                    SectionHeader(title: "Loss Details")
                    VStack(spacing: 0) {
                        if let reason = localEstimate.lossReason {
                            ClientInfoRow(label: "Reason", value: reason.displayName)
                            Divider().padding(.leading)
                        }
                        if let competitor = localEstimate.competitorName {
                            ClientInfoRow(label: "Awarded To", value: competitor)
                            Divider().padding(.leading)
                        }
                        if let notes = localEstimate.winLossNotes {
                            ClientInfoRow(label: "Notes", value: notes)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(localEstimate.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isGeneratingPDF {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            exportPDF(variant: .internalCopy)
                        } label: {
                            Label("Internal Copy (with margins)", systemImage: "lock.shield")
                        }
                        Button {
                            exportPDF(variant: .clientCopy)
                        } label: {
                            Label("Client Copy (no margins)", systemImage: "person.crop.rectangle")
                        }
                        Divider()
                        Button {
                            showRevisionHistory = true
                        } label: {
                            Label("Revision history", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showRevisionHistory) {
            // Phase 9 audit fix: replaced the JSON-only sheet with
            // the decoded + diff viewer. The legacy
            // EstimateRevisionHistorySheet remains in
            // RevisionHistoryView.swift for any direct callers but
            // is no longer wired here.
            EstimateRevisionHistoryView(estimate: localEstimate)
                .environmentObject(store)
        }
        .sheet(isPresented: $showEdit) {
            EstimateCreateView(existing: localEstimate)
        }
        .sheet(isPresented: $showAddLine) {
            ProductServicePickerSheet(clientID: localEstimate.clientID) { newItem in
                localEstimate.lineItems.append(newItem)
                localEstimate.syncStatus = .pending
                store.upsertEstimate(localEstimate)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showCreateQuote) {
            QuoteCreateView(fromEstimate: localEstimate)
        }
        .sheet(isPresented: $showReviewerPicker) {
            ReviewerPickerSheet(
                pickedReviewerID: $pickedReviewerID,
                onConfirm: { reviewerID in
                    submitForReview(reviewerID: reviewerID)
                    showReviewerPicker = false
                },
                onCancel: { showReviewerPicker = false }
            )
            .environmentObject(store)
        }
        .alert("Can't approve yet", isPresented: $showApprovalValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(approvalValidationMsg)
        }
        .alert("Mark as Lost", isPresented: $showMarkLost) {
            Button("Mark Lost", role: .destructive) { markLost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Record why this bid was lost for future analysis.")
        }
    }

    // MARK: - Line Items Section

    @ViewBuilder private var lineItemsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header row
            HStack {
                Text("Products & Services")
                    .font(.headline)
                    .padding(.horizontal)
                Spacer()
                if canEditLineItems {
                    Button {
                        showAddLine = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.purple)
                    }
                    .padding(.trailing)
                }
            }
            .padding(.top, 4)

            if localEstimate.lineItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No line items yet")
                        .font(.subheadline).foregroundColor(.secondary)
                    if canEditLineItems {
                        Button {
                            showAddLine = true
                        } label: {
                            Label("Add from Product & Service Library", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(localEstimate.lineItems.enumerated()), id: \.element.id) { idx, item in
                        EstimateLineItemRow(
                            item: item,
                            productService: item.productServiceID.flatMap { psid in
                                store.productServices.first(where: { $0.id == psid })
                            },
                            canDelete: canEditLineItems
                        ) {
                            localEstimate.lineItems.remove(at: idx)
                            localEstimate.syncStatus = .pending
                            store.upsertEstimate(localEstimate)
                        }
                        if idx < localEstimate.lineItems.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)

                if canEditLineItems {
                    Button {
                        showAddLine = true
                    } label: {
                        Label("Add Line Item", systemImage: "plus.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple.opacity(0.08))
                            .foregroundColor(.purple)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Pricing Breakdown

    @ViewBuilder private var estimatePricingBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pricing Breakdown")
                .font(.headline)
                .padding(.horizontal)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                // Subtotal
                PricingBreakdownRow(label: "Subtotal", value: localEstimate.subtotal)

                // Contingency
                if localEstimate.contingencyPercent > 0 {
                    Divider().padding(.leading)
                    PricingBreakdownRow(
                        label: "Contingency (\(pctStr(localEstimate.contingencyPercent))%)",
                        value: localEstimate.contingencyAmount
                    )
                }

                // Overhead
                if localEstimate.overheadPercent > 0 {
                    Divider().padding(.leading)
                    PricingBreakdownRow(
                        label: "Overhead (\(pctStr(localEstimate.overheadPercent))%)",
                        value: localEstimate.overheadAmount
                    )
                }

                // Profit
                if localEstimate.profitPercent > 0 {
                    Divider().padding(.leading)
                    PricingBreakdownRow(
                        label: "Profit (\(pctStr(localEstimate.profitPercent))%)",
                        value: localEstimate.profitAmount
                    )
                }

                // Total
                Divider()
                HStack {
                    Text("Total Estimated").font(.headline)
                    Spacer()
                    Text(localEstimate.totalEstimated.currencyString)
                        .font(.headline).bold()
                }
                .padding()
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private func pctStr(_ val: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: val)
        let d = Double(truncating: ns)
        return d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2g", d)
    }

    private func updateStatus(_ status: EstimateStatus) {
        localEstimate.status = status
        if status == .awarded { localEstimate.awardedDate = Date() }
        localEstimate.syncStatus = .pending
        store.upsertEstimate(localEstimate)
    }

    /// Step 1 of the new workflow: estimator submits for internal review,
    /// designating a reviewer. Stamps the reviewer's name on the estimate
    /// (so a future "Pending My Review" inbox can filter on it) and fires
    /// a local notification so the reviewer sees a banner. Pure metadata
    /// — no quote / project side effects yet.
    private func submitForReview(reviewerID: UUID) {
        guard let reviewer = store.employees.first(where: { $0.id == reviewerID }) else { return }
        localEstimate.internalReviewBy = reviewer.fullName
        localEstimate.status           = .internalReview
        localEstimate.syncStatus       = .pending
        store.upsertEstimate(localEstimate)
        NotificationManager.shared.notifyEstimateReviewRequested(
            reviewerName:      reviewer.fullName,
            estimateName:      localEstimate.name,
            estimateJobNumber: localEstimate.jobNumber
        )
    }

    /// Step 2 of the new workflow: reviewer approves the estimate and
    /// triggers the client-facing path. Validates completeness, then
    /// auto-creates a Quote pre-populated from the estimate (line items,
    /// scope, totals, contingency, payment terms), opens the Quote sheet
    /// for review/polish before sending, and moves the estimate to
    /// `.submitted` (it has now been submitted to the client via the
    /// quote). Replaces the old approveAndSubmit() which only flipped
    /// status without producing the client-facing document.
    private func approveAndSendToClient() {
        // Pre-flight validation — block invalid approvals so empty quotes
        // never reach a client.
        if localEstimate.lineItems.isEmpty {
            approvalValidationMsg = "This estimate has no line items. Add at least one before approving."
            showApprovalValidationAlert = true
            return
        }
        if store.client(id: localEstimate.clientID) == nil {
            approvalValidationMsg = "This estimate isn't linked to a client. Set the client before approving."
            showApprovalValidationAlert = true
            return
        }
        if localEstimate.totalEstimated <= 0 {
            approvalValidationMsg = "Estimate total must be greater than zero. Check line item quantities and rates."
            showApprovalValidationAlert = true
            return
        }

        // Stamp the approval — reviewer name preserved from submitForReview
        // step; if the estimate was approved without going through the
        // picker (legacy path), fall back to the current user.
        if (localEstimate.internalReviewBy ?? "").isEmpty {
            localEstimate.internalReviewBy = store.currentUser?.fullName
        }
        localEstimate.internalApprovedAt = Date()
        localEstimate.submittedDate      = Date()
        localEstimate.status             = .submitted
        localEstimate.syncStatus         = .pending
        store.upsertEstimate(localEstimate)

        // Open the Quote sheet — QuoteCreateView already accepts
        // `fromEstimate` and copies all the data on appear.
        showCreateQuote = true
    }

    /// Legacy fallback. Kept callable for code paths that bypass the
    /// picker (e.g., automated tests or migration scripts). The UI no
    /// longer surfaces this — see approveAndSendToClient().
    private func approveAndSubmit() {
        localEstimate.internalReviewBy   = store.currentUser?.fullName
        localEstimate.internalApprovedAt = Date()
        localEstimate.submittedDate      = Date()
        localEstimate.status             = .submitted
        localEstimate.syncStatus         = .pending
        store.upsertEstimate(localEstimate)
    }

    private func exportPDF(variant: EstimatePDFRenderer.Variant) {
        isGeneratingPDF = true
        let estimateCopy = localEstimate
        let name = clientName
        // Snapshot the attached terms now so the renderer (which runs
        // off the main actor) gets a consistent value-type copy.
        let termsCopy = store.estimateTerms(for: estimateCopy.id)
        Task.detached(priority: .userInitiated) {
            let pdfData = EstimatePDFRenderer(
                estimate:      estimateCopy,
                clientName:    name,
                variant:       variant,
                estimateTerms: termsCopy
            ).render()
            let safe = estimateCopy.jobNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let suffix = (variant == .internalCopy) ? "_internal" : "_client"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Estimate_\(safe)\(suffix).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems      = [url]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }

    private func markLost() {
        localEstimate.status      = .lost
        localEstimate.lossReason  = lossReason
        localEstimate.competitorName = competitorName.isEmpty ? nil : competitorName
        localEstimate.winLossNotes   = winLossNotes.isEmpty ? nil : winLossNotes
        localEstimate.syncStatus  = .pending
        store.upsertEstimate(localEstimate)
    }
}

// MARK: - Estimate CRM Link Card

struct EstimateCRMLinkCard: View {
    @Binding var estimate: Estimate
    @EnvironmentObject var store: AppStore

    private var linkedOpportunity: CRMOpportunity? {
        guard let oppID = estimate.opportunityID else { return nil }
        return store.crmOpportunities.first { $0.id == oppID && !$0.isDeleted }
    }

    var body: some View {
        if let opp = linkedOpportunity {
            // Linked — show opportunity details
            NavigationLink(destination: CRMOpportunityDetailView(opportunity: opp)) {
                HStack(spacing: 12) {
                    Image(systemName: "link.circle.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CRM Opportunity")
                            .font(.caption).foregroundColor(.secondary)
                        Text(opp.title)
                            .font(.subheadline).bold()
                            .lineLimit(1)
                        Label(opp.stage.rawValue, systemImage: opp.stage.icon)
                            .font(.caption)
                            .foregroundColor(opp.stage.color)
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
        } else {
            // Unlinked — show warning + create button
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not linked to CRM")
                        .font(.subheadline).bold()
                    Text("This estimate has no CRM opportunity. Tap to create one.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    var mutable = estimate
                    store.ensureCRMLink(for: &mutable)
                    store.upsertEstimate(mutable)
                    estimate = mutable
                } label: {
                    Text("Link")
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
        }
    }
}

// MARK: - Estimate Line Item Row

struct EstimateLineItemRow: View {
    let item: CostCodeItem
    let productService: ProductService?   // nil = legacy / manually-entered item
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {

            // Type badge — purple for library-backed, gray for manual
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(badgeColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: badgeIcon)
                    .foregroundColor(badgeColor)
                    .font(.system(size: 15))
            }

            // Description + meta
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.code)
                        .font(.caption2).bold()
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                    Text(productService?.name ?? item.description)
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(1)
                }
                // Category + unit
                HStack(spacing: 6) {
                    if let cat = item.category ?? productService?.category {
                        Circle().fill(cat.color).frame(width: 6, height: 6)
                        Text(cat.rawValue)
                            .font(.caption2).foregroundColor(cat.color)
                        Text("·").foregroundColor(.secondary).font(.caption2)
                    }
                    Text(item.unit)
                        .font(.caption2).foregroundColor(.secondary)
                }
                // Notes / description line (if different from PS name)
                if productService != nil && !item.description.isEmpty &&
                   item.description != productService?.name &&
                   item.description != productService?.description {
                    Text(item.description)
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1)
                }
                // Qty × rate
                Text("\(qtyStr(item.estimatedQuantity)) \(item.unit)  ×  \(item.unitRate.currencyString)")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            // Total + delete
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.estimatedTotal.currencyString)
                    .font(.subheadline).bold()

                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var badgeColor: Color {
        if let ps = productService { return ps.type.color }
        return Color.purple
    }

    private var badgeIcon: String {
        if let ps = productService { return ps.type.icon }
        return "list.bullet.rectangle"
    }

    private func qtyStr(_ val: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: val)
        let d = Double(truncating: ns)
        return d.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(d))
            : String(format: "%.2g", d)
    }
}

// MARK: - Pricing Breakdown Row

struct PricingBreakdownRow: View {
    let label: String
    let value: Decimal

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value.currencyString).font(.subheadline)
        }
        .padding()
    }
}

// MARK: - Estimate Create View

struct EstimateCreateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Estimate?              = nil
    var preselectedClientID: UUID?       = nil
    var preselectedSiteID: UUID?         = nil
    var context: CommercialContext?      = nil   // from CommercialIntakeView
    var onCreated: ((Estimate) -> Void)? = nil

    // Selection state
    @State private var selectedClientID:  UUID? = nil
    @State private var selectedSiteID:    UUID? = nil
    @State private var selectedContactID: UUID? = nil

    // Form fields
    @State private var name               = ""
    @State private var opportunityType: OpportunityType = .rfq
    @State private var pricingType: PricingType         = .lumpSum
    @State private var scopeDescription   = ""
    @State private var hasBidDueDate      = false
    @State private var bidDueDate         = Date()
    @State private var contingencyString  = "0"
    @State private var overheadString     = "0"
    @State private var profitString       = "0"
    @State private var notes              = ""

    // Sheet state
    @State private var showClientPicker   = false
    @State private var showSitePicker     = false
    @State private var showContactPicker  = false
    @State private var showValidationError = false
    @State private var validationMessage  = ""

    // Phase-2 deferred audit fix: concurrent-edit detection on edits.
    @State private var editingBaselineUpdatedAt: Date = Date()
    @State private var conflictServerEstimate: Estimate? = nil
    @State private var showConflictAlert = false
    @State private var pendingLocalEstimate: Estimate? = nil

    // Terms & Conditions support — stable estimate ID for the form
    // session. For new estimates, this UUID is assigned to the new
    // estimate at save() time so any terms attached during the form
    // session land on the correct FK.
    @State private var editingEstimateID: UUID = UUID()
    @State private var defaultsAttemptedThisSession: Bool = false
    /// Single enum-driven sheet for terms — avoids the multi-sheet
    /// binding flap SwiftUI exhibits when several `.sheet(isPresented:)`
    /// modifiers compete on the same view.
    private enum ActiveTermsSheet: String, Identifiable {
        case picker, custom, preview
        var id: String { rawValue }
    }
    @State private var activeTermsSheet: ActiveTermsSheet? = nil

    private var isEditing: Bool { existing != nil }

    /// Phase 9 (lock-on-promote): once an estimate has been converted
    /// to a quote, its line items + scope are SNAPSHOTTED on that
    /// quote. Editing the source estimate from this point would silently
    /// drift away from the snapshot — reports comparing estimate vs
    /// actuals would use a baseline different from the one the quote
    /// represents. The lock is iOS-only (server still allows updates
    /// but iOS doesn't expose any mutation paths once locked).
    private var isLocked: Bool {
        existing?.status == .converted
    }

    /// Quote that this estimate was converted to, if any. Used to surface
    /// a "View linked quote" link on the lock banner so the user has a
    /// clear next step.
    private var linkedQuote: Quote? {
        guard let convertedQuoteID = existing?.convertedQuoteID else { return nil }
        return store.quotes.first { $0.id == convertedQuoteID && !$0.isDeleted }
    }

    private var selectedClient: Client? {
        guard let id = selectedClientID else { return nil }
        return store.client(id: id)
    }

    private var selectedSite: ClientSite? {
        guard let siteID = selectedSiteID else { return nil }
        return selectedClient?.sites.first(where: { $0.id == siteID })
    }

    /// Drives the terms section's read-only state. Submitted /
    /// completed / converted estimates freeze attached terms.
    private var termsReadOnly: Bool {
        guard let s = existing?.status else { return false }
        return s.termsAreReadOnly
    }

    private var selectedContact: CRMContact? {
        guard let cid = selectedContactID else { return nil }
        return store.crmContacts.first(where: { $0.id == cid })
    }

    var body: some View {
        NavigationStack {
            Form {
                // Phase 9 (lock-on-promote): converted estimates are
                // read-only because their line items have been
                // snapshotted onto a quote.
                if isLocked {
                    Section {
                        lockedBanner
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
                clientSection
                siteSection
                contactSection
                jobDetailsSection
                Section("Bid Due Date") {
                    Toggle("Set Bid Due Date", isOn: $hasBidDueDate)
                    if hasBidDueDate {
                        DatePicker("Due Date", selection: $bidDueDate, displayedComponents: .date)
                    }
                }
                Section("Scope Description") {
                    TextEditor(text: $scopeDescription).frame(minHeight: 80)
                }
                Section("Pricing Adjustments") {
                    percentRow("Contingency", text: $contingencyString)
                    percentRow("Overhead",    text: $overheadString)
                    percentRow("Profit",      text: $profitString)
                }
                // Terms & Conditions — Path-A clone of QuoteTermsSection.
                // Section delegates sheet presentation back to this
                // parent via the on*Present closures so we own a single
                // enum-driven sheet (activeTermsSheet) and avoid the
                // nested-sheet binding flap.
                EstimateTermsSection(
                    estimateID:       editingEstimateID,
                    readOnly:         termsReadOnly,
                    onPresentPicker:  { activeTermsSheet = .picker },
                    onPresentCustom:  { activeTermsSheet = .custom },
                    onPresentPreview: { activeTermsSheet = .preview }
                )
                .environmentObject(store)
                Section("Internal Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            // Form-level disable when locked. Individual rows still
            // render — they're just non-interactive. Users can READ
            // the estimate, just not change it.
            .disabled(isLocked)
            .navigationTitle(isEditing ? "Edit Estimate" : "New Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Re-enable the Cancel button so users can dismiss
                    // a locked view (the form-level .disabled() above
                    // would otherwise grey out the toolbar too).
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
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .alert("Someone else updated this estimate",
                   isPresented: $showConflictAlert) {
                Button("Overwrite with my changes", role: .destructive) {
                    if let est = pendingLocalEstimate, let cid = selectedClientID {
                        finalizeEstimateSave(est, clientID: cid)
                    }
                }
                Button("Discard my changes", role: .cancel) {
                    Task { await store.refreshAll() }
                    dismiss()
                }
            } message: {
                if let server = conflictServerEstimate {
                    let by = server.lastModifiedBy.isEmpty ? "another user" : server.lastModifiedBy
                    let when = server.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    Text("\(by) updated this estimate on the server at \(when), after you opened it. Saving now would overwrite their changes.")
                } else {
                    Text("The server has newer changes than your local copy.")
                }
            }
            .sheet(isPresented: $showClientPicker) {
                ClientPickerSheet(selectedClientID: $selectedClientID)
            }
            .sheet(isPresented: $showSitePicker) {
                if let clientID = selectedClientID {
                    SitePickerSheet(clientID: clientID, selectedSiteID: $selectedSiteID)
                        .environmentObject(store)
                        .onDisappear { autoSuggestContact() }
                }
            }
            .sheet(isPresented: $showContactPicker) {
                if let clientID = selectedClientID {
                    ClientContactPickerSheet(
                        clientID:          clientID,
                        siteID:            selectedSiteID,
                        selectedContactID: $selectedContactID
                    )
                    .environmentObject(store)
                }
            }
            // Terms & Conditions sheet router — single enum drives all
            // three terms-related sheets so SwiftUI never has competing
            // bindings active at once. The picker / custom / preview
            // sheets NEVER trigger workflow status changes on the
            // parent estimate.
            .sheet(item: $activeTermsSheet) { kind in
                switch kind {
                case .picker:
                    EstimateTermsPickerSheet(estimateID: editingEstimateID)
                        .environmentObject(store)
                case .custom:
                    EstimateCustomTermSheet(estimateID: editingEstimateID)
                        .environmentObject(store)
                case .preview:
                    EstimateTermsPreviewSheet(estimateID: editingEstimateID)
                        .environmentObject(store)
                }
            }
            .onAppear {
                populate()
                applyDefaultTermsIfNeeded()
            }
            .task {
                // Pull current templates + already-attached terms so
                // the section is populated. Cheap queries — small
                // tables, single tenant. NEVER triggers status changes.
                await SyncEngine.shared.pullTermsTemplates()
                await SyncEngine.shared.pullEstimateTerms()
            }
        }
    }

    // MARK: - Extracted Sections (prevents type-checker timeout)

    @ViewBuilder private var clientSection: some View {
        Section {
            Button { showClientPicker = true } label: {
                EstimatePickerRow(
                    icon:    selectedClient != nil ? nil : "building.2",
                    label:   selectedClient?.name ?? "Select Client",
                    isEmpty: selectedClient == nil
                )
            }
        } header: { stepHeader(number: "1", title: "Client", required: true) }
    }

    @ViewBuilder private var siteSection: some View {
        Section {
            Button {
                if selectedClientID == nil {
                    validationMessage = "Please select a client first."
                    showValidationError = true
                } else {
                    showSitePicker = true
                }
            } label: {
                if let site = selectedSite {
                    let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
                    EstimatePickerRow(icon: "mappin.circle.fill", iconColor: .orange,
                                     label: site.name, subtitle: addr, isEmpty: false)
                } else {
                    EstimatePickerRow(
                        icon:    "mappin.slash",
                        label:   selectedClientID == nil ? "Select client first" : "Select Site",
                        isEmpty: true
                    )
                }
            }
            .disabled(selectedClientID == nil)
        } header: {
            stepHeader(number: "2", title: "Site", required: true,
                       badge: selectedSiteID == nil ? "Required" : nil)
        }
    }

    @ViewBuilder private var contactSection: some View {
        Section {
            Button {
                if selectedClientID == nil {
                    validationMessage = "Please select a client first."
                    showValidationError = true
                } else {
                    showContactPicker = true
                }
            } label: {
                if let contact = selectedContact {
                    EstimatePickerRow(icon: contact.role.icon, iconColor: contact.role.color,
                                     label: contact.fullName, subtitle: contact.role.label, isEmpty: false)
                } else {
                    EstimatePickerRow(
                        icon:    "person.slash",
                        label:   selectedClientID == nil ? "Select client first" : "Select Contact",
                        isEmpty: true
                    )
                }
            }
            .disabled(selectedClientID == nil)
        } header: {
            stepHeader(number: "3", title: "Primary Contact", required: true,
                       badge: selectedContactID == nil ? "Required" : nil)
        }
    }

    @ViewBuilder private var jobDetailsSection: some View {
        Section("Job Details *") {
            TextField("Estimate / Bid Name", text: $name)
            Picker("Type", selection: $opportunityType) {
                ForEach(OpportunityType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.menu)
            Picker("Pricing Type", selection: $pricingType) {
                ForEach(PricingType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func autoSuggestContact() {
        guard selectedContactID == nil,
              let siteID   = selectedSiteID,
              let clientID = selectedClientID else { return }
        let siteMatch = store.crmContacts.first {
            $0.clientID == clientID &&
            $0.siteID == siteID &&
            ($0.role == .siteContact || $0.role == .decisionMaker)
        }
        let primaryMatch = store.crmContacts.first {
            $0.clientID == clientID && $0.isPrimary
        }
        selectedContactID = siteMatch?.id ?? primaryMatch?.id
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func stepHeader(number: String, title: String, required: Bool, badge: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2).bold()
                .frame(width: 18, height: 18)
                .background(Color.purple)
                .foregroundColor(.white)
                .clipShape(Circle())
            Text(title).font(.subheadline).bold()
            if required { Text("*").foregroundColor(.red).font(.caption) }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
        }
    }

    @ViewBuilder
    private func percentRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Text("%").foregroundColor(.secondary)
        }
    }

    // MARK: - Populate

    private func populate() {
        // Apply CommercialContext (lowest priority — existing and preselected override)
        if let ctx = context {
            if selectedClientID  == nil { selectedClientID  = ctx.clientID }
            if selectedSiteID    == nil { selectedSiteID    = ctx.siteID }
            if selectedContactID == nil { selectedContactID = ctx.contactID }
        }
        if let id = preselectedClientID  { selectedClientID  = id }
        if let id = preselectedSiteID    { selectedSiteID    = id }
        guard let e = existing else { return }
        // Align the form's stable terms-FK with the existing estimate
        // so any terms attached during edit land on the right row.
        editingEstimateID   = e.id
        selectedClientID    = e.clientID
        selectedSiteID      = e.siteID
        selectedContactID   = e.primaryContactID
        name                = e.name
        opportunityType     = e.opportunityType
        pricingType         = e.pricingType
        scopeDescription    = e.scopeDescription ?? ""
        hasBidDueDate       = e.bidDueDate != nil
        bidDueDate          = e.bidDueDate ?? Date()
        contingencyString   = "\(e.contingencyPercent)"
        overheadString      = "\(e.overheadPercent)"
        profitString        = "\(e.profitPercent)"
        notes               = e.notes ?? ""
        // Capture for the conflict pre-check on save.
        editingBaselineUpdatedAt = e.updatedAt
    }

    /// One-shot default-templates attachment. Mirrors the
    /// `applyDefaultTermsIfNeeded` flow on QuoteCreateView. Reads
    /// the estimate's `termsDefaultApplied` flag (or treats new
    /// estimates as "needs apply") and snapshots every active
    /// is_default template onto this estimate. Read-only estimates
    /// never get default-attachment.
    /// IMPORTANT: this NEVER changes the estimate's status — only
    /// terms_default_applied is touched on the parent record at
    /// finalizeEstimateSave time.
    private func applyDefaultTermsIfNeeded() {
        guard !defaultsAttemptedThisSession else { return }
        defaultsAttemptedThisSession = true

        guard !termsReadOnly else { return }

        let needsApply: Bool
        if let e = existing {
            needsApply = !e.termsDefaultApplied
        } else {
            needsApply = true
        }
        guard needsApply else { return }

        // Don't re-attach defaults already present (matched by templateID)
        let existingTemplateIDs = Set(
            store.estimateTerms(for: editingEstimateID).compactMap { $0.templateID }
        )
        let defaults = store.activeTermsTemplates
            .filter { $0.isDefault && !existingTemplateIDs.contains($0.id) }
        for d in defaults {
            store.attachTermsTemplateToEstimate(d, estimateID: editingEstimateID)
        }
    }

    // MARK: - Save

    /// Phase 9 lock banner. Shown at top of the form when the estimate
    /// has already been converted to a quote. Includes a tap-through to
    /// the linked quote when one is in the local cache.
    @ViewBuilder
    private var lockedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.indigo)
                Text("Locked — converted to quote")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
            }
            Text("This estimate has been converted to a quote. Editing here would drift from the snapshot the quote was built from. Open the linked quote to make changes.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let q = linkedQuote {
                NavigationLink {
                    QuoteDetailView(quote: q)
                        .environmentObject(store)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Open quote \(q.jobNumber)")
                            .font(.caption.bold())
                    }
                    .foregroundColor(.indigo)
                }
                // Re-enable the link inside the otherwise-disabled form.
                .disabled(false)
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(10)
    }

    private func save() {
        // Phase 9 lock — defensive guard. UI shouldn't allow Save to be
        // tapped when locked (toolbar swaps in a Locked label) but if
        // any code path slips through we abort with a clear message.
        if isLocked {
            validationMessage = "This estimate has been converted to a quote and is locked. Open the linked quote to make changes."
            showValidationError = true
            return
        }
        guard let clientID = selectedClientID else {
            validationMessage = "Please select a client."
            showValidationError = true
            return
        }
        guard selectedSiteID != nil else {
            validationMessage = "A site is required. Select where this work will be performed."
            showValidationError = true
            return
        }
        guard selectedContactID != nil else {
            validationMessage = "A primary contact is required. Who should this estimate be addressed to?"
            showValidationError = true
            return
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Estimate name is required."
            showValidationError = true
            return
        }

        let jobNumber = existing?.jobNumber ?? AppSettings.shared.nextJobNumber()

        var estimate = existing ?? Estimate(
            jobNumber: jobNumber,
            clientID:  clientID,
            name:      name
        )
        // Align estimate.id with the form's stable editingEstimateID so
        // any estimate_terms attached during this session land on the
        // right FK. No-op for existing estimates (populate() already
        // synced editingEstimateID = e.id).
        let isNewEstimate = (existing == nil)
        if isNewEstimate { estimate.id = editingEstimateID }
        estimate.clientID           = clientID
        estimate.siteID             = selectedSiteID
        estimate.primaryContactID   = selectedContactID
        estimate.name               = name
        estimate.opportunityType    = opportunityType
        estimate.pricingType        = pricingType
        estimate.scopeDescription   = scopeDescription.isEmpty ? nil : scopeDescription
        // Defaults have had their one chance to attach (during
        // applyDefaultTermsIfNeeded() on appear). Mark the ledger so
        // a later sync that brings in a new is_default template
        // doesn't retroactively attach it to this estimate.
        estimate.termsDefaultApplied = true
        estimate.bidDueDate         = hasBidDueDate ? bidDueDate : nil
        estimate.contingencyPercent = Decimal(string: contingencyString) ?? 0
        estimate.overheadPercent    = Decimal(string: overheadString) ?? 0
        estimate.profitPercent      = Decimal(string: profitString) ?? 0
        estimate.notes              = notes.isEmpty ? nil : notes
        estimate.estimatorID        = store.currentUser?.id
        estimate.lastModifiedBy     = store.currentUser?.fullName ?? ""
        estimate.lastModifiedAt     = Date()
        estimate.updatedAt          = Date()
        estimate.syncStatus         = .pending

        // Stamp CRM/project linkage from the context the user came in with.
        // Only on new estimates — editing keeps whatever origin it was created with.
        if existing == nil {
            if let oppID = context?.opportunityID {
                estimate.originType    = .crmOpportunity
                estimate.opportunityID = oppID
            } else if let projID = context?.projectID {
                estimate.originType = .project
                estimate.projectID  = projID
            }
            // else: leave default .directCommercial. ensureCRMLink may
            // still attach a CRM opp for tracking, but origin stays direct.
        }

        // Phase-2 deferred audit fix: concurrent-edit pre-check on
        // edits. New estimates can't conflict.
        if existing != nil {
            pendingLocalEstimate = estimate
            Task { @MainActor in
                let result = await ConflictDetectionService.shared.checkEstimate(
                    id:                estimate.id,
                    baselineUpdatedAt: editingBaselineUpdatedAt
                )
                switch result {
                case .clean, .checkFailed, .notFound:
                    finalizeEstimateSave(estimate, clientID: clientID)
                case .conflict(let server):
                    conflictServerEstimate = server
                    showConflictAlert      = true
                }
            }
        } else {
            finalizeEstimateSave(estimate, clientID: clientID)
        }
    }

    /// Extracted from save() so the conflict alert path can call it
    /// after the user confirms "Overwrite with my changes".
    private func finalizeEstimateSave(_ estimate: Estimate, clientID: UUID) {
        // Phase 7 / Decision 2 UX polish: detect when the auto-create
        // path will fire so we can surface a toast naming the new
        // Opportunity. Two paths converge on a brand-new estimate that
        // had no opportunity at save time:
        //   1. `upsertEstimate` calls `ensureCRMLink` (AppStore:960)
        //   2. The `context.opportunityID == nil` branch below calls
        //      `createOpportunityFromContext`
        // Either way, the stored estimate's opportunityID flips from
        // nil → set during this method. We capture the "before" state
        // here and read the "after" via the store post-save.
        let willAutoCreateOpp = (existing == nil)
            && (estimate.opportunityID == nil)
            && (context?.opportunityID == nil)

        store.upsertEstimate(estimate)
        onCreated?(estimate)

        // Auto-create CRM opportunity from context if we have one and no opportunity yet
        if var ctx = context, ctx.opportunityID == nil {
            ctx.clientID   = clientID
            ctx.estimateID = estimate.id
            if ctx.workType == nil { ctx.workType = .projectWork }
            store.createOpportunityFromContext(&ctx)
        }

        // Surface a toast naming the auto-created Opportunity so the
        // user knows the linkage happened and where to rename it.
        // Pre-fix the auto-create was silent except for a CRMActivity
        // feed entry — the audit (Decision 2) called this out as a
        // missing piece even though the data-layer side was wired.
        if willAutoCreateOpp,
           let stored = store.estimates.first(where: { $0.id == estimate.id }),
           let oppID  = stored.opportunityID,
           let opp    = store.crmOpportunities.first(where: { $0.id == oppID }) {
            ToastService.shared.info(
                "Opportunity “\(opp.title)” auto-created — rename anytime from CRM."
            )
        }

        dismiss()
    }
}

// MARK: - Estimate Picker Row Helper

private struct EstimatePickerRow: View {
    var icon:      String?
    var iconColor: Color = .secondary
    var label:     String
    var subtitle:  String = ""
    var isEmpty:   Bool   = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .foregroundColor(isEmpty ? Color(.quaternaryLabel) : iconColor)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).foregroundColor(isEmpty ? .secondary : .primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - AppStore: Estimate Documents

import Combine

extension AppStore {

    // All estimate documents (stored separately from project documents)
    var allEstimateDocs: [ProjectDocument] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "bv_estimate_documents"),
              let docs  = try? decoder.decode([ProjectDocument].self, from: data)
        else { return [] }
        return docs
    }

    func estimateDocs(for estimateID: UUID) -> [ProjectDocument] {
        allEstimateDocs
            .filter  { $0.projectID == estimateID }   // projectID field repurposed as ownerID
            .sorted  { $0.uploadedAt > $1.uploadedAt }
    }

    func addEstimateDoc(_ doc: ProjectDocument) {
        var current = allEstimateDocs
        current.append(doc)
        saveEstimateDocMeta(current)
        objectWillChange.send()
    }

    func updateEstimateDoc(_ doc: ProjectDocument) {
        var current = allEstimateDocs
        if let i = current.firstIndex(where: { $0.id == doc.id }) { current[i] = doc }
        saveEstimateDocMeta(current)
        objectWillChange.send()
    }

    func deleteEstimateDoc(_ doc: ProjectDocument) {
        try? FileManager.default.removeItem(at: doc.storedURL)
        var current = allEstimateDocs
        current.removeAll { $0.id == doc.id }
        saveEstimateDocMeta(current)
        objectWillChange.send()
    }

    private func saveEstimateDocMeta(_ docs: [ProjectDocument]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(docs) {
            UserDefaults.standard.set(data, forKey: "bv_estimate_documents")
        }
    }
}

// MARK: - Estimate Documents Section (inline in EstimateDetailView)

struct EstimateDocumentsSection: View {
    let estimateID: UUID
    @EnvironmentObject var store: AppStore
    @State private var showPicker    = false
    @State private var showAll       = false
    @State private var selectedDoc: ProjectDocument? = nil

    private var docs: [ProjectDocument] { store.estimateDocs(for: estimateID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                SectionHeader(title: "Estimate Documents", count: docs.count)
                Spacer()
                if docs.count > 4 {
                    Button("View All") { showAll = true }
                        .font(.subheadline)
                        .padding(.trailing)
                }
            }

            if docs.isEmpty {
                EmptyCard(message: "No documents yet. Attach RFQs, drawings, sub quotes, takeoff sheets and more.")
            } else {
                VStack(spacing: 0) {
                    ForEach(docs.prefix(4)) { doc in
                        Button { selectedDoc = doc } label: {
                            EstimateDocRow(doc: doc)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        if doc.id != docs.prefix(4).last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            // Add Document button
            Button { showPicker = true } label: {
                Label("Add Document", systemImage: "plus.circle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.indigo.opacity(0.1))
                    .foregroundColor(.indigo)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        // File picker sheet
        .sheet(isPresented: $showPicker) {
            EstimateDocumentPickerSheet(estimateID: estimateID)
        }
        // View all sheet
        .sheet(isPresented: $showAll) {
            EstimateDocumentListView(estimateID: estimateID)
        }
        // Document detail sheet
        .sheet(item: $selectedDoc) { doc in
            NavigationStack {
                EstimateDocDetailView(doc: doc)
            }
        }
    }
}

// MARK: - Estimate Doc Row

private struct EstimateDocRow: View {
    let doc: ProjectDocument

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(doc.category.color.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: doc.fileIcon)
                    .foregroundColor(doc.category.color)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(doc.category.displayName)
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(doc.category.color.opacity(0.1))
                        .foregroundColor(doc.category.color)
                        .cornerRadius(4)
                    Text(doc.fileSizeString)
                        .font(.caption).foregroundColor(.secondary)
                    Text("·")
                        .font(.caption).foregroundColor(.secondary)
                    Text(doc.uploadedAt.shortDate)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Estimate Document Picker Sheet

private struct EstimateDocumentPickerSheet: View {
    let estimateID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showDocPicker = false
    @State private var categoryOverride: ProjectDocumentCategory? = nil

    // Estimate-relevant quick-pick categories
    private let quickCategories: [(ProjectDocumentCategory, String, String)] = [
        (.contract, "RFQ / ITB",         "doc.text.fill"),
        (.drawing,  "Drawings & Specs",   "pencil.and.ruler.fill"),
        (.report,   "Takeoff / Calcs",    "function"),
        (.quote,    "Sub / Supplier Quote","tag.fill"),
        (.photo,    "Site Photos",        "camera.fill"),
        (.permit,   "Permits / Approvals","checkmark.seal.fill"),
        (.safety,   "Safety Specs",       "exclamationmark.shield.fill"),
        (.other,    "Other",              "doc.fill"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("What type of document are you adding?") {
                    ForEach(quickCategories, id: \.0) { cat, label, icon in
                        Button {
                            categoryOverride = cat
                            showDocPicker    = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(cat.color.opacity(0.12))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: icon)
                                        .foregroundColor(cat.color)
                                }
                                Text(label)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showDocPicker) {
                DocumentPicker(allowedTypes: [.pdf, .image, .item]) { urls in
                    importFiles(urls, category: categoryOverride ?? .other)
                    dismiss()
                }
            }
        }
    }

    private func importFiles(_ urls: [URL], category: ProjectDocumentCategory) {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            let ext      = url.pathExtension.lowercased()
            let filename = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let dest     = docDir.appendingPathComponent(filename)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            let size     = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var doc = ProjectDocument(
                projectID:       estimateID,   // owner = estimateID
                name:            url.deletingPathExtension().lastPathComponent,
                originalFileName: url.lastPathComponent,
                fileExtension:   ext,
                fileSize:        size,
                storedFileName:  filename,
                category:        category,
                uploadedBy:      AppStore.shared.currentUser?.fullName ?? "Unknown"
            )
            store.addEstimateDoc(doc)
        }
    }
}

// MARK: - Estimate Document Detail View

struct EstimateDocDetailView: View {
    let doc: ProjectDocument
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var localDoc: ProjectDocument
    @State private var showPreview    = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showEdit       = false
    @State private var showDeleteAlert = false

    init(doc: ProjectDocument) {
        self.doc = doc
        self._localDoc = State(initialValue: doc)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // File hero
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(localDoc.category.color.opacity(0.1))
                            .frame(height: 100)
                        Image(systemName: localDoc.fileIcon)
                            .font(.system(size: 44))
                            .foregroundColor(localDoc.category.color)
                    }
                    Text(localDoc.name)
                        .font(.title3).bold()
                        .multilineTextAlignment(.center)
                    Text(localDoc.category.displayName)
                        .font(.caption).bold()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(localDoc.category.color.opacity(0.12))
                        .foregroundColor(localDoc.category.color)
                        .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // Metadata
                VStack(spacing: 0) {
                    MetaRow(label: "File", value: localDoc.originalFileName)
                    Divider().padding(.leading)
                    MetaRow(label: "Size", value: localDoc.fileSizeString)
                    Divider().padding(.leading)
                    MetaRow(label: "Added", value: localDoc.uploadedAt.shortDate)
                    Divider().padding(.leading)
                    MetaRow(label: "By", value: localDoc.uploadedBy)
                    if !localDoc.fileExists {
                        Divider().padding(.leading)
                        MetaRow(label: "Status", value: "⚠ File not found on device")
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Notes
                if let notes = localDoc.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        Text(notes)
                            .font(.subheadline)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                // Actions
                VStack(spacing: 12) {
                    if localDoc.fileExists {
                        Button { showPreview = true } label: {
                            Label("Open / Preview", systemImage: "eye.fill")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }
                    Button {
                        shareItems = [localDoc.storedURL]
                        showShareSheet = true
                    } label: {
                        Label("Share / Export", systemImage: "square.and.arrow.up")
                            .font(.subheadline).bold()
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.blue.opacity(0.10))
                            .foregroundColor(.blue)
                            .cornerRadius(12)
                    }
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Delete Document", systemImage: "trash")
                            .font(.subheadline).bold()
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.red.opacity(0.10))
                            .foregroundColor(.red)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            QuickLookPreview(url: localDoc.storedURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showEdit) {
            EstimateDocEditView(doc: localDoc) { updated in
                store.updateEstimateDoc(updated)
                localDoc = updated
            }
        }
        .alert("Delete Document?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                store.deleteEstimateDoc(localDoc)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \"\(localDoc.name)\". This cannot be undone.")
        }
    }

    private struct MetaRow: View {
        let label: String
        let value: String
        var body: some View {
            HStack {
                Text(label).font(.subheadline).foregroundColor(.secondary)
                Spacer()
                Text(value).font(.subheadline).bold().multilineTextAlignment(.trailing)
            }
            .padding()
        }
    }
}

// MARK: - Estimate Doc Edit View

struct EstimateDocEditView: View {
    let doc: ProjectDocument
    var onSave: (ProjectDocument) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var name: String
    @State private var category: ProjectDocumentCategory
    @State private var notes: String

    init(doc: ProjectDocument, onSave: @escaping (ProjectDocument) -> Void) {
        self.doc    = doc
        self.onSave = onSave
        _name     = State(initialValue: doc.name)
        _category = State(initialValue: doc.category)
        _notes    = State(initialValue: doc.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("File Name") {
                    TextField("Name", text: $name)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(ProjectDocumentCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Notes") {
                    TextField("Optional notes…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var updated = doc
                        updated.name     = name.isEmpty ? doc.name : name
                        updated.category = category
                        updated.notes    = notes.isEmpty ? nil : notes
                        onSave(updated)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

// MARK: - Estimate Document List View (full list)

struct EstimateDocumentListView: View {
    let estimateID: UUID
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""
    @State private var selectedCategory: ProjectDocumentCategory? = nil
    @State private var showPicker = false
    @State private var selectedDoc: ProjectDocument? = nil

    private var docs: [ProjectDocument] { store.estimateDocs(for: estimateID) }

    private var filtered: [ProjectDocument] {
        docs.filter { doc in
            let q = searchText.isEmpty ||
                doc.name.localizedCaseInsensitiveContains(searchText) ||
                doc.originalFileName.localizedCaseInsensitiveContains(searchText)
            let c = selectedCategory == nil || doc.category == selectedCategory
            return q && c
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Category filter chips
                if !docs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            EstimateDocChip(title: "All", color: .indigo, isSelected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(ProjectDocumentCategory.allCases, id: \.self) { cat in
                                if docs.contains(where: { $0.category == cat }) {
                                    EstimateDocChip(
                                        title: cat.displayName,
                                        color: cat.color,
                                        isSelected: selectedCategory == cat
                                    ) {
                                        selectedCategory = selectedCategory == cat ? nil : cat
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowSeparator(.hidden)
                }

                if filtered.isEmpty {
                    Text("No documents match your filter.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(filtered) { doc in
                        Button { selectedDoc = doc } label: {
                            EstimateDocRow(doc: doc)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idxSet in
                        idxSet.forEach { store.deleteEstimateDoc(filtered[$0]) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search documents…")
            .navigationTitle("Estimate Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                EstimateDocumentPickerSheet(estimateID: estimateID)
            }
            .sheet(item: $selectedDoc) { doc in
                NavigationStack {
                    EstimateDocDetailView(doc: doc)
                }
            }
        }
    }
}

private struct EstimateDocChip: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption).bold()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.1))
                .foregroundColor(isSelected ? .white : color)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reviewer Picker Sheet
// Used by EstimateDetailView when the estimator submits an estimate for
// internal review. Lists active employees with decision-maker roles
// (estimator, project_manager, manager, executive, office_admin —
// field_worker excluded). On Confirm, the parent fires the local
// notification and stamps internal_review_by on the estimate.

private struct ReviewerPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @Binding var pickedReviewerID: UUID?
    var onConfirm: (UUID) -> Void
    var onCancel:  () -> Void

    @State private var searchText: String = ""

    /// Roles allowed to act as estimate reviewers. Mirrors the SQL
    /// is_estimating_admin() function — field_worker is intentionally
    /// excluded so estimates aren't routed to crew for approval.
    private static let allowedRoles: Set<UserRole> = [
        .estimator, .projectManager, .manager, .executive, .officeAdmin
    ]

    private var candidates: [Employee] {
        store.employees
            .filter { $0.isActive
                      && Self.allowedRoles.contains($0.role)
                      && (searchText.isEmpty
                          || $0.fullName.localizedCaseInsensitiveContains(searchText)
                          || $0.role.displayName.localizedCaseInsensitiveContains(searchText)) }
            .sorted { $0.lastName.localizedCaseInsensitiveCompare($1.lastName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.employees.filter({ $0.isActive && Self.allowedRoles.contains($0.role) }).isEmpty {
                    EmptyStatePlaceholder(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "No eligible reviewers",
                        subtitle: "Reviewers must be active employees with the estimator, project manager, manager, executive, or office admin role. Add one in Employees first.",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    List {
                        Section {
                            ForEach(candidates) { emp in
                                Button {
                                    pickedReviewerID = emp.id
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(emp.fullName).foregroundColor(.primary)
                                            Text(emp.role.displayName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if pickedReviewerID == emp.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text("The reviewer gets a local notification and the estimate is stamped with their name.")
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search by name or role")
                }
            }
            .navigationTitle("Pick a Reviewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        if let id = pickedReviewerID { onConfirm(id) }
                    }
                    .bold()
                    .disabled(pickedReviewerID == nil)
                }
            }
        }
    }
}
