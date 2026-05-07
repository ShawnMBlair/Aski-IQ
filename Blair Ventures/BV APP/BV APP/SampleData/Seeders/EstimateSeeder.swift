// EstimateSeeder.swift
// Aski IQ — Loads sample Estimates.
//
// FK consumers:
//   - clientID_ref       → Clients (required)
//   - opportunityID_ref  → CRM Opportunities (optional; resolves only if
//                          OpportunitySeeder has run; nil otherwise)
//   - projectID_ref      → Projects (optional; ProjectSeeder runs FIRST in
//                          the orchestrator so won-estimate links resolve)
//
// Calls existing service `upsertEstimate` so RLS, validation, sync, and
// the CRM bridge (which auto-links a CRM opp when none exists) all run.

import Foundation

@MainActor
struct EstimateSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Estimates" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey    = row.ref,
                  let jobNumber = row.string("jobNumber"),
                  let name      = row.string("name") else { continue }

            // FK — required
            guard let clientRef = row.refField("clientID_ref") else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing clientID_ref>", sourceTab: tabName)
            }
            let clientID = try s.resolver.requireUUID(for: clientRef, sourceTab: tabName)

            // Build the model — synthesized memberwise init covers
            // required fields; everything else assigned below.
            var est = Estimate(jobNumber: jobNumber, clientID: clientID, name: name)
            est.id           = UUID()
            est.companyID    = s.batch.companyID

            // Optional FKs — best-effort resolution
            est.opportunityID = row.refField("opportunityID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            est.projectID     = row.refField("projectID_ref")
                .flatMap { s.resolver.uuid(for: $0) }

            // Status + classification
            est.status          = row.swiftEnum("status",          type: EstimateStatus.self) ?? .estimating
            est.opportunityType = row.swiftEnum("opportunityType", type: OpportunityType.self) ?? .rfq
            est.pricingType     = row.swiftEnum("pricingType",     type: PricingType.self)     ?? .lumpSum
            est.revisionNumber  = row.int("revisionNumber") ?? 1

            // Dates (relative T-N / T+N tokens resolve against the
            // batch's createdAt so the dataset is reproducible)
            let now = s.batch.createdAt
            est.rfqReceivedDate    = try row.relativeDate("rfqReceivedDate_rel", now: now)
            est.bidDueDate         = try row.relativeDate("bidDueDate_rel",      now: now)
            est.submittedDate      = try row.relativeDate("submittedDate_rel",   now: now)
            est.awardedDate        = try row.relativeDate("awardedDate_rel",     now: now)
            est.internalApprovedAt = try row.relativeDate("internalApprovedAt_rel", now: now)

            // Pricing
            est.awardedValue       = row.decimal("awardedValue")
            est.contingencyPercent = row.decimal("contingencyPercent") ?? 0
            est.overheadPercent    = row.decimal("overheadPercent")    ?? 0
            est.profitPercent      = row.decimal("profitPercent")      ?? 0

            // Narrative
            est.scopeDescription = row.string("scopeDescription")
            est.notes            = row.string("notes")
            est.internalNotes    = row.string("internalNotes")
            est.internalReviewBy = row.string("internalReviewBy")

            // Loss tracking — only meaningful when status == .lost
            est.lossReason     = row.swiftEnum("lossReason", type: LossReason.self)
            est.competitorName = row.string("competitorName")
            est.winLossNotes   = row.string("winLossNotes")

            // Sample-data stamp
            s.stamp(&est)

            // Register BEFORE persisting so QuoteSeeder (which runs after)
            // can resolve estimateID_ref in one pass.
            s.resolver.register(refKey: refKey, uuid: est.id, tab: tabName)

            store.upsertEstimate(est)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
