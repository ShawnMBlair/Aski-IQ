// RevisionService.swift
// Aski IQ — Immutable revision history for Quotes and Estimates.
//
// WHY THIS EXISTS
// The 2026-04-28 strategy report (§16 Phase 1.B) flagged version history as
// a P0 gap before beta — every competitor lets you see what an estimate
// looked like before you cut the markup or before the client haggled. Our
// AuditSnapshot table captures generic events; this is a typed, queryable
// snapshot specifically for the two financially load-bearing entities.
//
// DESIGN
//   - Tables `quote_revisions` and `estimate_revisions` (Supabase) hold a
//     JSON snapshot of the parent record at the moment of each transition.
//   - Revisions are immutable: no update / delete RLS policies on the tables.
//   - Revision numbers are monotonic per-parent, starting at 1.
//   - Snapshots are written BEFORE state-changing transitions, so the new
//     state is what's saved on the parent and the snapshot is what was true
//     immediately prior — letting compliance reconstruct "what did the client
//     see at quote-sent time?".
//
// USAGE
//   try await RevisionService.shared.snapshotQuote(quote, summary: "Sent to client")
//   let revs = try await RevisionService.shared.loadRevisions(forQuote: quote.id)

import Foundation
import Supabase

@MainActor
final class RevisionService {

    static let shared = RevisionService()
    private init() {}

    // MARK: - Models

    struct QuoteRevision: Identifiable, Codable {
        let id:              UUID
        let quoteID:         UUID
        let companyID:       UUID
        let revisionNumber:  Int
        let snapshotJSON:    String
        let changeSummary:   String?
        let createdAt:       Date
        let createdBy:       String
    }

    struct EstimateRevision: Identifiable, Codable {
        let id:              UUID
        let estimateID:      UUID
        let companyID:       UUID
        let revisionNumber:  Int
        let snapshotJSON:    String
        let changeSummary:   String?
        let createdAt:       Date
        let createdBy:       String
    }

    // MARK: - Snapshot creation

    /// Snapshot the current state of a Quote. Idempotent on no-op transitions —
    /// callers should only invoke this when something materially changed.
    /// Best-effort: failure is logged but not surfaced to the user, so a
    /// transient network error doesn't block the underlying save.
    func snapshotQuote(_ quote: Quote, summary: String? = nil) async {
        guard let companyID = AppStore.shared.currentCompanyID else { return }
        let nextRev = await nextRevisionNumber(forQuote: quote.id)
        let snapshot = encode(quote)
        let by = AppStore.shared.currentUser?.fullName ?? ""

        struct Row: Codable {
            let id:              String
            let quote_id:        String
            let company_id:      String
            let revision_number: Int
            let snapshot_json:   String
            let change_summary:  String?
            let created_by:      String
        }
        let row = Row(
            id:              UUID().uuidString,
            quote_id:        quote.id.uuidString,
            company_id:      companyID.uuidString,
            revision_number: nextRev,
            snapshot_json:   snapshot,
            change_summary:  summary,
            created_by:      by
        )
        do {
            try await supabase.from(SupabaseTable.quoteRevisions).insert(row).execute()
        } catch {
            // Log but don't throw — revision history is best-effort.
            print("[RevisionService] snapshotQuote failed: \(error)")
        }
    }

    /// Snapshot the current state of an Estimate. Same semantics as snapshotQuote.
    func snapshotEstimate(_ estimate: Estimate, summary: String? = nil) async {
        guard let companyID = AppStore.shared.currentCompanyID else { return }
        let nextRev = await nextRevisionNumber(forEstimate: estimate.id)
        let snapshot = encode(estimate)
        let by = AppStore.shared.currentUser?.fullName ?? ""

        struct Row: Codable {
            let id:              String
            let estimate_id:     String
            let company_id:      String
            let revision_number: Int
            let snapshot_json:   String
            let change_summary:  String?
            let created_by:      String
        }
        let row = Row(
            id:              UUID().uuidString,
            estimate_id:     estimate.id.uuidString,
            company_id:      companyID.uuidString,
            revision_number: nextRev,
            snapshot_json:   snapshot,
            change_summary:  summary,
            created_by:      by
        )
        do {
            try await supabase.from(SupabaseTable.estimateRevisions).insert(row).execute()
        } catch {
            print("[RevisionService] snapshotEstimate failed: \(error)")
        }
    }

