// CRMCommercialBridge.swift
// AskiCommand — CRM ↔ Commercial Relationship Layer
//
// Key rule: Any commercial activity involving a client always writes back to CRM.
// This extension ensures estimates, quotes, material sales, and invoices created
// from any entry point (CRM, Projects, More → Commercial) maintain a CRM opportunity
// and log every stage change as a CRM activity.
//
// ARCHITECTURE: All won/lost transitions must flow through resolveOpportunityOutcome().
// markOpportunityWon() and markOpportunityLost() in CRMStore are thin wrappers that
// delegate here. No view should mutate opp.stage = .won/.lost directly.

import Foundation

// MARK: - Opportunity Outcome / Source Types

enum OpportunityOutcome: Equatable {
    case won
    case lost
}

enum OutcomeSource: CustomStringConvertible {
    case crm
    case commercialQuote
    case commercialEstimate
    case projectConversion

    var description: String {
        switch self {
        case .crm:                return "CRM"
        case .commercialQuote:    return "Quote"
        case .commercialEstimate: return "Estimate"
        case .projectConversion:  return "Project Conversion"
        }
    }
}

extension AppStore {

    // MARK: - Central Win/Loss Handler
    //
    // ALL won/lost transitions must go through this function.
    // It updates the opportunity, syncs back to the linked quote and estimate,
    // logs CRM activity, and pushes every affected entity to Supabase.
    // Idempotent — safe to call multiple times.

