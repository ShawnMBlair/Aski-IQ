// SampleDataResetService.swift
// Aski IQ — Calls the `clear_sample_data` Postgres RPC.
//
// Encapsulates:
//   - Auth gate (executive only — RPC enforces server-side too)
//   - Typed-confirmation phrase check (fast-fail before round-trip)
//   - Per-table delete count parsing
//   - In-memory store cleanup so the UI reflects the wipe immediately
//   - Active-batch UserDefaults cleanup
//   - Spotlight purge for the cleared records
//
// Two callers:
//   - Settings UI Clear button (source: .userClear)
//   - Seeder rollback on a failed load (source: .seederRollback)

import Foundation
import Combine
import Supabase

@MainActor
final class SampleDataResetService {

    static let shared = SampleDataResetService()
    private init() {}

    enum CallSource {
        case userClear
        case seederRollback
    }

    struct ResetResult {
        let perTableCounts: [String: Int]
        var totalDeleted: Int { perTableCounts.values.reduce(0, +) }
    }

    /// Execute the reset. Throws on any failure (caller decides whether to surface).
    func clear(
        companyID:     UUID,
        batchID:       UUID,
        store:         AppStore,
        source:        CallSource,
        confirmPhrase: String = "DELETE SAMPLE DATA"
    ) async throws -> ResetResult {

        // Local guard — defends against a UI bug; server enforces too.
        guard confirmPhrase == "DELETE SAMPLE DATA" else {
            throw SampleDataError.confirmationPhraseMismatch
        }

        // Local guard — caller must be executive (server enforces too).
        // The seeder rollback path also uses an executive (whoever loaded).
        guard store.currentUserRole == .executive else {
            throw SampleDataError.notAuthorized(
                role: store.currentUserRole.rawValue,
                allowed: [UserRole.executive.rawValue]
            )
        }

        // Call the RPC
        let response: [PerTableCount]
        do {
            response = try await supabase.rpc(
                "clear_sample_data",
                params: [
                    "p_company_id":     companyID.uuidString,
                    "p_batch_id":       batchID.uuidString,
                    "p_confirm_phrase": confirmPhrase
                ]
            ).execute().value
        } catch {
            throw SampleDataError.resetRpcFailed(underlying: error)
        }

        let counts = Dictionary(uniqueKeysWithValues:
            response.map { ($0.tableName, Int($0.rowsDeleted)) })

        // Sanity check — if user invoked clear but nothing was deleted,
        // surface that. (Seeder rollback may legitimately delete zero.)
        if source == .userClear, counts.values.allSatisfy({ $0 == 0 }) {
            throw SampleDataError.clearedNothing
        }

        // Local cleanup — wipe the in-memory arrays of any sample row.
        // We rely on each model's `isSampleData` flag to filter; SyncEngine
        // will subsequently pull the (now-empty) server state.
        purgeInMemorySampleRows(in: store, batchID: batchID)

        // Drop active-batch tracking
        SampleDataActiveBatch.clear(companyID: companyID)

        // Spotlight purge
        SpotlightService.shared.deleteAll()  // safest — re-index runs on next refresh

        return ResetResult(perTableCounts: counts)
    }

    // MARK: - Private

    private func purgeInMemorySampleRows(in store: AppStore, batchID: UUID) {
        // Iterate every @Published collection that holds a SampleDataTrackable
        // type and remove rows whose batchID matches.
        // (One block per array — easier to extend than reflection.)
        store.clients          .removeAll { $0.matchesBatch(batchID) }
        store.projects         .removeAll { $0.matchesBatch(batchID) }
        store.estimates        .removeAll { $0.matchesBatch(batchID) }
        store.quotes           .removeAll { $0.matchesBatch(batchID) }
        store.changeOrders     .removeAll { $0.matchesBatch(batchID) }
        store.invoices         .removeAll { $0.matchesBatch(batchID) }
        store.materialSales    .removeAll { $0.matchesBatch(batchID) }
        store.materialRequests .removeAll { $0.matchesBatch(batchID) }
        store.purchaseOrders   .removeAll { $0.matchesBatch(batchID) }
        store.suppliers        .removeAll { $0.matchesBatch(batchID) }
        store.subcontractors   .removeAll { $0.matchesBatch(batchID) }
        store.subContracts     .removeAll { $0.matchesBatch(batchID) }
        store.contracts        .removeAll { $0.matchesBatch(batchID) }
        store.lienWaivers      .removeAll { $0.matchesBatch(batchID) }
        store.projectBudgets   .removeAll { $0.matchesBatch(batchID) }
        store.rfis             .removeAll { $0.matchesBatch(batchID) }
        store.equipment        .removeAll { $0.matchesBatch(batchID) }
        store.crews            .removeAll { $0.matchesBatch(batchID) }
        store.scheduleEntries  .removeAll { $0.matchesBatch(batchID) }
        store.timesheetEntries .removeAll { $0.matchesBatch(batchID) }
        store.exceptionLogs    .removeAll { $0.matchesBatch(batchID) }
        store.incidents        .removeAll { $0.matchesBatch(batchID) }
        store.formSubmissions  .removeAll { $0.matchesBatch(batchID) }
        store.crmContacts      .removeAll { $0.matchesBatch(batchID) }
        store.crmOpportunities .removeAll { $0.matchesBatch(batchID) }
        store.crmTasks         .removeAll { $0.matchesBatch(batchID) }
        store.crmActivities    .removeAll { $0.matchesBatch(batchID) }
        store.crmAttachments   .removeAll { $0.matchesBatch(batchID) }
        store.handoffChecklists.removeAll { $0.matchesBatch(batchID) }
        store.employees        .removeAll { $0.matchesBatch(batchID) }
        // DJRs persist in UserDefaults — handled by the seeder pattern when
        // we add isSampleData to DailyJobReport.
        store.objectWillChange.send()
    }

    // MARK: - Decoding shape

    private struct PerTableCount: Decodable {
        let tableName:    String
        let rowsDeleted:  Int

        enum CodingKeys: String, CodingKey {
            case tableName   = "table_name"
            case rowsDeleted = "rows_deleted"
        }
    }
}

// MARK: - Trackable batch matcher

extension SampleDataTrackable {
    /// True iff this record was loaded under the given batch.
    func matchesBatch(_ batchID: UUID) -> Bool {
        isSampleData && sampleDataBatchID == batchID
    }
}
