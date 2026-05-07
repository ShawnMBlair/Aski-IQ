// SampleDataSeeder.swift
// Aski IQ — Orchestrator that loads the canonical sample dataset
// into the current authenticated tenant.
//
// Flow (matches §5 Load Workflow of the architecture doc):
//   1. Pre-flight (auth + role + no active batch + manifest compatibility)
//   2. Reserve batch metadata
//   3. Parse JSON dataset
//   4. For each module in topological order, run the module-specific
//      seeder. Each seeder generates UUIDs, stamps the batch metadata,
//      registers refs with the resolver, and calls existing upsertX(_:)
//      services so RLS / sync / automation all run identically.
//   5. Post-flight: persist active batch ID, emit toast, return result.
//
// Failure handling: any thrown error rolls back via the
// `clear_sample_data` RPC using the in-flight batch ID.

import Foundation

@MainActor
final class SampleDataSeeder {

    // MARK: Inputs
    let store:    AppStore
    let dataset:  ParsedDataset
    let resolver = SampleDataReferenceResolver()

    // MARK: Computed at init
    let batch:    SampleDataBatch
    let isoVersion: String  // bundled app version

    // MARK: Counters
    private var perModule: [String: Int] = [:]

    // MARK: Init

    /// Throws if caller isn't authenticated, isn't an admin, or the
    /// dataset is incompatible with the current app version.
    init(store: AppStore, dataset: ParsedDataset, currentAppVersion: String) throws {
        guard let companyID = store.currentCompanyID,
              let user      = store.currentUser else {
            throw SampleDataError.notAuthenticated
        }
        let role = store.currentUserRole
        let allowedRoles: [UserRole] = [.executive, .officeAdmin]
        guard allowedRoles.contains(role) else {
            throw SampleDataError.notAuthorized(
                role: role.rawValue,
                allowed: allowedRoles.map(\.rawValue)
            )
        }
        if let active = SampleDataActiveBatch.get(companyID: companyID) {
            throw SampleDataError.batchAlreadyActive(existing: active)
        }
        try SampleDataParser.preflight(dataset, currentAppVersion: currentAppVersion)

        self.store      = store
        self.dataset    = dataset
        self.isoVersion = currentAppVersion
        self.batch = SampleDataBatch(
            id:          UUID(),
            seedVersion: dataset.manifest.seedVersion,
            datasetName: dataset.manifest.datasetName,
            companyID:   companyID,
            createdAt:   Date(),
            createdBy:   user.id
        )
    }

    // MARK: Run

