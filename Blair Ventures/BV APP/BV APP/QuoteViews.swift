// QuoteViews.swift
// AskiCommand – Quote Module
// Session 4 Step 5: Quote-to-project conversion added

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Quote Model

struct Quote: BaseModel {
    static func == (lhs: Quote, rhs: Quote) -> Bool { lhs.id == rhs.id }

    // MARK: BaseModel fields
    var id: UUID = UUID()
    var externalID: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. Quotes link CRM opportunities to commercial
    /// pricing — derived from the parent estimate's `companyID` (or
    /// `currentCompanyID` as a fallback). Required NOT NULL server-side.
    var companyID: UUID? = nil

    var jobNumber: String           // Quote number: Q-YYYY-NNNN
    var revision: Int = 1
    var estimateID: UUID
    var opportunityID: UUID? = nil  // bi-directional link to CRM opportunity
    var projectID: UUID?
    var clientID: UUID
    var clientName: String
    var siteAddress: String?
    var preparedBy: String
    var quoteDate: Date = Date()
    var expiryDate: Date = Calendar.current.date(
        byAdding: .day, value: 30, to: Date()
    ) ?? Date()

    var scopeSummary: String = ""
    var inclusions: String = ""
    var exclusions: String = ""
    var assumptions: String = ""

    // Line items — the authoritative source of pricing
    // Subtotal is auto-computed from line items when they exist;
    // falls back to the manually-entered subtotal for legacy / Quick Quote records.
    var lineItems: [CostCodeItem] = []
    var subtotal: Decimal = 0         // manual override (used when lineItems is empty)
    var discountPercent: Decimal = 0
    var contingencyPercent: Decimal = 0
    var taxRate: Decimal = 0          // e.g. 5.0 for 5% GST; loaded from AppSettings on creation

    // ── Computed pricing ──────────────────────────────────────────────────────

    /// Sum of all line item totals, or the manual subtotal if no items.
    var lineItemsSubtotal: Decimal {
        lineItems.isEmpty ? subtotal : lineItems.reduce(0) { $0 + $1.estimatedTotal }
    }

    /// Discount amount applied to the subtotal.
    var discountAmount: Decimal { lineItemsSubtotal * discountPercent / 100 }

    /// Subtotal after discount, before contingency.
    var subtotalAfterDiscount: Decimal { lineItemsSubtotal - discountAmount }

    /// Contingency amount.
    var contingencyAmount: Decimal { subtotalAfterDiscount * contingencyPercent / 100 }

    /// Total before tax (what was previously "totalBeforeTax").
    var totalBeforeTax: Decimal { subtotalAfterDiscount + contingencyAmount }

    /// Tax amount.
    var taxAmount: Decimal { totalBeforeTax * taxRate / 100 }

    /// Grand total including tax.
    var grandTotal: Decimal { totalBeforeTax + taxAmount }

    var paymentTerms: String = "Net 30 — 50% on mobilization, 50% on completion"
    var validityDays: Int = 30

    var status: QuoteStatus = .draft
    var approvedBy: String?
    var approvedAt: Date?
    var sentAt: Date?
    var acceptedAt: Date?
    var assignedPMID: UUID?
    var assignedPMName: String?

    /// SR-1.3 (legacy) — single-crew take-off preference.
    /// Superseded by `laborPlan.preferredCrewID` (SR-1.4). Kept on
    /// the model for migration round-trip; new writes go through
    /// laborPlan. Will be removed once labor_plan adoption is
    /// universal and the column is dropped server-side.
    var preferredCrewID: UUID? = nil

    /// SR-1.4 — take-off labor requirements. Captures count, worker
    /// class, required certifications, preferred / required workers,
    /// and an optional preferred crew. The recommendation engine
    /// reads this and assembles ANY valid combination of resources
    /// (fixed crew, custom crew, or single worker) that satisfies
    /// the requirement. Empty plan = no constraint; engine picks
    /// best fit using its default scoring.
    var laborPlan: LaborRequirement = LaborRequirement()

    // 2026-04 audit fix (re-audit P0): explicit ISO 4217 currency.
    // Pre-fix the model implicitly assumed USD/local-default; a CAD
    // shop sending a USD invoice through Stripe wouldn't notice the
    // mismatch until reconciliation. Defaults to "USD" for legacy
    // rows; new quotes use AppSettings.shared.preferredCurrency.
    var currency: String = "USD"

    // ── Loss tracking (Phase 4 audit fix) ─────────────────────────────────
    // Captured when a quote is marked Declined. Mirror of the same
    // fields on Estimate so reporting can roll up by reason regardless
    // of which side the loss was logged on. The QuoteDeclineSheet UI
    // populates these; the bridge propagates them to the linked CRM
    // opportunity via `resolveOpportunityOutcome(.lost)`.
    var lossReason: LossReason?      = nil
    var competitorName: String?      = nil
    var winLossNotes: String?        = nil
    var declinedAt: Date?            = nil

    // ── Terms & Conditions (Slice B) ──────────────────────────────────────
    // One-shot ledger flag: defaults are auto-attached on first save
    // and then this stays true for the life of the quote, so user
    // removals stick. See applyDefaultTermsIfNeeded() in TermsTemplate.swift.
    var termsDefaultApplied: Bool    = false

    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    // Soft delete
    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil

    init(jobNumber: String = "", estimateID: UUID = UUID(), clientID: UUID = UUID(),
         clientName: String = "", preparedBy: String = "") {
        self.jobNumber   = jobNumber
        self.estimateID  = estimateID
        self.clientID    = clientID
        self.clientName  = clientName
        self.preparedBy  = preparedBy
    }
}

enum QuoteStatus: String, Codable {
    case draft    = "draft"
    case approved = "approved"
    case sent     = "sent"
    case accepted = "accepted"
    case declined = "declined"

    var displayName: String {
        switch self {
        case .draft:    return "Draft"
        case .approved: return "Approved"
        case .sent:     return "Sent"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        }
    }

    var color: Color {
        switch self {
        case .draft:    return .orange
        case .approved: return .blue
        case .sent:     return .purple
        case .accepted: return .green
        case .declined: return .red
        }
    }
}

// MARK: - Quote Store Extension

extension AppStore {

    /// Returns a short human-readable summary of what changed between two
    /// versions of a Quote, used as the `change_summary` for the revision
    /// snapshot. Returns nil when nothing material changed (skip snapshot).
    fileprivate func quoteRevisionSummary(prior: Quote?, next: Quote) -> String? {
        guard let prior else { return nil }   // first-time insert handled separately
        var changes: [String] = []
        if prior.status != next.status {
            changes.append("status: \(prior.status.rawValue) → \(next.status.rawValue)")
        }
        if prior.grandTotal != next.grandTotal {
            changes.append("total: \(prior.grandTotal.currencyString) → \(next.grandTotal.currencyString)")
        }
        if prior.lineItems.count != next.lineItems.count {
            changes.append("line items: \(prior.lineItems.count) → \(next.lineItems.count)")
        }
        if prior.scopeSummary != next.scopeSummary {
            changes.append("scope edited")
        }
        if prior.discountPercent != next.discountPercent || prior.contingencyPercent != next.contingencyPercent {
            changes.append("markup adjusted")
        }
        return changes.isEmpty ? nil : changes.joined(separator: ", ")
    }