    func resolveOpportunityOutcome(
        opportunityID: UUID,
        outcome:       OpportunityOutcome,
        source:        OutcomeSource,
        quoteID:       UUID? = nil,
        estimateID:    UUID? = nil,
        projectID:     UUID? = nil,
        reason:        String? = nil,
        competitor:    String? = nil,
        notes:         String? = nil
    ) {
        guard let oppIdx = crmOpportunities.firstIndex(where: {
            $0.id == opportunityID && !$0.isDeleted
        }) else { return }
        let live = crmOpportunities[oppIdx]

        // Idempotency guard
        if outcome == .won  && live.stage == .won  { return }
        if outcome == .lost && live.stage == .lost { return }

        // Prefer passed-in IDs; fall back to what's already on the opportunity
        let resolvedQuoteID    = quoteID    ?? live.quoteID
        let resolvedEstimateID = estimateID ?? live.estimateID
        let resolvedProjectID  = projectID  ?? live.projectID

        // Phase 1 PMI workflow gate: a .won outcome must have either
        // a linked Quote OR a linked Estimate. Pre-fix the bridge
        // would happily mark an opportunity Won with no commercial
        // backing — auto-creating a project with a `nil` budget and
        // no job number, which then orphaned in reporting. The lost
        // path doesn't need this gate (we want loss-reason capture
        // even on stale leads).
        //
        // The check pulls live store state so a quote/estimate that
        // exists but is soft-deleted doesn't count as "linked."
        if outcome == .won {
            let hasLiveQuote = resolvedQuoteID
                .flatMap { qid in quotes.first { $0.id == qid && !$0.isDeleted } } != nil
            let hasLiveEstimate = resolvedEstimateID
                .flatMap { eid in estimates.first { $0.id == eid && !$0.isDeleted } } != nil
            if !hasLiveQuote && !hasLiveEstimate {
                ToastService.shared.error(
                    "Can't mark Won — opportunity has no linked Quote or Estimate. Create one first, or link an existing one to this opportunity."
                )
                print("⚠️ resolveOpportunityOutcome rejected: opp \(opportunityID) has no live quote/estimate")
                return
            }
        }

        var updated = live
        let now = Date()

        switch outcome {

        case .won:
            updated.stage       = .won
            updated.wonAt       = now
            updated.lostAt      = nil
            updated.lossReason  = ""
            updated.probability = 100
            if let qid = resolvedQuoteID    { updated.quoteID    = qid }
            if let eid = resolvedEstimateID { updated.estimateID = eid }
            if let pid = resolvedProjectID  { updated.projectID  = pid }
            // Refresh value from the linked quote when not already set
            if updated.value == 0,
               let qid   = updated.quoteID,
               let quote  = quotes.first(where: { $0.id == qid }) {
                updated.value = quote.grandTotal
            }
            updated.updatedAt  = now
            updated.syncStatus = .pending
            crmOpportunities[oppIdx] = updated

            // ── Bidirectional: quote → accepted ──────────────────────────────
            if let qid  = updated.quoteID,
               let qIdx = quotes.firstIndex(where: { $0.id == qid && !$0.isDeleted }),
               quotes[qIdx].status != .accepted {
                var q        = quotes[qIdx]
                q.status     = .accepted
                q.acceptedAt = now
                q.syncStatus = .pending
                quotes[qIdx] = q
                Task { await SyncEngine.shared.pushPendingQuotes() }
            }

            // ── Bidirectional: estimate → awarded ────────────────────────────
            if let eid  = updated.estimateID,
               let eIdx = estimates.firstIndex(where: { $0.id == eid }),
               estimates[eIdx].status != .awarded {
                var e        = estimates[eIdx]
                e.status     = .awarded
                e.syncStatus = .pending
                estimates[eIdx] = e
                Task { await SyncEngine.shared.pushPendingEstimates() }
            }

            // ── Auto-create Project if not already linked ─────────────────────
            if updated.projectID == nil {
                let clientName = clients.first(where: { $0.id == updated.clientID })?.name
                    ?? updated.title
                var proj = Project(name: updated.title, clientName: clientName)
                proj.clientID    = updated.clientID
                proj.siteID      = nil
                proj.status      = .awarded
                proj.startDate   = Date()
                proj.siteAddress = updated.siteAddress.isEmpty ? nil : updated.siteAddress
                proj.syncStatus  = .pending
                proj.lastModifiedBy = currentUser?.fullName ?? ""

                // Pull job number and contract value from linked quote or estimate
                if let qid = updated.quoteID,
                   let q   = quotes.first(where: { $0.id == qid }) {
                    proj.jobNumber     = q.jobNumber
                    proj.contractValue = q.totalBeforeTax
                } else if let eid = updated.estimateID,
                          let e   = estimates.first(where: { $0.id == eid }) {
                    proj.jobNumber       = e.jobNumber
                    proj.contractValue   = updated.value > 0 ? updated.value : e.totalEstimated
                    proj.estimatedBudget = e.totalEstimated
                } else {
                    proj.jobNumber     = AppSettings.shared.nextJobNumber()
                    proj.contractValue = updated.value > 0 ? updated.value : nil
                }

                // Assign the currently logged-in user as PM if they have the right role
                if currentUserRole.canMarkWonLost {
                    proj.assignedPMID   = currentUser?.id
                    proj.assignedPMName = currentUser?.fullName
                }

                // Direct insert to bypass upsertProject's role guard (caller is already
                // role-gated upstream via canMarkWonLost / resolveOpportunityOutcome).
                projects.append(proj)
                Task { await SyncEngine.shared.pushPending() }
                updated.projectID = proj.id
                crmOpportunities[oppIdx] = updated

                logCRMActivity(
                    type:          .projectCreated,
                    title:         "Project auto-created: \(proj.name)",
                    notes:         "Job #\(proj.jobNumber ?? "—"). Contract: \(proj.contractValue?.currencyString ?? "TBD").",
                    clientID:      updated.clientID,
                    contactID:     updated.contactID,
                    opportunityID: updated.id,
                    quoteID:       updated.quoteID,
                    projectID:     proj.id
                )

                // ── Auto-create draft Contract from the won quote ────────
                // Surfaces the contract module right at the moment the
                // sale is won, while context is fresh. Idempotent — we
                // skip if a contract for this quote already exists.
                if let qid = updated.quoteID,
                   !contracts.contains(where: { $0.quoteID == qid && !$0.isDeleted }) {
                    let clientName = clients.first(where: { $0.id == updated.clientID })?.name ?? updated.title
                    var contract = Contract(
                        title:           updated.title.isEmpty ? "Owner contract for \(clientName)" : updated.title,
                        contractType:    .ownerPrime,
                        counterpartyName: clientName
                    )
                    contract.status            = .underReview
                    contract.counterpartyType  = .client
                    contract.counterpartyID    = updated.clientID
                    contract.projectID         = proj.id
                    contract.quoteID           = qid
                    if let q = quotes.first(where: { $0.id == qid }) {
                        contract.contractValue = q.totalBeforeTax
                    } else {
                        contract.contractValue = updated.value > 0 ? updated.value : nil
                    }
                    contract.effectiveDate     = Date()
                    upsertContract(contract)
                    logCRMActivity(
                        type:          .stageChanged,
                        title:         "Contract draft auto-created from accepted quote",
                        notes:         "Review key clauses + add milestones in the Contracts tab.",
                        clientID:      updated.clientID,
                        contactID:     updated.contactID,
                        opportunityID: updated.id,
                        quoteID:       updated.quoteID,
                        projectID:     proj.id
                    )
                }
            }

            // ── Reverse linkage: stamp quote.projectID and estimate.projectID ──
            // The bidirectional blocks above set quote.status=.accepted and
            // estimate.status=.awarded, but at that point the project hasn't
            // been auto-created yet (or the resolvedProjectID may have been
            // nil). Now that updated.projectID is fully resolved, write it
            // back to both the quote and the estimate so all four records
            // (opp, quote, estimate, project) are mutually linked.
            if let projID = updated.projectID {
                if let qid  = updated.quoteID,
                   let qIdx = quotes.firstIndex(where: { $0.id == qid && !$0.isDeleted }),
                   quotes[qIdx].projectID != projID {
                    quotes[qIdx].projectID  = projID
                    quotes[qIdx].syncStatus = .pending
                    Task { await SyncEngine.shared.pushPendingQuotes() }
                }
                if let eid  = updated.estimateID,
                   let eIdx = estimates.firstIndex(where: { $0.id == eid }),
                   estimates[eIdx].projectID != projID {
                    estimates[eIdx].projectID  = projID
                    estimates[eIdx].syncStatus = .pending
                    Task { await SyncEngine.shared.pushPendingEstimates() }
                }
            }

            // ── Handoff checklist — created once ─────────────────────────────
            if handoffChecklists.filter({ $0.opportunityID == opportunityID }).isEmpty {
                handoffChecklists.append(contentsOf:
                    HandoffChecklistItem.defaultChecklist(
                        opportunityID: opportunityID,
                        projectID: updated.projectID
                    )
                )
            }

            logCRMActivity(
                type:          .quoteWon,
                title:         "Opportunity won: \(updated.title)",
                notes:         "Value: \(updated.value.currencyString). Source: \(source).",
                clientID:      updated.clientID,
                contactID:     updated.contactID,
                opportunityID: updated.id,
                quoteID:       updated.quoteID,
                projectID:     updated.projectID
            )

        case .lost:
            let lossReason = reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Quote declined"
            updated.stage          = .lost
            updated.lostAt         = now
            updated.wonAt          = nil
            updated.lossReason     = lossReason
            updated.competitorName = competitor ?? live.competitorName
            if let n = notes, !n.isEmpty { updated.notes = n }
            updated.probability    = 0
            if let qid = resolvedQuoteID    { updated.quoteID    = qid }
            if let eid = resolvedEstimateID { updated.estimateID = eid }
            updated.projectID  = nil     // lost deals don't get a project
            updated.updatedAt  = now
            updated.syncStatus = .pending
            crmOpportunities[oppIdx] = updated

            // ── Bidirectional: quote → declined ──────────────────────────────
            if let qid  = updated.quoteID,
               let qIdx = quotes.firstIndex(where: { $0.id == qid && !$0.isDeleted }),
               quotes[qIdx].status != .declined {
                var q        = quotes[qIdx]
                q.status     = .declined
                q.syncStatus = .pending
                quotes[qIdx] = q
                Task { await SyncEngine.shared.pushPendingQuotes() }
            }

            // ── Bidirectional: estimate → lost ───────────────────────────────
            if let eid  = updated.estimateID,
               let eIdx = estimates.firstIndex(where: { $0.id == eid }),
               estimates[eIdx].status != .lost {
                var e        = estimates[eIdx]
                e.status     = .lost
                e.syncStatus = .pending
                estimates[eIdx] = e
                Task { await SyncEngine.shared.pushPendingEstimates() }
            }

            logCRMActivity(
                type:          .quoteLost,
                title:         "Opportunity lost: \(updated.title)",
                notes:         "Reason: \(lossReason). Competitor: \(updated.competitorName).",
                clientID:      updated.clientID,
                contactID:     updated.contactID,
                opportunityID: updated.id,
                quoteID:       updated.quoteID,
                projectID:     nil
            )
        }

        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
        saveCRMData()
    }