    // MARK: - Load

    func loadRevisions(forQuote id: UUID) async throws -> [QuoteRevision] {
        struct Row: Codable {
            let id:              String
            let quote_id:        String
            let company_id:      String
            let revision_number: Int
            let snapshot_json:   String
            let change_summary:  String?
            let created_at:      String
            let created_by:      String
        }
        let rows: [Row] = try await supabase
            .from(SupabaseTable.quoteRevisions)
            .select()
            .eq("quote_id", value: id.uuidString)
            .order("revision_number", ascending: false)
            .execute()
            .value

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        return rows.compactMap { row -> QuoteRevision? in
            guard let revID = UUID(uuidString: row.id),
                  let qid   = UUID(uuidString: row.quote_id),
                  let cid   = UUID(uuidString: row.company_id) else { return nil }
            let date = iso.date(from: row.created_at)
                    ?? isoFallback.date(from: row.created_at)
                    ?? Date()
            return QuoteRevision(
                id:              revID,
                quoteID:         qid,
                companyID:       cid,
                revisionNumber:  row.revision_number,
                snapshotJSON:    row.snapshot_json,
                changeSummary:   row.change_summary,
                createdAt:       date,
                createdBy:       row.created_by
            )
        }
    }

    func loadRevisions(forEstimate id: UUID) async throws -> [EstimateRevision] {
        struct Row: Codable {
            let id:              String
            let estimate_id:     String
            let company_id:      String
            let revision_number: Int
            let snapshot_json:   String
            let change_summary:  String?
            let created_at:      String
            let created_by:      String
        }
        let rows: [Row] = try await supabase
            .from(SupabaseTable.estimateRevisions)
            .select()
            .eq("estimate_id", value: id.uuidString)
            .order("revision_number", ascending: false)
            .execute()
            .value

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        return rows.compactMap { row -> EstimateRevision? in
            guard let revID = UUID(uuidString: row.id),
                  let eid   = UUID(uuidString: row.estimate_id),
                  let cid   = UUID(uuidString: row.company_id) else { return nil }
            let date = iso.date(from: row.created_at)
                    ?? isoFallback.date(from: row.created_at)
                    ?? Date()
            return EstimateRevision(
                id:              revID,
                estimateID:      eid,
                companyID:       cid,
                revisionNumber:  row.revision_number,
                snapshotJSON:    row.snapshot_json,
                changeSummary:   row.change_summary,
                createdAt:       date,
                createdBy:       row.created_by
            )
        }
    }

    // MARK: - Helpers

    private func nextRevisionNumber(forQuote id: UUID) async -> Int {
        struct R: Codable { let revision_number: Int }
        do {
            let rows: [R] = try await supabase
                .from(SupabaseTable.quoteRevisions)
                .select("revision_number")
                .eq("quote_id", value: id.uuidString)
                .order("revision_number", ascending: false)
                .limit(1)
                .execute()
                .value
            return (rows.first?.revision_number ?? 0) + 1
        } catch {
            return 1
        }
    }

    private func nextRevisionNumber(forEstimate id: UUID) async -> Int {
        struct R: Codable { let revision_number: Int }
        do {
            let rows: [R] = try await supabase
                .from(SupabaseTable.estimateRevisions)
                .select("revision_number")
                .eq("estimate_id", value: id.uuidString)
                .order("revision_number", ascending: false)
                .limit(1)
                .execute()
                .value
            return (rows.first?.revision_number ?? 0) + 1
        } catch {
            return 1
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