    func upsertQuote(_ quote: Quote) {
        // Detect meaningful transitions BEFORE we mutate so we can snapshot
        // the prior state for the revision-history audit trail.
        let prior = quotes.first(where: { $0.id == quote.id })
        let revisionSummary = quoteRevisionSummary(prior: prior, next: quote)

        var updated = quote
        // BUG FIX: same pattern as the upsertClient bug — the
        // `!= .synced` guard caused local edits to .synced quotes
        // to be silently dropped. Quote was the most likely victim
        // since users edit quotes after they've been pulled from
        // the server constantly. Always mark .pending on local
        // edit; the pull path uses dedicated synced-upsert helpers.
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        // Stamp tenant scope: prefer the parent estimate's companyID so the
        // quote inherits its bid's tenant, with currentCompanyID as fallback.
        if updated.companyID == nil {
            updated.companyID =
                estimates.first(where: { $0.id == updated.estimateID })?.companyID
                ?? currentCompanyID
        }
        if let index = quotes.firstIndex(where: { $0.id == updated.id }) {
            quotes[index] = updated
        } else {
            quotes.append(updated)
        }

        // Snapshot the PRIOR state once we know the change was material.
        // First-time inserts get a "Created" baseline so the revision log
        // is a complete history from inception.
        if let summary = revisionSummary, let snapshot = prior ?? (revisionSummary != nil ? quote : nil) {
            Task { await RevisionService.shared.snapshotQuote(snapshot, summary: summary) }
        } else if prior == nil {
            Task { await RevisionService.shared.snapshotQuote(quote, summary: "Created") }
        }

        // Auto-link to CRM opportunity.
        // Search by quoteID first (direct link), then fall back to estimateID match.
        // BUG FIX: go through upsertCRMOpportunity() so the change is marked .pending
        // and gets pushed to Supabase — previously used direct array mutation which
        // left syncStatus = .synced and the quoteID link was lost on next pull.
        let oppIdx = crmOpportunities.firstIndex(where: { $0.quoteID == quote.id })
                  ?? crmOpportunities.firstIndex(where: { $0.estimateID == quote.estimateID })
        if let oppIdx {
            var updatedOpp = crmOpportunities[oppIdx]
            var changed = false
            if updatedOpp.quoteID == nil {
                updatedOpp.quoteID = quote.id
                updatedOpp.updatedAt = Date()
                changed = true
            }
            if quote.status == .sent,
               updatedOpp.stage != .quoteSent, updatedOpp.stage != .followUp,
               updatedOpp.stage != .won, updatedOpp.stage != .lost {
                updatedOpp.stage = .quoteSent
                updatedOpp.probability = OpportunityStage.quoteSent.defaultProbability
                updatedOpp.updatedAt = Date()
                changed = true
                logCRMActivity(
                    type: .quoteSent,
                    title: "Quote sent: \(quote.jobNumber)",
                    notes: quote.scopeSummary,
                    clientID: updatedOpp.clientID,
                    contactID: updatedOpp.contactID,
                    opportunityID: updatedOpp.id,
                    quoteID: quote.id,
                    projectID: nil
                )
            }
            if changed {
                // Mark pending so pushPendingCRMOpportunities() will persist the quoteID link
                updatedOpp.syncStatus = .pending
                upsertCRMOpportunity(updatedOpp)
                Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
            }
        }

        // CRM bridge: accepted quote → mark linked opportunity Won.
        if quote.status == .accepted {
            handleQuoteAccepted(quote)
        }
        // CRM bridge: declined quote → mark linked opportunity Lost.
        if quote.status == .declined {
            handleQuoteDeclined(quote)
        }

        // 2026-04 audit fix (Phase 9): write an audit row on every
        // material status transition. Pre-fix only revisions captured
        // these — but revisions are JSON dumps, not classified events.
        // The audit trail lets compliance answer "who marked this
        // accepted on what device on what date" without parsing JSON.
        if let p = prior, p.status != quote.status {
            createAuditSnapshot(
                for:       quote,
                eventType: "status_changed_\(p.status.rawValue)_to_\(quote.status.rawValue)",
                by:        currentUser?.fullName ?? "system"
            )
        } else if prior == nil {
            createAuditSnapshot(
                for:       quote,
                eventType: "created",
                by:        currentUser?.fullName ?? "system"
            )
        }

        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuotes() }
        // Week 4 audit closeout: keep iOS Spotlight in sync. Voided/
        // declined quotes are de-indexed inside upsert(quote:).
        SpotlightService.shared.upsert(quote: updated)
    }

    func deleteQuote(_ quote: Quote) {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager, .estimator],
                          action: "delete_quote") else { return }
        guard let idx = quotes.firstIndex(where: { $0.id == quote.id }) else { return }
        var deleted = quotes[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        quotes[idx] = deleted
        // 2026-04 audit fix (Phase 9): record the deletion in the
        // audit trail BEFORE re-saving so we capture the row's last-
        // known state. Soft-delete only — the row is still in the
        // table, but `isDeleted = true` and the snapshot freezes
        // what the operator saw at delete time.
        createAuditSnapshot(
            for:       deleted,
            eventType: "deleted",
            by:        currentUser?.fullName ?? "system"
        )
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuotes() }
    }

    func markQuoteSynced(id: UUID, status: SyncStatus) {
        guard let idx = quotes.firstIndex(where: { $0.id == id }) else { return }
        quotes[idx].syncStatus = status
        objectWillChange.send()
    }

    /// Generate the next quote number. Phase 3 hardening: matches the
    /// procurement / invoice pattern. Three guards on top of the
    /// pre-existing parsed-max+1 logic:
    ///   1. Soft-delete exclusion — soft-deleted quotes shouldn't burn
    ///      their number; the partial unique index on the DB side
    ///      (Phase 3 migration QUO1) only enforces uniqueness on live
    ///      rows, so the local helper has to match.
    ///   2. Company scope — multi-tenant local store can otherwise
    ///      include other companies' quotes in the max calculation.
    ///   3. Year filter via jobNumber prefix instead of createdAt —
    ///      a quote drafted in late December and saved in early January
    ///      has createdAt in year N but jobNumber for year N (since the
    ///      prefix is set at draft time). Filtering by jobNumber prefix
    ///      keeps the bookkeeping consistent with the issued number.
    func nextQuoteNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let yearPrefix = "Q-\(year)-"
        // FIX: monotonic numbering across deletes — see
        // AppStore.nextMaterialRequestNumber for the full rationale.
        let existingNumbers = quotes
            .filter { $0.companyID == currentCompanyID }
            .compactMap { q -> Int? in
                guard q.jobNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(q.jobNumber.dropFirst(yearPrefix.count))
            }
        let next = (existingNumbers.max() ?? 0) + 1
        return String(format: "Q-%d-%04d", year, next)
    }

    // MARK: - Quote to Project Conversion
    // Called when a quote is accepted and PM is assigned.
    // Creates a fully populated Project from the quote and estimate data.

    func convertQuoteToProject(_ quote: Quote, pmID: UUID?, pmName: String?) {
        // Idempotency guard — if the quote already has a project linked,
        // return without creating a duplicate. Covers double-tap, retry,
        // and the case where a magic-link acceptance already auto-created
        // a project via resolveOpportunityOutcome before the user opened
        // the manual conversion sheet.
        if let existingProjectID = quote.projectID,
           projects.contains(where: { $0.id == existingProjectID && !$0.isDeleted }) {
            print("ℹ️ convertQuoteToProject skipped — quote \(quote.id) already linked to project \(existingProjectID)")
            return
        }

        let estimate = estimates.first { $0.id == quote.estimateID }

        // Build project from quote
        var project = Project(
            name:       quote.jobNumber + " — " + (estimate?.name ?? quote.clientName),
            clientName: quote.clientName
        )

        project.jobNumber      = quote.jobNumber
        project.status         = .awarded
        project.siteAddress    = quote.siteAddress
        project.contractValue  = quote.totalBeforeTax
        project.estimatedBudget = estimate?.totalEstimated
        project.startDate      = Date()
        project.notes          = [
            quote.scopeSummary.isEmpty ? nil : "Scope: \(quote.scopeSummary)",
            quote.exclusions.isEmpty ? nil : "Exclusions: \(quote.exclusions)",
            quote.assumptions.isEmpty ? nil : "Assumptions: \(quote.assumptions)"
        ].compactMap { $0 }.joined(separator: "\n\n")
        // Slice 2 Entity-First: inherit the quote's opportunity so the
        // new project rolls up to the same CRM container. Required for
        // the upcoming projects.opportunity_id NOT NULL constraint.
        project.opportunityID  = quote.opportunityID
        // SR-1.3 (legacy): single-crew preference.
        project.preferredCrewID = quote.preferredCrewID
        // SR-1.4: full labor requirements payload — engine reads this
        // to assemble crews / custom crews / individual workers.
        project.laborPlan = quote.laborPlan
        project.syncStatus     = .pending
        project.lastModifiedBy = currentUser?.fullName ?? ""
        project.lastModifiedAt = Date()

        // Assign PM
        if let pmID = pmID {
            project.assignedPMID   = pmID
            project.assignedPMName = pmName
        }

        // Save project
        upsertProject(project)

        // Auto-copy signed PDF (if any) from the quote onto the new
        // project so the project's documents grid inherits the proof
        // of acceptance. No-ops silently for quotes that pre-date the
        // magic-link feature or were marked accepted in-app without
        // a signature.
        SignedQuotePDFGenerator.shared.copyExistingSignedPDF(
            fromQuoteID: quote.id,
            to:          .project(project.id),
            store:       self
        )

        // Auto-create project budget from estimate line items.
        // budgetFromEstimate splits labour / material / other by cost code category.
        // Falls back to a blank budget with contract value if no estimate is linked.
        var initialBudget = budgetFromEstimate(for: project)
        initialBudget.originalContractValue = quote.totalBeforeTax
        initialBudget.contingencyAmount     = quote.contingencyAmount
        upsertBudget(initialBudget)
        logCRMActivity(
            type:          .projectCreated,
            title:         "Budget created for \(project.jobNumber ?? quote.jobNumber)",
            notes:         "Contract value: \(quote.totalBeforeTax.currencyString). Contingency: \(quote.contingencyAmount.currencyString).",
            clientID:      quote.clientID,
            contactID:     nil,
            opportunityID: nil,
            quoteID:       quote.id,
            projectID:     project.id
        )

        // Link quote → project
        var updatedQuote = quote
        updatedQuote.projectID      = project.id
        updatedQuote.status         = .accepted
        updatedQuote.acceptedAt     = Date()
        updatedQuote.assignedPMID   = pmID
        updatedQuote.assignedPMName = pmName
        upsertQuote(updatedQuote)

        // Update estimate status
        if var estimate = estimate {
            estimate.projectID  = project.id
            estimate.status     = .awarded
            estimate.syncStatus = .pending
            upsertEstimate(estimate)
        }

        // ── CRM: mark opportunity Won via central handler ─────────────────────
        // PHASE-1 VERIFIED (Step 4): estimate→project conversion routes
        // through the same resolveOpportunityOutcome funnel as
        // CommercialWorkflowService.acceptQuote. No duplicate logic;
        // identical CRM/project/handoff side-effects.
        // resolveOpportunityOutcome() handles stage, wonAt, handoff checklist,
        // bidirectional quote/estimate sync, and all activity logging in one place.
        if let opp = crmOpportunities.first(where: {
            !$0.isDeleted && ($0.quoteID == quote.id || $0.estimateID == quote.estimateID)
        }) {
            resolveOpportunityOutcome(
                opportunityID: opp.id,
                outcome:       .won,
                source:        .projectConversion,
                quoteID:       quote.id,
                estimateID:    quote.estimateID,
                projectID:     project.id
            )
            logCRMActivity(
                type:          .projectCreated,
                title:         "Project created: \(project.jobNumber ?? quote.jobNumber)",
                notes:         "Assigned PM: \(pmName ?? "TBD"). Scope from \(quote.jobNumber).",
                clientID:      opp.clientID,
                contactID:     opp.contactID,
                opportunityID: opp.id,
                quoteID:       quote.id,
                projectID:     project.id
            )
        }
    }
}

// MARK: - Quote List View

private enum QuoteCreateFlow: Identifiable {
    case pickEstimate
    case create(Estimate)
    var id: String {
        switch self {
        case .pickEstimate:     return "pickEstimate"
        case .create(let est):  return "create-\(est.id.uuidString)"
        }
    }
}

struct QuoteListView: View {
    @EnvironmentObject var store: AppStore
    @State private var flow: QuoteCreateFlow? = nil
    @State private var searchText = ""

    /// Slice 6 stabilization (Bug C): reverted the "smart router" that
    /// bounced reps back to the intake when no quote-eligible estimates
    /// existed. That created an infinite loop — fresh estimates from
    /// the intake default to `.estimating` status which isn't
    /// `isQuoteEligible`, so reps got sent BACK to the intake every
    /// time. The fix is to always open QuoteCreateView; its existing
    /// "No estimates ready for a quote..." message and Estimate picker
    /// guide the user from there.
    private var hasQuoteableEstimates: Bool {
        store.estimates.contains { $0.status.isQuoteEligible && !$0.isDeleted }
    }

    private var filtered: [Quote] {
        store.quotes
            .filter {
                searchText.isEmpty ||
                $0.jobNumber.localizedCaseInsensitiveContains(searchText) ||
                $0.clientName.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Phase 2 first-launch sync gate (extended in Phase 7).
                // A fresh-install user creating a quote before clients /
                // estimates / opportunities pull would emit a record
                // referencing nonexistent IDs, causing FK or RLS failures
                // on push. Banner + disabled-create button reduces the
                // class of "I created it but it won't sync" reports.
                if !store.hasCompletedFirstSync {
                    FirstLaunchSyncGateBanner()
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                Group {
                    if filtered.isEmpty {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 52))
                                .foregroundColor(.secondary)
                            Text("No quotes yet.")
                                .font(.headline)
                            Text("Create a quote from an existing estimate.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("New Quote") { flow = .pickEstimate }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.hasCompletedFirstSync)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(filtered) { quote in
                                NavigationLink {
                                    QuoteDetailView(quote: quote)
                                } label: {
                                    QuoteListRow(quote: quote)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search quotes or clients")
            .refreshable { await store.refreshAll() }
            .navigationTitle("Quotes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { flow = .pickEstimate } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!store.hasCompletedFirstSync)
                }
            }
            // Phase 7 / Decision 1: route Quote create through an
            // Estimate picker. `Quote.estimateID` is a NOT NULL FK, so
            // creating a quote without first picking an estimate would
            // always fail on push. Pre-fix the user could open
            // QuoteCreateView() with no estimate selected, fill out
            // line items, then hit an unfixable "no estimate selected"
            // validation error at save.
            .sheet(item: $flow) { state in
                switch state {
                case .pickEstimate:
                    RequiredEstimatePickerSheet { picked in
                        flow = .create(picked)
                    }
                    .environmentObject(store)
                case .create(let est):
                    QuoteCreateView(fromEstimate: est)
                        .environmentObject(store)
                }
            }
        }
    }
}

// MARK: - Quote List Row

struct QuoteListRow: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(quote.jobNumber)
                    .font(.caption).bold()
                    .foregroundColor(.purple)
                    .fontDesign(.monospaced)
                Text("Rev \(quote.revision)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                QuoteStatusBadge(status: quote.status)
            }
            Text(quote.clientName).font(.headline)
            HStack(spacing: 16) {
                Label(quote.totalBeforeTax.currencyString, systemImage: "dollarsign.circle")
                    .font(.caption).foregroundColor(.secondary)
                Label(quote.quoteDate.shortDate, systemImage: "calendar")
                    .font(.caption).foregroundColor(.secondary)
                Label("Exp \(quote.expiryDate.shortDate)", systemImage: "clock")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quote Status Badge

struct QuoteStatusBadge: View {
    let status: QuoteStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.color.opacity(0.15))
            .foregroundColor(status.color)
            .cornerRadius(6)
    }
}

// MARK: - Quote Detail View

struct QuoteDetailView: View {
    let quote: Quote
    @EnvironmentObject var store: AppStore
    @State private var localQuote: Quote
    @State private var showEdit = false
    @State private var showConvertToProject = false
    /// Phase 4 audit fix: presents a sheet capturing reason +
    /// competitor + notes when an admin marks a quote Declined,
    /// so the loss data flows into both the Quote AND the linked
    /// CRM opportunity.
    @State private var showDeclineSheet = false
    /// Phase 8 audit fix: revision history browser. RevisionService
    /// already snapshots on every material change; this surface
    /// gives users a way to actually look at the history.
    @State private var showRevisionHistory = false

    /// Week 4 audit closeout: Quote → MaterialSale creation prompt
    /// when an accepted quote has no associated material sale.
    @State private var showCreateMaterialSale = false
    @State private var showShareSheet   = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF  = false
    @State private var showAddLineItem  = false

    // Email composer state
    @State private var showEmailSheet:  Bool = false
    @State private var pendingPDFData:  Data? = nil
    @State private var pendingFilename: String = ""

    // (showRevisionHistory was duplicated here pre-2026-04 audit;
    // the canonical declaration now lives at the top of this struct
    // with a Phase 8 audit comment. Removed to clear "Invalid
    // redeclaration" build error.)