    // MARK: - Ensure CRM Link for Estimate
    //
    // Finds or creates a CRM opportunity linked to the given estimate and sets
    // `estimate.opportunityID`. Safe to call on every save — returns immediately
    // if the link already exists.

    @discardableResult
    func ensureCRMLink(for estimate: inout Estimate) -> CRMOpportunity? {
        // 1. Already linked and the opp still exists
        if let oppID = estimate.opportunityID,
           let existing = crmOpportunities.first(where: { $0.id == oppID && !$0.isDeleted }) {
            return existing
        }

        // 2. An opportunity on the CRM side already knows about this estimate
        if let existing = crmOpportunities.first(where: {
            $0.estimateID == estimate.id && !$0.isDeleted
        }) {
            estimate.opportunityID = existing.id
            return existing
        }

        // 3. No link exists — auto-create an opportunity from estimate metadata.
        //    Bypass upsertCRMOpportunity's role check since upsertEstimate already
        //    validated the caller's role. Insert directly and push.
        var opp           = CRMOpportunity(clientID: estimate.clientID)
        opp.title         = estimate.name
        opp.estimateID    = estimate.id
        opp.contactID     = estimate.primaryContactID
        opp.serviceType   = estimate.opportunityType.displayName
        opp.description   = estimate.scopeDescription ?? ""
        opp.value         = estimate.totalEstimated
        opp.stage         = .estimateRequired
        opp.probability   = OpportunityStage.estimateRequired.defaultProbability
        opp.source        = .directInquiry
        opp.assignedToID   = estimate.estimatorID ?? currentUser?.id
        opp.assignedToName = currentUser?.fullName ?? ""
        opp.syncStatus     = .pending
        opp.updatedAt      = Date()

        // Populate site address from the client record if available
        if let siteID = estimate.siteID,
           let client  = client(id: estimate.clientID),
           let site    = client.sites.first(where: { $0.id == siteID }) {
            let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
            opp.siteAddress = addr
        }

        crmOpportunities.append(opp)
        estimate.opportunityID = opp.id
        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }

