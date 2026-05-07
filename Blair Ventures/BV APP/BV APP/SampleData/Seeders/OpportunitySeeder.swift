// OpportunitySeeder.swift
// Aski IQ — Loads sample CRM Opportunities.
//
// FK consumers:
//   - clientID_ref       → Clients (REQUIRED)
//   - contactID_ref      → CRMContacts (optional; resolves only if
//                          ContactSeeder has run — Batch 2)
//   - projectID_ref      → Projects (optional; ProjectSeeder runs FIRST
//                          in Phase B so won-opp links resolve)
//   - estimateID_ref     → Estimates (optional; circular — Estimate seeds
//                          AFTER Opportunity, so this resolves to nil
//                          on first pass. Set by EstimateSeeder via
//                          ensureCRMLink rebound or by a future backfill
//                          pass; not a blocker for the test loop.)
//
// WHY THIS SEEDER MATTERS
// EstimateSeeder calls upsertEstimate, which auto-creates a CRM
// opportunity via ensureCRMLink when no `opportunityID` is set. Without
// this seeder, those auto-created opportunities are NOT flagged as
// sample data and survive Clear Sample Data — contaminating the tenant.
//
// By seeding opportunities FIRST and registering each __ref → UUID,
// EstimateSeeder finds the parent opportunity via `opportunityID_ref`
// and skips the auto-link path entirely.

import Foundation

@MainActor
struct OpportunitySeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Opportunities" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey = row.ref else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing __ref>", sourceTab: tabName)
            }

            // FK — required
            guard let clientRef = row.refField("clientID_ref") else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing clientID_ref>", sourceTab: tabName)
            }
            let clientID = try s.resolver.requireUUID(for: clientRef, sourceTab: tabName)

            // Build the model — synthesized memberwise init covers it
            var opp = CRMOpportunity(clientID: clientID)
            opp.id        = UUID()
            opp.companyID = s.batch.companyID

            // Identity + classification
            opp.title       = row.string("title") ?? ""
            opp.stage       = row.swiftEnum("stage",  type: OpportunityStage.self) ?? .newLead
            opp.serviceType = row.string("serviceType") ?? ""
            opp.siteAddress = row.string("siteAddress") ?? ""
            opp.description = row.string("description") ?? ""
            opp.notes       = row.string("notes")       ?? ""

            // Pricing
            opp.value       = row.decimal("value") ?? 0
            opp.probability = row.int("probability") ?? defaultProbability(for: opp.stage)

            // People + source
            opp.assignedToName = row.string("assignedToName") ?? ""
            opp.assignedToID   = row.refField("assignedToID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            opp.source         = row.swiftEnum("source", type: LeadSource.self) ?? .directInquiry

            // Loss tracking — only meaningful when stage == .lost
            opp.lossReason     = row.string("lossReason")     ?? ""
            opp.competitorName = row.string("competitorName") ?? ""

            // Optional FKs
            opp.contactID  = row.refField("contactID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            opp.projectID  = row.refField("projectID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            opp.estimateID = row.refField("estimateID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            opp.quoteID    = row.refField("quoteID_ref")
                .flatMap { s.resolver.uuid(for: $0) }

            // Dates (relative T-N tokens resolve against batch.createdAt)
            let now = s.batch.createdAt
            opp.createdAt      = try row.relativeDate("createdAt_rel",      now: now) ?? now
            opp.updatedAt      = try row.relativeDate("updatedAt_rel",      now: now) ?? opp.createdAt
            opp.estimatedStart = try row.relativeDate("estimatedStart_rel", now: now)
            opp.wonAt          = try row.relativeDate("wonAt_rel",          now: now)
            opp.lostAt         = try row.relativeDate("lostAt_rel",         now: now)

            // Sample-data stamp
            s.stamp(&opp)

            // Register BEFORE persisting so EstimateSeeder (which runs
            // AFTER OpportunitySeeder per the orchestrator) can resolve
            // est.opportunityID_ref to this UUID — preventing the
            // ensureCRMLink auto-link path that would otherwise create
            // a non-sample shadow opportunity.
            s.resolver.register(refKey: refKey, uuid: opp.id, tab: tabName)

            store.upsertCRMOpportunity(opp)
            s.recordInsert(tab: tabName)
        }
    }

    /// Heuristic probability when not specified in the workbook.
    /// Mirrors what a PM would set manually based on stage.
    private func defaultProbability(for stage: OpportunityStage) -> Int {
        switch stage {
        case .newLead:          return 10
        case .contacted:        return 20
        case .siteVisit:        return 35
        case .estimateRequired: return 50
        case .quoteSent:        return 65
        case .followUp:         return 75
        case .won:              return 100
        case .lost:             return 0
        }
    }

    private var store: AppStore { s.store }
}