    // MARK: - Magic-link acceptance state
    /// Cached status for the pill at the top of the screen ("Awaiting
    /// acceptance · expires…", "Accepted by Jane Doe…", etc.).
    @State private var acceptanceStatus: QuoteAcceptanceService.AcceptanceStatus? = nil
    /// Token + URL freshly minted, ready to be inserted into the email
    /// body before the EmailComposeSheet opens.
    @State private var pendingAcceptanceURL: URL? = nil
    @State private var isMintingAcceptance: Bool = false
    @State private var showRevokeConfirm: Bool = false
    @State private var acceptanceError: String? = nil

    // Slice C: send-time soft warnings for both the standard "Send
    // Quote to Client" path and the magic-link acceptance variant.
    // computeSendWarnings() runs before either flow fires; if non-empty
    // a confirmation dialog appears with "Send anyway" / "Cancel".
    @State private var pendingSendWarnings: [QuoteSendWarning] = []
    @State private var showSendWarningDialog: Bool = false
    /// Which send branch is queued behind the warning dialog. Cleared
    /// after the dialog dismisses so a Cancel doesn't leave stale state.
    private enum PendingSendKind { case sendToClient, emailWithAcceptance }
    @State private var pendingSendKind: PendingSendKind? = nil

    init(quote: Quote) {
        self.quote = quote
        self._localQuote = State(initialValue: quote)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(localQuote.jobNumber)
                            .font(.subheadline).bold()
                            .foregroundColor(.purple)
                            .fontDesign(.monospaced)
                        Spacer()
                        QuoteStatusBadge(status: localQuote.status)
                    }
                    Text(localQuote.clientName)
                        .font(.subheadline).foregroundColor(.secondary)
                    if let address = localQuote.siteAddress {
                        Label(address, systemImage: "mappin.circle")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quote Date").font(.caption).foregroundColor(.secondary)
                            Text(localQuote.quoteDate.shortDate).font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Expires").font(.caption).foregroundColor(.secondary)
                            Text(localQuote.expiryDate.shortDate).font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prepared by").font(.caption).foregroundColor(.secondary)
                            Text(localQuote.preparedBy).font(.subheadline)
                        }
                    }
                    if let pm = localQuote.assignedPMName {
                        Label("PM: \(pm)", systemImage: "person.badge.shield.checkmark")
                            .font(.caption).foregroundColor(.blue)
                    }
                    // Magic-link acceptance status pill — surfaces the
                    // outcome of any pending / accepted / revoked link
                    // so the rep doesn't have to chase the customer.
                    if let status = acceptanceStatus, status.hasToken {
                        Label(status.displaySummary,
                              systemImage: status.acceptedAt != nil
                                ? "checkmark.seal.fill"
                                : (status.revokedAt != nil ? "xmark.circle.fill" : "envelope.badge.fill"))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(
                                status.acceptedAt != nil ? .green :
                                (status.revokedAt != nil ? .secondary : .blue)
                            )
                            .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // Line Items
                HStack {
                    SectionHeader(title: "Line Items")
                    Spacer()
                    if localQuote.status == .draft || localQuote.status == .approved {
                        Button {
                            showAddLineItem = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                        }
                        .padding(.trailing)
                    }
                }

                if localQuote.lineItems.isEmpty {
                    Text("No line items — pricing uses the manual subtotal.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                } else {
                    let canEdit = localQuote.status == .draft || localQuote.status == .approved
                    VStack(spacing: 0) {
                        ForEach(Array(localQuote.lineItems.enumerated()), id: \.element.id) { idx, item in
                            HStack(alignment: .top, spacing: 0) {
                                LineItemRow(item: item)
                                if canEdit {
                                    Button {
                                        localQuote.lineItems.remove(at: idx)
                                        store.upsertQuote(localQuote)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundColor(.red.opacity(0.7))
                                            .padding(.top, 14)
                                            .padding(.trailing, 14)
                                    }
                                }
                            }
                            if idx < localQuote.lineItems.count - 1 {
                                Divider().padding(.leading)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Pricing
                SectionHeader(title: "Pricing")
                VStack(spacing: 0) {
                    PricingRow(
                        label: localQuote.lineItems.isEmpty ? "Subtotal" : "Line Items Total",
                        value: localQuote.lineItemsSubtotal
                    )
                    if localQuote.discountPercent > 0 {
                        Divider().padding(.leading)
                        PricingRow(
                            label: "Discount (\(pctStr(localQuote.discountPercent))%)",
                            value: -localQuote.discountAmount
                        )
                        Divider().padding(.leading)
                        PricingRow(label: "After Discount", value: localQuote.subtotalAfterDiscount)
                    }
                    if localQuote.contingencyPercent > 0 {
                        Divider().padding(.leading)
                        PricingRow(
                            label: "Contingency (\(pctStr(localQuote.contingencyPercent))%)",
                            value: localQuote.contingencyAmount
                        )
                    }
                    Divider()
                    HStack {
                        Text("Total (excl. tax)").font(.headline)
                        Spacer()
                        Text(localQuote.totalBeforeTax.currencyString)
                            .font(.headline).bold()
                    }
                    .padding()
                    if localQuote.taxRate > 0 {
                        Divider().padding(.leading)
                        PricingRow(
                            label: "\(AppSettings.shared.taxLabel) (\(pctStr(localQuote.taxRate))%)",
                            value: localQuote.taxAmount
                        )
                        Divider()
                        HStack {
                            Text("Grand Total").font(.headline).bold()
                            Spacer()
                            Text(localQuote.grandTotal.currencyString)
                                .font(.title3).bold().foregroundColor(.green)
                        }
                        .padding()
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Scope sections
                if !localQuote.scopeSummary.isEmpty {
                    SectionHeader(title: "Scope")
                    QuoteTextBlock(text: localQuote.scopeSummary)
                }
                if !localQuote.inclusions.isEmpty {
                    SectionHeader(title: "Inclusions")
                    QuoteTextBlock(text: localQuote.inclusions)
                }
                if !localQuote.exclusions.isEmpty {
                    SectionHeader(title: "Exclusions")
                    QuoteTextBlock(text: localQuote.exclusions)
                }
                if !localQuote.assumptions.isEmpty {
                    SectionHeader(title: "Assumptions")
                    QuoteTextBlock(text: localQuote.assumptions)
                }

                SectionHeader(title: "Payment Terms")
                QuoteTextBlock(text: localQuote.paymentTerms)

                // Slice 5: approval threshold indicator. Renders nothing
                // for sub-threshold quotes; surfaces "Request Approval"
                // / "Pending" / "Approved" / "Rejected" with re-submit
                // option above the action buttons.
                QuoteApprovalPill(quote: localQuote)
                    .environmentObject(store)
                    .padding(.horizontal)

                // Action Buttons
                VStack(spacing: 10) {

                    if localQuote.status == .draft {
                        Button { updateStatus(.approved) } label: {
                            Label("Approve Quote", systemImage: "checkmark.seal.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }

                    if localQuote.status == .approved {
                        // Primary CTA — emails the client with PDF + magic
                        // acceptance link, then opens the existing
                        // EmailComposeSheet for review/edit before send.
                        // The composer marks status = .sent on successful
                        // send. Falls back to "Mark as Sent" below for
                        // out-of-band channels (already emailed manually,
                        // sent via courier, etc.) so the user can still
                        // record the state without re-emailing.
                        Button {
                            triggerSendWithWarnings(kind: .emailWithAcceptance)
                        } label: {
                            Label("Send Quote to Client",
                                  systemImage: "paperplane.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        .disabled(isMintingAcceptance || isGeneratingPDF)

                        Button { updateStatus(.sent) } label: {
                            Label("Mark as Sent (already sent elsewhere)",
                                  systemImage: "checkmark.circle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.gray.opacity(0.12))
                                .foregroundColor(.secondary)
                                .cornerRadius(12)
                        }
                    }

                    if localQuote.status == .sent {
                        Button { showConvertToProject = true } label: {
                            Label("Quote Accepted — Create Project", systemImage: "folder.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        Button { showDeclineSheet = true } label: {
                            Label("Quote Declined", systemImage: "xmark.circle")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.red.opacity(0.12))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }
                    }

                    // If accepted and project exists
                    if localQuote.status == .accepted, let projectID = localQuote.projectID,
                       let project = store.project(id: projectID) {
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            Label("View Project — \(project.name)", systemImage: "folder.fill")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(12)
                        }
                    }

                    // Week 4 audit closeout: Quote → Material Sale
                    // creation prompt. Only shown when accepted, has
                    // no existing sale linked back, and current user
                    // can create sales (estimating-admin or higher).
                    // The bridge auto-creates an opportunity; we just
                    // pre-fill clientID and seed quoteID so the back-
                    // link is preserved per Phase 6's audit fix.
                    if localQuote.status == .accepted,
                       !store.materialSales.contains(where: { $0.quoteID == localQuote.id && !$0.isDeleted }),
                       store.currentUserRole.canEditCRM || store.currentUserRole.isAdmin {
                        Button {
                            showCreateMaterialSale = true
                        } label: {
                            Label("Track materials as a Sale (optional)",
                                  systemImage: "shippingbox.fill")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .cornerRadius(12)
                        }
                    }

                    // Inverse case: a Material Sale already exists →
                    // show a navigation link instead of the prompt
                    // so users don't accidentally double-track the
                    // same materials.
                    if localQuote.status == .accepted,
                       let sale = store.materialSales.first(where: { $0.quoteID == localQuote.id && !$0.isDeleted }) {
                        NavigationLink {
                            MaterialSaleDetailView(sale: sale)
                        } label: {
                            Label("View Material Sale — \(sale.saleNumber)",
                                  systemImage: "shippingbox.fill")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)

                // ── Documents ─────────────────────────────────────────────────
                QuoteDocumentsSection(quoteID: localQuote.id, jobNumber: localQuote.jobNumber)

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(localQuote.jobNumber)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isGeneratingPDF {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            exportPDF()
                        } label: {
                            Label("Share PDF…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            triggerSendWithWarnings(kind: .sendToClient)
                        } label: {
                            Label("Email PDF to client…", systemImage: "envelope.fill")
                        }
                        // Phase 8 audit fix: revision history viewer.
                        // Available to anyone who can see the quote —
                        // server-side RLS already gates the underlying
                        // table by tenant.
                        Button {
                            showRevisionHistory = true
                        } label: {
                            Label("Version History", systemImage: "clock.arrow.circlepath")
                        }
                        // Magic-link acceptance: mints a one-time URL,
                        // prepends it into the email body, then opens the
                        // existing EmailComposeSheet so the rep can review
                        // and send. Only available to admins (server
                        // enforces the same).
                        if store.currentUserRole.isAdmin {
                            Button {
                                triggerSendWithWarnings(kind: .emailWithAcceptance)
                            } label: {
                                Label("Email PDF + acceptance link…",
                                      systemImage: "checkmark.seal.fill")
                            }
                            if acceptanceStatus?.acceptedAt == nil,
                               acceptanceStatus?.hasToken == true,
                               acceptanceStatus?.revokedAt == nil {
                                Button(role: .destructive) {
                                    showRevokeConfirm = true
                                } label: {
                                    Label("Revoke acceptance link",
                                          systemImage: "xmark.circle.fill")
                                }
                            }
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
                    .accessibilityLabel("Share or email this quote")
                }
                Button("Edit") { showEdit = true }
                    .disabled(localQuote.status == .accepted)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        // (Revision-history sheet binding moved farther down to use
        // the Week 2 diff-aware QuoteRevisionHistoryView — the older
        // JSON-only QuoteRevisionHistorySheet binding lived here and
        // collided with the newer one. Removed to fix duplicate-
        // sheet-binding build error.)
        .sheet(isPresented: $showEmailSheet) {
            if let pdf = pendingPDFData {
                EmailComposeSheet(
                    recipientSuggestions: clientContactEmails,
                    defaultSubject: "Quote \(localQuote.jobNumber)",
                    defaultBody: emailDefaultBody,
                    pdfData: pdf,
                    pdfFilename: pendingFilename,
                    entityType: "quote",
                    entityID: localQuote.id,
                    clientID: localQuote.clientID,
                    contactID: nil,
                    opportunityID: store.crmOpportunities.first(where: { $0.quoteID == localQuote.id })?.id,
                    quoteID: localQuote.id,
                    projectID: nil
                )
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showEdit) {
            QuoteCreateView(existing: localQuote)
        }
        .sheet(isPresented: $showConvertToProject) {
            ConvertToProjectSheet(quote: localQuote) { updatedQuote in
                localQuote = updatedQuote
            }
        }
        .sheet(isPresented: $showDeclineSheet) {
            QuoteDeclineSheet(quote: localQuote) { reason, competitor, notes in
                applyDecline(reason: reason, competitor: competitor, notes: notes)
            }
        }
        .sheet(isPresented: $showRevisionHistory) {
            QuoteRevisionHistoryView(quote: localQuote)
                .environmentObject(store)
        }
        .sheet(isPresented: $showCreateMaterialSale) {
            // Pre-stamp a CommercialContext so the create sheet
            // inherits clientID, projectID (if set), and quoteID —
            // the Phase 6 audit fix made the sheet thread these
            // back onto the new MaterialSale automatically. Use
            // named params in struct declaration order; defaults
            // cover the fields we don't set.
            MaterialSaleCreateEditView(
                preselectedSaleType: .materialSale,
                context: CommercialContext(
                    workType:       .materialSale,
                    clientID:       localQuote.clientID,
                    clientName:     localQuote.clientName,
                    opportunityID:  localQuote.opportunityID,
                    projectID:      localQuote.projectID,
                    estimateID:     localQuote.estimateID,
                    quoteID:        localQuote.id,
                    source:         .fromQuote
                )
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showAddLineItem) {
            ProductServicePickerSheet(clientID: localQuote.clientID) { newItem in
                localQuote.lineItems.append(newItem)
                store.upsertQuote(localQuote)
            }
        }
        // Load acceptance status on first appearance and whenever the
        // quote ID changes (e.g. duplicating into a new revision).
        .task(id: localQuote.id) {
            await reloadAcceptanceStatus()
        }
        // Pulled out from the menu so the alert renders above the modal
        // sheet rather than inline.
        .alert("Revoke acceptance link?", isPresented: $showRevokeConfirm) {
            Button("Revoke", role: .destructive) {
                Task { await revokeAcceptanceLink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The customer's link will stop working immediately. Mint a new link by sending the quote again.")
        }
        // Slice C: send-time soft warning. Both Send Quote / Email PDF
        // / Email PDF + acceptance buttons funnel through this dialog
        // when the quote has no T&C attached or has a service-type gap.
        .confirmationDialog(
            "Send this quote?",
            isPresented: $showSendWarningDialog,
            titleVisibility: .visible
        ) {
            Button("Send anyway", role: .destructive) {
                if let kind = pendingSendKind { executeSend(kind: kind) }
                pendingSendKind = nil
            }
            Button("Review T&C first", role: .cancel) {
                pendingSendKind = nil
            }
        } message: {
            Text(pendingSendWarnings.map { $0.message }.joined(separator: "\n\n"))
        }
    }

    // Formats a Decimal percentage without trailing zeros (e.g. 5.0 → "5", 7.5 → "7.5")
    private func pctStr(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? n.stringValue
    }

    /// Pulls a deduped, prioritised list of email addresses for the linked
    /// client — primary contact first, then any other CRM contacts on the
    /// same client. Used to suggest recipients in the email composer.
    private var clientContactEmails: [String] {
        var seen = Set<String>()
        var out: [String] = []
        // Primary contact email from the Client record (if present).
        if let client = store.client(id: localQuote.clientID),
           let email  = client.contactEmail,
           !email.isEmpty,
           seen.insert(email.lowercased()).inserted {
            out.append(email)
        }
        // CRM contacts on this client.
        for c in store.crmContacts where c.clientID == localQuote.clientID && !c.isDeleted {
            if !c.email.isEmpty, seen.insert(c.email.lowercased()).inserted {
                out.append(c.email)
            }
        }
        return out
    }

    private var emailDefaultBody: String {
        let greeting: String
        if let client = store.client(id: localQuote.clientID), !client.name.isEmpty {
            greeting = "Hi \(client.name) team,"
        } else {
            greeting = "Hello,"
        }
        let user = store.currentUser?.fullName ?? AppSettings.shared.companyName
        let signature = user.isEmpty ? AppSettings.shared.companyName : user
        // When a magic-link acceptance URL has been minted right before
        // this email is composed, prepend a clear call-to-action above
        // the standard sign-off so the customer can accept in one click.
        let acceptanceBlock: String
        if let url = pendingAcceptanceURL {
            acceptanceBlock = """


            ✅ Approve digitally:
            \(url.absoluteString)

            (One-click acceptance with a built-in signature pad. The link expires in 30 days.)
            """
        } else {
            acceptanceBlock = ""
        }
        return """
        \(greeting)

        Please find quote \(localQuote.jobNumber) attached. Let me know if you'd like to discuss any of the line items or scope.\(acceptanceBlock)

        Thanks,
        \(signature)
        """
    }

    // MARK: - Slice C: Send-time warning gate

    /// Single entry point for both send branches. Computes the soft
    /// warnings (no T&C attached / unmatched service types). When any
    /// apply, queues the requested action behind the confirmation
    /// dialog; otherwise fires the action directly.
    private func triggerSendWithWarnings(kind: PendingSendKind) {
        let warnings = store.sendTimeWarnings(
            forLineItems: localQuote.lineItems,
            quoteID:      localQuote.id
        )
        if warnings.isEmpty {
            executeSend(kind: kind)
        } else {
            pendingSendWarnings  = warnings
            pendingSendKind      = kind
            showSendWarningDialog = true
        }
    }

    /// Runs the actual send branch the user requested. Called either
    /// directly (no warnings) or from the confirmation dialog's
    /// "Send anyway" action.
    private func executeSend(kind: PendingSendKind) {
        switch kind {
        case .sendToClient:
            emailPDF()
        case .emailWithAcceptance:
            Task { await emailPDFWithAcceptance() }
        }
    }

    /// Mints an acceptance token, prepares the PDF, and opens the email
    /// composer with the magic-link URL prepended into the body. Same
    /// renderer as `emailPDF()` — only the body changes.
    @MainActor
    private func emailPDFWithAcceptance() async {
        guard !isMintingAcceptance else { return }
        isMintingAcceptance = true
        defer { isMintingAcceptance = false }
        do {
            let mint = try await QuoteAcceptanceService.shared.mintToken(quoteID: localQuote.id)
            pendingAcceptanceURL = mint.url
            await reloadAcceptanceStatus()
            ToastService.shared.success("Acceptance link minted — review the email and send.")
            // Reuse the existing PDF + email composer flow.
            emailPDF()
        } catch let err as QuoteAcceptanceService.AcceptanceError {
            ToastService.shared.error(err.errorDescription ?? "Couldn't mint link")
        } catch {
            ToastService.shared.error(error.localizedDescription)
        }
    }

    /// Pulls the most-recent acceptance-status row for this quote so the
    /// header pill reflects pending / accepted / revoked. Idempotent;
    /// safe to call repeatedly.
    private func reloadAcceptanceStatus() async {
        do {
            acceptanceStatus = try await QuoteAcceptanceService.shared.fetchStatus(
                quoteID: localQuote.id
            )
        } catch {
            // Silent failure — pill simply won't render. The status RPC
            // returning an error usually means "no token row yet", which
            // is the common case for new quotes.
            acceptanceStatus = nil
        }
    }

    private func revokeAcceptanceLink() async {
        do {
            try await QuoteAcceptanceService.shared.revoke(quoteID: localQuote.id)
            await reloadAcceptanceStatus()
            ToastService.shared.warning("Acceptance link revoked.")
        } catch {
            ToastService.shared.error("Couldn't revoke: \(error.localizedDescription)")
        }
    }

    /// Render the PDF (same renderer as Share PDF) then open the email composer.
    private func emailPDF() {
        isGeneratingPDF = true
        let quoteCopy = localQuote
        let lineItems = localQuote.lineItems.isEmpty
            ? (store.estimates.first { $0.id == localQuote.estimateID }?.lineItems ?? [])
            : localQuote.lineItems
        let taxRate  = localQuote.taxRate > 0 ? localQuote.taxRate : Decimal(AppSettings.shared.taxRate)
        let taxLabel = AppSettings.shared.taxLabel
        let attachedTerms = store.quoteTerms(for: localQuote.id)
        Task.detached(priority: .userInitiated) {
            let pdf = QuotePDFRenderer(
                quote:      quoteCopy,
                lineItems:  lineItems,
                taxRate:    taxRate,
                taxLabel:   taxLabel,
                quoteTerms: attachedTerms
            ).render()
            let safe = quoteCopy.jobNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let filename = "Quote_\(safe).pdf"
            await MainActor.run {
                pendingPDFData  = pdf
                pendingFilename = filename
                isGeneratingPDF = false
                showEmailSheet  = true
            }
        }
    }

    private func exportPDF() {
        isGeneratingPDF = true
        let quoteCopy   = localQuote
        let storeCopy   = store
        // Use the quote's own line items; fall back to the linked estimate's items for
        // legacy quotes that were created before line items were stored on the quote.
        let lineItems   = localQuote.lineItems.isEmpty
            ? (store.estimates.first { $0.id == localQuote.estimateID }?.lineItems ?? [])
            : localQuote.lineItems
        let taxRate     = localQuote.taxRate > 0 ? localQuote.taxRate : Decimal(AppSettings.shared.taxRate)
        let taxLabel    = AppSettings.shared.taxLabel
        let attachedTerms = store.quoteTerms(for: localQuote.id)
        Task.detached(priority: .userInitiated) {
            let pdfData = QuotePDFRenderer(
                quote:      quoteCopy,
                lineItems:  lineItems,
                taxRate:    taxRate,
                taxLabel:   taxLabel,
                quoteTerms: attachedTerms
            ).render()
            let safe = quoteCopy.jobNumber
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let clientSafe = quoteCopy.clientName
                .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
            let fileName = "Quote_\(safe)_\(clientSafe).pdf"

            // ── Persist in Documents directory (permanent) ────────────────────
            let docDir   = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let permURL  = docDir.appendingPathComponent(fileName)
            try? pdfData.write(to: permURL)

            // Register as a quote document (idempotent — skip if name already saved)
            await MainActor.run {
                let existing = storeCopy.quoteDocs(for: quoteCopy.id)
                    .contains { $0.originalFileName == fileName }
                if !existing {
                    let doc = ProjectDocument(
                        projectID:        quoteCopy.id,
                        name:             "Quote \(quoteCopy.jobNumber)",
                        originalFileName: fileName,
                        fileExtension:    "pdf",
                        fileSize:         pdfData.count,
                        storedFileName:   fileName,
                        category:         .quote,
                        uploadedBy:       storeCopy.currentUser?.fullName ?? "System"
                    )
                    storeCopy.addQuoteDoc(doc)
                }
            }

            // ── Share sheet (temp copy for AirDrop / email) ───────────────────
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try? pdfData.write(to: tempURL)

            await MainActor.run {
                shareItems      = [tempURL]
                isGeneratingPDF = false
                showShareSheet  = true
            }
        }
    }

    private func updateStatus(_ status: QuoteStatus) {
        localQuote.status = status
        if status == .approved {
            localQuote.approvedBy = store.currentUser?.fullName
            localQuote.approvedAt = Date()
        }
        if status == .sent {
            localQuote.sentAt = Date()
        }
        // Won/Lost CRM sync is handled by handleQuoteAccepted/handleQuoteDeclined
        // hooks inside upsertQuote() — no inline opp mutation needed here.
        store.upsertQuote(localQuote)
    }

    /// Phase 4 audit fix: dedicated decline path that captures the
    /// reason / competitor / notes triple and threads them through
    /// `handleQuoteDeclined` so the linked CRM opportunity gets
    /// stamped with the same data. Pre-fix the decline flow lost
    /// every piece of loss context — only the status flipped.
    private func applyDecline(reason: LossReason, competitor: String, notes: String) {
        // Slice 3: route through CommercialWorkflowService so the
        // decline path goes through the same audit + (future) state-
        // machine logic as accept. The service handles:
        //   - upsertQuote with declined status + loss-reason capture
        //   - handleQuoteDeclined → resolveOpportunityOutcome(.lost)
        //     with the full reason/competitor/notes triple
        //   - opp/estimate sync-back
        let result = CommercialWorkflowService.shared.declineQuote(
            localQuote,
            reason:     reason,
            competitor: competitor,
            notes:      notes
        )
        if case .failure(let err) = result {
            ToastService.shared.error(err.userMessage)
            return
        }
        // Refresh the local copy so the view reflects the new status.
        if let updated = store.quotes.first(where: { $0.id == localQuote.id }) {
            localQuote = updated
        }
    }
}

// MARK: - Quote Decline Sheet (Phase 4 audit)
//
// Captures the loss-reason triple (reason / competitor / notes) when
// an admin marks a quote Declined. Mirror of the same decision that's
// already part of the Estimate flow — we add it here so reporting can
// roll up loss data regardless of which side recorded it.
//
// On apply, the parent's `applyDecline(reason:competitor:notes:)`
// stamps the values onto the Quote AND fires `handleQuoteDeclined`
// so the CRM opportunity's `lossReason` / `competitorName` /
// `lostAt` fields get the same payload.
struct QuoteDeclineSheet: View {
    let quote: Quote
    let onApply: (LossReason, String, String) -> Void

    @Environment(\.dismiss) var dismiss

    @State private var selectedReason: LossReason = .price
    @State private var competitor: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Why did this quote not land? Used in win/loss reporting and stamped on the linked CRM opportunity.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Reason") {
                    Picker("Reason", selection: $selectedReason) {
                        ForEach(LossReason.allCases, id: \.self) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Competitor (optional)") {
                    TextField("Who won the work?", text: $competitor)
                        .autocorrectionDisabled()
                }

                Section("Notes (optional)") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                Section {
                    Button(role: .destructive) {
                        onApply(selectedReason, competitor.trimmingCharacters(in: .whitespaces),
                                notes.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    } label: {
                        Label("Mark Quote as Declined", systemImage: "xmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Decline Quote \(quote.jobNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Convert to Project Sheet
// PM is assigned here. This is the handoff from estimator to PM.

struct ConvertToProjectSheet: View {
    let quote: Quote
    let onComplete: (Quote) -> Void
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedPMID: UUID? = nil
    @State private var showValidationError = false

    private var projectManagers: [Employee] {
        store.employees.filter {
            $0.isActive && ($0.role == .projectManager || $0.role == .manager || $0.role == .executive)
        }.sorted { $0.lastName < $1.lastName }
    }

    var body: some View {
        NavigationStack {
            Form {

                // Summary
                Section("Quote Summary") {
                    HStack {
                        Text("Job Number")
                        Spacer()
                        Text(quote.jobNumber)
                            .foregroundColor(.purple)
                            .fontDesign(.monospaced)
                            .font(.subheadline)
                    }
                    HStack {
                        Text("Client")
                        Spacer()
                        Text(quote.clientName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    HStack {
                        Text("Contract Value")
                        Spacer()
                        Text(quote.totalBeforeTax.currencyString)
                            .foregroundColor(.green)
                            .font(.subheadline).bold()
                    }
                }

                // PM Assignment
                Section {
                    Picker("Assign Project Manager", selection: $selectedPMID) {
                        Text("Select PM").tag(UUID?.none)
                        ForEach(projectManagers) { pm in
                            Text(pm.fullName).tag(Optional(pm.id))
                        }
                    }
                    .pickerStyle(.menu)
                    if projectManagers.isEmpty {
                        Text("No project managers found. Add employees with PM role first.")
                            .font(.caption).foregroundColor(.orange)
                    }
                } header: {
                    Text("Project Manager *")
                } footer: {
                    Text("The PM will be notified and takes over from the estimator at this point.")
                }

                // What gets created
                Section {
                    Label("Project created with job number \(quote.jobNumber)", systemImage: "folder.badge.plus")
                        .font(.subheadline)
                    Label("Budget set to \(quote.totalBeforeTax.currencyString)", systemImage: "dollarsign.circle")
                        .font(.subheadline)
                    Label("Scope, exclusions and assumptions carried over", systemImage: "doc.text")
                        .font(.subheadline)
                    Label("Estimate baseline locked", systemImage: "lock.fill")
                        .font(.subheadline)
                } header: {
                    Text("What happens next")
                }
            }
            .navigationTitle("Create Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create Project") {
                        createProject()
                    }
                    .bold()
                    .foregroundColor(.green)
                }
            }
            .alert("Select a PM", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please assign a project manager before creating the project.")
            }
        }
        .presentationDetents([.large])
    }

    private func createProject() {
        guard let pmID = selectedPMID else {
            showValidationError = true
            return
        }
        let pm = store.employee(id: pmID)
        // Slice 3: route through CommercialWorkflowService instead of
        // calling store.convertQuoteToProject directly. The service
        // owns precondition checks, role gating, and (Slice 4+) state-
        // machine validation. Surfaces failures as user-readable
        // toasts instead of the silent no-op the bare store call had.
        let result = CommercialWorkflowService.shared.convertQuoteToProject(
            quote, pmID: pmID, pmName: pm?.fullName
        )
        switch result {
        case .success:
            let updatedQuote = store.quotes.first { $0.id == quote.id } ?? quote
            onComplete(updatedQuote)
            dismiss()
        case .failure(let err):
            ToastService.shared.error(err.userMessage)
        }
    }
}

// MARK: - AppStore: Quote Document Storage

extension AppStore {

    var allQuoteDocs: [ProjectDocument] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_quote_documents"),
              let docs  = try? decoder.decode([ProjectDocument].self, from: data)
        else { return [] }
        return docs
    }

    func quoteDocs(for quoteID: UUID) -> [ProjectDocument] {
        allQuoteDocs
            .filter  { $0.projectID == quoteID }   // projectID field used as ownerID
            .sorted  { $0.uploadedAt > $1.uploadedAt }
    }

    func addQuoteDoc(_ doc: ProjectDocument) {
        var current = allQuoteDocs
        if !current.contains(where: { $0.id == doc.id }) {
            current.append(doc)
        }
        saveQuoteDocMeta(current)
        objectWillChange.send()
    }

    func deleteQuoteDoc(_ doc: ProjectDocument) {
        try? FileManager.default.removeItem(at: doc.storedURL)
        var current = allQuoteDocs
        current.removeAll { $0.id == doc.id }
        saveQuoteDocMeta(current)
        objectWillChange.send()
    }

    private func saveQuoteDocMeta(_ docs: [ProjectDocument]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(docs) {
            UserDefaults.standard.set(data, forKey: "ak_quote_documents")
        }
    }
}

// MARK: - Quote Documents Section

struct QuoteDocumentsSection: View {
    let quoteID: UUID
    let jobNumber: String
    @EnvironmentObject var store: AppStore
    @State private var showPicker  = false
    @State private var selectedDoc: ProjectDocument? = nil

    private var docs: [ProjectDocument] { store.quoteDocs(for: quoteID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Documents")
                    .font(.headline)
                    .padding(.horizontal)
                Spacer()
                Button { showPicker = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3).foregroundColor(.blue)
                }
                .padding(.trailing)
            }

            if docs.isEmpty {
                Text("No documents yet. Export a PDF to save it here, or add attachments.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(docs) { doc in
                        Button { selectedDoc = doc } label: {
                            QuoteDocRow(doc: doc)
                        }
                        .buttonStyle(.plain)
                        if doc.id != docs.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            // Manual "Add Document" button
            Button { showPicker = true } label: {
                Label("Attach Document", systemImage: "paperclip")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.08))
                    .foregroundColor(.blue)
                    .cornerRadius(10)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showPicker) {
            QuoteDocumentPickerSheet(quoteID: quoteID)
                .environmentObject(store)
        }
        .sheet(item: $selectedDoc) { doc in
            NavigationStack { QuoteDocDetailView(doc: doc) }
                .environmentObject(store)
        }
    }
}

private struct QuoteDocRow: View {
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
                Text(doc.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(doc.category.displayName)
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(doc.category.color.opacity(0.1))
                        .foregroundColor(doc.category.color)
                        .cornerRadius(4)
                    Text(doc.fileSizeString)
                        .font(.caption).foregroundColor(.secondary)
                    Text("·").font(.caption).foregroundColor(.secondary)
                    Text(doc.uploadedAt.shortDate)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct QuoteDocumentPickerSheet: View {
    let quoteID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showDocPicker = false
    @State private var selectedCategory: ProjectDocumentCategory = .quote

    private let categories: [(ProjectDocumentCategory, String, String)] = [
        (.quote,    "Quote PDF",          "doc.richtext.fill"),
        (.contract, "Contract / PO",      "doc.text.fill"),
        (.drawing,  "Drawings & Specs",   "pencil.and.ruler.fill"),
        (.report,   "Supporting Calcs",   "function"),
        (.photo,    "Site Photos",        "camera.fill"),
        (.other,    "Other",              "paperclip"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Document Type") {
                    ForEach(categories, id: \.0) { cat, label, icon in
                        Button {
                            selectedCategory = cat
                            showDocPicker    = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(cat.color.opacity(0.12)).frame(width: 36, height: 36)
                                    Image(systemName: icon).foregroundColor(cat.color).font(.system(size: 14))
                                }
                                Text(label).font(.subheadline).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
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
                    importFiles(urls, category: selectedCategory)
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
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let doc = ProjectDocument(
                projectID:        quoteID,
                name:             url.deletingPathExtension().lastPathComponent,
                originalFileName: url.lastPathComponent,
                fileExtension:    ext,
                fileSize:         size,
                storedFileName:   filename,
                category:         category,
                uploadedBy:       AppStore.shared.currentUser?.fullName ?? "Unknown"
            )
            store.addQuoteDoc(doc)
        }
    }
}

struct QuoteDocDetailView: View {
    let doc: ProjectDocument
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showPreview    = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showDeleteAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // File hero
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(doc.category.color.opacity(0.1)).frame(height: 90)
                    Image(systemName: doc.fileIcon)
                        .font(.system(size: 40)).foregroundColor(doc.category.color)
                }
                .padding(.horizontal)
                Text(doc.name).font(.title3).bold().multilineTextAlignment(.center)

                // Meta
                VStack(spacing: 0) {
                    docRow("File",  doc.originalFileName)
                    Divider().padding(.leading)
                    docRow("Size",  doc.fileSizeString)
                    Divider().padding(.leading)
                    docRow("Added", doc.uploadedAt.shortDate)
                    Divider().padding(.leading)
                    docRow("By",    doc.uploadedBy)
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // Actions
                VStack(spacing: 12) {
                    if doc.fileExists {
                        Button { showPreview = true } label: {
                            Label("Open / Preview", systemImage: "eye.fill")
                                .font(.subheadline).bold().frame(maxWidth: .infinity).padding()
                                .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                        }
                    }
                    Button {
                        shareItems = [doc.storedURL]; showShareSheet = true
                    } label: {
                        Label("Share / Export", systemImage: "square.and.arrow.up")
                            .font(.subheadline).bold().frame(maxWidth: .infinity).padding()
                            .background(Color.blue.opacity(0.10)).foregroundColor(.blue).cornerRadius(12)
                    }
                    Button(role: .destructive) { showDeleteAlert = true } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.subheadline).bold().frame(maxWidth: .infinity).padding()
                            .background(Color.red.opacity(0.10)).foregroundColor(.red).cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top)
        }
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPreview) {
            QuickLookPreview(url: doc.storedURL).ignoresSafeArea()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Delete Document?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                store.deleteQuoteDoc(doc); dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \"\(doc.name)\". This cannot be undone.")
        }
    }

    private func docRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.subheadline).bold().multilineTextAlignment(.trailing)
        }
        .padding()
    }
}

// MARK: - Pricing Row

struct PricingRow: View {
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

// MARK: - Quote Text Block

struct QuoteTextBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
    }
}

// MARK: - Quote Create View

struct QuoteCreateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Quote? = nil
    var fromEstimate: Estimate? = nil

    @State private var selectedEstimateID: UUID? = nil
    @State private var clientName = ""
    @State private var siteAddress = ""
    @State private var scopeSummary = ""
    @State private var inclusions = ""
    @State private var exclusions = ""
    @State private var assumptions = ""
    @State private var paymentTerms = AppSettings.shared.defaultPaymentTerms
    @State private var contingencyString = "0"
    @State private var taxRateString = String(AppSettings.shared.taxRate)
    @State private var validityDays = AppSettings.shared.defaultQuoteValidityDays
    @State private var showValidationError = false
    @State private var validationMessage = ""

    // Phase 5 audit fix: line items are now editable inline at create
    // time rather than waiting for the user to open the quote and add
    // them in detail view. The picker preserves productServiceID + the
    // client pricing override hierarchy, so a freshly-created quote
    // links cleanly back to the product/service library for reporting.
    @State private var lineItems: [CostCodeItem] = []
    // Replaced by activeCreateSheet enum router below — kept as
    // implicit nil-safe state by the router. (No @State needed.)
    /// Holds a temporary client UUID derived from the selected
    /// estimate so the picker can resolve client-specific pricing
    /// even before the Quote record exists.
    @State private var resolvedClientID: UUID? = nil
    /// SR-1.4: take-off labor requirements. Replaces the legacy
    /// single-crew preference with a structured plan (count, class,
    /// certs, preferred / required workers, preferred crew). The
    /// recommendation engine reads this and assembles ANY valid
    /// resource combination (fixed crew / custom crew / single
    /// worker) that satisfies it.
    @State private var laborPlan: LaborRequirement = LaborRequirement()

    // Phase-2 deferred audit fix: concurrent-edit detection. Same
    // pattern shipped on ProjectCreateEditView — captures the
    // baseline updated_at when the form opens, compares to server
    // before push, surfaces an alert if a different device wrote
    // in the meantime.
    @State private var editingBaselineUpdatedAt: Date = Date()
    @State private var conflictServerQuote: Quote? = nil
    @State private var showConflictAlert = false
    @State private var pendingLocalQuote: Quote? = nil

    // "Save & Send" workflow state. The flag is set when the user taps
    // the action button, then read inside finalizeQuoteSave() so the
    // existing validation + conflict-detection pipeline can be reused
    // verbatim. isSendingEmail drives the inline progress indicator and
    // disables both Save buttons while the send is in flight.
    @State private var pendingSendAfterSave = false
    @State private var isSendingEmail = false

    // ─── Single sheet router for ALL of QuoteCreateView's modal flows.
    // SwiftUI's behavior with multiple .sheet modifiers — especially
    // when some are attached to nested views like QuoteTermsSection
    // inside the Form — is unreliable: bindings flap and sheets
    // dismiss themselves on present. Consolidating every modal
    // through one enum-driven .sheet eliminates the conflict.
    @State private var activeCreateSheet: ActiveCreateSheet? = nil

    enum ActiveCreateSheet: Identifiable {
        case productPicker
        case sendReview(Quote)
        case termsPicker
        case termsCustom
        case termsPreview

        var id: String {
            switch self {
            case .productPicker: return "productPicker"
            case .sendReview(let q): return "sendReview-\(q.id.uuidString)"
            case .termsPicker:   return "termsPicker"
            case .termsCustom:   return "termsCustom"
            case .termsPreview:  return "termsPreview"
            }
        }
    }

    // Slice B: stable quote ID for the lifetime of the form session.
    // Terms attach against this ID. For new quotes it's a fresh UUID
    // generated on first appearance; for edits it's the existing quote's
    // ID (stamped in populate()). save() uses this as quote.id so the
    // foreign key from quote_terms resolves correctly on first push.
    @State private var editingQuoteID: UUID = UUID()
    @State private var defaultsAttemptedThisSession: Bool = false

    // Slice C: send-time soft warnings. Computed when the user taps
    // Save & Send; if non-empty, a confirmation dialog appears before
    // the actual save fires.
    @State private var pendingSendWarnings: [QuoteSendWarning] = []
    @State private var showSendWarningDialog: Bool = false

    private var isEditing: Bool { existing != nil }

    /// Resolved client for the quote-being-edited. Used for the email
    /// recipient list and the greeting in the body. Populated from the
    /// selected estimate (new quote) or the existing quote's clientID
    /// (edit path) — same source as resolvedClientID.
    private var sendTargetClient: Client? {
        if let id = resolvedClientID { return store.client(id: id) }
        if let id = existing?.clientID { return store.client(id: id) }
        return nil
    }

    /// Deduped, prioritised email recipients for the linked client —
    /// primary contact first, then any other CRM contacts. Mirrors the
    /// helper of the same name on QuoteDetailView so the two send
    /// pathways resolve recipients identically.
    private var sendTargetEmails: [String] {
        guard let clientID = resolvedClientID ?? existing?.clientID else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        if let client = store.client(id: clientID),
           let email  = client.contactEmail,
           !email.isEmpty,
           seen.insert(email.lowercased()).inserted {
            out.append(email)
        }
        for c in store.crmContacts where c.clientID == clientID && !c.isDeleted {
            if !c.email.isEmpty, seen.insert(c.email.lowercased()).inserted {
                out.append(c.email)
            }
        }
        return out
    }

    /// Estimates eligible to be converted into a Quote.
    /// 2026-04 audit fix: pre-fix this was `.awarded`-only, which
    /// forced users to mark estimates as awarded before they actually
    /// were — confusing and corrupted the win/loss reporting. The
    /// `EstimateStatus.isQuoteEligible` helper now drives which
    /// statuses qualify (internalReview / submitted / awarded). Already
    /// converted estimates are intentionally excluded so the same
    /// estimate doesn't spawn duplicate quotes.
    private var quoteEligibleEstimates: [Estimate] {
        store.estimates
            .filter { $0.status.isQuoteEligible && !$0.isDeleted }
            .sorted { $0.name < $1.name }
    }

    /// Backwards-compat alias kept so other call sites in this file
    /// don't break. Returns the same broader list — read sites that
    /// explicitly want only awarded estimates should be migrated.
    private var awardedEstimates: [Estimate] { quoteEligibleEstimates }

    /// Finds the selected estimate from any status — the `fromEstimate` parameter takes
    /// priority so that pre-population works even before the store sync catches up.
    private var selectedEstimate: Estimate? {
        if let fe = fromEstimate, fe.id == selectedEstimateID { return fe }
        return store.estimates.first { $0.id == selectedEstimateID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Estimate *") {
                    Picker("Select Estimate", selection: $selectedEstimateID) {
                        Text("Select Estimate").tag(UUID?.none)
                        ForEach(quoteEligibleEstimates) { e in
                            // Append status so users see why a draft
                            // (Internal Review / Submitted) shows up
                            // alongside their Awarded rows.
                            Text("\(e.jobNumber) — \(e.name) · \(e.status.displayName)")
                                .tag(Optional(e.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedEstimateID) {
                        prefillFromEstimate()
                    }
                    if quoteEligibleEstimates.isEmpty {
                        Text("No estimates ready for a quote. An estimate becomes eligible once it reaches Internal Review or later.")
                            .font(.caption).foregroundColor(.orange)
                    }
                }

                Section("Client *") {
                    TextField("Client Name", text: $clientName)
                    TextField("Site Address", text: $siteAddress)
                }

                Section("Pricing") {
                    if let estimate = selectedEstimate {
                        HStack {
                            Text("Estimate Total")
                            Spacer()
                            Text(estimate.totalEstimated.currencyString)
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Contingency")
                        Spacer()
                        TextField("0", text: $contingencyString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("\(AppSettings.shared.taxLabel) Rate")
                        Spacer()
                        TextField("0", text: $taxRateString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                }

                // Phase 5 audit fix: dedicated line-items section.
                // Pre-fix the create flow only showed an "X items
                // carried over" badge — users had to open the quote
                // again in detail view to see/edit. Now the picker is
                // here, productServiceID is preserved on every add,
                // and client-specific pricing applies automatically
                // because we pass the resolved client ID.
                Section {
                    if lineItems.isEmpty {
                        Text("No line items yet. Add from the product/service library or carry them from the linked estimate.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(lineItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.code)
                                        .font(.caption).bold()
                                        .fontDesign(.monospaced)
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Text(item.estimatedTotal.currencyString)
                                        .font(.subheadline).bold()
                                }
                                Text(item.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Text("\(NSDecimalNumber(decimal: item.estimatedQuantity).stringValue) \(item.unit)")
                                        .font(.caption2).foregroundColor(.secondary)
                                    Text("@ \(item.unitRate.currencyString)")
                                        .font(.caption2).foregroundColor(.secondary)
                                    if item.productServiceID != nil {
                                        Image(systemName: "link")
                                            .font(.caption2)
                                            .foregroundColor(.purple)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            lineItems.remove(atOffsets: offsets)
                        }

                        HStack {
                            Text("Subtotal")
                                .font(.subheadline).bold()
                            Spacer()
                            Text(lineItems.reduce(Decimal(0)) { $0 + $1.estimatedTotal }.currencyString)
                                .font(.subheadline).bold()
                                .foregroundColor(.green)
                        }
                    }

                    Button {
                        activeCreateSheet = .productPicker
                    } label: {
                        Label("Add Line Item from Library", systemImage: "shippingbox.fill")
                    }

                    if let est = selectedEstimate, !est.lineItems.isEmpty,
                       lineItems.count != est.lineItems.count {
                        Button {
                            // One-tap replace with whatever's on the
                            // estimate. Used after manual editing if
                            // the user wants to start over from the
                            // estimate baseline.
                            lineItems = est.lineItems
                        } label: {
                            Label("Reset to Estimate Items (\(est.lineItems.count))",
                                  systemImage: "arrow.counterclockwise")
                                .foregroundColor(.purple)
                        }
                    }
                } header: {
                    Text("Line Items")
                } footer: {
                    if lineItems.contains(where: { $0.productServiceID == nil }) {
                        Text("Items added from the library link back to your product/service catalog (purple link icon). Items without a link came from a manual estimate entry — open them in the Detail view to attach them later.")
                    } else {
                        Text("All items linked to the product/service library. Reporting will roll up correctly.")
                    }
                }

                Section("Scope Summary") {
                    TextEditor(text: $scopeSummary).frame(minHeight: 80)
                }
                Section("Inclusions") {
                    TextEditor(text: $inclusions).frame(minHeight: 60)
                }
                Section("Exclusions") {
                    TextEditor(text: $exclusions).frame(minHeight: 60)
                }
                Section("Assumptions") {
                    TextEditor(text: $assumptions).frame(minHeight: 60)
                }
                Section("Payment Terms") {
                    TextEditor(text: $paymentTerms).frame(minHeight: 60)
                }

                // Slice B: Terms & Conditions attachment. Read-only when
                // the underlying quote is in a terminal/sent state so
                // historical wording stays frozen.
                // Critical workflow fix: section no longer owns its own
                // .sheet modifiers — instead it calls back to the
                // parent's single sheet router via the on*Present
                // closures. This eliminates the nested-sheet binding
                // flap that was auto-dismissing the picker.
                QuoteTermsSection(
                    quoteID:   editingQuoteID,
                    readOnly:  termsReadOnlyForCurrentQuote,
                    lineItems: lineItems,
                    onPresentPicker:  { activeCreateSheet = .termsPicker },
                    onPresentCustom:  { activeCreateSheet = .termsCustom },
                    onPresentPreview: { activeCreateSheet = .termsPreview }
                )
                .environmentObject(store)

                Section("Validity") {
                    Stepper("\(validityDays) days", value: $validityDays, in: 7...90, step: 7)
                }

                // SR-1.4 — Labor Plan section
                //
                // Take-off layer. The estimator declares WHAT the work
                // needs (count, worker class, required certs, optional
                // preferred people / crew). The recommendation engine
                // satisfies the requirement with ANY valid combination —
                // a fixed crew, a custom crew assembled from qualified
                // individuals, or a single worker. This eliminates the
                // single-crew bottleneck (where pinning one crew delayed
                // the project even when other qualified workers were
                // idle).
                LaborPlanSection(plan: $laborPlan)
                    .environmentObject(store)

                // One-tap save-and-deliver. Mirrors the "Send Quote to
                // Client" action button on QuoteDetailView so users
                // creating a quote in a single sitting don't have to
                // bounce out to the detail view to email it. Pipes
                // through finalizeQuoteSave() so validation, conflict
                // detection, and CRM bridging stay consistent. If the
                // email send fails the quote is still saved (fallback)
                // — the user can retry from the detail view.
                Section {
                    Button {
                        // Slice C: compute soft warnings (no terms
                        // attached / missing matching templates). If
                        // any apply, surface a confirmation dialog
                        // first; otherwise proceed straight to send.
                        let warnings = store.sendTimeWarnings(
                            forLineItems: lineItems,
                            quoteID:      editingQuoteID
                        )
                        if warnings.isEmpty {
                            pendingSendAfterSave = true
                            save()
                        } else {
                            pendingSendWarnings  = warnings
                            showSendWarningDialog = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isSendingEmail {
                                ProgressView()
                                    .tint(.white)
                                Text("Sending…")
                                    .font(.headline)
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Save & Send Quote")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(sendTargetEmails.isEmpty ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isSendingEmail || sendTargetEmails.isEmpty)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    if sendTargetEmails.isEmpty {
                        Text("No email on file for this client. Add a contact email on the Client record, or use Save and email from the quote detail view.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("Saves the quote, attaches the PDF, and emails it to \(sendTargetEmails.first ?? "the client") with a one-click acceptance link.")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Quote" : "New Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSendingEmail)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(isSendingEmail)
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            // Slice C: send-time soft warnings. Always confirms before
            // overriding so the rep doesn't fire a quote without T&C
            // by accident. "Send anyway" proceeds with the same
            // pendingSendAfterSave + save() pipeline as the no-warnings
            // path.
            .confirmationDialog(
                "Send this quote?",
                isPresented: $showSendWarningDialog,
                titleVisibility: .visible
            ) {
                Button("Send anyway", role: .destructive) {
                    pendingSendAfterSave = true
                    save()
                }
                Button("Review T&C first", role: .cancel) {}
            } message: {
                Text(pendingSendWarnings.map { $0.message }.joined(separator: "\n\n"))
            }
            .alert("Someone else updated this quote",
                   isPresented: $showConflictAlert) {
                Button("Overwrite with my changes", role: .destructive) {
                    if let q = pendingLocalQuote, let est = store.estimates.first(where: { $0.id == q.estimateID }) {
                        finalizeQuoteSave(q, estimate: est, isNew: false)
                    } else if let q = pendingLocalQuote {
                        finalizeQuoteSave(q, estimate: nil, isNew: false)
                    }
                }
                Button("Discard my changes", role: .cancel) {
                    Task { await store.refreshAll() }
                    dismiss()
                }
            } message: {
                if let server = conflictServerQuote {
                    let by = server.lastModifiedBy.isEmpty ? "another user" : server.lastModifiedBy
                    let when = server.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    Text("\(by) updated this quote on the server at \(when), after you opened it. Saving now would overwrite their changes.")
                } else {
                    Text("The server has newer changes than your local copy. Saving now would overwrite them.")
                }
            }
            .onAppear {
                populate()
                applyDefaultTermsIfNeeded()
            }
            .task {
                // Slice B: pull current templates + already-attached
                // terms so the section is populated. Cheap queries —
                // small tables, single tenant.
                await SyncEngine.shared.pullTermsTemplates()
                await SyncEngine.shared.pullQuoteTerms()
            }
            // Critical workflow fix: ALL of QuoteCreateView's modal
            // flows go through ONE sheet router. Pre-fix there were
            // three separate sheet modifiers (productPicker on parent,
            // sendReview on parent, termsPicker/Custom/Preview on
            // QuoteTermsSection). SwiftUI's binding flap across nested
            // levels caused sheets to auto-dismiss on present — the
            // exact symptom the user kept hitting on the Terms picker.
            // One enum-driven sheet, no flap.
            .sheet(item: $activeCreateSheet) { kind in
                switch kind {
                case .productPicker:
                    ProductServicePickerSheet(clientID: resolvedClientID) { newItem in
                        lineItems.append(newItem)
                    }
                    .environmentObject(store)

                case .sendReview(let reviewQuote):
                    QuoteSendReviewSheet(
                        quote: reviewQuote,
                        performSend: { recipients, includeLink in
                            await runEmailPipelineForReview(
                                quote: reviewQuote,
                                recipients: recipients,
                                includeAcceptanceLink: includeLink
                            )
                        },
                        onSendSucceeded: {
                            handleSendSucceeded(for: reviewQuote)
                        }
                    )
                    .environmentObject(store)

                case .termsPicker:
                    QuoteTermsPickerSheet(quoteID: editingQuoteID, lineItems: lineItems)
                        .environmentObject(store)

                case .termsCustom:
                    QuoteCustomTermSheet(quoteID: editingQuoteID)
                        .environmentObject(store)

                case .termsPreview:
                    QuoteTermsPreviewSheet(quoteID: editingQuoteID)
                        .environmentObject(store)
                }
            }
        }
    }

    private func prefillFromEstimate() {
        guard let estimate = selectedEstimate else { return }
        let client = store.client(id: estimate.clientID)

        // Client name — use CRM record, fall back to the estimate name so the field
        // is never left blank (which would block saving).
        clientName = client?.name ?? estimate.name
        // Phase 5 audit fix: capture the resolved client UUID so the
        // ProductServicePickerSheet can apply client-specific pricing
        // overrides on every line item the user adds. Without this,
        // newly-picked items always landed at default catalog price
        // even when the client had a negotiated rate.
        resolvedClientID = estimate.clientID

        // Best site address: default site, then billing address
        if let defaultSite = client?.sites.first(where: { $0.isDefault }) {
            siteAddress = defaultSite.formattedAddress.isEmpty ? defaultSite.address : defaultSite.formattedAddress
        } else {
            siteAddress = client?.fullBillingAddress ?? ""
        }

        // Scope summary from line items; fall back to estimate scope description
        if !estimate.lineItems.isEmpty {
            scopeSummary = estimate.lineItems.map { "• \($0.description)" }.joined(separator: "\n")
        } else if let desc = estimate.scopeDescription, !desc.isEmpty {
            scopeSummary = desc
        }

        inclusions        = estimate.scopeDescription ?? ""
        contingencyString = "\(estimate.contingencyPercent)"
        paymentTerms      = client?.defaultPaymentTerms ?? AppSettings.shared.defaultPaymentTerms

        // Carry estimate line items into the in-progress quote ONLY on
        // first selection (when our local lineItems is still empty).
        // Re-selecting an estimate after manual edits shouldn't blow
        // away the user's work — the "Reset to Estimate Items" button
        // gives them an explicit do-over instead.
        if lineItems.isEmpty && !estimate.lineItems.isEmpty {
            lineItems = estimate.lineItems
        }

        // Pre-populate tax rate from app settings
        if taxRateString.isEmpty { taxRateString = String(AppSettings.shared.taxRate) }
    }

    private func populate() {
        if let estimate = fromEstimate {
            selectedEstimateID = estimate.id
            prefillFromEstimate()
            return
        }
        guard let q = existing else { return }
        selectedEstimateID = q.estimateID
        clientName         = q.clientName
        siteAddress        = q.siteAddress ?? ""
        scopeSummary       = q.scopeSummary
        inclusions         = q.inclusions
        exclusions         = q.exclusions
        assumptions        = q.assumptions
        paymentTerms       = q.paymentTerms
        contingencyString  = "\(q.contingencyPercent)"
        taxRateString      = q.taxRate > 0 ? "\(q.taxRate)" : String(AppSettings.shared.taxRate)
        validityDays       = q.validityDays
        // Capture baseline timestamp so save() can pre-check the
        // server before pushing — surfaces concurrent edits.
        editingBaselineUpdatedAt = q.updatedAt
        // Editing path — load the quote's existing line items into
        // local state so the picker can append/edit/remove against
        // them. resolvedClientID drives client-specific pricing for
        // any new items the user adds via the picker.
        lineItems          = q.lineItems
        resolvedClientID   = q.clientID
        // SR-1.4: hydrate the take-off labor plan. Falls back to
        // building a plan from the legacy preferredCrewID field
        // when the quote pre-dates SR-1.4 and laborPlan is empty.
        if !q.laborPlan.isEmpty {
            laborPlan = q.laborPlan
        } else if let legacyCrewID = q.preferredCrewID {
            laborPlan = LaborRequirement(preferredCrewID: legacyCrewID)
        } else {
            laborPlan = LaborRequirement()
        }
        // Slice B: align the form's stable ID with the existing quote
        // so the terms section reads/writes against the right rows.
        editingQuoteID     = q.id
    }

    // MARK: - Slice B helpers

    /// Computes the read-only state for the terms section. Sent /
    /// accepted / declined quotes lock the wording per snapshot rule;
    /// expired (past expiryDate, not yet accepted) also locks since
    /// resending would normally produce a new revision.
    private var termsReadOnlyForCurrentQuote: Bool {
        guard let q = existing else { return false }   // new quote: always editable
        if q.status.termsAreReadOnly { return true }
        // "Expired" isn't a stored status — derive it from the quote.
        if q.status != .accepted && q.expiryDate < Date() { return true }
        return false
    }

    /// One-shot default-templates application. Fires when the form
    /// first appears and:
    ///   - the quote is new (no existing record yet), OR
    ///   - the existing quote has terms_default_applied = false AND
    ///     the quote isn't in a read-only state (sent/accepted/declined/expired).
    ///
    /// User removals after this stick — defaults don't re-attach. Sent
    /// quotes with the legacy false flag are NOT backfilled — that
    /// would silently mutate already-sent wording. They're left alone.
    private func applyDefaultTermsIfNeeded() {
        guard !defaultsAttemptedThisSession else { return }
        defaultsAttemptedThisSession = true

        // Read-only quotes never get default-attachment, even if the
        // ledger flag is false. Pulling new T&C onto a sent quote
        // would change history.
        guard !termsReadOnlyForCurrentQuote else { return }

        let needsApply: Bool
        if let q = existing {
            needsApply = !q.termsDefaultApplied
        } else {
            needsApply = true
        }
        guard needsApply else { return }

        // Don't re-attach defaults that already exist on this quote
        // (matched by templateID). Covers the legacy-backfill case
        // where a quote was created before this feature shipped but
        // a rep manually attached the same templates after launch.
        let existingTemplateIDs = Set(
            store.quoteTerms(for: editingQuoteID).compactMap { $0.templateID }
        )
        let defaults = store.activeTermsTemplates
            .filter { $0.isDefault && !existingTemplateIDs.contains($0.id) }
        for d in defaults {
            store.attachTermsTemplateToQuote(d, quoteID: editingQuoteID)
        }
    }

    private func save() {
        guard let estimateID = selectedEstimateID else {
            validationMessage = "Please select an estimate."
            showValidationError = true
            pendingSendAfterSave = false
            return
        }
        guard !clientName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Client name is required."
            showValidationError = true
            pendingSendAfterSave = false
            return
        }
        // 2026-04 audit: defend against re-converting an estimate that
        // already produced a quote. Without this, hitting Save twice on
        // the same screen would mint two quotes against the same
        // estimate and leave one of them orphaned.
        if let est = store.estimates.first(where: { $0.id == estimateID }),
           let prior = est.convertedQuoteID,
           existing == nil {
            validationMessage = "This estimate has already been converted to a quote (\(prior.uuidString.prefix(8))). Open that quote instead of creating a new one."
            showValidationError = true
            pendingSendAfterSave = false
            return
        }

        let estimate = store.estimates.first { $0.id == estimateID }

        let isNew = existing == nil

        var quote = existing ?? Quote(
            jobNumber:  store.nextQuoteNumber(),
            estimateID: estimateID,
            clientID:   estimate?.clientID ?? UUID(),
            clientName: clientName,
            preparedBy: store.currentUser?.fullName ?? "Unknown"
        )
        // Slice B: align the new quote's ID with the form's stable
        // editingQuoteID so any quote_terms attached during this
        // session land on the right foreign key.
        if isNew { quote.id = editingQuoteID }
        quote.clientName         = clientName
        quote.siteAddress        = siteAddress.isEmpty ? nil : siteAddress
        quote.scopeSummary       = scopeSummary
        quote.inclusions         = inclusions
        quote.exclusions         = exclusions
        quote.assumptions        = assumptions
        quote.paymentTerms       = paymentTerms
        quote.contingencyPercent = Decimal(string: contingencyString) ?? 0
        // Slice 7 (Phase 10 value snapshot): never store a zero taxRate.
        // The PDF renderer falls back to AppSettings when zero, which
        // is a drift point — if the company changes its default rate
        // later, every zero-rate quote silently re-renders at the new
        // value. Locking the rate here makes the snapshot durable.
        let parsedTaxRate = Decimal(string: taxRateString) ?? Decimal(AppSettings.shared.taxRate)
        quote.taxRate = parsedTaxRate > 0 ? parsedTaxRate : Decimal(AppSettings.shared.taxRate)
        quote.validityDays       = validityDays
        quote.expiryDate         = Calendar.current.date(
            byAdding: .day, value: validityDays, to: Date()
        ) ?? Date()
        // Slice B: defaults have had their one chance to attach
        // (during applyDefaultTermsIfNeeded() on appear). Mark the
        // ledger so a later sync that brings in a new is_default
        // template doesn't retroactively attach it to this quote.
        quote.termsDefaultApplied = true

        // SR-1.4: persist the take-off labor plan. Normalize first
        // (trim, dedupe, clamp count) so the engine reads clean data.
        let plan = laborPlan.normalized()
        quote.laborPlan = plan
        // Keep the legacy preferredCrewID column populated for back-
        // compat with any reader that still uses it (server-side
        // queries, dashboards). The engine itself reads laborPlan.
        quote.preferredCrewID = plan.preferredCrewID

        // Phase 5 audit fix: line items are now edited inline in this
        // form, so the local `lineItems` state is the authoritative
        // source. populate() / prefillFromEstimate() seeds it from
        // the estimate (or the existing quote if editing). The picker
        // appends to it; the swipe-to-delete removes from it.
        //
        // Pre-fix the create flow always copied the ESTIMATE'S items
        // unconditionally on save, which silently overwrote anything
        // the user picked. Now we hand local state through verbatim.
        quote.lineItems = lineItems
        if quote.lineItems.isEmpty {
            // Fallback for legacy / Quick Quote records: use the
            // estimate's total as a manual subtotal so the quote
            // isn't $0 when no line items exist.
            quote.subtotal = estimate?.totalEstimated ?? 0
        }

        // Link to CRM opportunity
        if quote.opportunityID == nil,
           let opp = store.crmOpportunities.first(where: {
               $0.estimateID == estimateID || $0.quoteID == quote.id
           }) {
            quote.opportunityID = opp.id
        }

        // Phase-2 deferred audit fix: concurrent-edit pre-check on
        // the EDIT path only. New quotes can't conflict (no row to
        // compare). Lifts the same flow as ProjectCreateEditView.
        if !isNew {
            pendingLocalQuote = quote
            Task { @MainActor in
                let result = await ConflictDetectionService.shared.checkQuote(
                    id:                quote.id,
                    baselineUpdatedAt: editingBaselineUpdatedAt
                )
                switch result {
                case .clean, .checkFailed, .notFound:
                    finalizeQuoteSave(quote, estimate: estimate, isNew: isNew)
                case .conflict(let server):
                    conflictServerQuote = server
                    showConflictAlert   = true
                }
            }
        } else {
            finalizeQuoteSave(quote, estimate: estimate, isNew: isNew)
        }
    }

    /// Extracted from save() so the conflict path can call it after
    /// the user confirms "Overwrite with my changes".
    private func finalizeQuoteSave(_ quote: Quote, estimate: Estimate?, isNew: Bool) {
        store.upsertQuote(quote)

        // CRM bridge: advance opportunity stage and log "Quote Created" for new quotes.
        if isNew {
            store.handleQuoteCreated(quote)
        }

        // 2026-04 audit fix: stamp the source estimate as `.converted`
        // and write the back-link `convertedQuoteID`. Pre-fix the
        // estimate stayed at `.awarded` (or whatever status it had)
        // and there was no breadcrumb showing what quote it produced.
        // Only run on first conversion (isNew) — subsequent saves of
        // the same quote shouldn't re-stamp the estimate.
        if isNew, var est = estimate {
            est.status            = .converted
            est.convertedQuoteID  = quote.id
            // upsertEstimate auto-stamps .pending and pushes; no need
            // to set syncStatus manually.
            store.upsertEstimate(est)

            // estimate_terms → quote_terms carry-forward. Snapshots
            // every term attached to the source estimate onto the new
            // quote so the user doesn't have to re-pick. Safe to call
            // even when no estimate_terms exist (returns 0 immediately).
            // NOTE: this runs AFTER the quote is upserted above so
            // quoteID is valid. Carry-forward NEVER changes either
            // record's status — the conversion to .converted has
            // already been applied above; this only writes terms rows.
            let carriedCount = store.carryEstimateTermsForwardToQuote(
                estimateID: est.id,
                quoteID:    quote.id
            )
            if carriedCount > 0 {
                print("📋 Estimate→Quote carry-forward: snapshotted \(carriedCount) term(s) from estimate \(est.jobNumber) onto new quote \(quote.jobNumber)")
            }
        }

        // Critical workflow fix: Save & Send branch no longer fires
        // the email pipeline directly. The quote is persisted above
        // at its current status (.draft for new, unchanged for edit);
        // we then open QuoteSendReviewSheet. The review sheet collects
        // recipients + confirms scope/total/terms and runs the email
        // pipeline only when the user taps Send. Status flips ONLY on
        // email success — never on save, never on sheet dismiss.
        if pendingSendAfterSave {
            pendingSendAfterSave = false
            // Pre-flight the state machine + approval gate BEFORE the
            // review sheet opens so the user gets the rejection
            // immediately rather than after filling in recipients.
            let pre = CommercialWorkflowService.shared.precheckCanSendQuote(
                quote, via: .manual
            )
            if case .failure(let err) = pre {
                ToastService.shared.error("Can't send: \(err.userMessage)")
                dismiss()
                return
            }
            activeCreateSheet = .sendReview(quote)
            return
        }

        dismiss()
    }

    /// Runs the actual email pipeline (mint → render → send) for the
    /// review sheet. Returns the EmailService result so the sheet can
    /// surface errors inline. Does NOT flip status — that's the caller's
    /// job, gated on this Result being .success.
    ///
    /// This is the only place that touches EmailService. The review
    /// sheet supplies the final recipients (which may differ from
    /// sendTargetEmails if the user removed CCs), and the
    /// includeAcceptanceLink flag toggles the magic-link mint.
    @MainActor
    private func runEmailPipelineForReview(
        quote: Quote,
        recipients: [String],
        includeAcceptanceLink: Bool
    ) async -> Result<Void, EmailService.EmailError> {

        // Magic-link mint is admin-gated server-side AND user-toggled
        // here. Non-admins always get .notAdmin; we silently fall
        // through without the link.
        var acceptanceURL: URL? = nil
        if includeAcceptanceLink {
            do {
                let mint = try await QuoteAcceptanceService.shared.mintToken(quoteID: quote.id)
                acceptanceURL = mint.url
            } catch QuoteAcceptanceService.AcceptanceError.notAdmin {
                // Expected for non-admins.
            } catch {
                // Other mint failures are non-fatal — proceed without link.
            }
        }

        // Render PDF off-main.
        let pdfLineItems = quote.lineItems.isEmpty
            ? (store.estimates.first { $0.id == quote.estimateID }?.lineItems ?? [])
            : quote.lineItems
        let taxRate  = quote.taxRate > 0 ? quote.taxRate : Decimal(AppSettings.shared.taxRate)
        let taxLabel = AppSettings.shared.taxLabel
        let attachedTerms = store.quoteTerms(for: quote.id)
        let pdfData: Data = await Task.detached(priority: .userInitiated) {
            QuotePDFRenderer(
                quote:      quote,
                lineItems:  pdfLineItems,
                taxRate:    taxRate,
                taxLabel:   taxLabel,
                quoteTerms: attachedTerms
            ).render()
        }.value
        let safeJob  = quote.jobNumber
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        let filename = "Quote_\(safeJob).pdf"

        let body    = composeEmailBody(for: quote, acceptanceURL: acceptanceURL)
        let subject = "Quote \(quote.jobNumber)"
        let html    = EmailHTMLTemplate.wrap(
            plainText:   body,
            companyName: AppSettings.shared.companyName,
            subject:     subject,
            footerNote:  acceptanceURL == nil
                ? "Reply to this email if you have any questions about the quote."
                : "Tap the digital acceptance link in the email body to sign in one click."
        )

        return await EmailService.shared.sendPDF(
            to:          recipients,
            subject:     subject,
            bodyText:    body,
            bodyHTML:    html,
            pdfData:     pdfData,
            pdfFilename: filename,
            entityType:  "quote",
            entityID:    quote.id
        )
    }

    /// Runs after the review sheet confirms the email actually delivered.
    /// Flips the quote status to .sent (via the workflow service so the
    /// state machine + audit log run), shows the success toast, and
    /// dismisses the parent QuoteCreateView.
    @MainActor
    private func handleSendSucceeded(for quote: Quote) {
        let result = CommercialWorkflowService.shared.recordQuoteSent(quote, via: .manual)
        if case .failure(let err) = result {
            // Email succeeded but state-flip rejected (e.g. concurrent
            // edit on another device flipped status to .accepted before
            // we could). Don't double-toast — the email did go out.
            print("⚠️ recordQuoteSent failed post-send: \(err.userMessage)")
        }
        ToastService.shared.success("Quote sent.")
        dismiss()
    }

    /// Builds the plain-text email body. Mirrors QuoteDetailView's
    /// `emailDefaultBody` so the wording is identical whether the
    /// quote is sent from the create flow or the detail view.
    private func composeEmailBody(for quote: Quote, acceptanceURL: URL?) -> String {
        let greeting: String
        if let client = sendTargetClient, !client.name.isEmpty {
            greeting = "Hi \(client.name) team,"
        } else {
            greeting = "Hello,"
        }
        let user = store.currentUser?.fullName ?? AppSettings.shared.companyName
        let signature = user.isEmpty ? AppSettings.shared.companyName : user
        let acceptanceBlock: String
        if let url = acceptanceURL {
            acceptanceBlock = """


            ✅ Approve digitally:
            \(url.absoluteString)

            (One-click acceptance with a built-in signature pad. The link expires in 30 days.)
            """
        } else {
            acceptanceBlock = ""
        }
        return """
        \(greeting)

        Please find quote \(quote.jobNumber) attached. Let me know if you'd like to discuss any of the line items or scope.\(acceptanceBlock)

        Thanks,
        \(signature)
        """
    }
}

// MARK: - Line Item Row

struct LineItemRow: View {
    let item: CostCodeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.code)
                    .font(.caption).bold().foregroundColor(.blue)
                Spacer()
                Text(item.estimatedTotal.currencyString)
                    .font(.subheadline).bold()
            }
            Text(item.description).font(.subheadline)
            HStack(spacing: 16) {
                Text("\(item.estimatedQuantity) \(item.unit)")
                    .font(.caption).foregroundColor(.secondary)
                Text("@ \(item.unitRate.currencyString)/\(item.unit)")
                    .font(.caption).foregroundColor(.secondary)
                if let variance = item.variance {
                    Label(
                        variance >= 0
                            ? "+" + variance.currencyString
                            : variance.currencyString,
                        systemImage: variance >= 0 ? "arrow.up" : "arrow.down"
                    )
                    .font(.caption)
                    .foregroundColor(variance >= 0 ? .green : .red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Add Line Item Sheet

struct AddLineItemSheet: View {
    let onAdd: (CostCodeItem) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var code = ""
    @State private var description = ""
    @State private var unit = "hrs"
    @State private var quantityString = ""
    @State private var rateString = ""

    private let units = ["hrs", "m²", "lm", "ea", "tonne", "day", "ls", "m³"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Cost Code *") {
                    TextField("Code (e.g. INS-001)", text: $code)
                    TextField("Description", text: $description)
                }
                Section("Pricing *") {
                    Picker("Unit", selection: $unit) {
                        ForEach(units, id: \.self) { u in
                            Text(u).tag(u)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        TextField("Quantity", text: $quantityString)
                            .keyboardType(.decimalPad)
                        Text(unit).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("$")
                        TextField("Unit Rate", text: $rateString)
                            .keyboardType(.decimalPad)
                        Text("per \(unit)").foregroundColor(.secondary)
                    }
                }
                if let qty  = Decimal(string: quantityString),
                   let rate = Decimal(string: rateString) {
                    Section("Calculated Total") {
                        HStack {
                            Text("Estimated Total")
                            Spacer()
                            Text((qty * rate).currencyString)
                                .bold().foregroundColor(.green)
                        }
                    }
                }
            }
            .navigationTitle("Add Line Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        guard let qty  = Decimal(string: quantityString),
                              let rate = Decimal(string: rateString) else { return }
                        let item = CostCodeItem(
                            code:              code,
                            description:       description,
                            unit:              unit,
                            estimatedQuantity: qty,
                            unitRate:          rate
                        )
                        onAdd(item)
                        dismiss()
                    }
                    .bold()
                    .disabled(code.isEmpty || description.isEmpty ||
                              quantityString.isEmpty || rateString.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Sample-data tracking
extension Quote: SampleDataTrackable {}
