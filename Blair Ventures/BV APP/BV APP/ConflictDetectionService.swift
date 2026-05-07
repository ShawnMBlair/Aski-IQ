// ConflictDetectionService.swift
// Aski IQ — Pre-push concurrent-edit detection (deferred Phase 2 minimal).
//
// THE GAP THIS CLOSES
// Until now every upsert was last-write-wins: device A and device B
// open the same project, both edit different fields, both save —
// whichever pushes second silently overwrites the first. The 2026-04
// audit deferred true 3-way merge as needing a server-side
// concurrent-edit signal first.
//
// THIS FILE
// A pragmatic minimum: BEFORE we push a local edit, query the row's
// `updated_at` on the server and compare to the timestamp we held
// when the user started editing. If the server moved forward in the
// meantime, we have a conflict — return a typed result the caller
// can route to a UI for resolution.
//
// SCOPE
// Currently covers Project. Same pattern can extend to other
// entities by mirroring the per-table fetch helper. We keep it
// narrow so the first version ships clean.
//
// USAGE
//   let result = try await ConflictDetectionService.shared.checkProject(
//       id: project.id,
//       baselineUpdatedAt: editingStartedAt
//   )
//   switch result {
//   case .clean:
//       store.upsertProject(localProject)
//   case .conflict(let serverProject):
//       presentConflictSheet(local: localProject, server: serverProject)
//   case .notFound:
//       presentDeletedAlert()
//   }

import Foundation
import Supabase

@MainActor
final class ConflictDetectionService {

    static let shared = ConflictDetectionService()
    private init() {}

    // MARK: - Result

    enum CheckResult<T> {
        /// Server's timestamp matches what we expected — safe to push.
        case clean
        /// Server moved forward since we started editing. Carries the
        /// freshly-pulled server copy so the UI can show both sides.
        case conflict(server: T)
        /// The row no longer exists on the server (deleted there).
        /// Caller should ask the user whether to re-create or discard.
        case notFound
        /// Transport / decoding error. We default to "let the push go"
        /// on transport errors rather than block the user from saving
        /// in offline-flaky conditions; the failed-sync banner covers
        /// the actual write failure.
        case checkFailed(Error)
    }

    // MARK: - Project conflict check

    /// Compares server `updated_at` for the given project against
    /// the baseline timestamp the iOS form held when the user
    /// started editing. Anything strictly later means another
    /// device/user wrote in the meantime.
    func checkProject(
        id:                UUID,
        baselineUpdatedAt: Date
    ) async -> CheckResult<Project> {
        struct Row: Decodable {
            let id: String
            let name: String
            let client_name: String?
            let updated_at: String?
            let last_modified_by: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from(SupabaseTable.projects)
                .select("id,name,client_name,updated_at,last_modified_by")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  let serverID = UUID(uuidString: row.id) else {
                return .notFound
            }

            let serverTs = parseTimestamp(row.updated_at)

            if serverTs > baselineUpdatedAt.addingTimeInterval(1.0) {
                var stub = Project(
                    name:       row.name,
                    clientName: row.client_name ?? ""
                )
                stub.id             = serverID
                stub.updatedAt      = serverTs
                stub.lastModifiedBy = row.last_modified_by ?? ""
                return .conflict(server: stub)
            }
            return .clean
        } catch {
            return .checkFailed(error)
        }
    }

    // MARK: - Quote conflict check
    //
    // Same pattern as `checkProject`. Used by QuoteDetailView /
    // QuoteCreateView before they push edits, so two estimators
    // poking at the same quote concurrently see a real prompt
    // instead of last-write-wins.
    func checkQuote(
        id:                UUID,
        baselineUpdatedAt: Date
    ) async -> CheckResult<Quote> {
        struct Row: Decodable {
            let id: String
            let job_number: String
            let estimate_id: String?
            let client_id: String?
            let client_name: String?
            let prepared_by: String?
            let updated_at: String?
            let last_modified_by: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from(SupabaseTable.quotes)
                .select("id,job_number,estimate_id,client_id,client_name,prepared_by,updated_at,last_modified_by")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  let serverID   = UUID(uuidString: row.id),
                  let estimateID = row.estimate_id.flatMap({ UUID(uuidString: $0) }),
                  let clientID   = row.client_id.flatMap({ UUID(uuidString: $0) })
            else {
                return .notFound
            }

            let serverTs = parseTimestamp(row.updated_at)

            if serverTs > baselineUpdatedAt.addingTimeInterval(1.0) {
                var stub = Quote(
                    jobNumber:  row.job_number,
                    estimateID: estimateID,
                    clientID:   clientID,
                    clientName: row.client_name ?? "",
                    preparedBy: row.prepared_by ?? ""
                )
                stub.id             = serverID
                stub.updatedAt      = serverTs
                stub.lastModifiedBy = row.last_modified_by ?? ""
                return .conflict(server: stub)
            }
            return .clean
        } catch {
            return .checkFailed(error)
        }
    }

    // MARK: - Invoice conflict check

    func checkInvoice(
        id:                UUID,
        baselineUpdatedAt: Date
    ) async -> CheckResult<Invoice> {
        struct Row: Decodable {
            let id: String
            let invoice_number: String
            let updated_at: String?
            let last_modified_by: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from(SupabaseTable.invoices)
                .select("id,invoice_number,updated_at,last_modified_by")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  let serverID = UUID(uuidString: row.id) else {
                return .notFound
            }

            let serverTs = parseTimestamp(row.updated_at)

            if serverTs > baselineUpdatedAt.addingTimeInterval(1.0) {
                var stub = Invoice(invoiceNumber: row.invoice_number)
                stub.id             = serverID
                stub.updatedAt      = serverTs
                stub.lastModifiedBy = row.last_modified_by ?? ""
                return .conflict(server: stub)
            }
            return .clean
        } catch {
            return .checkFailed(error)
        }
    }

    // MARK: - Estimate conflict check

    func checkEstimate(
        id:                UUID,
        baselineUpdatedAt: Date
    ) async -> CheckResult<Estimate> {
        struct Row: Decodable {
            let id: String
            let job_number: String
            let client_id: String?
            let name: String
            let updated_at: String?
            let last_modified_by: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from(SupabaseTable.estimates)
                .select("id,job_number,client_id,name,updated_at,last_modified_by")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  let serverID = UUID(uuidString: row.id),
                  let clientID = row.client_id.flatMap({ UUID(uuidString: $0) })
            else {
                return .notFound
            }

            let serverTs = parseTimestamp(row.updated_at)

            if serverTs > baselineUpdatedAt.addingTimeInterval(1.0) {
                var stub = Estimate(
                    jobNumber: row.job_number,
                    clientID:  clientID,
                    name:      row.name
                )
                stub.id             = serverID
                stub.updatedAt      = serverTs
                stub.lastModifiedBy = row.last_modified_by ?? ""
                return .conflict(server: stub)
            }
            return .clean
        } catch {
            return .checkFailed(error)
        }
    }

    // MARK: - Helpers

    /// Parse a server timestamp string. Both fractional and plain
    /// ISO8601 forms are seen across our pull paths; try both. Falls
    /// back to `.distantPast` so a missing timestamp can't accidentally
    /// flag a conflict.
    private func parseTimestamp(_ raw: String?) -> Date {
        guard let s = raw else { return .distantPast }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return iso.date(from: s) ?? plain.date(from: s) ?? .distantPast
    }
}