    /// Top-level load. Returns when every module seeder has finished.
    ///
    /// FK ORDER NOTES
    /// - Projects must seed BEFORE Estimates/Quotes/COs so `projectID_ref`
    ///   resolves without a backfill pass.
    /// - Opportunities (when implemented) seed AFTER Projects so won-opp
    ///   `projectID_ref` resolves.
    /// - Lines / details seed after their parents (estimates → estimate lines,
    ///   etc.) so `*_id_ref` resolves.
    ///
    /// BATCH STATUS
    /// Active seeders (Batch 1 vertical slice): Client, Employee, Project,
    /// Estimate, Quote, ChangeOrder. All others are commented out and will
    /// be re-enabled in Batch 2+.
    func load() async throws -> SampleDataLoadResult {
        let started = Date()

        do {
            // Phase A — Foundations
            try ClientSeeder        (s: self).run()
            // try ClientSiteSeeder    (s: self).run()         // Batch 2
            // try ContactSeeder       (s: self).run()         // Batch 2
            try EmployeeSeeder      (s: self).run()
            // try CrewSeeder          (s: self).run()         // Batch 3
            // try CostCodeSeeder      (s: self).run()         // Batch 2
            // try ProductServiceSeeder(s: self).run()         // Batch 2
            // try VendorSeeder        (s: self).run()         // Batch 2
            // try SubcontractorSeeder (s: self).run()         // Batch 2
            // try EquipmentSeeder     (s: self).run()         // Batch 3
            // try CertificateSeeder   (s: self).run()         // Batch 3
            // try ClientPricingSeeder (s: self).run()         // Batch 3

            // Phase B — Projects (must run BEFORE estimates/quotes/COs)
            try ProjectSeeder       (s: self).run()

            // Phase C — Sales pipeline
            // OpportunitySeeder MUST run before EstimateSeeder.
            // Otherwise upsertEstimate's ensureCRMLink auto-creates
            // non-sample CRM opportunities for every sample estimate
            // that lacks an opportunityID — they survive Clear and
            // contaminate the tenant.
            try OpportunitySeeder   (s: self).run()
            try EstimateSeeder      (s: self).run()
            // try EstimateLineSeeder  (s: self).run()         // Batch 2
            try QuoteSeeder         (s: self).run()
            // try QuoteLineSeeder     (s: self).run()         // Batch 2

            // Phase D — Project transactions
            // try ProjectBudgetSeeder      (s: self).run()    // Batch 4
            // try ProjectBudgetLineSeeder  (s: self).run()    // Batch 4
            // try SubcontractSeeder        (s: self).run()    // Batch 3
            // try ScheduleSeeder           (s: self).run()    // Batch 4
            // try TimesheetSeeder          (s: self).run()    // Batch 4
            // try MaterialRequestSeeder    (s: self).run()    // Batch 3
            // try MaterialRequestLineSeeder(s: self).run()    // Batch 3
            // try PurchaseOrderSeeder      (s: self).run()    // Batch 3
            // try PurchaseOrderLineSeeder  (s: self).run()    // Batch 3
            // try RFISeeder                (s: self).run()    // Batch 5
            try ChangeOrderSeeder        (s: self).run()
            // try ChangeOrderLineSeeder    (s: self).run()    // Batch 5

            // Phase E — Field reporting + safety
            // try DJRSeeder           (s: self).run()         // Batch 4
            // try IncidentSeeder      (s: self).run()         // Batch 4
            // try SafetyRecordSeeder  (s: self).run()         // Batch 4

            // Phase F — Billing + closeout
            // try InvoiceSeeder       (s: self).run()         // Batch 5
            // try InvoiceLineSeeder   (s: self).run()         // Batch 5
            // try LienWaiverSeeder    (s: self).run()         // Batch 5
            // try MaterialSaleSeeder  (s: self).run()         // Batch 3
            // try MaterialSaleLineSeeder(s: self).run()       // Batch 3

            // Phase G — CRM peripherals + docs
            // try CRMTaskSeeder       (s: self).run()         // Batch 5
            // try CRMActivitySeeder   (s: self).run()         // Batch 5
            // try HandoffSeeder       (s: self).run()         // Batch 5
            // try DocumentSeeder      (s: self).run()         // Batch 5
        } catch {
            // Best-effort rollback — call the reset RPC for this batch.
            await self.rollback()
            throw error
        }

        // Persist active batch ID so the Settings UI knows which batch
        // to clear. Switching tenants reads a different key.
        SampleDataActiveBatch.set(batch.id, companyID: batch.companyID)

        return SampleDataLoadResult(
            batch:           batch,
            perModuleCounts: perModule,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: API for module seeders

    /// Look up a tab's rows. Returns empty if absent (so seeders can be
    /// no-ops on legacy datasets).
    func rows(for tab: String) -> [ParsedDataset.Row] {
        dataset.tabs[tab] ?? []
    }

    /// Increment the per-module counter; called once per inserted row.
    func recordInsert(tab: String) {
        perModule[tab, default: 0] += 1
    }

    /// Apply standard sample-data metadata + tenant scope to a record.
    /// Module seeders call this immediately before persisting.
    func stamp<T>(_ record: inout T) where T: SampleDataTrackable {
        record.stamp(batch: batch)
    }

    // MARK: Rollback

    private func rollback() async {
        // Use the same RPC the user-facing reset uses. The batch ID is
        // ours; we pass the typed phrase ourselves.
        do {
            _ = try await SampleDataResetService.shared.clear(
                companyID: batch.companyID,
                batchID:   batch.id,
                store:     store,
                source:    .seederRollback
            )
        } catch {
            // Don't shadow the original failure — log and move on.
            print("⚠️ SampleDataSeeder rollback failed: \(error)")
        }
    }
}

// MARK: - Module seeder protocol

@MainActor
protocol SampleDataModuleSeeder {
    var s: SampleDataSeeder { get }
    var tabName: String { get }
    func run() throws
}