        logCRMActivity(
            type:          .estimateCreated,
            title:         "Estimate created: \(estimate.name)",
            notes:         "Job #\(estimate.jobNumber). Estimated value: \(estimate.totalEstimated.currencyString). CRM opportunity auto-created.",
            clientID:      estimate.clientID,
            contactID:     estimate.primaryContactID,
            opportunityID: opp.id,
            quoteID:       nil,
            projectID:     nil
        )

        return opp
    }

    // MARK: - CRM Writeback: Quote Created
    //
    // Call when a Quote is created from an Estimate. Advances the linked opportunity
    // to .estimateRequired stage if it hasn't moved further, and logs the event.

    func handleQuoteCreated(_ quote: Quote) {
        let oppIdx = crmOpportunities.firstIndex(where: {
            !$0.isDeleted && (
                $0.quoteID     == quote.id         ||
                $0.estimateID  == quote.estimateID  ||
                ($0.clientID   == quote.clientID &&
                 $0.stage      == .estimateRequired)
            )
        })
        guard let idx = oppIdx else { return }
        var opp = crmOpportunities[idx]

        var changed = false
        if opp.quoteID == nil {
            opp.quoteID  = quote.id
            opp.updatedAt = Date()
            changed = true
        }
        // Advance stage to Follow-Up if still at Estimate stage
        if opp.stage == .estimateRequired || opp.stage == .contacted || opp.stage == .siteVisit {
            opp.stage       = .followUp
            opp.probability = OpportunityStage.followUp.defaultProbability
            opp.updatedAt   = Date()
            changed = true
        }
        if changed {
            opp.syncStatus = .pending
            upsertCRMOpportunity(opp)
        }

        logCRMActivity(
            type:          .quoteCreated,
            title:         "Quote created: \(quote.jobNumber)",
            notes:         "Total: \(quote.grandTotal.currencyString)",
            clientID:      quote.clientID,
            contactID:     opp.contactID,
            opportunityID: opp.id,
            quoteID:       quote.id,
            projectID:     nil
        )
    }

    // MARK: - CRM Writeback: Quote Accepted
    //
    // Called when a quote status transitions to `.accepted`. Finds the linked
    // opportunity and resolves it as Won via the central handler.

    func handleQuoteAccepted(_ quote: Quote) {
        guard let opp = crmOpportunities.first(where: {
            !$0.isDeleted && ($0.quoteID == quote.id || $0.estimateID == quote.estimateID)
        }) else { return }
        guard opp.stage != .won else { return }
        resolveOpportunityOutcome(
            opportunityID: opp.id,
            outcome:       .won,
            source:        .commercialQuote,
            quoteID:       quote.id,
            estimateID:    quote.estimateID,
            projectID:     quote.projectID
        )
    }

    // MARK: - CRM Writeback: Quote Declined
    //
    // Called when a quote status changes to `.declined`. Delegates to the central
    // handler which also marks the linked estimate lost and logs the event.

    func handleQuoteDeclined(_ quote: Quote, reason: String = "", notes: String = "") {
        guard let opp = crmOpportunities.first(where: {
            !$0.isDeleted && ($0.quoteID == quote.id || $0.estimateID == quote.estimateID)
        }) else { return }
        guard opp.stage != .lost else { return }
        resolveOpportunityOutcome(
            opportunityID: opp.id,
            outcome:       .lost,
            source:        .commercialQuote,
            quoteID:       quote.id,
            estimateID:    quote.estimateID,
            reason:        reason.isEmpty ? "Quote declined" : reason,
            notes:         notes.isEmpty  ? "Quote \(quote.jobNumber) was declined by the client." : notes
        )
    }

    // MARK: - CRM Writeback: Invoice Events

    /// Logs an invoice-created activity. Call from upsertInvoice for new invoices.
    func logInvoiceCreatedToCRM(_ invoice: Invoice) {
        // Find the best matching open/won opportunity for this client
        let opp = resolvedOpportunity(for: invoice)
        logCRMActivity(
            type:          .invoiceCreated,
            title:         "Invoice created: \(invoice.invoiceNumber)",
            notes:         "Amount: \(invoice.total.currencyString)",
            clientID:      invoice.clientID,
            contactID:     nil,
            opportunityID: opp?.id,
            quoteID:       nil,
            projectID:     invoice.projectID
        )
    }

    /// Logs a payment-received activity. Call when a payment is recorded on an invoice.
    func logPaymentReceivedToCRM(_ invoice: Invoice, amount: Decimal) {
        let opp = resolvedOpportunity(for: invoice)
        logCRMActivity(
            type:          .paymentReceived,
            title:         "Payment received: \(invoice.invoiceNumber)",
            notes:         "Payment: \(amount.currencyString). Invoice total: \(invoice.total.currencyString).",
            clientID:      invoice.clientID,
            contactID:     nil,
            opportunityID: opp?.id,
            quoteID:       nil,
            projectID:     invoice.projectID
        )
    }

    /// Finds the most relevant won/active CRM opportunity for an invoice.
    private func resolvedOpportunity(for invoice: Invoice) -> CRMOpportunity? {
        guard let clientID = invoice.clientID else { return nil }
        // Prefer project-linked won opportunity
        if let projID = invoice.projectID {
            if let opp = crmOpportunities.first(where: { $0.projectID == projID && !$0.isDeleted }) {
                return opp
            }
        }
        // Fall back to any won opportunity for this client
        return crmOpportunities.first(where: {
            $0.clientID == clientID && $0.stage == .won && !$0.isDeleted
        })
    }

    // MARK: - Material Sale CRUD

    func upsertMaterialSale(_ item: MaterialSale) {
        guard requireRole([.estimator, .projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_material_sale") else { return }
        let isNew = !materialSales.contains(where: { $0.id == item.id })
        let oldStatus = materialSales.first(where: { $0.id == item.id })?.status
        var updated           = item
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        updated.lastModifiedBy = currentUser?.fullName ?? ""

        // Auto-create a CRM opportunity when the sale is first saved.
        if isNew && updated.opportunityID == nil {
            ensureMaterialSaleCRMLink(for: &updated)
        }

        // Transition into .invoiced → auto-generate an Invoice and back-link it.
        // Idempotent: skip if invoiceID is already set, or if the new status is
        // not .invoiced, or if the previous status was already .invoiced.
        if updated.status == .invoiced,
           oldStatus != .invoiced,
           updated.invoiceID == nil {
            if let invoice = generateInvoice(from: updated) {
                updated.invoiceID = invoice.id
                addInvoice(invoice)
                logCRMActivity(
                    type: .invoiceCreated,
                    title: "Invoice auto-generated from \(updated.saleNumber)",
                    notes: "Material sale invoiced — \(invoice.total.currencyString)",
                    clientID: updated.clientID,
                    contactID: updated.contactID,
                    opportunityID: updated.opportunityID,
                    quoteID: updated.quoteID,
                    projectID: updated.projectID
                )
            }
        }

        if let index = materialSales.firstIndex(where: { $0.id == updated.id }) {
            materialSales[index] = updated
        } else {
            materialSales.append(updated)
        }
        Task { await SyncEngine.shared.pushPendingMaterialSales() }
    }

    /// Builds a draft Invoice mirroring a MaterialSale's line items.
    /// Returns nil if the sale has no line items (nothing to invoice).
    /// Caller is responsible for `addInvoice(...)` and back-linking `invoiceID`.
    private func generateInvoice(from sale: MaterialSale) -> Invoice? {
        guard !sale.lineItems.isEmpty else { return nil }
        let invoiceNumber = sale.saleNumber.isEmpty
            ? "INV-\(Int(Date().timeIntervalSince1970))"
            : "INV-\(sale.saleNumber)"
        var invoice = Invoice(invoiceNumber: invoiceNumber, projectID: sale.projectID)
        invoice.clientID    = sale.clientID
        invoice.companyID   = sale.companyID
        invoice.status      = .draft
        invoice.invoiceDate = Date()
        invoice.dueDate     = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        // MaterialSale.taxRate is percentage (5.0 = 5%); Invoice.taxRate is decimal (0.05).
        invoice.taxRate     = sale.taxRate / 100
        invoice.billToName  = client(id: sale.clientID)?.name ?? ""
        invoice.notes       = "Generated from material sale \(sale.saleNumber)."
        invoice.lineItems   = sale.lineItems.map {
            InvoiceLineItem(
                id:          UUID(),
                description: $0.description,
                quantity:    $0.quantity,
                unitPrice:   $0.unitPrice,
                taxable:     true
            )
        }
        return invoice
    }

    func deleteMaterialSale(_ item: MaterialSale) {
        guard requireRole([.manager, .executive], action: "delete_material_sale") else { return }
        guard let idx = materialSales.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = materialSales[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        materialSales[idx] = deleted
    }

    // MARK: - Material Sale CRM Auto-Link

    @discardableResult
    func ensureMaterialSaleCRMLink(for sale: inout MaterialSale) -> CRMOpportunity? {
        // Already linked?
        if let oppID = sale.opportunityID,
           let existing = crmOpportunities.first(where: { $0.id == oppID && !$0.isDeleted }) {
            return existing
        }

        var opp           = CRMOpportunity(clientID: sale.clientID)
        opp.title         = "\(sale.saleType.displayName) — \(sale.saleNumber.isEmpty ? "New Sale" : sale.saleNumber)"
        opp.contactID     = sale.contactID
        opp.serviceType   = sale.saleType.displayName
        opp.value         = sale.grandTotal
        opp.stage         = .estimateRequired
        opp.probability   = OpportunityStage.estimateRequired.defaultProbability
        opp.source        = .directInquiry
        opp.assignedToID   = currentUser?.id
        opp.assignedToName = currentUser?.fullName ?? ""
        opp.syncStatus     = .pending
        opp.updatedAt      = Date()

        if let siteID = sale.siteID,
           let client  = client(id: sale.clientID),
           let site    = client.sites.first(where: { $0.id == siteID }) {
            let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
            opp.siteAddress = addr
        } else if let addr = sale.deliveryAddress {
            opp.siteAddress = addr
        }

        crmOpportunities.append(opp)
        sale.opportunityID = opp.id
        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }

        logCRMActivity(
            type:          .materialSaleCreated,
            title:         "Material sale created: \(sale.saleType.displayName)",
            notes:         "Sale #\(sale.saleNumber). Value: \(sale.grandTotal.currencyString). CRM opportunity auto-created.",
            clientID:      sale.clientID,
            contactID:     sale.contactID,
            opportunityID: opp.id,
            quoteID:       nil,
            projectID:     nil
        )

        return opp
    }

    // MARK: - Phase 1 Step 5: Material Sale CRM Backfill
    //
    // Result of `backfillMaterialSaleLinkage` — surfaced in the dev-menu
    // diagnostic so an admin running the action sees exactly how many
    // sales were linked and how many were skipped (e.g. soft-deleted
    // rows, missing client, etc.).
    struct MaterialSaleBackfillResult: Equatable {
        let inspected: Int
        let linked:    Int
        let skipped:   Int
    }

    /// Iterate every Material Sale for the current tenant whose
    /// `opportunityID` is nil and run `ensureMaterialSaleCRMLink` on
    /// each, persisting the resulting linkage. Idempotent — sales that
    /// already have an opportunity are not touched. Soft-deleted sales
    /// are skipped (they shouldn't appear in CRM at all). Sales whose
    /// `clientID` no longer resolves are skipped and counted as such.
    ///
    /// PHASE-1 VERIFIED (Step 5): closes the gap identified in the v3
    /// audit where existing sales created before the auto-link wiring
    /// remained CRM-invisible. Restricted to executive/owner — see the
    /// dev-menu surface gate.
    @discardableResult
    func backfillMaterialSaleLinkage() -> MaterialSaleBackfillResult {
        let candidates = materialSales.filter {
            !$0.isDeleted && $0.opportunityID == nil
        }
        var linked  = 0
        var skipped = 0
        for var sale in candidates {
            // Defensive: confirm the client still exists in this tenant.
            guard clients.contains(where: { $0.id == sale.clientID && !$0.isDeleted }) else {
                print("⚠️ backfillMaterialSaleLinkage skip — orphan client for sale \(sale.id)")
                skipped += 1
                continue
            }
            _ = ensureMaterialSaleCRMLink(for: &sale)
            // Re-stamp the in-memory sale with the new opportunityID.
            if let idx = materialSales.firstIndex(where: { $0.id == sale.id }) {
                sale.syncStatus = .pending
                materialSales[idx] = sale
                linked += 1
            }
        }
        if linked > 0 {
            saveToDisk()
            Task { await SyncEngine.shared.pushPendingMaterialSales() }
        }
        return MaterialSaleBackfillResult(
            inspected: candidates.count,
            linked:    linked,
            skipped:   skipped
        )
    }

    // MARK: - Material Sale Queries

    func materialSales(for clientID: UUID) -> [MaterialSale] {
        materialSales.filter { $0.clientID == clientID && !$0.isDeleted }
    }

    var openMaterialSales: [MaterialSale] {
        materialSales.filter { $0.status.isActive && !$0.isDeleted }
    }

    var materialSaleCount: Int {
        materialSales.filter { !$0.isDeleted }.count
    }

    /// Generate the next material-sale number. Phase 3 hardening:
    /// already used parsed-max+1 (good), tightened with companyID +
    /// !isDeleted filters and switched the year filter from createdAt
    /// to saleNumber prefix-match for consistency with the other
    /// modules. DB-side partial unique index on
    /// (company_id, sale_number) WHERE is_deleted = false (MS1
    /// migration) catches cross-device races.
    func nextSaleNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let yearPrefix = "MS-\(year)-"
        let maxExisting = materialSales
            .filter { $0.companyID == currentCompanyID && !$0.isDeleted }
            .compactMap { ms -> Int? in
                guard ms.saleNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(ms.saleNumber.dropFirst(yearPrefix.count))
            }
            .max() ?? 0
        return String(format: "MS-%d-%04d", year, maxExisting + 1)
    }
}
